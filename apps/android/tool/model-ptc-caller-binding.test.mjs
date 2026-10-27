import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { createRequire } from 'node:module'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createAppOwnedModelPtcCaller } from '../runtime/model-ptc-caller-binding.mjs'
import { createAppOwnedListAgentsPtcOwner } from '../runtime/model-ptc-owner.mjs'
import { createAndroidPtcToolDefinition, registerAndroidPtcTool } from '../runtime/tool-isolated-ptc.mjs'
import {
  createAppOwnedListAgentsPtcCaller, createAppOwnedListAgentsPtcPolicyIssuer,
  reviewListAgentsForModelPtc,
} from '../runtime/model-ptc-list-agents-review.mjs'
import { prepareModelPtcGuestSdk } from '../runtime/model-ptc-guest-sdk.mjs'
import { prepareModelIsolatedScript } from '../runtime/model-isolated-script.mjs'
import { projectIsolatedSandboxPolicy, requireIsolatedSandboxPolicy } from '../runtime/isolated-sandbox-policy.mjs'
import { createNativeIsolatedExecutionBridge } from '../runtime/native-isolated-execution-bridge.mjs'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'

const stagedRequire = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const staged = name => import(pathToFileURL(stagedRequire.resolve(name)).href)
const AsyncFunction = (async () => {}).constructor

test('guest tools SDK accepts only reviewed JavaScript identifiers as data', async () => {
  for (const name of ['constructor', '__proto__', 'prototype', 'then', 'foo.bar', 'a-b']) {
    assert.throws(() => prepareModelPtcGuestSdk('return 1', [name]),
      { code: 'ANDROID_TOOL_HOST_INVALID' })
  }
  assert.throws(() => prepareModelPtcGuestSdk('const tools = {}; return 1', ['safe_echo']),
    { code: 'ANDROID_PTC_TYPESCRIPT_INVALID' })
  const sdk = prepareModelPtcGuestSdk('return await tools.safe_echo({ text: "hello" })', ['safe_echo'])
  assert.deepEqual(sdk.args.toolNames, ['safe_echo'])
  assert.equal(sdk.program.split('\n')[0].includes('safe_echo'), false)
  const body = new AsyncFunction('input', 'host', sdk.program)
  await assert.rejects(body(sdk.args, { callAsync: async () => ({
    error: { code: 'ANDROID_TOOL_NOT_GRANTED', message: 'review revoked' },
  }) }), { code: 'ANDROID_TOOL_NOT_GRANTED', message: 'review revoked' })
})

async function setup(t, options = {}) {
  const [
    { Context }, { default: LlmRuntime }, { default: SessionStore, SessionId },
    { default: SessionProjections }, { default: SystemPrompt },
    { default: ToolRuntime, defineTool }, { default: AgentRegistry },
    { default: AgentLoop },
  ] = await Promise.all([
    staged('@deepseek-ai/cordis'), staged('@deepseek-ai/dsh-llm'),
    staged('@deepseek-ai/dsh-session'), staged('@deepseek-ai/dsh-session-projection'),
    staged('@deepseek-ai/dsh-system-prompt'), staged('@deepseek-ai/dsh-tools'),
    staged('@deepseek-ai/dsh-agent'), staged('@deepseek-ai/dsh-agent-loop'),
  ])
  const ctx = new Context()
  t.after(() => ctx.fiber.dispose())
  for (const plugin of [LlmRuntime, SessionStore, SessionProjections, SystemPrompt,
    ToolRuntime, AgentRegistry]) await ctx.plugin(plugin)
  await ctx.plugin(AgentLoop, { agents: [] })
  const agent = await ctx.agentLoop.create(SessionId(`android-${randomUUID()}`))
  const calls = []
  let callbacks
  let program
  let inputJson
  let outputJson
  let cancelled = false
  const transport = { async request(method, params) {
    calls.push(method)
    if (method === 'native.isolated.admit') {
      program = params.program
      inputJson = params.inputJson
      assert.equal(params.sessionId, agent.session.id)
      assert.deepEqual(params.scope.readablePaths, [])
      assert.deepEqual(params.scope.exactHosts, [])
      return { runId: params.runId, token: 'native-private-token' }
    }
    if (method === 'native.isolated.bindTools') return true
    if (method === 'native.isolated.execute') {
      await options.beforeExecute?.()
      const body = new AsyncFunction('input', 'host', program)
      const value = await body(JSON.parse(inputJson), { callAsync: async input => {
        assert.equal(input.action, 'TOOL_CALL')
        const { action, ...forwarded } = input
        const result = await callbacks.call({ ...forwarded, runId: params.runId,
          token: 'native-private-token' })
        const { runId: _runId, callId: _callId, ...reply } = result
        return reply
      } })
      outputJson = JSON.stringify(value)
      return true
    }
    if (method === 'native.isolated.cancel') {
      cancelled = true
      options.onCancel?.()
      return true
    }
    if (method === 'native.isolated.settle') return {
      runId: params.runId, state: cancelled ? 'CANCELLED' : 'COMPLETED',
      outputJson: cancelled ? null : outputJson,
      detail: cancelled ? 'cancelled' : null, guestUid: cancelled ? null : 99001,
    }
    if (method === 'native.isolated.release') {
      if (options.failRelease) throw new Error('native retirement unavailable')
      return true
    }
    throw new Error(`Unexpected native method ${method}`)
  } }
  const journalRoot = await mkdtemp(join(tmpdir(), 'dsh-model-ptc-caller-'))
  t.after(() => rm(journalRoot, { recursive: true, force: true }))
  const journal = new IsolatedToolCallJournal(journalRoot)
  callbacks = new NativeIsolatedToolCallbacks(transport, journal)
  t.after(() => callbacks.dispose())
  const bridge = createNativeIsolatedExecutionBridge(transport)
  const approvedScope = { ownerId: 'app-model-tool', sessionId: agent.session.id,
    version: 1, workspaceId: null, readablePaths: [], writablePaths: [],
    exactHosts: [], fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000 }
  const policy = projectIsolatedSandboxPolicy({ approvedScope })
  const draft = code => prepareModelIsolatedScript({ code, description: 'Review a read-only tool',
    language: 'typescript-function-body' }, {
    sessionId: agent.session.id, sandboxPolicy: policy, deadlineMillis: 5000,
    ...(options.kind === undefined ? {} : { executionKind: options.kind }),
  })
  return { ctx, agent, calls, bridge, callbacks, defineTool, draft, journal }
}

