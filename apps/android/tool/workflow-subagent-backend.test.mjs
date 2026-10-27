import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { glob, mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import Include from '@deepseek-ai/cordis-plugin-include'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentPresets from '@deepseek-ai/dsh-agent-preset-registry'
import { SessionId } from '@deepseek-ai/dsh-session'
import LocalJobRegistry from '@deepseek-ai/dsh-jobs-local'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SubagentRuntime from '@deepseek-ai/dsh-subagent'
import * as Spawn from '@deepseek-ai/dsh-subagent-spawn-in-process'
import { MockAdapter, textResponse, toolCallResponse } from '../../../packages/core/agent-loop/tests/mock-adapter.ts'
import { TestSessionQuery } from '../../../packages/subagent/subagent/tests/test-session-query.ts'
import { mountWorkingDirectoryFixture } from '../../../packages/subagent/subagent/tests/working-directory-fixture.ts'
import { createWorkflowSubagentBackend, installWorkflowSubagentPreset } from '../runtime/workflow-subagent-backend.mjs'
import { WorkflowGuestHostPort } from '../runtime/workflow-guest-host-port.mjs'
import { NativeWorkflowGuestCallbacks } from '../runtime/native-workflow-guest-callbacks.mjs'
import { createNativeWorkflowPrivateOwner } from '../runtime/native-workflow-private-owner.mjs'
import { createWorkflowSessionRecord } from '../runtime/workflow-session-record.mjs'
import { inspectWorkflowColdRun } from '../runtime/workflow-cold-observation.mjs'

async function setup(t, script = [textResponse('real child answer'), textResponse('restored answer')]) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-android-workflow-child-'))
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await ctx.plugin(Loader)
  ctx.loader.builtins.include = Include
  await mountAgentLoopTestDependencies(ctx)
  await mountWorkingDirectoryFixture(ctx)
  await ctx.plugin(JsonlSessionPersistence, { root, compression: 'none' })
  await ctx.plugin(TestSessionQuery)
  await ctx.plugin(SubagentRuntime)
  await ctx.plugin(Spawn, { providerName: 'spawn' })
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(AgentPresets, { default: 'parent' })
  await ctx.agentPresets.register({ id: 'parent', plugins: [{
    name: pathToFileURL(join(import.meta.dirname,
      '../../../packages/subagent/subagent/tests/fixtures/activation-presets/plugins/preset-tool.js')).href,
    config: { tool: 'parent_only_tool' },
  }] })
  const adapter = new MockAdapter(script)
  ctx.llm.registerAdapter(['mock'], adapter)
  const handle = await ctx.agents.create({
    sessionId: SessionId('workflow-parent'),
    agentOptions: { provider: 'mock', model: 'mock' },
    setup: async agentCtx => void await ctx.agentPresets.mount(agentCtx, 'parent'),
  })
  return { ctx, parent: handle.agent, adapter, root }
}

function prepared() {
  return {
    kind: 'workflow', runId: '00000000-0000-4000-8000-000000000001',
    program: 'return 1', args: {}, deadlineMillis: 5000,
    meta: { name: 'review', description: 'Review files' },
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  }
}

function appReservation(parent, runId) {
  return async (_request, _signal, _parent, _runId, childId) =>
    ({ runId, parentId: parent.id, childId })
}

function backendFor(ctx, parent, options = {}) {
  const runId = options.runId ?? prepared().runId
  return createWorkflowSubagentBackend({ ctx, parent, runId,
    authorize: options.authorize ?? appReservation(parent, runId) })
}

