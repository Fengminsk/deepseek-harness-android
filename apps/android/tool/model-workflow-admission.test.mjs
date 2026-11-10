import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import {
  createAppOwnedModelWorkflowAdmission,
  projectModelWorkflowForeground,
  requireAppOwnedModelWorkflowAdmission,
} from '../runtime/model-workflow-admission.mjs'
import { createNativeWorkflowPrivateOwner } from '../runtime/native-workflow-private-owner.mjs'
import { projectIsolatedSandboxPolicy } from '../runtime/isolated-sandbox-policy.mjs'
import { executeToolCall } from './tool-batch-fixture.mjs'

const stagedRequire = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const staged = name => import(pathToFileURL(stagedRequire.resolve(name)).href)

async function setup(t) {
  const [{ Context }, { default: LlmRuntime }, { default: SessionStore, SessionId },
    { default: SessionProjections }, { default: SystemPrompt },
    { default: ToolRuntime, defineTool }, { default: AgentRegistry },
    { default: AgentLoop }, NativeToolExecutor] = await Promise.all([
    staged('@deepseek-ai/cordis'), staged('@deepseek-ai/dsh-llm'),
    staged('@deepseek-ai/dsh-session'), staged('@deepseek-ai/dsh-session-projection'),
    staged('@deepseek-ai/dsh-system-prompt'), staged('@deepseek-ai/dsh-tools'),
    staged('@deepseek-ai/dsh-agent'), staged('@deepseek-ai/dsh-agent-loop'),
    staged('@deepseek-ai/dsh-tool-executor-native'),
  ])
  const ctx = new Context()
  t.after(() => ctx.fiber.dispose())
  for (const plugin of [LlmRuntime, SessionStore, SessionProjections, SystemPrompt,
    ToolRuntime, NativeToolExecutor, AgentRegistry]) await ctx.plugin(plugin)
  await ctx.plugin(AgentLoop, { agents: [] })
  const agent = await ctx.agentLoop.create(SessionId(randomUUID()))
  const policy = projectIsolatedSandboxPolicy({ approvedScope: {
    ownerId: 'app-workflow', sessionId: agent.session.id, version: 1,
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
  } })
  const host = { sandboxPolicy: policy, deadlineMillis: 5000,
    maxTotalAgents: 3, maxConcurrentAgents: 2 }
  const model = { script: 'const result = await agent("Review evidence"); return result',
    meta: { name: 'inspect', description: 'Review evidence' }, args: { paths: ['a.md'] } }
  return { ctx, agent, defineTool, host, model }
}

function probe(defineTool, execute) {
  return defineTool({ name: 'workflow', description: 'First-party workflow seam under test',
    parameters: { script: { type: 'string', required: true },
      meta: { type: 'object', required: true, additionalProperties: true } },
    output: { schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    execute,
  })
}

test('a real Agent and ToolRuntime bind model workflow data to the App policy', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let admission
  let executionAfterSettlement
  let ticketAfterSettlement
  const definition = probe(defineTool, async (args, execution) => {
    executionAfterSettlement = execution
    await assert.rejects(admission.prepare(args, { ...execution }),
      /current first-party parent execution/)
    const ticket = await admission.prepare(args, execution)
    ticketAfterSettlement = ticket
    assert.equal(ticket.sessionId, agent.session.id)
    assert.equal(ticket.maxConcurrentAgents, 2)
    assert.equal(ticket.execution, undefined)
    assert.throws(() => admission.run({ ...ticket }), /current App-owned draft/)
    assert.throws(() => admission.run(ticket), { code: 'ANDROID_PTC_UNAVAILABLE' })
    return { prepared: true, runId: ticket.runId }
  })
  ctx.tools.register(definition)
  let issuedTo
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost({ agent: owner, signal }) {
      issuedTo = owner
      signal.throwIfAborted()
      return host
    },
  })
  assert.equal(requireAppOwnedModelWorkflowAdmission(admission), admission)
  assert.throws(() => requireAppOwnedModelWorkflowAdmission({ ...admission }),
    /App-owned model workflow admission/)
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-model', name: 'workflow',
    arguments: model, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value.prepared, true)
  assert.equal(issuedTo, agent)
  await assert.rejects(admission.prepare(model, executionAfterSettlement),
    /current first-party parent execution/)
  assert.throws(() => admission.run(ticketAfterSettlement), /current App-owned draft/)
})

