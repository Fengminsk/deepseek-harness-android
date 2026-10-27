import assert from 'node:assert/strict'
import test from 'node:test'
import { PassThrough } from 'node:stream'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { createAcceptanceCallbackRouting } from './device-runtime-acceptance/callback-routing.mjs'
import { NativeWorkflowGuestCallbacks } from '../runtime/native-workflow-guest-callbacks.mjs'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'

const requireStaged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const staged = name => import(pathToFileURL(requireStaged.resolve(name)).href)
const [{ Context }, { JsonRpcLineTransport }, { default: SystemPrompt }, { default: ToolRuntime, defineTool }] =
  await Promise.all([staged('@deepseek-ai/cordis'), staged('@deepseek-ai/dsh-sdk-protocol'),
    staged('@deepseek-ai/dsh-system-prompt'), staged('@deepseek-ai/dsh-tools')])

const runId = '00000000-0000-4000-8000-000000000079'
const token = 'app-private-callback-token'
const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

function rpcPair() {
  const up = new PassThrough(), down = new PassThrough()
  const node = new JsonRpcLineTransport(up, down)
  const native = new JsonRpcLineTransport(down, up)
  node.start(); native.start()
  return { node, native, close() { node.close(); native.close(); up.destroy(); down.destroy() } }
}

for (const kind of ['workflow', 'tool']) {
  test(`${kind} call and retirement cross RPC while the Cordis acceptance fiber is still pending`, async t => {
    const ctx = new Context()
    const ready = deferred(), finish = deferred(), finished = deferred()
    let pair, root, started = false
    t.after(async () => {
      // Disposal waits for the async inject fiber. Release it first even if an
      // assertion or RPC fails, keeping its transport alive through retirement.
      finish.resolve()
      try { if (started) await finished.promise }
      finally {
        try { await ctx.fiber.dispose() }
        finally {
          pair?.close()
          if (root) await rm(root, { recursive: true, force: true })
        }
      }
    })
    await ctx.plugin(SystemPrompt)
    await ctx.plugin(ToolRuntime)
    pair = rpcPair()
    const { node, native } = pair
    const routing = createAcceptanceCallbackRouting()
    const methods = []
    native.onRequest(async method => { methods.push(method); return true })
    node.onRequest((method, params) => routing.dispatch(method, params))
    let callbacks, unbind
    if (kind === 'tool') {
      root = await mkdtemp(join(tmpdir(), 'dsh-device-callback-'))
      ctx.tools.register(defineTool({ name: 'safe_echo', description: 'RPC fixture echo',
        parameters: { text: { type: 'string', required: true } },
        output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
        async execute(args) { return args.text },
      }))
    }
    const events = []
    started = true
    ctx.inject([], async pendingCtx => {
      try {
        callbacks = kind === 'workflow' ? new NativeWorkflowGuestCallbacks(node)
          : new NativeIsolatedToolCallbacks(node, new IsolatedToolCallJournal(root))
        // This is the old fixture's precise failure condition. The strict
        // lookup remains unavailable until the async inject callback returns.
        pendingCtx.provide('pendingAcceptanceCallbacks', callbacks)
        unbind = routing.bind(kind, callbacks)
        if (kind === 'workflow') {
          await callbacks.bind({ prepared: { kind, runId, program: 'return 42', args: {},
            deadlineMillis: 5000, meta: { name: 'compute' }, maxTotalAgents: 2, maxConcurrentAgents: 1 },
            admission: { runId, token }, authorizeChild: async () => true,
            activateChild: async () => { throw new Error('Compute must not launch a child') },
            onProgress: async () => {},
          })
        } else {
          await callbacks.bind({ prepared: { kind: 'script', runId, sessionId: runId, scope: {
            ownerId: 'host', sessionId: runId, version: 1, workspaceId: null,
            readablePaths: [], writablePaths: [], exactHosts: [], fileCallLimit: 0,
            networkCallLimit: 0, leaseMillis: 5000,
          } }, admission: { runId, token }, runtime: ctx.tools,
          parent: { token: Symbol('outer'), callId: 'parent', signal: new AbortController().signal,
            agent: { session: { id: runId, append(type, data) { events.push({ type, data }) } } } },
          allowedToolNames: ['safe_echo'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }) })
        }
        ready.resolve()
        await finish.promise
      } catch (error) { ready.reject(error); finished.reject(error) }
      finally {
        try { await callbacks?.dispose() } finally { unbind?.(); finished.resolve() }
      }
    })
    await ready.promise
    assert.equal(ctx.get('pendingAcceptanceCallbacks'), undefined)
    assert.ok(ctx.get('pendingAcceptanceCallbacks', false))
    node.onRequest((_method, params) => ctx.get('pendingAcceptanceCallbacks').call(params))
    await assert.rejects(native.request(`native.${kind}Callback`, { runId, token }), /undefined/)
    node.onRequest((method, params) => routing.dispatch(method, params))
    const reply = await native.request(`native.${kind}Callback`, { runId, token, callId: 1,
      ...(kind === 'workflow' ? { action: 'WORKFLOW_BEGIN', value: {} }
        : { name: 'safe_echo', arguments: { text: 'real ToolRuntime reply' } }) })
    assert.equal(reply.runId, runId)
    assert.equal(reply.callId, 1)
    if (kind === 'workflow') {
      assert.deepEqual(reply.value, { meta: { name: 'compute' }, args: {}, limits: {
        maxTotalAgents: 2, maxConcurrentAgents: 1, maxItemsPerCall: 32, syncTimeoutMs: 5000,
      } })
      assert.equal(Object.hasOwn(reply.value, 'body'), false)
    }
    else {
      assert.equal(reply.value, 'real ToolRuntime reply')
      assert.deepEqual(events.map(event => event.type), ['tool/ptc-dispatch-start', 'tool/ptc-dispatch'])
    }
    assert.deepEqual(await native.request(`native.${kind}Callback.cancel`, { runId, token }), { closed: true })
    assert.equal(ctx.get('pendingAcceptanceCallbacks'), undefined)
    assert.deepEqual(methods, [kind === 'workflow' ? 'native.workflow.bindCallbacks' : 'native.isolated.bindTools'])
    finish.resolve(); await finished.promise
    await assert.rejects(native.request(`native.${kind}Callback.cancel`, { runId, token }), /owner is unavailable/)
  })
}

test('routing rejects a missing or replaced owner without accepting retirement', async () => {
  const routing = createAcceptanceCallbackRouting()
  await assert.rejects(routing.dispatch('native.toolCallback.cancel', {}), /unavailable/)
  await assert.rejects(routing.dispatch('native.unknown', {}), /Unexpected/)
  const owner = { call: async params => params, close: async () => { throw new Error('retirement not confirmed') } }
  const remove = routing.bind('tool', owner)
  assert.throws(() => routing.bind('tool', owner), /duplicate/)
  await assert.rejects(routing.dispatch('native.toolCallback.cancel', {}), /retirement not confirmed/)
  remove()
  const replacement = { call: async () => 'new owner', close: async () => ({ closed: true }) }
  routing.bind('tool', replacement)
  remove()
  assert.equal(await routing.dispatch('native.toolCallback', {}), 'new owner')
})