test('App-owned list_agents policy issues a fresh zero-grant lease only for a live Agent', async t => {
  const { ctx, agent } = await setup(t)
  assert.throws(() => createAppOwnedListAgentsPtcPolicyIssuer({ agents: {} }),
    /live Agent registry/)
  const issuer = createAppOwnedListAgentsPtcPolicyIssuer({ agents: ctx.agents })
  const input = { sessionId: agent.session.id, agent,
    signal: new AbortController().signal }
  const first = issuer.issue(input)
  const second = issuer.issue(input)
  assert.notStrictEqual(first, second)
  assert.strictEqual(requireIsolatedSandboxPolicy(first), first)
  assert.equal(first.mode, 'read-only')
  assert.equal(first.networkMode, 'deny')
  assert.deepEqual(first.scope, {
    ownerId: 'app-model-list-agents', sessionId: agent.session.id,
    version: 1, workspaceId: null, readablePaths: [], writablePaths: [],
    exactHosts: [], fileCallLimit: 0, networkCallLimit: 0,
    leaseMillis: 5000,
  })
  const prepared = prepareModelIsolatedScript({
    code: 'return await tools.list_agents({})', description: 'List direct children',
    language: 'typescript-function-body',
  }, { sessionId: agent.session.id, sandboxPolicy: first, deadlineMillis: 5000 })
  assert.deepEqual(prepared.execution.scope, first.scope)
  for (const request of [
    { ...input, sessionId: randomUUID() },
    { ...input, agent: { id: agent.id, session: agent.session } },
    { ...input, permission: 'workspace-write' },
    Object.defineProperty({ agent, signal: input.signal }, 'sessionId', {
      get() { throw new Error('untrusted getter ran') },
    }),
  ]) assert.throws(() => issuer.issue(request), /current Agent session/)
  const cancelled = new AbortController()
  cancelled.abort(new Error('parent cancelled'))
  assert.throws(() => issuer.issue({ ...input, signal: cancelled.signal }),
    /parent cancelled/)
  issuer.close()
  assert.throws(() => issuer.issue(input), /policy owner is closed/)
})

