import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { IsolatedToolCallPort, reviewedToolProjectionError, confirmedToolCallbackClosure } from '../runtime/isolated-tool-call-port.mjs'
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
  const visible = new Set(options.names ?? ['safe_echo', 'another_tool'])
  const definitions = new Map([...visible].map(name => [name, { name }]))
  const parentController = new AbortController()
  const runtime = {
    get(name) { return visible.has(name) ? definitions.get(name) : undefined },
    async execute(batch) {
      inputs.push(batch)
      const block = batch.calls[0]
      const single = {
        callId: block.id, name: block.name,
        arguments: JSON.parse(block.arguments),
        agent: batch.agent, signal: batch.signal,
      }
      const result = await (options.execute?.(single) ?? {
        isError: false, content: [{ type: 'text', text: 'ok' }],
        value: { echo: single.arguments },
      })
      return {
        results: [{ callId: block.id, result }],
        additionalContexts: [], concluded: false,
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
    deferContext(context) { contexts.push(context) },
  }
  const contexts = []
  const port = new IsolatedToolCallPort({
    prepared: { ...prepared(), kind: options.kind ?? 'script' },
    admission: { runId: RUN_ID, token: 'native-admission' },
    runtime, parent, allowedToolNames: [...visible],
    authorizeTool: options.authorizeTool ?? (async input => ({
      effect: 'pure', definition: input.definition,
    })),
    journal: options.journal ?? journal(),
  })
  return { port, events, inputs, visible, definitions, parentController, runtime, parent, contexts }
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
  assert.equal(inputs[0].agent, inputs[1].agent)
  assert.equal(inputs[0].calls[0].id, 'outer:ptc:1')
  assert.equal(inputs[1].calls[0].id, 'outer:ptc:2')
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
  const { port, inputs } = setup({ execute: async () => {
    started.resolve()
    await release.promise
    return { isError: false, content: [], value: { leaked: true } }
  } })
  const running = port.call(call())
  await started.promise
  const queued = port.call(call('another_tool', {}, 2))
  const closing = port.close('guest exited')
  release.resolve()
  await assert.rejects(running, error => {
    assert.equal(error.code, 'ANDROID_TOOL_CALLBACK_CLOSED')
    assert.deepEqual(confirmedToolCallbackClosure(error, RUN_ID, 1), { closed: true, cancelRequested: false })
    assert.equal(confirmedToolCallbackClosure(error, RUN_ID, 2), undefined)
    assert.equal(confirmedToolCallbackClosure(error, 'another-run', 1), undefined)
    assert.equal(confirmedToolCallbackClosure({ ...error }, RUN_ID, 1), undefined)
    return true
  })
  await assert.rejects(queued, { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  await closing
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
  await port.close()
})

for (const failedStage of ['observe', 'flush', 'confirm']) {
  test(`parent cancellation cannot confirm a Linux outcome after ${failedStage} failure`, async () => {
    const started = deferred(), release = deferred(), stored = journal()
    let flushes = 0
    const wrapped = Object.fromEntries(['prepare', 'dispatch', 'observe', 'confirm'].map(name => [name, async (...args) => {
      if (name === failedStage) throw new Error(`Deliberate ${failedStage} failure`)
      return stored[name](...args)
    }]))
    const { port, parentController } = setup({ kind: 'ptc', names: ['linux_exec'], journal: wrapped,
      authorizeTool: async input => ({ definition: input.definition, effect: 'isolated-execution',
        flushSession: async () => !(++flushes === 2 && failedStage === 'flush') }),
      execute: async () => { started.resolve(); await release.promise; return { isError: true,
        content: [{ type: 'text', text: 'cancelled' }], error: { message: 'cancelled', info: { code: 'ABORTED' } } } },
    })
    const running = port.call(call('linux_exec', { command: 'fixture:pending' }))
    await started.promise
    parentController.abort('parent cancelled')
    release.resolve()
    await assert.rejects(running)
    await assert.rejects(port.close(), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
    assert.notEqual((await stored.inspect({ runId: RUN_ID, callId: 1 })).state, 'confirmed')
  })
}

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
  assert.equal(inputs[1].calls[0].id, 'outer:ptc:4')
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
  const [{ Context }, { default: SystemPrompt }, { default: ToolRuntime, defineTool }, nativeExecutor] =
    await Promise.all([
      staged('@deepseek-ai/cordis'),
      staged('@deepseek-ai/dsh-system-prompt'),
      staged('@deepseek-ai/dsh-tools'),
      staged('@deepseek-ai/dsh-tool-executor-native'),
    ])
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  // The merged ToolRuntime dispatches through a mounted executor; production
  // composes the native executor, so this fixture does too.
  await ctx.plugin(nativeExecutor)
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
  const [{ Context }, { default: SystemPrompt }, { default: ToolRuntime, defineTool }, nativeExecutor] =
    await Promise.all([
      staged('@deepseek-ai/cordis'),
      staged('@deepseek-ai/dsh-system-prompt'),
      staged('@deepseek-ai/dsh-tools'),
      staged('@deepseek-ai/dsh-tool-executor-native'),
    ])
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  // The merged ToolRuntime dispatches through a mounted executor; production
  // composes the native executor, so this fixture does too.
  await ctx.plugin(nativeExecutor)
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

test('mutations require PTC, exact action classification and a durability barrier', async () => {
  assert.throws(() => setup({ names: ['write'] }), { code: 'ANDROID_TOOL_HOST_INVALID' })
  for (const name of ['linux_exec', 'linux_import', 'linux_export', 'linux_inspect']) {
    for (const kind of ['script', 'workflow']) assert.throws(() => setup({ names: [name], kind }), { code: 'ANDROID_TOOL_HOST_INVALID' })
  }
  for (const [name, args, effect, flush] of [
    ['write', {}, 'read-only', async () => true],
    ['edit', {}, 'pure', async () => true],
    ['android_attachments', { action: 'materialize' }, 'read-only', async () => true],
    ['android_attachments', { action: 'read' }, 'workspace-write', async () => true],
    ['write', {}, 'workspace-write', undefined],
    ['safe_echo', {}, 'workspace-write', async () => true],
    ['linux_exec', {}, 'read-only', async () => true],
    ['linux_import', {}, 'pure', async () => true],
    ['linux_export', {}, 'workspace-write', async () => true],
    ['linux_exec', {}, 'isolated-execution', undefined],
    ['linux_inspect', {}, 'isolated-execution', async () => true],
    ['safe_echo', {}, 'isolated-execution', async () => true],
  ]) {
    const { port, inputs } = setup({ kind: 'ptc', names: [name],
      authorizeTool: async input => ({ effect, definition: input.definition,
        ...(flush ? { flushSession: flush } : {}) }) })
    await assert.rejects(port.call(call(name, args)), { code: 'ANDROID_TOOL_NOT_GRANTED' })
    assert.equal(inputs.length, 0)
    await port.close()
  }
})

test('both mutation audit barriers must reach a durable Session before confirmation', async () => {
  for (const failAt of [1, 2]) {
    for (const throws of [false, true]) {
      const callJournal = journal()
      let flushes = 0
      const { port, inputs, events } = setup({ kind: 'ptc', names: ['write'], journal: callJournal,
        authorizeTool: async input => ({ effect: 'workspace-write', definition: input.definition,
          async flushSession() {
            if (++flushes === failAt) {
              if (throws) throw new Error('durability failure')
              return false
            }
            return true
          } }),
        execute: async () => ({ isError: false, content: [], value: { path: '/workspace/created.txt' } }),
      })
      await assert.rejects(port.call(call('write', { file_path: 'created.txt' })),
        { code: 'ANDROID_TOOL_SESSION_UNCONFIRMED' })
      assert.equal(inputs.length, failAt - 1)
      assert.equal(events.length, failAt)
      assert.equal((await callJournal.inspect({ runId: RUN_ID, callId: 1 })).state,
        failAt === 1 ? 'prepared' : 'result-unconfirmed')
      await assert.rejects(port.close(), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
    }
  }
})

test('projected mutation keeps host metadata and forwards deferred contexts unchanged', async () => {
  const context = Object.freeze({ role: 'user', id: 'receipt', source: { kind: 'test-receipt' },
    content: [{ type: 'text', text: 'Committed /workspace/created.txt' }] })
  const meta = { path: '/workspace/created.txt', diff: '+hello' }
  let flushes = 0
  const { port, events, contexts } = setup({ kind: 'ptc', names: ['write'],
    authorizeTool: async input => ({ effect: 'workspace-write', definition: input.definition,
      projectResult: value => ({ path: value.path }), async flushSession() { flushes++; return true } }),
    execute: async () => ({ isError: false, content: [], value: { path: meta.path, after: 'hello' },
      meta, additionalContexts: [context] }),
  })
  assert.deepEqual(JSON.parse(JSON.stringify(await port.call(call('write', { file_path: 'created.txt' })))),
    { path: meta.path })
  assert.equal(flushes, 2)
  assert.equal(contexts[0], context)
  assert.deepEqual(JSON.parse(JSON.stringify(events[1].data.meta)), meta)
  assert.equal(events[1].data.mutation.status, 'completed')
  assert.equal(events[1].data.additionalContexts[0].id, context.id)
  await port.close()
})

test('mutation errors and unsupported metadata retain paths and require verification before retry', async () => {
  for (const toolError of [false, true]) {
    const callJournal = journal()
    const { port, events, contexts } = setup({ kind: 'ptc', names: ['edit'], journal: callJournal,
      authorizeTool: async input => ({ effect: 'workspace-write', definition: input.definition,
        projectResult: value => ({ path: value.path }), flushSession: async () => true }),
      execute: async () => toolError
        ? { isError: true, content: [], error: { message: 'observer failed', info: { code: 'OBSERVATION_FAILED' } } }
        : { isError: false, content: [], value: { path: '/workspace/changed.txt' },
          meta: { path: '/workspace/changed.txt', diff: 'x'.repeat(140 * 1024) } },
    })
    await assert.rejects(port.call(call('edit', { file_path: 'changed.txt' })), error =>
      error.code === (toolError ? 'ANDROID_TOOL_DISPATCH_FAILED' : 'ANDROID_TOOL_RESULT_UNSUPPORTED')
      && /may have changed.*Verify.*do not repeat/u.test(error.message))
    assert.equal(events[1].data.mutation.requestedPath, 'changed.txt')
    assert.equal(events[1].data.mutation.canonicalPath, toolError ? undefined : '/workspace/changed.txt')
    assert.equal(events[1].data.mutation.status, 'verify-before-retry')
    assert.ok(contexts.some(value => JSON.stringify(value).includes('verify-before-retry')))
    assert.equal((await callJournal.inspect({ runId: RUN_ID, callId: 1 })).state, 'confirmed')
    await port.close()
  }
})

test('cancelled mutation preserves its returned receipt and durable terminal audit but is never replayable', async () => {
  const started = deferred(), release = deferred(), callJournal = journal()
  const context = { role: 'user', id: 'committed', source: { kind: 'test-receipt' },
    content: [{ type: 'text', text: 'Committed /workspace/late.txt' }] }
  let flushes = 0
  const { port, events, contexts } = setup({ kind: 'ptc', names: ['write'], journal: callJournal,
    authorizeTool: async input => ({ effect: 'workspace-write', definition: input.definition,
      async flushSession() { flushes++; return true } }),
    execute: async () => {
      started.resolve(); await release.promise
      return { isError: true, content: [], error: { message: 'aborted', info: { code: 'TOOL_ABORTED' } },
        additionalContexts: [context] }
    },
  })
  const running = port.call(call('write', { file_path: 'late.txt' }))
  await started.promise
  const closing = port.close('cancel requested')
  release.resolve()
  await assert.rejects(running, { code: 'ANDROID_TOOL_CALLBACK_CLOSED' })
  await closing
  assert.equal(flushes, 2)
  assert.equal(contexts[0], context)
  assert.equal(events[1].data.additionalContexts[0].id, 'committed')
  assert.equal(events[1].data.mutation.status, 'verify-before-retry')
  assert.deepEqual(await callJournal.inspect({ runId: RUN_ID, callId: 1 }),
    { runId: RUN_ID, callId: 1, state: 'confirmed', outcome: 'tool-error' })
})

