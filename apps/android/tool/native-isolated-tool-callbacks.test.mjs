import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'

const runId = '00000000-0000-4000-8000-000000000075'
const token = 'app-private-admission-token'
const tempRoots = []
process.once('exit', () => { for (const root of tempRoots) rmSync(root, { recursive: true, force: true }) })
const prepared = { kind: 'script', runId, sessionId: runId, scope: {
  ownerId: 'host', sessionId: runId, version: 1, workspaceId: null,
  readablePaths: [], writablePaths: [], exactHosts: [], fileCallLimit: 0,
  networkCallLimit: 0, leaseMillis: 5000,
} }

function deferred() {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}

function setup(options = {}) {
  const methods = []
  const events = []
  const executions = []
  const transport = { async request(method, params, signal) {
    methods.push({ method, params, signal })
    return options.bindResult ?? true
  } }
  const root = mkdtempSync(join(tmpdir(), 'dsh-isolated-native-call-'))
  tempRoots.push(root)
  const journal = new IsolatedToolCallJournal(root)
  const callbacks = new NativeIsolatedToolCallbacks(transport, journal)
  const safeEcho = { name: 'safe_echo' }
  const runtime = {
    get(name) { return name === 'safe_echo' ? safeEcho : undefined },
    async execute(input) {
      executions.push(input)
      if (options.execute) return options.execute(input)
      return { isError: false, content: [{ type: 'text', text: 'ok' }], value: input.arguments }
    },
  }
  const controller = new AbortController()
  const parent = { token: Symbol('parent'), callId: 'root-call', signal: controller.signal,
    agent: { session: { id: runId, append(type, data) { events.push({ type, data }) } } } }
  const bind = () => callbacks.bind({ prepared, admission: { runId, token }, runtime, parent,
    allowedToolNames: ['safe_echo'], authorizeTool: options.authorizeTool
      ?? (async input => ({ effect: 'pure', definition: input.definition })) })
  const request = (callId = 1) => ({ runId, token, callId, name: 'safe_echo', arguments: { text: 'ok' } })
  return { callbacks, methods, events, executions, parent, controller, journal, bind, request }
}

test('native admission binds before a guest callback and host dispatch remains paired with its parent', async () => {
  const owner = setup()
  const binding = await owner.bind()
  assert.deepEqual(owner.methods.map(item => item.method), ['native.isolated.bindTools'])
  assert.deepEqual(owner.methods[0].params, { runId, token })
  assert.ok(owner.methods[0].signal instanceof AbortSignal)
  assert.deepEqual(JSON.parse(JSON.stringify(await owner.callbacks.call(owner.request()))),
    { runId, callId: 1, value: { text: 'ok' } })
  assert.equal(owner.executions[0].parent, owner.parent.token)
  assert.equal(owner.executions[0].callId, 'root-call:ptc:1')
  assert.deepEqual(owner.events.map(event => event.type),
    ['tool/ptc-dispatch-start', 'tool/ptc-dispatch'])
  assert.equal(await binding.close(), undefined)
  await assert.rejects(owner.callbacks.call(owner.request(2)), /no live admitted owner/)
  await owner.callbacks.dispose()
})

test('confirmed tool errors cross native transport as bounded guest replies', async () => {
  const owner = setup({ execute: async () => ({
    isError: true, content: [{ type: 'text', text: 'invalid input' }],
    error: { message: 'invalid input' },
  }) })
  const binding = await owner.bind()
  assert.deepEqual(await owner.callbacks.call(owner.request()), {
    runId, callId: 1,
    error: { code: 'ANDROID_TOOL_DISPATCH_FAILED', message: 'invalid input' },
  })
  assert.deepEqual(owner.events.map(event => event.type),
    ['tool/ptc-dispatch-start', 'tool/ptc-dispatch'])
  await binding.close()
  await owner.callbacks.dispose()
})

