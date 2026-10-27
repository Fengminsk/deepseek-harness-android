import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { IsolatedToolCallPort, reviewedToolProjectionError } from '../runtime/isolated-tool-call-port.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'

const RUN_ID = '00000000-0000-4000-8000-000000000001'
const tempRoots = []
process.once('exit', () => { for (const root of tempRoots) rmSync(root, { recursive: true, force: true }) })
const journal = () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-isolated-call-'))
  tempRoots.push(root)
  return new IsolatedToolCallJournal(root)
}

function prepared() {
  return { kind: 'script', runId: RUN_ID, sessionId: RUN_ID, scope: {
    ownerId: 'host', sessionId: RUN_ID, version: 1, workspaceId: null,
    readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
  } }
}

function deferred() {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}

function setup(options = {}) {
  const events = []
  const inputs = []
  const visible = new Set(['safe_echo', 'another_tool'])
  const definitions = new Map([...visible].map(name => [name, { name }]))
  const parentController = new AbortController()
  const runtime = {
    get(name) { return visible.has(name) ? definitions.get(name) : undefined },
    async execute(input) {
      inputs.push(input)
      return options.execute?.(input) ?? {
        isError: false, content: [{ type: 'text', text: 'ok' }],
        value: { echo: input.arguments },
      }
    },
  }
  const parent = {
    token: Symbol('registry-owned-parent'), callId: 'outer', rootCallId: 'root',
    signal: parentController.signal,
    agent: { session: { id: RUN_ID, append(type, data) {
      if (options.append) options.append(type, data)
      events.push({ type, data })
    } } },
  }
  const port = new IsolatedToolCallPort({
    prepared: prepared(),
    admission: { runId: RUN_ID, token: 'native-admission' },
    runtime, parent, allowedToolNames: ['safe_echo', 'another_tool'],
    authorizeTool: options.authorizeTool ?? (async input => ({
      effect: 'pure', definition: input.definition,
    })),
    journal: options.journal ?? journal(),
  })
  return { port, events, inputs, visible, definitions, parentController, runtime, parent }
}

function call(name = 'safe_echo', args = { text: 'hello' }, callId = 1) {
  return { runId: RUN_ID, callId, name, arguments: args }
}

test('dispatch is parent owned, policy routed, serial and audited before guest output', async () => {
  const first = deferred()
  const started = deferred()
  let count = 0
  const { port, events, inputs } = setup({ execute: async input => {
    if (++count === 1) { started.resolve(); await first.promise }
    return { isError: false, content: [{ type: 'text', text: 'ok' }], value: input.arguments }
  } })
  const args = { nested: { a: 1 } }
  const one = port.call(call('safe_echo', args))
  const two = port.call(call('another_tool', { n: 2 }, 2))
  args.nested.a = 9
  await started.promise
  assert.equal(inputs.length, 1)
  first.resolve()
  assert.deepEqual(JSON.parse(JSON.stringify(await one)), { nested: { a: 1 } })
  assert.deepEqual(JSON.parse(JSON.stringify(await two)), { n: 2 })
  assert.deepEqual(events.map(event => event.type), [
    'tool/ptc-dispatch-start', 'tool/ptc-dispatch',
    'tool/ptc-dispatch-start', 'tool/ptc-dispatch',
  ])
  assert.equal(inputs[0].parent, inputs[1].parent)
  assert.equal(inputs[0].rootCallId, 'root')
  assert.equal(inputs[1].callId, 'outer:ptc:2')
  await port.close()
})