test('a mismatched activation flows from the backend to the owning child port', async t => {
  const reserved = '00000000-0000-4000-8000-000000000011'
  const different = '00000000-0000-4000-8000-000000000012'
  const { ctx: original, parent } = await setup(t)
  await installWorkflowSubagentPreset(original)
  let disposed = 0
  const ctx = {
    agents: original.agents,
    subagents: { startActivation: async () => ({ childId: different,
      result: Promise.resolve({ output: [], stopReason: 'completed' }),
      dispose: async () => { disposed += 1 } }) },
    agentPresets: original.agentPresets,
    tools: original.tools, get: name => original.get(name),
  }
  const backend = backendFor(ctx, parent)
  const guest = new WorkflowGuestHostPort({ prepared: prepared(),
    authorizeChild: backend.authorizeChild, activateChild: backend.activateChild,
    onProgress: async () => {} })
  guest.begin({})
  await assert.rejects(guest.startChild({ prompt: 'Inspect' }, reserved),
    { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  assert.equal(disposed, 1)
  await guest.close()
  backend.close()
})

function host(backend) {
  const guest = new WorkflowGuestHostPort({
    prepared: prepared(), authorizeChild: backend.authorizeChild,
    activateChild: backend.activateChild, onProgress: async () => {},
  })
  guest.begin({})
  const originalStart = guest.startChild.bind(guest)
  guest.startChild = (request, reserved = randomUUID()) => originalStart(request, reserved)
  return guest
}

test('cold observer reopens the real flushed parent Session without replay or a false run-end', async t => {
  const { ctx, parent, root } = await setup(t)
  const request = { ...prepared(), sessionId: parent.session.id }
  const record = createWorkflowSessionRecord(ctx, request, parent)
  await record.start()
  await record.progress({ type: 'agent-start', info: {
    seq: 1, label: 'Review', childId: 'persisted-child',
  } })
  assert.deepEqual(await inspectWorkflowColdRun(ctx,
    { sessionId: parent.session.id, runId: request.runId }, new Set([request.runId])),
  { runId: request.runId, state: 'running', requiresReview: false })
  await ctx.fiber.dispose()

  const restarted = new Context()
  try {
    await restarted.plugin(JsonlSessionPersistence, { root, compression: 'none' })
    const cold = { sessionPersistence: restarted.sessionPersistence,
      sessions: { get: () => undefined } }
    const observation = await inspectWorkflowColdRun(cold,
      { sessionId: parent.session.id, runId: request.runId }, new Set())
    assert.deepEqual(observation, { runId: request.runId, state: 'interrupted-unconfirmed',
      reason: 'previous-host', requiresReview: true })

    const handle = await restarted.sessionPersistence.open(parent.session.id, 'read')
    try {
      const { events } = await handle.read(0)
      assert.ok(events.some(event => event.type === 'tool-workflow/run-start'
        && event.data.runId === request.runId))
      assert.ok(events.some(event => event.type === 'tool-workflow/agent-start'
        && event.data.runId === request.runId))
      assert.equal(events.some(event => event.type === 'tool-workflow/run-end'
        && event.data.runId === request.runId), false)
    } finally { await handle.close() }
  } finally { await restarted.fiber.dispose() }
})

test('real child uses isolated preset, durable lineage and cold resume', async t => {
  const { ctx, parent, adapter, root } = await setup(t)
  const uninstall = await installWorkflowSubagentPreset(ctx)
  const backend = backendFor(ctx, parent)
  let child
  ctx.on('subagent/start', info => { child = ctx.agents.get(info.id) })
  const guest = host(backend)
  const published = await guest.startChild({ prompt: 'Review this task' })
  assert.equal(child?.id, published.childId)
  assert.equal(child?.session.header.parentSession, parent.id)
  assert.equal(child?.session.header.agentPreset, 'android-workflow-child')
  assert.deepEqual(ctx.tools.schemas(parent).map(tool => tool.name), ['parent_only_tool'])
  assert.deepEqual(ctx.tools.schemas(child), [])
  assert.deepEqual(JSON.parse(JSON.stringify((await guest.childResult({ callId: published.callId })).output)),
    [{ type: 'text', text: 'real child answer' }])
  assert.deepEqual(adapter.requests[0]?.tools ?? [], [])
  assert.ok(parent.session.snapshotEvents().some(event => event.type === 'subagent/catalog'
    && event.data.childId === published.childId))
  await guest.disposeChild({ callId: published.callId })
  await guest.close()
  const saved = await Array.fromAsync(glob('**/*.jsonl', { cwd: root }))
  const contents = await Promise.all(saved.map(async path =>
    (await readFile(join(root, path), 'utf8')).split('\n').filter(Boolean).map(JSON.parse)))
  const records = contents.find(rows => rows[0]?.id === published.childId)
  assert.ok(records, `expected persisted child among ${saved.join(', ')}`)
  assert.equal(records[0].parentSession, parent.id)
  assert.equal(records[0].agentPreset, 'android-workflow-child')
  assert.ok(records.some(event => event.type === 'subagent/descriptor'))
  backend.close()
  await uninstall()

  const uninstallAgain = await installWorkflowSubagentPreset(ctx)
  const afterRestart = backendFor(ctx, parent)
  const receipt = await ctx.subagents.sendMessage(parent, SessionId(published.childId),
    [{ type: 'text', text: 'Continue after release' }],
    { signal: new AbortController().signal })
  assert.equal(typeof receipt, 'string')
  await ctx.subagents.waitForChildren(parent)
  assert.equal(adapter.requests.length, 2)
  assert.deepEqual(adapter.requests[1]?.tools ?? [], [])
  afterRestart.close()
  await uninstallAgain()
})

test('schema child returns an authoritative scoped tool result without inheriting host tools', async t => {
  const resultValue = { answer: 'verified', count: 2 }
  const schema = { type: 'object', properties: {
    answer: { type: 'string' }, count: { type: 'integer' },
  }, required: ['answer', 'count'], additionalProperties: false }
  const { ctx, parent, adapter } = await setup(t,
    [toolCallResponse('capture-1', 'structured_output', resultValue)])
  let hostToolRan = false
  const unregisterHost = ctx.tools.register({
    name: 'structured_output', description: 'host spoof must not run',
    parameters: schema,
    output: { schema: { type: 'string' }, render: () => [{ type: 'text', text: 'spoofed' }] },
    execute: async () => { hostToolRan = true; return 'spoofed' },
  })
  const unregisterShell = ctx.tools.register({
    name: 'host_wide_tool', description: 'parent capability must stay hidden',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    output: { schema: { type: 'string' }, render: () => [{ type: 'text', text: 'x' }] },
    execute: async () => 'x',
  })
  const uninstall = await installWorkflowSubagentPreset(ctx)
  try {
    const backend = backendFor(ctx, parent)
    const guest = host(backend)
    const published = await guest.startChild({ prompt: 'Return verified finding', schema })
    const child = ctx.agents.get(SessionId(published.childId))
    assert.equal(child?.session.header.agentPreset, 'android-workflow-structured-child')
    assert.deepEqual(ctx.tools.schemas(child).map(tool => tool.name), ['structured_output'])
    assert.deepEqual(ctx.tools.schemas(child)[0]?.parameters, schema)
    const result = await guest.childResult({ callId: published.callId })
    assert.equal(result.stopReason, 'completed')
    assert.deepEqual(JSON.parse(JSON.stringify(result.structured)), resultValue)
    assert.equal(hostToolRan, false)
    assert.deepEqual(adapter.requests[0]?.tools?.map(tool => tool.name), ['structured_output'])
    await guest.close()
    backend.close()
  } finally { await uninstall(); unregisterShell(); unregisterHost() }
})

test('schema child cannot synthesize structured output from plain model text', async t => {
  const { ctx, parent } = await setup(t, [textResponse('{"answer":"looks structured"}')])
  const uninstall = await installWorkflowSubagentPreset(ctx)
  try {
    const backend = backendFor(ctx, parent)
    const guest = host(backend)
    const published = await guest.startChild({ prompt: 'Return JSON', schema: {
      type: 'object', properties: { answer: { type: 'string' } }, required: ['answer'],
      additionalProperties: false,
    } })
    const result = await guest.childResult({ callId: published.callId })
    assert.equal(result.structured, undefined)
    await guest.close()
    backend.close()
  } finally { await uninstall() }
})

test('invalid structured tool arguments must be rejected before an accepted result', async t => {
  const schema = { type: 'object', properties: { answer: { type: 'string' } },
    required: ['answer'], additionalProperties: false }
  const { ctx, parent, adapter } = await setup(t, [
    toolCallResponse('invalid-result', 'structured_output', { answer: 7 }),
    toolCallResponse('valid-result', 'structured_output', { answer: 'accepted' }),
  ])
  const uninstall = await installWorkflowSubagentPreset(ctx)
  try {
    const backend = backendFor(ctx, parent)
    const guest = host(backend)
    const published = await guest.startChild({ prompt: 'Follow the schema', schema })
    const result = await guest.childResult({ callId: published.callId })
    assert.deepEqual(JSON.parse(JSON.stringify(result.structured)), { answer: 'accepted' })
    assert.equal(adapter.requests.length, 2)
    await guest.close()
    backend.close()
  } finally { await uninstall() }
})

test('a running structured child rejects every late non-result scoped tool', async t => {
  const { ctx, parent } = await setup(t, ['hang'])
  const uninstall = await installWorkflowSubagentPreset(ctx)
  try {
    const backend = backendFor(ctx, parent)
    const guest = host(backend)
    const published = await guest.startChild({ prompt: 'Wait', schema: {
      type: 'object', properties: { answer: { type: 'string' } },
      required: ['answer'], additionalProperties: false,
    } })
    const child = ctx.agents.get(SessionId(published.childId))
    assert.ok(child)
    let executed = false
    const unregister = child.ctx.tools.register({
      name: 'late_local_shell', description: 'must never execute',
      parameters: { type: 'object', properties: {}, additionalProperties: false },
      output: { schema: { type: 'string' }, render: () => [{ type: 'text', text: 'x' }] },
      execute: async () => { executed = true; return 'x' },
    })
    try {
      const result = await ctx.tools.execute({ signal: new AbortController().signal,
        callId: 'late-structured-call', name: 'late_local_shell', arguments: {}, agent: child })
      assert.equal(result.isError, true)
      assert.equal(executed, false)
      assert.match(result.content[0]?.text ?? '', /not authorized by its current parent and child policies/)
    } finally { unregister(); await guest.close(); backend.close() }
  } finally { await uninstall() }
})

test('stale parent and missing App authorization cannot start a child', async t => {
  const { ctx, parent } = await setup(t)
  const uninstall = await installWorkflowSubagentPreset(ctx)
  assert.throws(() => backendFor(ctx, { ...parent, id: parent.id }),
    { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  const backend = backendFor(ctx, parent, { authorize: async () => false })
  const guest = host(backend)
  await assert.rejects(guest.startChild({ prompt: 'No App consent' }),
    { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  await assert.rejects(backend.activateChild({ prompt: 'bypass' }, new AbortController().signal),
    { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  await guest.close()
  backend.close()
  const booleanApproval = backendFor(ctx, parent, { authorize: async () => true })
  const legacyGuest = host(booleanApproval)
  await assert.rejects(legacyGuest.startChild({ prompt: 'Boolean is not a reservation' }),
    { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  await legacyGuest.close()
  booleanApproval.close()
  await uninstall()
})

test('child start requires one exact durable reservation and parent model route', async t => {
  const { ctx, parent } = await setup(t)
  const uninstall = await installWorkflowSubagentPreset(ctx)
  const runId = prepared().runId
  const reserved = randomUUID()
  const wrongOwner = backendFor(ctx, parent, { authorize: async () => ({
    runId, parentId: randomUUID(), childId: reserved,
  }) })
  const deniedGuest = host(wrongOwner)
  await assert.rejects(deniedGuest.startChild({ prompt: 'Reject wrong parent' }),
    { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  await assert.rejects(deniedGuest.startChild({ prompt: 'Reject wrong reservation with schema',
    schema: { type: 'object', properties: {}, additionalProperties: false } }),
  { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  await deniedGuest.close()
  wrongOwner.close()

  const backend = backendFor(ctx, parent, { authorize: async () => ({
    runId, parentId: parent.id, childId: reserved,
  }) })
  const guest = host(backend)
  await assert.rejects(guest.startChild({ prompt: 'Reject model switch', model: 'other-model' }),
    { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  const published = await guest.startChild({ prompt: 'Exact reservation' }, reserved)
  assert.equal(published.childId, reserved)
  await assert.rejects(backend.activateChild({ prompt: 'Bypass one-use grant' },
    new AbortController().signal), { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  await guest.close()
  backend.close()
  await uninstall()
})

test('parent route change after child authorization prevents activation', async t => {
  const { ctx, parent } = await setup(t)
  const uninstall = await installWorkflowSubagentPreset(ctx)
  const backend = backendFor(ctx, parent)
  const reserved = randomUUID()
  const request = { prompt: 'No route widening' }
  const signal = new AbortController().signal
  assert.equal(await backend.authorizeChild(request, signal, reserved), true)
  const header = parent.session.requestHeader()
  const route = header?.config ?? parent.options
  const former = route.model
  route.model = 'changed-after-authorization'
  try {
    await assert.rejects(backend.activateChild(request, signal),
      { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  } finally {
    route.model = former
    backend.close()
    await uninstall()
  }
})

test('guest closure retires a real running child', async t => {
  const { ctx, parent } = await setup(t, ['hang'])
  const uninstall = await installWorkflowSubagentPreset(ctx)
  const backend = backendFor(ctx, parent)
  const guest = host(backend)
  const published = await guest.startChild({ prompt: 'Remain busy' })
  const child = ctx.agents.get(SessionId(published.childId))
  assert.ok(child)
  const unregisterLateTool = ctx.tools.register({
    name: 'late_host_tool', description: 'registered after child publication',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    output: { schema: { type: 'string' }, render: () => [{ type: 'text', text: 'x' }] },
    execute: async () => 'x',
  })
  assert.deepEqual(ctx.tools.schemas(child), [])
  await guest.close()
  assert.equal(ctx.agents.get(SessionId(published.childId)), undefined)
  unregisterLateTool()
  backend.close()
  await uninstall()
})

test('a host-wide Android tool remains hidden inside the child preset', async t => {
  const { ctx, parent } = await setup(t)
  const unregister = ctx.tools.register({
    name: 'host_wide_tool', description: 'must be hidden from the child',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    output: { schema: { type: 'string' }, render: () => [{ type: 'text', text: 'x' }] },
    execute: async () => 'x',
  })
  const uninstall = await installWorkflowSubagentPreset(ctx)
  try {
    const backend = backendFor(ctx, parent)
    const guest = host(backend)
    const child = await guest.startChild({ prompt: 'Check tool isolation' })
    const agent = ctx.agents.get(SessionId(child.childId))
    assert.ok(agent)
    assert.deepEqual(ctx.tools.schemas(agent), [])
    await guest.close()
    backend.close()
  } finally { await uninstall(); unregister() }
})

test('a late child-local tool cannot execute without an exact child grant', async t => {
  const { ctx, parent } = await setup(t, ['hang'])
  const uninstall = await installWorkflowSubagentPreset(ctx)
  const backend = backendFor(ctx, parent)
  const guest = host(backend)
  const published = await guest.startChild({ prompt: 'Check local tool denial' })
  const child = ctx.agents.get(SessionId(published.childId))
  assert.ok(child)
  let executed = false
  const unregister = child.ctx.tools.register({
    name: 'late_local_shell', description: 'must never execute',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    output: { schema: { type: 'string' }, render: () => [{ type: 'text', text: 'x' }] },
    execute: async () => { executed = true; return 'x' },
  })
  try {
    const result = await ctx.tools.execute({ signal: new AbortController().signal,
      callId: 'late-local-call', name: 'late_local_shell', arguments: {}, agent: child })
    assert.equal(executed, false)
    assert.equal(result.isError, true)
    assert.match(result.content[0]?.text ?? '', /not authorized by its current parent and child policies/)
  } finally {
    unregister()
    await guest.close()
    backend.close()
    await uninstall()
  }
})

test('independent workflows share one runtime preset', async t => {
  const { ctx, parent } = await setup(t, [textResponse('one'), textResponse('two')])
  const uninstall = await installWorkflowSubagentPreset(ctx)
  const backends = [0, 1].map(() => backendFor(ctx, parent))
  const guests = backends.map(host)
  const published = await Promise.all(guests.map((guest, i) => guest.startChild({ prompt: `Task ${i}` })))
  assert.notEqual(published[0].childId, published[1].childId)
  await Promise.all(guests.map((guest, i) => guest.childResult({ callId: published[i].callId })))
  await Promise.all(guests.map(guest => guest.close()))
  for (const backend of backends) backend.close()
  await uninstall()
})

test('private native owner binds App reservation to a real confined child and joins retirement', async t => {
  const { ctx, parent } = await setup(t)
  const callbacks = new NativeWorkflowGuestCallbacks({ request: async (method, params) => {
    assert.equal(method, 'native.workflow.bindCallbacks')
    assert.deepEqual(params, { runId: prepared().runId, token: 'private-token' })
    return true
  } })
  const owner = createNativeWorkflowPrivateOwner(ctx, callbacks)
  const bound = await owner.attach({ prepared: prepared(),
    admission: { runId: prepared().runId, token: 'private-token' }, parent,
    onProgress: async () => {} })
  const frame = (callId, action, value, childId) => ({ runId: prepared().runId,
    token: 'private-token', callId, action, value,
    ...(childId === undefined ? {} : { childId }) })
  await callbacks.call(frame(1, 'WORKFLOW_BEGIN', {}))
  const reserved = randomUUID()
  const started = await callbacks.call(frame(2, 'WORKFLOW_START_CHILD',
    { prompt: 'Inspect confined child' }, reserved))
  assert.equal(started.value.childId, reserved)
  const child = ctx.agents.get(SessionId(reserved))
  assert.ok(child)
  assert.deepEqual(ctx.tools.schemas(child), [])
  const result = await callbacks.call(frame(3, 'WORKFLOW_CHILD_RESULT', { callId: 1 }))
  assert.deepEqual(JSON.parse(JSON.stringify(result.value.output)),
    [{ type: 'text', text: 'real child answer' }])
  await callbacks.call(frame(4, 'WORKFLOW_DISPOSE_CHILD', { callId: 1 }))
  assert.equal(ctx.agents.get(SessionId(reserved)), undefined)
  await bound.close()
  await owner.dispose()
  await assert.rejects(owner.attach({}), /closed/)
})

test('private DSL owner admits fixed guest source, binds original body and releases confirmed completion', async t => {
  const { ctx, parent } = await setup(t)
  const emitted = []
  ctx.on('session/event', (session, event) => {
    if (session === parent.session && event.type.startsWith('tool-workflow/')) {
      emitted.push({ type: event.type, data: event.data })
    }
  })
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const calls = []
  let nativeChildId
  let callbacks
  const transport = { async request(method, params) {
    calls.push(method)
    if (method === 'native.workflow.admit') {
      assert.equal(params.inputJson, '{}')
      assert.equal(params.workflowBody, source.program)
      assert.doesNotMatch(params.program, /return 1/)
      return { runId: source.runId, token: 'private-token' }
    }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') {
      const initialized = await callbacks.call({ ...params, callId: 1,
        action: 'WORKFLOW_BEGIN', value: {} })
      assert.equal(Object.hasOwn(initialized.value, 'body'), false)
      const childId = randomUUID()
      nativeChildId = childId
      await callbacks.call({ ...params, callId: 2,
        action: 'WORKFLOW_START_CHILD', value: { prompt: 'Review a file' }, childId })
      await callbacks.call({ ...params, callId: 3, action: 'WORKFLOW_PROGRESS',
        value: [{ type: 'agent-start', info: { seq: 1, label: 'Review a file', childId } }] })
      assert.deepEqual(await owner.inspectRun({ sessionId: source.sessionId, runId: source.runId }),
        { runId: source.runId, state: 'running', nativeState: 'ADMITTED',
          pendingChildren: 1, requiresReview: false })
      const child = await callbacks.call({ ...params, callId: 4,
        action: 'WORKFLOW_CHILD_RESULT', value: { callId: 1 } })
      assert.equal(child.value.stopReason, 'completed')
      await callbacks.call({ ...params, callId: 5, action: 'WORKFLOW_PROGRESS',
        value: [{ type: 'agent-end', info: { seq: 1, label: 'Review a file',
          childId, outcome: 'completed' } }] })
      await callbacks.call({ ...params, callId: 6,
        action: 'WORKFLOW_DISPOSE_CHILD', value: { callId: 1 } })
      return true
    }
    if (method === 'native.workflow.inspect') return { runId: source.runId, state: 'ADMITTED',
      children: [{ childId: nativeChildId, state: 'LAUNCHING' }] }
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'COMPLETED',
      outputJson: '{"value":1,"stopReason":"completed","agentsStarted":1}', requiresReview: false }
    if (method === 'native.workflow.release') return true
    throw Error(`unexpected ${method}`)
  } }
  callbacks = new NativeWorkflowGuestCallbacks(transport)
  const owner = createNativeWorkflowPrivateOwner(ctx, callbacks, transport)
  const receipt = await owner.runDsl({ prepared: source, parent, onProgress: async () => {} })
  assert.equal(receipt.state, 'COMPLETED')
  assert.deepEqual(await owner.inspectRun({ sessionId: source.sessionId, runId: source.runId }),
    { runId: source.runId, state: 'completed', requiresReview: false })
  assert.deepEqual(calls, ['native.workflow.admit', 'native.workflow.bindCallbacks',
    'native.workflow.execute', 'native.workflow.inspect', 'native.workflow.settle', 'native.workflow.release'])
  const normalized = emitted.map(({ type, data }) => ({
    type, data: { ...data, ...(Object.hasOwn(data, 'childId') ? { childId: '[child]' } : {}) },
  }))
  assert.deepEqual(normalized, JSON.parse(await readFile(
    new URL('./workflow-session-record.snapshot.json', import.meta.url), 'utf8')))
  const reader = await ctx.sessionPersistence.open(parent.session.id, 'read')
  try {
    const stored = (await reader.read()).events
      .filter(event => event.type.startsWith('tool-workflow/'))
      .map(event => ({
        type: event.type,
        data: { ...event.data, ...(Object.hasOwn(event.data, 'childId')
          ? { childId: '[child]' } : {}) },
      }))
    assert.deepEqual(stored, normalized)
  } finally { await reader.close() }
  await owner.dispose()
})

test('App-private background workflow is owned by the original jobs registry and settles once', async t => {
  const { ctx, parent } = await setup(t)
  await ctx.plugin(LocalJobRegistry, {})
  ctx.jobs.attachController('workflow-background-test')
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  let finishExecution
  const execution = new Promise(resolve => { finishExecution = resolve })
  const calls = []
  const transport = { async request(method) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId: source.runId, token: 'private-token' }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') return execution
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'COMPLETED',
      outputJson: '{"value":{"ok":true},"stopReason":"completed","agentsStarted":0}',
      requiresReview: false }
    if (method === 'native.workflow.release') return true
    throw Error(`unexpected ${method}`)
  } }
  const owner = createNativeWorkflowPrivateOwner(ctx, new NativeWorkflowGuestCallbacks(transport), transport)
  const started = owner.startBackgroundDsl({ prepared: source, parent,
    toolCall: { callId: 'workflow-background', rootCallId: 'workflow-background' } })
  assert.equal(started.kind, 'background')
  assert.equal(started.runId, source.runId)
  assert.match(started.jobId, /^workflow-/)
  assert.equal(ctx.jobs.get(started.jobId, parent.id).status, 'running')
  assert.throws(() => ctx.jobs.get(started.jobId, SessionId('foreign')), /belongs to another session/i)
  while (!calls.includes('native.workflow.execute')) await new Promise(resolve => setTimeout(resolve, 1))
  assert.equal(ctx.jobs.get(started.jobId, parent.id).status, 'running')
  finishExecution(true)
  const settled = await ctx.jobs.wait(started.jobId, 5000, parent.id)
  assert.equal(settled.status, 'completed')
  assert.match(ctx.jobs.read(started.jobId, parent.id).result, /"ok": true/)
  assert.equal(ctx.jobs.read(started.jobId, parent.id).result, undefined)
  assert.deepEqual(calls, ['native.workflow.admit', 'native.workflow.bindCallbacks',
    'native.workflow.execute', 'native.workflow.settle', 'native.workflow.release'])
  await owner.dispose()
})

test('background job cancellation waits for native retirement and never publishes output', async t => {
  const { ctx, parent } = await setup(t)
  await ctx.plugin(LocalJobRegistry, {})
  ctx.jobs.attachController('workflow-background-test')
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  let finishExecution, finishCancellation
  const execution = new Promise(resolve => { finishExecution = resolve })
  const cancellation = new Promise(resolve => { finishCancellation = resolve })
  const calls = []
  const transport = { async request(method) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId: source.runId, token: 'private-token' }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') return execution
    if (method === 'native.workflow.cancel') return cancellation
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'CANCELLED', outputJson: null, requiresReview: false }
    if (method === 'native.workflow.release') return true
    throw Error(`unexpected ${method}`)
  } }
  const owner = createNativeWorkflowPrivateOwner(ctx, new NativeWorkflowGuestCallbacks(transport), transport)
  const started = owner.startBackgroundDsl({ prepared: source, parent })
  while (!calls.includes('native.workflow.execute')) await new Promise(resolve => setTimeout(resolve, 1))
  assert.equal(ctx.jobs.kill(started.jobId, parent.id, 'user cancelled'), 'requested')
  while (!calls.includes('native.workflow.cancel')) await new Promise(resolve => setTimeout(resolve, 1))
  assert.equal(ctx.jobs.get(started.jobId, parent.id).status, 'stopping')
  finishExecution(true)
  finishCancellation(true)
  const settled = await ctx.jobs.wait(started.jobId, 5000, parent.id)
  assert.equal(settled.status, 'killed')
  assert.equal(ctx.jobs.read(started.jobId, parent.id).result, undefined)
  assert.equal((await owner.inspectRun({ sessionId: source.sessionId, runId: source.runId })).state,
    'cancelled')
  await owner.dispose()
})

test('private DSL owner joins a concurrent Abort cancellation before settlement', async t => {
  const { ctx, parent } = await setup(t)
  const recordTypes = []
  ctx.on('session/event', (session, event) => {
    if (session === parent.session && event.type.startsWith('tool-workflow/')) {
      recordTypes.push(event.type)
    }
  })
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const abort = new AbortController()
  let confirmCancellation
  const cancellation = new Promise(resolve => { confirmCancellation = resolve })
  let observeCancellation
  const cancelObserved = new Promise(resolve => { observeCancellation = resolve })
  const calls = []
  const transport = { async request(method) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId: source.runId, token: 'private-token' }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') {
      abort.abort(new Error('user cancelled'))
      return true
    }
    if (method === 'native.workflow.cancel') {
      observeCancellation()
      return cancellation
    }
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'CANCELLED', outputJson: null, requiresReview: false }
    if (method === 'native.workflow.release') return true
    throw Error(`unexpected ${method}`)
  } }
  const owner = createNativeWorkflowPrivateOwner(ctx, new NativeWorkflowGuestCallbacks(transport), transport)
  const running = owner.runDsl({ prepared: source, parent, onProgress: async () => {},
    signal: abort.signal })
  const timeout = setTimeout(() => observeCancellation(), 5000)
  try { await cancelObserved } finally { clearTimeout(timeout) }
  assert.deepEqual(calls, ['native.workflow.admit', 'native.workflow.bindCallbacks',
    'native.workflow.execute', 'native.workflow.cancel'])
  confirmCancellation(true)
  await assert.rejects(running, /user cancelled/)
  assert.deepEqual(calls.slice(-3), ['native.workflow.cancel', 'native.workflow.settle',
    'native.workflow.release'])
  assert.deepEqual(recordTypes, ['tool-workflow/run-start', 'tool-workflow/run-end'])
  await owner.dispose()
})

test('private DSL owner withholds a guest-reported error despite a completed script receipt', async t => {
  const { ctx, parent } = await setup(t)
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const calls = []
  const transport = { async request(method) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId: source.runId, token: 'private-token' }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') return true
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'COMPLETED',
      outputJson: '{"value":null,"stopReason":"error"}', requiresReview: false }
    throw Error(`unexpected ${method}`)
  } }
  const owner = createNativeWorkflowPrivateOwner(ctx, new NativeWorkflowGuestCallbacks(transport), transport)
  await assert.rejects(owner.runDsl({ prepared: source, parent,
    onProgress: async () => {} }), /did not report completion/)
  assert.equal(calls.includes('native.workflow.release'), false)
  await owner.dispose()
})

test('private DSL owner withholds completion when the guest child count differs from recorded progress', async t => {
  const { ctx, parent } = await setup(t)
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const recordTypes = []
  ctx.on('session/event', (session, event) => {
    if (session === parent.session && event.type.startsWith('tool-workflow/')) {
      recordTypes.push(event.type)
    }
  })
  const calls = []
  const transport = { async request(method) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId: source.runId, token: 'private-token' }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') return true
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'COMPLETED',
      outputJson: '{"value":1,"stopReason":"completed","agentsStarted":1}', requiresReview: false }
    throw Error(`unexpected ${method}`)
  } }
  const owner = createNativeWorkflowPrivateOwner(ctx, new NativeWorkflowGuestCallbacks(transport), transport)
  await assert.rejects(owner.runDsl({ prepared: source, parent }), /did not report completion/)
  assert.equal(calls.includes('native.workflow.release'), false)
  assert.deepEqual(recordTypes, ['tool-workflow/run-start'])
  await owner.dispose()
})

test('private DSL owner retains an admitted run when child retirement is unconfirmed', async t => {
  const { ctx, parent } = await setup(t)
  const recordTypes = []
  ctx.on('session/event', (session, event) => {
    if (session === parent.session && event.type.startsWith('tool-workflow/')) {
      recordTypes.push(event.type)
    }
  })
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const calls = []
  const transport = { async request(method) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId: source.runId, token: 'private-token' }
    if (method === 'native.workflow.execute') return true
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'COMPLETED',
      outputJson: '{"value":1,"stopReason":"completed","agentsStarted":0}', requiresReview: false }
    throw Error(`unexpected ${method}`)
  } }
  const callbacks = { bind: async () => ({ runId: source.runId,
    close: async () => { throw Error('child disposal unconfirmed') } }), dispose: async () => {} }
  const owner = createNativeWorkflowPrivateOwner(ctx, callbacks, transport)
  await assert.rejects(owner.runDsl({ prepared: source, parent,
    onProgress: async () => {} }), /child disposal unconfirmed/)
  assert.equal(calls.includes('native.workflow.release'), false)
  assert.deepEqual(recordTypes, ['tool-workflow/run-start'])
  await owner.dispose()
})