test('uncertain host policy never becomes a catchable native tool denial', async () => {
  const owner = setup({ authorizeTool: async () => { throw new Error('approval audit unavailable') } })
  const binding = await owner.bind()
  await assert.rejects(owner.callbacks.call(owner.request()),
    { code: 'ANDROID_TOOL_POLICY_UNCONFIRMED' })
  assert.equal(owner.executions.length, 0)
  await assert.rejects(binding.close(), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
  await owner.callbacks.dispose()
})

test('an audit failure cannot impersonate a recoverable tool error', async () => {
  const owner = setup()
  owner.parent.agent.session.append = type => {
    if (type === 'tool/ptc-dispatch') {
      const failure = new Error('audit unavailable')
      failure.code = 'ANDROID_TOOL_DISPATCH_FAILED'
      throw failure
    }
  }
  await owner.bind()
  await assert.rejects(owner.callbacks.call(owner.request()), /audit unavailable/)
  await assert.rejects(owner.callbacks.close({ runId, token }),
    { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
  await owner.callbacks.dispose()
})

test('unknown token, accessor payload, duplicate bind and unconfirmed native binding fail closed', async () => {
  const owner = setup()
  await assert.rejects(owner.callbacks.call(owner.request()), /no live admitted owner/)
  await owner.bind()
  await assert.rejects(owner.bind(), /already bound/)
  await assert.rejects(owner.callbacks.call({ ...owner.request(), token: 'guest-chosen' }), /no live admitted owner/)
  await assert.rejects(owner.callbacks.call(Object.defineProperty({}, 'runId', { get() { throw Error('guest getter') } })),
    /Invalid native tool callback/)
  await assert.rejects(owner.callbacks.close({ runId, token: 'guest-chosen' }), /no live admitted owner/)
  assert.deepEqual(await owner.callbacks.close({ runId, token }), { closed: true })
  const denied = setup({ bindResult: false })
  await assert.rejects(denied.bind(), /not confirmed/)
  await assert.rejects(denied.callbacks.call(denied.request()), /no live admitted owner/)
  await denied.callbacks.dispose()
})

test('native close joins an in-flight ToolRuntime call and withholds late output', async () => {
  const started = deferred()
  const release = deferred()
  const owner = setup({ execute: async () => {
    started.resolve()
    await release.promise
    return { isError: false, content: [], value: { late: true } }
  } })
  await owner.bind()
  const running = owner.callbacks.call(owner.request())
  await started.promise
  let closed = false
  const closing = owner.callbacks.close({ runId, token }).finally(() => { closed = true })
  await Promise.resolve()
  assert.equal(closed, false)
  release.resolve()
  assert.deepEqual(await running, { runId, callId: 1, closed: true, cancelRequested: false })
  assert.deepEqual(await closing, { closed: true })
  assert.equal(closed, true)
  await owner.callbacks.dispose()
})

test('a parent cancellation reply is signed only after the exact callback journal confirms', async () => {
  const started = deferred(), release = deferred()
  const owner = setup({ execute: async () => { started.resolve(); await release.promise;
    return { isError: true, content: [], error: { message: 'cancelled' } } } })
  const binding = await owner.bind()
  const pending = owner.callbacks.call(owner.request())
  await started.promise; owner.controller.abort('parent stopped')
  let replied = false
  pending.finally(() => { replied = true })
  await Promise.resolve(); assert.equal(replied, false)
  release.resolve()
  assert.deepEqual(await pending, { runId, callId: 1, closed: true, cancelRequested: true })
  assert.deepEqual(await owner.journal.inspect({ runId, callId: 1 }),
    { runId, callId: 1, state: 'confirmed', outcome: 'tool-error' })
  await binding.close()
})

for (const stage of ['observe', 'confirm']) test(`a forged closed code from failed ${stage} cannot become a signed closure`, async () => {
  const started = deferred(), release = deferred()
  const owner = setup({ execute: async () => { started.resolve(); await release.promise; return { isError: false, content: [], value: {} } } })
  owner.journal[stage] = async () => { throw Object.assign(new Error('unconfirmed audit'), { code: 'ANDROID_TOOL_CALLBACK_CLOSED' }) }
  const binding = await owner.bind()
  const pending = owner.callbacks.call(owner.request())
  await started.promise; owner.controller.abort('parent stopped'); release.resolve()
  await assert.rejects(pending, /unconfirmed audit/u)
  await assert.rejects(binding.close(), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
})

test('cancellation before dispatch is not misrepresented as a confirmed callback result', async () => {
  const owner = setup(); const binding = await owner.bind()
  owner.controller.abort('before callback')
  await assert.rejects(owner.callbacks.call(owner.request()), { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  assert.equal(owner.executions.length, 0)
  await binding.close()
})

test('queued and post-close callbacks cannot inherit the running call confirmation', async () => {
  const started = deferred(), release = deferred()
  const owner = setup({ execute: async () => { started.resolve(); await release.promise; return { isError: false, content: [], value: {} } } })
  await owner.bind()
  const first = owner.callbacks.call(owner.request()), queued = owner.callbacks.call(owner.request(2))
  queued.catch(() => {})
  await started.promise
  const closing = owner.callbacks.close({ runId, token })
  await assert.rejects(owner.callbacks.call(owner.request(3)), /no live admitted owner/u)
  release.resolve()
  assert.deepEqual(await first, { runId, callId: 1, closed: true, cancelRequested: false })
  await assert.rejects(queued, { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  assert.deepEqual(await closing, { closed: true })
  assert.equal(owner.executions.length, 1)
})