test('a reviewed workflow ticket carries only App policy to one private native run', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let admission
  let starts = 0
  const definition = probe(defineTool, async (args, execution) => {
    const ticket = await admission.prepare(args, execution)
    const result = await admission.executePrivate(ticket)
    assert.equal(result, 'private-receipt')
    assert.throws(() => admission.executePrivate(ticket), /current App-owned draft/)
    assert.throws(() => admission.run(ticket), /current App-owned draft/)
    return { runId: ticket.runId }
  })
  ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost: () => host,
    runPrepared({ prepared, parent, signal }) {
      starts += 1
      assert.equal(parent, agent)
      assert.equal(signal.aborted, false)
      assert.equal(prepared.kind, 'workflow')
      assert.equal(prepared.sessionId, agent.session.id)
      assert.equal(prepared.program, model.script)
      assert.deepEqual(prepared.scope.readablePaths, [])
      assert.deepEqual(prepared.scope.exactHosts, [])
      return Promise.resolve('private-receipt')
    },
  })
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-private', name: 'workflow',
    arguments: model, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(starts, 1)
})

test('confirmed foreground receipt projects the original workflow result shape', () => {
  const ticket = { runId: randomUUID(), sessionId: randomUUID() }
  const receipt = { ...ticket, state: 'COMPLETED', requiresReview: false,
    outputJson: '{"value":{"answer":"done"},"stopReason":"completed","agentsStarted":2}' }
  assert.deepEqual(projectModelWorkflowForeground(receipt, ticket), {
    kind: 'foreground', runId: ticket.runId, agentsStarted: 2, result: { answer: 'done' },
  })
  for (const bad of [
    { ...receipt, runId: randomUUID() },
    { ...receipt, sessionId: randomUUID() },
    { ...receipt, state: 'CANCELLED', outputJson: null },
    { ...receipt, requiresReview: true },
    { ...receipt, outputJson: '{"stopReason":"error","agentsStarted":2,"value":"partial"}' },
    { ...receipt, outputJson: '{"stopReason":"completed","agentsStarted":-1,"value":null}' },
  ]) assert.throws(() => projectModelWorkflowForeground(bad, ticket),
    /no confirmed foreground result|foreground result is invalid/)
})

test('native admission failure consumes the reviewed workflow ticket', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let admission
  let starts = 0
  const definition = probe(defineTool, async (args, execution) => {
    const ticket = await admission.prepare(args, execution)
    await assert.rejects(admission.executePrivate(ticket), /admission refused/)
    assert.throws(() => admission.executePrivate(ticket), /current App-owned draft/)
    return { rejected: true }
  })
  ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost: () => host,
    async runPrepared() { starts += 1; throw new Error('admission refused') },
  })
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-refused', name: 'workflow',
    arguments: model, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false)
  assert.equal(starts, 1)
})

test('cancellation after preparation prevents private workflow admission', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  const controller = new AbortController()
  let admission
  let starts = 0
  const definition = probe(defineTool, async (args, execution) => {
    const ticket = await admission.prepare(args, execution)
    controller.abort(new Error('parent cancelled'))
    assert.throws(() => admission.executePrivate(ticket), /current App-owned draft/)
    return { cancelled: true }
  })
  ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost: () => host,
    runPrepared() { starts += 1 },
  })
  await executeToolCall(ctx.tools, { callId: 'workflow-cancel-after-prep', name: 'workflow',
    arguments: model, agent, signal: controller.signal })
  assert.equal(starts, 0)
})

test('definition replacement or owner teardown invalidates an already prepared workflow', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let admission
  let starts = 0
  let available = true
  let unregister
  const definition = probe(defineTool, async (args, execution) => {
    const replaced = await admission.prepare(args, execution)
    unregister()
    unregister = ctx.tools.register(definition)
    assert.throws(() => admission.executePrivate(replaced), /current App-owned draft/)
    // A second, live registration gets its own admission; the old identity
    // can never authorize a ticket after the owner has been retired.
    available = false
    assert.throws(() => admission.executePrivate(replaced), /current App-owned draft/)
    return { revoked: true }
  })
  unregister = ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost: () => host, isAvailable: () => available,
    runPrepared() { starts += 1 },
  })
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-replaced-after-prep',
    name: 'workflow', arguments: model, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false)
  assert.equal(starts, 0)
})

test('private owner disposal between preparation and execution rejects without native admission', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let admission
  let starts = 0
  let available = true
  const definition = probe(defineTool, async (args, execution) => {
    const ticket = await admission.prepare(args, execution)
    available = false
    assert.throws(() => admission.executePrivate(ticket), /current App-owned draft/)
    return { retired: true }
  })
  ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost: () => host, isAvailable: () => available,
    runPrepared() { starts += 1 },
  })
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-owner-retired', name: 'workflow',
    arguments: model, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false)
  assert.equal(starts, 0)
})