test('private DSL owner rejects a different parent Session before native admission', async t => {
  const { ctx, parent } = await setup(t)
  const source = { ...prepared(), sessionId: randomUUID(), scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const calls = []
  const transport = { async request(method) { calls.push(method); return true } }
  const owner = createNativeWorkflowPrivateOwner(ctx, new NativeWorkflowGuestCallbacks(transport), transport)
  await assert.rejects(owner.runDsl({ prepared: source, parent }), /exact parent Session/)
  assert.deepEqual(calls, [])
  await assert.rejects(owner.runDsl({ prepared: { ...source, sessionId: parent.session.id },
    parent: { id: parent.id, session: parent.session } }), /exact live parent Agent/)
  assert.deepEqual(calls, [])
  await owner.dispose()
})

test('disposed workflow owner rejects a stale private start before native admission', async t => {
  const { ctx, parent } = await setup(t)
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const calls = []
  const transport = { async request(method) { calls.push(method); return true } }
  const owner = createNativeWorkflowPrivateOwner(ctx,
    { bind() {}, async dispose() {} }, transport)
  await owner.dispose()
  await assert.rejects(owner.runDsl({ prepared: source, parent }), /owner has closed/)
  assert.deepEqual(calls, [])
})

test('private DSL owner cancels and releases a confirmed execution failure', async t => {
  const { ctx, parent } = await setup(t)
  const source = { ...prepared(), sessionId: parent.session.id, scope: {
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } }
  const calls = []
  const transport = { async request(method) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId: source.runId, token: 'private-token' }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') throw Error('guest failed')
    if (method === 'native.workflow.cancel') return true
    if (method === 'native.workflow.settle') return { runId: source.runId,
      sessionId: source.sessionId, state: 'FAILED', outputJson: null, requiresReview: false }
    if (method === 'native.workflow.release') return true
    throw Error(`unexpected ${method}`)
  } }
  const owner = createNativeWorkflowPrivateOwner(ctx, new NativeWorkflowGuestCallbacks(transport), transport)
  await assert.rejects(owner.runDsl({ prepared: source, parent,
    onProgress: async () => {} }), /guest failed/)
  assert.deepEqual(calls.slice(-3), ['native.workflow.cancel', 'native.workflow.settle',
    'native.workflow.release'])
  await owner.dispose()
})