test('cross-run callback, forbidden tool and accessor payload cannot enter registry', async () => {
  const { port, inputs } = setup()
  assert.throws(() => port.call({ ...call(), runId: 'other' }), { code: 'ANDROID_TOOL_OWNER_INVALID' })
  assert.throws(() => port.call(call('run_code', {}, 2)), { code: 'ANDROID_TOOL_NOT_GRANTED' })
  assert.throws(() => port.call(call('android_shell', {}, 3)), { code: 'ANDROID_TOOL_NOT_GRANTED' })
  assert.throws(() => port.call(Object.defineProperty({}, 'runId', { get() { throw Error('getter') } })),
    { code: 'ANDROID_TOOL_CALLBACK_INVALID' })
  assert.throws(() => port.call(call('safe_echo', { get secret() { throw Error('getter') } }, 5)),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.equal(inputs.length, 0)
  await port.close()
})

test('revoked visibility is checked after prior call settles', async () => {
  const first = deferred()
  const { port, visible, inputs } = setup({ execute: async input => {
    await first.promise
    return { isError: false, content: [], value: input.arguments }
  } })
  const one = port.call(call())
  const two = port.call(call('another_tool', {}, 2))
  await Promise.resolve()
  visible.delete('another_tool')
  first.resolve()
  await one
  await assert.rejects(two, { code: 'ANDROID_TOOL_NOT_GRANTED' })
  assert.equal(inputs.length, 1)
  await port.close()
})

test('cancellation joins running tool and withholds its late value', async () => {
  const release = deferred()
  const started = deferred()
  const { port, inputs } = setup({ execute: async input => {
    started.resolve()
    await release.promise
    return { isError: false, content: [], value: { leaked: true } }
  } })
  const running = port.call(call())
  await started.promise
  const queued = port.call(call('another_tool', {}, 2))
  const closing = port.close('guest exited')
  release.resolve()
  await assert.rejects(running, { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  await assert.rejects(queued, { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  await assert.rejects(closing, { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
  assert.equal(inputs.length, 1)
})

test('an audit append failure before dispatch stops the tool', async () => {
  const { port, inputs } = setup({ append(type) {
    if (type === 'tool/ptc-dispatch-start') throw Error('journal unavailable')
  } })
  await assert.rejects(port.call(call()), /journal unavailable/)
  assert.equal(inputs.length, 0)
  await assert.rejects(port.close(), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
})

test('oversized output is recorded as a bounded bridge failure and never reaches the guest', async () => {
  const huge = 'x'.repeat(200 * 1024)
  const { port, events } = setup({ execute: async () => ({
    isError: false, content: [{ type: 'text', text: huge }], value: { leaked: huge },
  }) })
  await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_RESULT_UNSUPPORTED' })
  const settled = events.find(event => event.type === 'tool/ptc-dispatch')
  assert.equal(settled.data.isError, true)
  assert.equal(settled.data.error.code, 'ANDROID_TOOL_RESULT_UNSUPPORTED')
  assert.ok(JSON.stringify(settled.data).length < 1024)
  await port.close()
})

test('oversized guest value is confirmed as unsupported and does not poison later calls', async () => {
  const callJournal = journal()
  let count = 0
  const { port, events } = setup({ journal: callJournal, execute: async input => ++count === 1
    ? { isError: false, content: [{ type: 'text', text: 'bounded audit' }],
      value: { large: 'x'.repeat(65 * 1024) } }
    : { isError: false, content: [], value: input.arguments } })
  await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_RESULT_UNSUPPORTED' })
  assert.deepEqual(await callJournal.inspect({ runId: RUN_ID, callId: 1 }), {
    runId: RUN_ID, callId: 1, state: 'confirmed', outcome: 'unsupported',
  })
  assert.equal(events[1].data.isError, true)
  assert.equal(events[1].data.error.code, 'ANDROID_TOOL_RESULT_UNSUPPORTED')
  assert.deepEqual(JSON.parse(JSON.stringify(await port.call(call('safe_echo', { next: true }, 2)))),
    { next: true })
  await port.close()
})

test('only privately registered bounded projection hints reach guest and durable audit', async t => {
  assert.throws(() => reviewedToolProjectionError('x'.repeat(4097)), /within 4 KiB/u)
  const reviewed = reviewedToolProjectionError('Request a smaller page')
  reviewed.message = 'untrusted replacement'
  for (const [error, expected] of [[reviewed, 'Request a smaller page'],
    [new TypeError('private path or unexpected detail'), 'Reviewed tool result could not be projected'],
    [{ message: 'forged recovery' }, 'Reviewed tool result could not be projected']]) {
    const { port, events } = setup({ authorizeTool: async input => ({
      effect: 'read-only', definition: input.definition, projectResult() { throw error },
    }) })
    t.after(() => port.close())
    await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_RESULT_UNSUPPORTED', message: expected })
    assert.equal(events.at(-1).data.error.reason, expected)
  }
})

test('unrepresentable guest values and oversized tool errors settle as unsupported', async () => {
  const callJournal = journal()
  const circular = {}
  circular.self = circular
  let count = 0
  const { port, events } = setup({ journal: callJournal, execute: async () => ++count === 1
    ? { isError: false, content: [], value: circular }
    : { isError: true, content: [], error: { message: 'x'.repeat(5 * 1024) } } })
  for (const callId of [1, 2]) {
    await assert.rejects(port.call(call('safe_echo', {}, callId)),
      { code: 'ANDROID_TOOL_RESULT_UNSUPPORTED' })
    assert.equal((await callJournal.inspect({ runId: RUN_ID, callId })).state, 'confirmed')
    assert.equal((await callJournal.inspect({ runId: RUN_ID, callId })).outcome, 'unsupported')
  }
  assert.equal(events.filter(event => event.type === 'tool/ptc-dispatch').length, 2)
  await port.close()
})

test('parent cancellation closes the lane and joins a running call', async () => {
  const release = deferred()
  const started = deferred()
  const { port, parentController } = setup({ execute: async () => {
    started.resolve()
    await release.promise
    return { isError: false, content: [], value: 'late' }
  } })
  const running = port.call(call())
  await started.promise
  parentController.abort('outer cancelled')
  release.resolve()
  await assert.rejects(running, { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  assert.throws(() => port.call(call()), { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  await assert.rejects(port.close(), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
})

test('matching admission and visible trusted allowlist are mandatory', () => {
  const { port, runtime, parent } = setup()
  assert.throws(() => new IsolatedToolCallPort({}), { code: 'ANDROID_TOOL_OWNER_INVALID' })
  assert.throws(() => new IsolatedToolCallPort({
    prepared: prepared(), admission: { runId: 'other', token: 'x' },
  }), { code: 'ANDROID_TOOL_OWNER_INVALID' })
  assert.throws(() => new IsolatedToolCallPort({
    prepared: prepared(), admission: { runId: RUN_ID, token: 'native-admission' },
    runtime, parent: { ...parent, agent: { session: { ...parent.agent.session, id: 'other' } } },
    allowedToolNames: ['safe_echo'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }),
  }), { code: 'ANDROID_TOOL_HOST_INVALID' })
  assert.throws(() => port.call(call('safe_echo', { value: Number.NaN })),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => new IsolatedToolCallPort({
    prepared: { ...prepared(), scope: { ...prepared().scope, readablePaths: ['a.txt'],
      workspaceId: RUN_ID, fileCallLimit: 1 } },
    admission: { runId: RUN_ID, token: 'native-admission' }, runtime, parent,
    allowedToolNames: ['safe_echo'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }),
  }), { code: 'ANDROID_TOOL_SCOPE_UNAVAILABLE' })
  visibleAmbient(runtime)
  assert.throws(() => new IsolatedToolCallPort({
    prepared: prepared(), admission: { runId: RUN_ID, token: 'native-admission' },
    runtime, parent, allowedToolNames: ['android_shell'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }),
  }), { code: 'ANDROID_TOOL_HOST_INVALID' })
  for (const name of ['android_linux', 'workflow', 'android_ptc']) {
    assert.throws(() => new IsolatedToolCallPort({
      prepared: prepared(), admission: { runId: RUN_ID, token: 'native-admission' },
      runtime: { ...runtime, get: requested => requested === name ? { name } : runtime.get(requested) },
      parent, allowedToolNames: [name], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }),
    }), { code: 'ANDROID_TOOL_HOST_INVALID' })
  }
})

function visibleAmbient(runtime) {
  const get = runtime.get
  runtime.get = (name, agent) => name === 'android_shell' ? { name } : get(name, agent)
}

test('host policy is rechecked immediately before each queued dispatch', async () => {
  const first = deferred()
  const started = deferred()
  const seen = []
  let authorized = 'pure'
  const { port, inputs } = setup({
    authorizeTool: async input => {
      seen.push(input)
      return authorized ? { effect: authorized, definition: input.definition } : null
    },
    execute: async input => {
      if (inputs.length === 1) { started.resolve(); await first.promise }
      return { isError: false, content: [], value: input.arguments }
    },
  })
  const one = port.call(call())
  const two = port.call(call('another_tool', {}, 2))
  await started.promise
  authorized = false
  first.resolve()
  await one
  await assert.rejects(two, { code: 'ANDROID_TOOL_NOT_GRANTED' })
  assert.equal(inputs.length, 1)
  assert.equal(seen.length, 2)
  await port.close()
})

test('same-name replacement cannot inherit a previously reviewed guest grant', async () => {
  const { port, definitions, inputs } = setup()
  definitions.set('safe_echo', { name: 'safe_echo', execute: () => 'new implementation' })
  await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_NOT_GRANTED' })
  assert.equal(inputs.length, 0)
  await port.close()
})

test('generic allow=true cannot substitute for a read-only effect classification', async () => {
  const { port, inputs } = setup({ authorizeTool: async () => true })
  await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_NOT_GRANTED' })
  assert.equal(inputs.length, 0)
  await port.close()
})

test('effect label or classification for a different definition cannot authorize dispatch', async () => {
  for (const authorizeTool of [
    async () => 'pure',
    async () => ({ effect: 'read-only', definition: { name: 'safe_echo' } }),
    async input => ({ effect: 'write', definition: input.definition }),
    async input => Object.defineProperty({ definition: input.definition },
      'effect', { get() { throw new Error('classification getter') } }),
  ]) {
    const { port, inputs } = setup({ authorizeTool })
    await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_NOT_GRANTED' })
    assert.equal(inputs.length, 0)
    await port.close()
  }
})

test('uncertain policy review poisons the run without tool dispatch', async () => {
  const { port, inputs } = setup({ authorizeTool: async () => {
    throw new Error('approval audit unavailable')
  } })
  await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_POLICY_UNCONFIRMED' })
  assert.throws(() => port.call(call('safe_echo', {}, 2)),
    { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  await assert.rejects(port.close(), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
  assert.equal(inputs.length, 0)
})

test('denied callback attempts consume the run budget', async () => {
  const { port, inputs } = setup()
  for (let index = 0; index < 32; index += 1) {
    assert.throws(() => port.call(call('android_shell', {}, index + 1)),
      { code: 'ANDROID_TOOL_NOT_GRANTED' })
  }
  assert.throws(() => port.call(call()), { code: 'ANDROID_TOOL_LIMIT' })
  assert.equal(inputs.length, 0)
  await port.close()
})

test('replayed and skipped guest call IDs cannot repeat an effect', async () => {
  const { port, inputs } = setup()
  await port.call(call())
  assert.throws(() => port.call(call()), { code: 'ANDROID_TOOL_REPLAY' })
  assert.throws(() => port.call(call('safe_echo', {}, 4)), { code: 'ANDROID_TOOL_REPLAY' })
  await port.call(call('safe_echo', { text: 'next' }, 4))
  assert.equal(inputs.length, 2)
  assert.equal(inputs[1].callId, 'outer:ptc:4')
  await port.close()
})

test('materialized tool failure is audited and can be recovered by guest code', async () => {
  let count = 0
  const { port, events } = setup({ execute: async input => ++count === 1
    ? { isError: true, content: [{ type: 'text', text: 'denied' }], error: { message: 'denied' } }
    : { isError: false, content: [], value: input.arguments } })
  await assert.rejects(port.call(call()), { code: 'ANDROID_TOOL_DISPATCH_FAILED' })
  assert.deepEqual(JSON.parse(JSON.stringify(await port.call(call('another_tool', { okay: true }, 2)))),
    { okay: true })
  assert.equal(events.filter(event => event.type === 'tool/ptc-dispatch').length, 2)
  await port.close()
})

test('production ToolRuntime validates schema and routes the admitted callback through its pipeline', async t => {
  const requireStaged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
  const staged = specifier => import(pathToFileURL(requireStaged.resolve(specifier)).href)
  const [{ Context }, { default: SystemPrompt }, { default: ToolRuntime, defineTool }] =
    await Promise.all([
      staged('@deepseek-ai/cordis'),
      staged('@deepseek-ai/dsh-system-prompt'),
      staged('@deepseek-ai/dsh-tools'),
    ])
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  t.after(() => ctx.fiber.dispose())
  const remove = ctx.tools.register(defineTool({
    name: 'safe_echo', description: 'A real registry tool',
    parameters: { text: { type: 'string', required: true } },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute(args) { return args.text },
  }))
  const events = []
  const parent = {
    token: Symbol('outer execution'), callId: 'outer', rootCallId: 'root',
    signal: new AbortController().signal,
    agent: { session: { id: RUN_ID, append(type, data) { events.push({ type, data }) } } },
  }
  const port = new IsolatedToolCallPort({
    prepared: prepared(),
    admission: { runId: RUN_ID, token: 'native-admission' },
    runtime: ctx.tools, parent, allowedToolNames: ['safe_echo'],
    authorizeTool: async input => ({ effect: 'pure', definition: input.definition }),
    journal: journal(),
  })
  assert.equal(await port.call(call('safe_echo', { text: 'from registry' })), 'from registry')
  await assert.rejects(port.call(call('safe_echo', { wrong: 1 }, 2)),
    { code: 'ANDROID_TOOL_DISPATCH_FAILED' })
  assert.equal(events.filter(event => event.type === 'tool/ptc-dispatch').length, 2)
  remove()
  await assert.rejects(port.call(call('safe_echo', { text: 'revoked' }, 3)),
    { code: 'ANDROID_TOOL_NOT_GRANTED' })
  const replacement = ctx.tools.register(defineTool({
    name: 'safe_echo', description: 'A changed implementation',
    parameters: { text: { type: 'string', required: true } },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { return 'replacement must not run' },
  }))
  await assert.rejects(port.call(call('safe_echo', { text: 'same name' }, 4)),
    { code: 'ANDROID_TOOL_NOT_GRANTED' })
  replacement()
  await port.close()
})

test('production ToolRuntime rejects a same-name swap during Android callback policy', async t => {
  const requireStaged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
  const staged = specifier => import(pathToFileURL(requireStaged.resolve(specifier)).href)
  const [{ Context }, { default: SystemPrompt }, { default: ToolRuntime, defineTool }] =
    await Promise.all([
      staged('@deepseek-ai/cordis'),
      staged('@deepseek-ai/dsh-system-prompt'),
      staged('@deepseek-ai/dsh-tools'),
    ])
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  t.after(() => ctx.fiber.dispose())
  const entered = deferred()
  const release = deferred()
  let replacementCalls = 0
  const remove = ctx.tools.register(defineTool({
    name: 'safe_echo', description: 'Originally reviewed read-only tool',
    parameters: { text: { type: 'string', required: true } },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute(args) { return args.text },
  }))
  ctx.on('tools/pre-execute', async (_exec, next) => {
    entered.resolve()
    await release.promise
    return next()
  })
  const events = []
  const parent = {
    token: Symbol('outer execution'), callId: 'outer', rootCallId: 'root',
    signal: new AbortController().signal,
    agent: { session: { id: RUN_ID, append(type, data) { events.push({ type, data }) } } },
  }
  const port = new IsolatedToolCallPort({
    prepared: prepared(),
    admission: { runId: RUN_ID, token: 'native-admission' },
    runtime: ctx.tools, parent, allowedToolNames: ['safe_echo'],
    authorizeTool: async input => ({ effect: 'pure', definition: input.definition }),
    journal: journal(),
  })
  const running = port.call(call('safe_echo', { text: 'reviewed' }))
  try {
    await entered.promise
    remove()
    ctx.tools.register(defineTool({
      name: 'safe_echo', description: 'Later tool under the same name',
      parameters: { text: { type: 'string', required: true } },
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      async execute() { replacementCalls++; return 'must not run' },
    }))
    release.resolve()
    await assert.rejects(running, { code: 'ANDROID_TOOL_DISPATCH_FAILED' })
    assert.equal(replacementCalls, 0)
    assert.deepEqual(events.map(event => event.type), [
      'tool/ptc-dispatch-start', 'tool/ptc-dispatch',
    ])
    assert.equal(events[1].data.error.code, 'UNKNOWN_TOOL')
  } finally {
    release.resolve()
    await running.catch(() => {})
    await port.close()
  }
})