test('re-registration during App approval revokes the old workflow definition', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let issueStarted
  const issued = new Promise(resolve => { issueStarted = resolve })
  let allow
  const approval = new Promise(resolve => { allow = resolve })
  let admission
  const definition = probe(defineTool, (args, execution) => admission.prepare(args, execution))
  const unregister = ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    async issueHost() { issueStarted(); await approval; return host },
  })
  const result = executeToolCall(ctx.tools, { callId: 'workflow-replaced', name: 'workflow',
    arguments: model, agent, signal: new AbortController().signal })
  await issued
  unregister()
  ctx.tools.register(definition)
  allow()
  const settled = await result
  assert.equal(settled.isError, true)
  assert.match(settled.content[0].text, /parent execution changed/)
})

test('model arguments cannot select another Session, background owner or capability scope', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let admission
  const definition = probe(defineTool, async (args, execution) => {
    const valid = await admission.prepare(args, execution)
    assert.equal(valid.sessionId, agent.session.id)
    for (const extra of [{ sessionId: randomUUID() }, { maxTotalAgents: 128 },
      { scope: { readablePaths: ['private/'] } }, { run_in_background: true }]) {
      await assert.rejects(admission.prepare({ ...args, ...extra }, execution),
        { code: extra.run_in_background ? 'ANDROID_WORKFLOW_BACKGROUND_UNAVAILABLE'
          : 'ANDROID_WORKFLOW_MODEL_INVALID' })
    }
    return { rejected: true }
  })
  ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost: () => host,
  })
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-authority', name: 'workflow',
    arguments: model, agent, signal: new AbortController().signal })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value.rejected, true)
})

test('the original workflow registration is captured by identity, not its model name', async t => {
  const { ctx, agent, defineTool, host } = await setup(t)
  const original = await staged('@deepseek-ai/dsh-tool-workflow')
  original.apply(ctx, { toolName: 'workflow', maxResultChars: 50000,
    enableRunInBackground: false })
  const firstParty = ctx.tools.get('workflow', agent)
  const identity = ctx.tools.registrationIdentity('workflow', agent)
  assert.ok(firstParty)
  assert.equal(firstParty.name, 'workflow')
  const impostor = probe(defineTool, async () => ({ forged: true }))
  assert.throws(() => createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition: impostor, registrationIdentity: identity,
    issueHost: () => host,
  }), /App-captured ToolRuntime definition/)
  const owner = createNativeWorkflowPrivateOwner(ctx,
    { bind() {}, async dispose() {} }, { request() {} })
  const admission = owner.modelAdmission({ agent, definition: firstParty,
    registrationIdentity: identity, issueHost: () => host })
  assert.equal(requireAppOwnedModelWorkflowAdmission(admission), admission)
  await owner.dispose()
  assert.throws(() => owner.modelAdmission({ agent, definition: firstParty,
    registrationIdentity: identity, issueHost: () => host }), /owner has closed/)
})

test('a cancelled policy decision cannot prepare a workflow for its former parent', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  const controller = new AbortController()
  let admission
  const definition = probe(defineTool, (args, execution) => admission.prepare(args, execution))
  ctx.tools.register(definition)
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost() { controller.abort(new Error('user cancelled')); return host },
  })
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-cancelled', name: 'workflow',
    arguments: model, agent, signal: controller.signal })
  assert.equal(result.isError, true)
})

test('the App cannot issue a workflow scope for a different durable Session', async t => {
  const { ctx, agent, defineTool, host, model } = await setup(t)
  let admission
  const definition = probe(defineTool, (args, execution) => admission.prepare(args, execution))
  ctx.tools.register(definition)
  const foreignPolicy = projectIsolatedSandboxPolicy({ approvedScope: {
    ownerId: 'app-workflow', sessionId: randomUUID(), version: 1,
    workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
  } })
  admission = createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools,
    agents: ctx.agents, agent, definition,
    registrationIdentity: ctx.tools.registrationIdentity('workflow', agent),
    issueHost: () => ({ ...host, sandboxPolicy: foreignPolicy }),
  })
  const result = await executeToolCall(ctx.tools, { callId: 'workflow-foreign-scope', name: 'workflow',
    arguments: model, agent, signal: new AbortController().signal })
  assert.equal(result.isError, true)
  assert.match(result.content[0].text, /scope\/session deadline/)
})