test('App lifecycle binds model-style input to a live parent, zero-grant lease and first-party callback', async t => {
  const { ctx, agent, bridge, callbacks, defineTool, calls } = await setup(t)
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const childQueries = []
  const services = { agents: ctx.agents, subagents: {
    async listChildren(id, signal) {
      signal.throwIfAborted()
      childQueries.push(id)
      return [{ id: 'child-1', mode: 'continuable', label: 'First child' }]
    },
    async listDescendants() { throw new Error('recursive catalog must stay hidden') },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const owner = createAppOwnedListAgentsPtcOwner({
    bridge, callbacks, runtime: ctx.tools, services,
  })
  let activeParent
  ctx.tools.register(defineTool({
    name: 'app_ptc_owner_probe', description: 'Trusted test-only parent', parameters: {},
    output: { schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, parent) {
      activeParent = parent
      const modelInput = { code: 'return await tools.list_agents({ scope: "children" })',
        description: 'List direct children', language: 'typescript-function-body' }
      assert.throws(() => owner.start(modelInput, { ...parent }),
        /current ToolRuntime parent/)
      for (const extra of [{ sessionId: randomUUID() }, { writablePaths: ['/'] },
        { exactHosts: ['example.com'] }]) {
        assert.throws(() => owner.start({ ...modelInput, ...extra }, parent),
          { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
      }
      assert.deepEqual(calls, [], 'invalid input must not reach native admission')
      const receipt = await owner.start(modelInput, parent).result
      return receipt.value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer-owner-integration',
    name: 'app_ptc_owner_probe', arguments: {}, agent,
    signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(JSON.parse(JSON.stringify(result.value)), [{ kind: 'child', id: 'child-1',
    label: 'First child', status: 'inactive' }])
  assert.deepEqual(childQueries, [agent.id])
  assert.deepEqual(calls, ['native.isolated.admit', 'native.isolated.bindTools',
    'native.isolated.execute', 'native.isolated.settle', 'native.isolated.release'])
  assert.throws(() => owner.start({ code: 'return 1', description: 'late',
    language: 'typescript-function-body' }, activeParent), /current ToolRuntime parent/)
  const close = owner.close()
  assert.strictEqual(owner.close(), close)
  await close
  assert.throws(() => owner.start({}, activeParent), /App owner is closed/)
})

test('first-party list_agents review admits only the current parent direct-child query', async t => {
  const { ctx, agent, bridge, callbacks, defineTool, draft } = await setup(t)
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const lookedUp = []
  const subagents = {
    async listChildren(id, signal) {
      signal.throwIfAborted()
      lookedUp.push(id)
      return [{ id: 'first-party-child', mode: 'continuable', label: 'Direct child' }]
    },
    async listDescendants() { throw new Error('A descendant catalog must not be read') },
  }
  const services = { subagents, agents: ctx.agents }
  original.apply({ tools: ctx.tools, ...services })
  const definition = ctx.tools.get('list_agents', agent)
  assert.ok(definition)
  const review = reviewListAgentsForModelPtc({ runtime: ctx.tools, agent, definition, services })
  const signal = new AbortController().signal
  assert.equal(await review.authorizeArguments({}, { agent, signal }), true)
  assert.equal(await review.authorizeArguments({ scope: 'children' }, { agent, signal }), true)
  for (const args of [{ scope: 'descendants' }, { scope: 'children', extra: true },
    [], Object.create({ scope: 'children' }),
    Object.defineProperty({}, 'scope', { get() { throw new Error('getter ran') } })]) {
    assert.equal(await review.authorizeArguments(args, { agent, signal }), false)
  }
  assert.equal(await review.authorizeArguments({}, { agent: { id: agent.id }, signal }), false)
  const aborted = new AbortController()
  aborted.abort(new Error('parent cancelled'))
  await assert.rejects(review.authorizeArguments({}, { agent, signal: aborted.signal }),
    /parent cancelled/)
  assert.throws(() => reviewListAgentsForModelPtc({ runtime: ctx.tools, agent,
    definition: { name: 'list_agents' }, services }), /captured first-party/)
  assert.throws(() => reviewListAgentsForModelPtc({ runtime: ctx.tools, agent,
    definition, services: { ...services, agents: { get: () => ({ id: agent.id }) } } }),
  /captured first-party/)

  const caller = createAppOwnedListAgentsPtcCaller({ bridge, callbacks, runtime: ctx.tools,
    services,
  })
  ctx.tools.register(defineTool({ name: 'app_ptc_probe', description: 'Trusted test-only caller',
    parameters: {},
    output: { schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      const prepared = draft('const children = await tools.list_agents({}); let denied; try { await tools.list_agents({ scope: "descendants" }) } catch (error) { denied = error.code } return { children, denied }')
      return (await caller.start(prepared, execution).result).value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer-list', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(JSON.parse(JSON.stringify(result.value)), {
    children: [{ kind: 'child', id: 'first-party-child',
      label: 'Direct child', status: 'inactive' }],
    denied: 'ANDROID_TOOL_NOT_GRANTED',
  })
  assert.deepEqual(lookedUp, [agent.id])
  assert.equal(agent.session.snapshotEvents()
    .filter(event => event.type === 'tool/ptc-dispatch').length, 1)
})

test('production list_agents caller rejects a replacement registration and closes with its owner', async t => {
  const { ctx, agent, bridge, callbacks, defineTool, draft, calls } = await setup(t)
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const services = { agents: ctx.agents, subagents: {
    async listChildren() { return [] },
    async listDescendants() { throw new Error('descendants must stay hidden') },
  } }
  let unregister
  original.apply({ ...services, tools: {
    register(definition) { unregister = ctx.tools.register(definition) },
  } })
  const caller = createAppOwnedListAgentsPtcCaller({
    bridge, callbacks, runtime: ctx.tools, services,
  })
  let outerExecution
  ctx.tools.register(defineTool({
    name: 'app_ptc_probe', description: 'Trusted test-only parent', parameters: {},
    output: { schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      outerExecution = execution
      const first = await caller.start(draft('return await tools.list_agents({})'), execution).result
      unregister()
      ctx.tools.register(defineTool({ name: 'list_agents', description: 'Impostor', parameters: {},
        output: { schema: { type: 'array', items: { type: 'string' } },
          render: () => [{ type: 'text', text: 'impostor' }] },
        async execute() { throw new Error('impostor must never run') },
      }))
      assert.throws(() => caller.start(draft('return await tools.list_agents({})'), execution),
        /captured first-party list_agents definition/)
      return first.value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer-replacement', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(result.value, [])
  assert.deepEqual(calls, ['native.isolated.admit', 'native.isolated.bindTools',
    'native.isolated.execute', 'native.isolated.settle', 'native.isolated.release'])
  caller.close()
  assert.throws(() => caller.start(draft('return 1'), outerExecution), /owner is closed/)
})

test('closing the App owner cancels an admitted pending PTC start', async t => {
  const { ctx, agent, bridge, callbacks, defineTool, draft, calls } = await setup(t)
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const services = { agents: ctx.agents, subagents: {
    async listChildren() { return [] },
    async listDescendants() { throw new Error('descendants must stay hidden') },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const caller = createAppOwnedListAgentsPtcCaller({
    bridge, callbacks, runtime: ctx.tools, services,
  })
  ctx.tools.register(defineTool({
    name: 'app_ptc_probe', description: 'Trusted test-only parent', parameters: {},
    output: { schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }] },
    async execute(_args, execution) {
      const run = caller.start(draft('return await tools.list_agents({})'), execution)
      caller.close()
      assert.equal(run.cancelled, true)
      await assert.rejects(run.result, { code: 'ANDROID_EXECUTION_CANCELLED' })
      return 'cancelled'
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer-owner-close', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value, 'cancelled')
  assert.deepEqual(calls, [])
})

test('App owner close joins an in-flight first-party child query before transport teardown', async t => {
  const entered = Promise.withResolvers()
  const release = Promise.withResolvers()
  const { ctx, agent, bridge, callbacks, defineTool, draft, calls } = await setup(t)
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  let childQueries = 0
  const services = { agents: ctx.agents, subagents: {
    async listChildren(id, signal) {
      assert.equal(id, agent.id)
      childQueries++
      entered.resolve()
      await release.promise
      signal.throwIfAborted()
      return []
    },
    async listDescendants() { throw new Error('descendants must stay hidden') },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const caller = createAppOwnedListAgentsPtcCaller({
    bridge, callbacks, runtime: ctx.tools, services,
  })
  let parent
  ctx.tools.register(defineTool({
    name: 'app_ptc_probe', description: 'Trusted test-only parent', parameters: {},
    output: { schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      parent = execution
      return (await caller.start(draft('return await tools.list_agents({})'), execution).result).value
    },
  }))
  const outer = ctx.tools.execute({ callId: 'outer-close-join', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  await entered.promise
  const close = caller.close()
  assert.strictEqual(caller.close(), close)
  assert.throws(() => caller.start(draft('return 1'), parent), /owner is closed/)
  let settled = false
  close.finally(() => { settled = true }).catch(() => {})
  await Promise.resolve()
  assert.equal(settled, false, 'owner retirement must wait for its active callback')
  release.resolve()
  await close
  assert.equal(settled, true)
  assert.equal((await outer).isError, true)
  assert.equal(childQueries, 1)
  assert.ok(calls.includes('native.isolated.cancel'))
  assert.ok(calls.includes('native.isolated.release'))
})

test('App owner teardown reports an unconfirmed native retirement', async t => {
  const executing = Promise.withResolvers()
  const release = Promise.withResolvers()
  const { ctx, agent, bridge, callbacks, defineTool, draft } = await setup(t, {
    async beforeExecute() { executing.resolve(); await release.promise },
    onCancel: () => release.resolve(),
    failRelease: true,
  })
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const services = { agents: ctx.agents, subagents: {
    async listChildren() { return [] },
    async listDescendants() { throw new Error('descendants must stay hidden') },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const caller = createAppOwnedListAgentsPtcCaller({
    bridge, callbacks, runtime: ctx.tools, services,
  })
  ctx.tools.register(defineTool({
    name: 'app_ptc_probe', description: 'Trusted test-only parent', parameters: {},
    output: { schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      return (await caller.start(draft('return await tools.list_agents({})'), execution).result).value
    },
  }))
  const outer = ctx.tools.execute({ callId: 'outer-retirement-fail', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  await executing.promise
  const closing = caller.close()
  await assert.rejects(closing, error => error instanceof AggregateError
    && error.errors.some(reason => reason.code === 'ANDROID_EXECUTION_UNCONFIRMED'))
  assert.strictEqual(caller.close(), closing)
  assert.equal((await outer).isError, true)
})

test('real Agent and ToolRuntime own the parent token for an isolated tool callback', async t => {
  const { ctx, agent, calls, bridge, callbacks, defineTool, draft, journal } = await setup(t)
  let innerCalls = 0
  const safeEcho = defineTool({ name: 'safe_echo', description: 'Reviewed pure echo',
    parameters: { text: { type: 'string', required: true } },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute(args) { innerCalls++; return args.text },
  })
  ctx.tools.register(safeEcho)
  const caller = createAppOwnedModelPtcCaller({ bridge, callbacks, runtime: ctx.tools,
    reviewedTools: [{ name: 'safe_echo', definition: safeEcho,
      registrationIdentity: ctx.tools.registrationIdentity('safe_echo', agent), effect: 'pure' }],
  })
  let parentToken
  let parentExecution
  let runId
  ctx.tools.register(defineTool({ name: 'app_ptc_probe', description: 'Trusted test-only outer caller',
    parameters: {},
    output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      parentToken = execution.token
      parentExecution = execution
      assert.throws(() => caller.start(draft('return 1'), { ...execution }),
        /current ToolRuntime parent execution/)
      const prepared = draft('let rejected; try { await tools.safe_echo({}) } catch (error) { rejected = error.code } const text = await tools.safe_echo({ text: "hello" }); return { text, rejected }')
      runId = prepared.execution.runId
      return (await caller.start(prepared, execution).result).value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(JSON.parse(JSON.stringify(result.value)),
    { text: 'hello', rejected: 'ANDROID_TOOL_DISPATCH_FAILED' })
  assert.equal(typeof parentToken, 'symbol')
  assert.throws(() => caller.start(draft('return 1'), parentExecution),
    /current ToolRuntime parent execution/)
  assert.equal(innerCalls, 1)
  assert.deepEqual(calls, ['native.isolated.admit', 'native.isolated.bindTools',
    'native.isolated.execute', 'native.isolated.settle', 'native.isolated.release'])
  const audit = agent.session.snapshotEvents().filter(event => event.type.startsWith('tool/ptc-dispatch'))
  assert.deepEqual(audit.map(event => event.type), [
    'tool/ptc-dispatch-start', 'tool/ptc-dispatch',
    'tool/ptc-dispatch-start', 'tool/ptc-dispatch',
  ])
  assert.equal(audit[0].data.parentCallId, 'outer')
  assert.equal(audit[0].data.subCallId, 'outer:ptc:1')
  assert.equal((await journal.inspect({ runId, callId: 1 })).state, 'confirmed')
  assert.equal((await journal.inspect({ runId, callId: 1 })).outcome, 'tool-error')
  assert.equal((await journal.inspect({ runId, callId: 2 })).outcome, 'success')
})

test('a reviewed list cannot label writes as safe or admit an unrestricted reader', async t => {
  const { ctx, agent, bridge, callbacks, defineTool } = await setup(t)
  const definition = defineTool({ name: 'private_reader', description: 'A reader requiring scoped arguments',
    parameters: {}, output: { schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { return 'private data' },
  })
  ctx.tools.register(definition)
  const review = { name: definition.name, definition,
    registrationIdentity: ctx.tools.registrationIdentity(definition.name, agent) }
  for (const entry of [
    { ...review, effect: 'write', authorizeArguments: async () => true },
    { ...review, effect: 'read-only' },
    { ...review, effect: 'read-only', authorizeArguments: true },
  ]) {
    assert.throws(() => createAppOwnedModelPtcCaller({ bridge, callbacks,
      runtime: ctx.tools, reviewedTools: [entry] }),
    /reviewed tool definition and effect/)
  }
  for (const name of ['read', 'write', 'edit', 'android_files', 'android_shell', 'workflow']) {
    const ambient = defineTool({ name, description: 'Host authority', parameters: {},
      output: { schema: { type: 'string' },
        render: (_args, value) => [{ type: 'text', text: value }] },
      async execute() { return 'must not run' },
    })
    ctx.tools.register(ambient)
    assert.throws(() => createAppOwnedModelPtcCaller({ bridge, callbacks,
      runtime: ctx.tools, reviewedTools: [{ name, definition: ambient,
        registrationIdentity: ctx.tools.registrationIdentity(name, agent), effect: 'pure' }] }),
    /reviewed tool definition and effect/)
  }
})

test('reviewed mutation entries cannot omit authorization or durability, widen effects, or downgrade writes', async t => {
  const { ctx, agent, bridge, callbacks, defineTool } = await setup(t)
  for (const name of ['write', 'edit', 'android_attachments', 'private_writer']) {
    const definition = defineTool({ name, description: 'Review contract probe', parameters: {},
      output: { schema: { type: 'json' }, render: () => [] }, async execute() { return {} } })
    ctx.tools.register(definition)
    const entry = { name, definition, registrationIdentity: ctx.tools.registrationIdentity(name, agent),
      effect: 'workspace-write', authorizeArguments: async () => true, flushSession: async () => true }
    const invalid = [
      { ...entry, flushSession: undefined }, { ...entry, authorizeArguments: undefined },
      ...(name === 'android_attachments' ? [] : [{ ...entry, effectForArguments: () => 'read-only' }]),
      { ...entry, effect: 'read-only', effectForArguments: () => 'workspace-write' },
      ...(name === 'private_writer' ? [entry] : []),
    ]
    for (const review of invalid) assert.throws(() => createAppOwnedModelPtcCaller({
      bridge, callbacks, runtime: ctx.tools, reviewedTools: [review],
    }), /reviewed tool definition and effect/u)
  }
})

test('mixed attachment review selects effects per call and flushes only materialization', async t => {
  const { ctx, agent, bridge, callbacks, defineTool, draft } = await setup(t, { kind: 'ptc' })
  const performed = [], barriers = []
  const definition = defineTool({ name: 'android_attachments', description: 'Reviewed action probe',
    parameters: { action: { type: 'string', required: true } },
    output: { schema: { type: 'json' }, render: () => [] },
    async execute(args) { performed.push(args.action); return { action: args.action } },
  })
  ctx.tools.register(definition)
  const caller = createAppOwnedModelPtcCaller({ bridge, callbacks, runtime: ctx.tools,
    reviewedTools: [{ name: definition.name, definition,
      registrationIdentity: ctx.tools.registrationIdentity(definition.name, agent),
      effect: 'workspace-write', authorizeArguments: args => ['read', 'materialize', 'forged'].includes(args.action),
      effectForArguments: args => args.action === 'materialize' ? 'workspace-write'
        : args.action === 'forged' ? 'pure' : 'read-only',
      async flushSession() { barriers.push(performed.length); return true },
    }],
  })
  ctx.tools.register(defineTool({ name: 'app_ptc_probe', description: 'Trusted outer probe', parameters: {},
    output: { schema: { type: 'json' }, render: () => [] },
    async execute(_args, exec) {
      return (await caller.start(draft(`
        const read = await tools.android_attachments({ action: 'read' });
        const write = await tools.android_attachments({ action: 'materialize' });
        let denied;
        try { await tools.android_attachments({ action: 'forged' }) } catch (error) { denied = error.code }
        return { read, write, denied };
      `), exec).result).value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer', name: 'app_ptc_probe', arguments: {},
    agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(performed, ['read', 'materialize'])
  assert.deepEqual(barriers, [1, 2])
  assert.equal(result.value.denied, 'ANDROID_TOOL_NOT_GRANTED')
})

test('an unreviewed plugin is absent and an uncertain read approval stops the guest', async t => {
  const { ctx, agent, calls, bridge, callbacks, defineTool, draft } = await setup(t)
  let pluginCalls = 0
  const plugin = defineTool({ name: 'plugin_surprise', description: 'Unreviewed plugin',
    parameters: {}, output: { schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { pluginCalls++; return 'must not run' },
  })
  const reader = defineTool({ name: 'private_reader', description: 'Approval-owned read',
    parameters: {}, output: { schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { pluginCalls++; return 'must not run' },
  })
  ctx.tools.register(plugin)
  ctx.tools.register(reader)
  const caller = createAppOwnedModelPtcCaller({ bridge, callbacks, runtime: ctx.tools,
    reviewedTools: [{ name: reader.name, definition: reader,
      registrationIdentity: ctx.tools.registrationIdentity(reader.name, agent),
      effect: 'read-only', async authorizeArguments() { throw new Error('approval audit unavailable') } }],
  })
  ctx.tools.register(defineTool({ name: 'app_ptc_probe', description: 'Trusted test-only caller',
    parameters: {}, output: { schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      const prepared = draft('return { plugin: typeof tools.plugin_surprise, read: await tools.private_reader({}) }')
      return (await caller.start(prepared, execution).result).value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer-approval', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  assert.equal(result.isError, true)
  assert.equal(pluginCalls, 0)
  assert.ok(calls.includes('native.isolated.cancel'))
  assert.equal(agent.session.snapshotEvents()
    .filter(event => event.type.startsWith('tool/ptc-dispatch')).length, 0)
})

test('reviewed registration identity and owner scope deny same-object re-registration and forged authority', async t => {
  const { ctx, agent, calls, bridge, callbacks, defineTool, draft } = await setup(t)
  let innerCalls = 0
  const definition = defineTool({ name: 'safe_echo', description: 'First reviewed definition',
    parameters: {}, output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { innerCalls++; return 'reviewed' },
  })
  const remove = ctx.tools.register(definition)
  const caller = createAppOwnedModelPtcCaller({ bridge, callbacks, runtime: ctx.tools,
    reviewedTools: [{ name: 'safe_echo', definition,
      registrationIdentity: ctx.tools.registrationIdentity('safe_echo', agent), effect: 'pure' }],
  })
  remove()
  ctx.tools.register(definition)
  let denied
  ctx.tools.register(defineTool({ name: 'app_ptc_probe', description: 'Trusted test-only caller',
    parameters: {}, output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      assert.throws(() => prepareModelIsolatedScript({ code: 'return 1',
        description: 'forgery', language: 'typescript-function-body',
        sessionId: 'forged', allowedToolNames: ['safe_echo'] }, {
        sessionId: agent.session.id,
        sandboxPolicy: projectIsolatedSandboxPolicy({ approvedScope: {
          ownerId: 'app-model-tool', sessionId: agent.session.id, version: 1,
          workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
          fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
        } }), deadlineMillis: 5000,
      }), { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
      const prepared = draft('return { ok: true }')
      assert.throws(() => caller.start(prepared, { ...execution,
        agent: { session: { id: 'forged', append() {} } } }), /parent execution/)
      const valid = draft('return { ok: true, visible: typeof tools.safe_echo }')
      const value = (await caller.start(valid, execution).result).value
      // The replacement is absent from the reviewed allowlist at binding.
      try {
        const attempted = draft('return await host.callAsync({ action: "TOOL_CALL", callId: 1, name: "safe_echo", arguments: {} })')
        denied = (await caller.start(attempted, execution).result).value.error.code
      } catch (error) { denied = error.code }
      return value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(JSON.parse(JSON.stringify(result.value)), { ok: true, visible: 'undefined' })
  assert.equal(denied, 'ANDROID_TOOL_NOT_GRANTED')
  assert.equal(innerCalls, 0)
  assert.equal(agent.session.snapshotEvents().filter(event => event.type.startsWith('tool/ptc-dispatch')).length, 0)
  assert.ok(calls.includes('native.isolated.admit'))
})

test('production model registration stays absent under the source-controlled closed gate', async t => {
  const { ctx, agent, calls, bridge, callbacks } = await setup(t)
  const owner = createAppOwnedListAgentsPtcOwner({ bridge, callbacks, runtime: ctx.tools,
    services: { agents: ctx.agents, subagents: {
      async listChildren() { throw new Error('closed gate reached list_agents') },
    } },
  })
  const before = ctx.tools.schemas(agent).map(tool => tool.name)
  assert.equal(registerAndroidPtcTool(ctx, { owner, available: () => false }), false)
  assert.deepEqual(ctx.tools.schemas(agent).map(tool => tool.name), before)
  assert.deepEqual(calls, [])
  await owner.close()
})

test('accepted model tool uses a real parent, first-party child review and durable result', async t => {
  const { ctx, agent, calls, bridge, callbacks } = await setup(t)
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const lookedUp = []
  const services = { agents: ctx.agents, subagents: {
    async listChildren(id, signal) {
      signal.throwIfAborted()
      lookedUp.push(id)
      return [{ id: 'child-1', mode: 'continuable', label: 'First child' }]
    },
    async listDescendants() { throw new Error('recursive catalog is forbidden') },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const owner = createAppOwnedListAgentsPtcOwner({ bridge, callbacks, runtime: ctx.tools, services })
  let accepted = true
  assert.equal(registerAndroidPtcTool(ctx, { owner, available: () => accepted }), true)
  assert(ctx.tools.schemas(agent).some(schema => schema.name === 'android_ptc'))
  const tool = createAndroidPtcToolDefinition({ owner, available: () => accepted })
  assert.deepEqual(Object.keys(tool.parameters.properties), ['code', 'description'])
  const input = { code: 'return await tools.list_agents({ scope: "children" })',
    description: 'List direct children' }
  const result = await ctx.tools.execute({ callId: 'outer-model-tool', name: 'android_ptc',
    arguments: input, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(JSON.parse(JSON.stringify(result.value)), { logs: [], result: [{
    kind: 'child', id: 'child-1', label: 'First child', status: 'inactive',
  }] })
  assert.deepEqual(lookedUp, [agent.id])
  assert.deepEqual(calls, ['native.isolated.admit', 'native.isolated.bindTools',
    'native.isolated.execute', 'native.isolated.settle', 'native.isolated.release'])
  for (const extra of [{ language: 'python' }, { runId: randomUUID() },
    { writablePaths: ['/'] }, { networkMode: 'allow' }]) {
    const blocked = await ctx.tools.execute({ callId: `forged-${Object.keys(extra)[0]}`,
      name: 'android_ptc', arguments: { ...input, ...extra }, agent,
      signal: new AbortController().signal })
    assert.equal(blocked.isError, true)
  }
  assert.equal(calls.filter(call => call === 'native.isolated.admit').length, 1)
  accepted = false
  const denied = await ctx.tools.execute({ callId: 'revoked-model-tool',
    name: 'android_ptc', arguments: input, agent,
    signal: new AbortController().signal })
  assert.equal(denied.isError, true)
  assert.equal(calls.filter(call => call === 'native.isolated.admit').length, 1)
  await owner.close()
})

test('model PTC withholds output if the build gate closes during a native run', async t => {
  let accepted = true
  const { ctx, agent, calls, bridge, callbacks } = await setup(t, {
    beforeExecute() { accepted = false },
  })
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const services = { agents: ctx.agents, subagents: {
    async listChildren() { return [] },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const owner = createAppOwnedListAgentsPtcOwner({ bridge, callbacks, runtime: ctx.tools, services })
  assert.equal(registerAndroidPtcTool(ctx, { owner, available: () => accepted }), true)
  const result = await ctx.tools.execute({ callId: 'revoked-during-native-run',
    name: 'android_ptc', arguments: { code: 'return 7', description: 'Return a number' },
    agent, signal: new AbortController().signal })
  assert.equal(result.isError, true)
  assert.equal(result.value, undefined)
  assert.deepEqual(calls, ['native.isolated.admit', 'native.isolated.bindTools',
    'native.isolated.execute', 'native.isolated.settle', 'native.isolated.release'])
  await owner.close()
})

test('cancelled model PTC never publishes a late native result and joins retirement', async t => {
  let entered
  const waiting = new Promise(resolve => { entered = resolve })
  let unblock
  const hold = new Promise(resolve => { unblock = resolve })
  const { ctx, agent, calls, bridge, callbacks } = await setup(t, {
    beforeExecute() { entered(); return hold },
  })
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const services = { agents: ctx.agents, subagents: {
    async listChildren() { return [] },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const owner = createAppOwnedListAgentsPtcOwner({ bridge, callbacks, runtime: ctx.tools, services })
  assert.equal(registerAndroidPtcTool(ctx, { owner, available: () => true }), true)
  const controller = new AbortController()
  const result = ctx.tools.execute({ callId: 'cancelled-model-ptc', name: 'android_ptc',
    arguments: { code: 'return 7', description: 'Return a number' },
    agent, signal: controller.signal })
  await waiting
  controller.abort(new Error('user cancelled'))
  unblock()
  const completed = await result
  assert.equal(completed.isError, true)
  assert.equal(completed.value, undefined)
  assert(calls.includes('native.isolated.cancel'))
  assert.equal(calls.at(-1), 'native.isolated.release')
  await owner.close()
})

test('unloading the model PTC owner cancels and joins a pending model tool', async t => {
  let entered
  const waiting = new Promise(resolve => { entered = resolve })
  let unblock
  const hold = new Promise(resolve => { unblock = resolve })
  const { ctx, agent, calls, bridge, callbacks } = await setup(t, {
    beforeExecute() { entered(); return hold },
    onCancel() { unblock() },
  })
  const original = await import('@deepseek-ai/dsh-tool-subagent-control/list-agents')
  const services = { agents: ctx.agents, subagents: {
    async listChildren() { return [] },
  } }
  original.apply({ ...services, tools: ctx.tools })
  const owner = createAppOwnedListAgentsPtcOwner({ bridge, callbacks, runtime: ctx.tools, services })
  assert.equal(registerAndroidPtcTool(ctx, { owner, available: () => true }), true)
  const pending = ctx.tools.execute({ callId: 'model-ptc-unload', name: 'android_ptc',
    arguments: { code: 'return 7', description: 'Return a number' }, agent,
    signal: new AbortController().signal })
  await waiting
  const close = owner.close()
  await close
  const result = await pending
  assert.equal(result.isError, true)
  assert.equal(result.value, undefined)
  assert(calls.includes('native.isolated.cancel'))
  assert.equal(calls.at(-1), 'native.isolated.release')
})

test('same definition re-registered during argument review cannot dispatch', async t => {
  const { ctx, agent, bridge, callbacks, defineTool, draft } = await setup(t)
  let bodyCalls = 0
  const definition = defineTool({ name: 'safe_echo', description: 'Reviewed pure echo',
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { bodyCalls++; return 'must not run' },
  })
  const remove = ctx.tools.register(definition)
  const caller = createAppOwnedModelPtcCaller({ bridge, callbacks, runtime: ctx.tools,
    reviewedTools: [{ name: 'safe_echo', definition,
      registrationIdentity: ctx.tools.registrationIdentity('safe_echo', agent), effect: 'pure',
      async authorizeArguments() { remove(); ctx.tools.register(definition); return true },
    }],
  })
  ctx.tools.register(defineTool({ name: 'app_ptc_probe', description: 'Trusted test-only caller',
    parameters: {},
    output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      const prepared = draft('try { await tools.safe_echo({}) } catch (error) { return { denied: error.code } } return { leaked: true }')
      return (await caller.start(prepared, execution).result).value
    },
  }))
  const result = await ctx.tools.execute({ callId: 'outer-race', name: 'app_ptc_probe',
    arguments: {}, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.deepEqual(JSON.parse(JSON.stringify(result.value)), { denied: 'ANDROID_TOOL_NOT_GRANTED' })
  assert.equal(bodyCalls, 0)
  assert.equal(agent.session.snapshotEvents().filter(event => event.type.startsWith('tool/ptc-dispatch')).length, 0)
})

test('parent cancellation retires the guest before a second reviewed tool callback', async t => {
  const entered = Promise.withResolvers()
  const release = Promise.withResolvers()
  const { ctx, agent, calls, bridge, callbacks, defineTool, draft } = await setup(t, {
    onCancel: () => release.resolve(),
  })
  let innerCalls = 0
  const definition = defineTool({ name: 'safe_echo', description: 'Reviewed pure echo',
    parameters: { text: { type: 'string', required: true } },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute(args) {
      innerCalls++
      entered.resolve()
      await release.promise
      return args.text
    },
  })
  ctx.tools.register(definition)
  const caller = createAppOwnedModelPtcCaller({ bridge, callbacks, runtime: ctx.tools,
    reviewedTools: [{ name: 'safe_echo', definition,
      registrationIdentity: ctx.tools.registrationIdentity('safe_echo', agent), effect: 'pure' }],
  })
  let receipt
  ctx.tools.register(defineTool({ name: 'app_ptc_probe', description: 'Trusted test-only caller',
    parameters: {}, output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      const prepared = draft('try { await tools.safe_echo({ text: "first" }) } catch {}\ntry { await tools.safe_echo({ text: "second" }) } catch {}\nreturn { leaked: true }')
      receipt = await caller.start(prepared, execution).result
      return receipt
    },
  }))
  const controller = new AbortController()
  const outer = ctx.tools.execute({ callId: 'outer-cancel', name: 'app_ptc_probe',
    arguments: {}, agent, signal: controller.signal })
  await entered.promise
  controller.abort(new Error('stop'))
  const result = await outer
  assert.equal(result.isError, true)
  assert.equal(innerCalls, 1)
  assert.ok(receipt === undefined || receipt.state === 'failed')
  assert.equal(receipt === undefined || !Object.hasOwn(receipt, 'value'), true)
  assert.ok(calls.includes('native.isolated.cancel'))
})
