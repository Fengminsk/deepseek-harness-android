import assert from 'node:assert/strict'
import test from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId } from '@deepseek-ai/dsh-session'
import LocalJobRegistry from '@deepseek-ai/dsh-jobs-local'
import { createWorkflowToolDefinition } from '@deepseek-ai/dsh-tool-workflow'
import { createAppOwnedModelWorkflowAdmission } from '../runtime/model-workflow-admission.mjs'
import { modelWorkflowCapability, registerAndroidWorkflowTool } from '../runtime/tool-native-workflow.mjs'

const args = { script: 'return args.answer', meta: { name: 'inspect', description: 'Review supplied evidence' },
  args: { answer: 'done' } }

async function setup(t) {
  const ctx = new Context()
  t.after(() => ctx.fiber.dispose())
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(LocalJobRegistry, {})
  ctx.jobs.attachController('native-workflow-registration-test')
  const agent = await ctx.agentLoop.create(SessionId('android-1793060921975320-627842147'))
  const starts = []
  const owner = { modelAdmission(options) {
    return createAppOwnedModelWorkflowAdmission({ runtime: ctx.tools, agents: ctx.agents, ...options,
      runPrepared(request) {
        starts.push(request)
        return { runId: request.prepared.runId, sessionId: agent.session.id,
          state: 'COMPLETED', requiresReview: false,
          outputJson: JSON.stringify({ value: 'done', stopReason: 'completed', agentsStarted: 0 }) }
      },
      startBackground(request) {
        starts.push(request)
        const jobId = ctx.jobs.start({ kind: 'workflow', label: request.prepared.meta.name,
          owner: request.parent.id, toolCall: request.toolCall,
          run() {
            let stop
            const done = new Promise(resolve => { stop = resolve })
            return { done, cancel() { stop({ status: 'killed' }) } }
          },
        })
        return { kind: 'background', jobId, runId: request.prepared.runId }
      },
    })
  } }
  const execute = (arguments_ = args, signal = new AbortController().signal) => ctx.tools.execute({
    callId: 'workflow-model', name: 'workflow', arguments: arguments_, agent, signal,
  })
  return { ctx, agent, owner, starts, execute }
}

test('the production gate is closed by default and creates no model tool', async t => {
  const { ctx, owner, starts } = await setup(t)
  assert.equal(registerAndroidWorkflowTool(ctx, { owner }), false)
  assert.equal(ctx.tools.get('workflow'), undefined)
  assert.equal(modelWorkflowCapability().available, false)
  assert.equal(modelWorkflowCapability().background, false)
  assert.deepEqual(starts, [])
})

test('capability reports the reviewed maximum without opening the production gate', () => {
  const closed = modelWorkflowCapability()
  assert.deepEqual(closed, {
    available: false, reason: 'device-lifecycle-unverified',
    maxTotalAgents: 8, maxConcurrentAgents: 2, deadlineMillis: 120000, background: false,
    childTools: 'reviewed-parent-tools',
    reviewedChildTools: ['read', 'glob', 'grep', 'write', 'edit', 'web_search', 'web_fetch',
      'linux_exec', 'linux_import', 'linux_export', 'linux_inspect'],
    filesystem: 'activation-workspace-policy-intersection', network: 'reviewed-parent-web-tools',
    linuxDisk: 'child-session-private', linuxNetwork: 'off',
  })
  const admitted = modelWorkflowCapability(true)
  assert.deepEqual(admitted, { ...closed, available: true, reason: null, background: true })
  assert.throws(() => closed.reviewedChildTools.push('android_shell'), TypeError)
})

test('model-facing schema and assembled prompt describe actual inherited tools and restrictions', async t => {
  const { ctx, agent, owner } = await setup(t)
  registerAndroidWorkflowTool(ctx, { owner, available: () => true })
  const definition = ctx.tools.get('workflow', agent)
  const prompt = (await ctx.systemPrompt.assemble()).sections.find(section => section.name === 'tool:workflow')
  assert.ok(prompt)
  const description = definition.description
  const instruction = JSON.stringify(prompt)
  for (const name of modelWorkflowCapability().reviewedChildTools) {
    assert.ok(description.includes(name), `Description must expose ${name}`)
    assert.ok(instruction.includes(name), `Prompt must expose ${name}`)
  }
  assert.match(description, /maximum reviewed set, not a guarantee/u)
  assert.match(description, /both current parent and child sandbox policies and permission roots/u)
  assert.match(description, /original file observation checks/u)
  assert.match(description, /Web tools retain their inherited providers and checks/u)
  assert.match(description, /authorized tools before submitting structured_output/u)
  assert.match(description, /Linux tools appear only when already registered on the parent/u)
  assert.match(description, /child Session's private disk with no guest networking or App-UID Shell/u)
  assert.match(description, /otherwise command changes are discarded/u)
  assert.match(description, /later policy upgrades cannot widen the activation permission/u)
  assert.match(description, /linux_export publishes a new App file/u)
  assert.match(description, /Both transfers require activation-time and current parent\/child write permission/u)
  assert.match(description, /Linux execution capacity is one App-wide; serialize Linux steps across children/u)
  assert.match(description, /busy refusal means no native dispatch/u)
  assert.match(description, /do not treat it as completed or automatically replay it/u)
  for (const text of [description, instruction]) {
    assert.match(text, /parent.*model/u)
    assert.match(text, /Cold resume alone/u)
    assert.match(text, /no App-UID Shell, PTC, recursive delegation or cross-Session SAF\/attachment grants/u)
    assert.match(text, /no guest networking/u)
    assert.match(text, /both permission roots/u)
    assert.match(text, /Cold resume alone restores no file, web or Linux/u)
    assert.doesNotMatch(text, /model-only subagents|cannot read files|no file, browser or shell tools/u)
  }
  assert.match(instruction, /only when the user explicitly asks for workflows or multi-agent orchestration/u)
})

test('native registration reuses original parameters and real ToolRuntime identity with bounded App policy', async t => {
  const { ctx, agent, owner, starts, execute } = await setup(t)
  assert.equal(registerAndroidWorkflowTool(ctx, { owner, available: () => true }), true)
  const definition = ctx.tools.get('workflow', agent)
  const original = createWorkflowToolDefinition({ toolName: 'workflow',
    maxResultChars: 12_000, enableRunInBackground: true }, () => { throw Error('unused original runner') })
  assert.deepEqual(definition.parameters, original.parameters)
  assert.deepEqual(definition.output.schema, original.output.schema)
  const result = await execute()
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value.kind, 'foreground')
  assert.equal(result.value.result, 'done')
  assert.equal(starts.length, 1)
  assert.equal(starts[0].parent, agent)
  assert.equal(starts[0].prepared.sessionId, agent.session.id)
  assert.equal(starts[0].prepared.maxTotalAgents, 8)
  assert.equal(starts[0].prepared.maxConcurrentAgents, 2)
  assert.equal(starts[0].prepared.deadlineMillis, 120_000)
  assert.deepEqual(starts[0].prepared.scope.readablePaths, [])
  assert.deepEqual(starts[0].prepared.scope.exactHosts, [])
  assert.deepEqual(definition.presentCall(args), original.presentCall(args))
  const runtime = ctx.tools
  await ctx.fiber.dispose()
  assert.equal(runtime.get('workflow'), undefined)
})

test('background handoff keeps the actual Agent and ToolCall owner and uses real job cancellation', async t => {
  const { ctx, agent, owner, starts, execute } = await setup(t)
  registerAndroidWorkflowTool(ctx, { owner, available: () => true })
  const controller = new AbortController()
  const result = await execute({ ...args, run_in_background: true }, controller.signal)
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value.kind, 'background')
  assert.equal(starts[0].signal, undefined)
  assert.deepEqual(starts[0].toolCall, { callId: 'workflow-model', rootCallId: 'workflow-model' })
  controller.abort(new Error('tool step ended'))
  assert.equal(ctx.jobs.get(result.value.jobId, agent.id).status, 'running')
  assert.throws(() => ctx.jobs.get(result.value.jobId, SessionId('foreign')), /belongs to another session/)
  assert.equal(ctx.jobs.kill(result.value.jobId, agent.id, 'user cancelled'), 'requested')
  assert.equal((await ctx.jobs.wait(result.value.jobId, 1000, agent.id)).status, 'killed')
  assert.equal(ctx.jobs.read(result.value.jobId, agent.id).result, undefined)
})

test('closed availability and changed registrations cannot dispatch native work', async t => {
  const { ctx, agent, owner, starts, execute } = await setup(t)
  let available = true
  registerAndroidWorkflowTool(ctx, { owner, available: () => available })
  available = false
  assert.equal((await execute()).isError, true)
  available = true
  const definition = ctx.tools.get('workflow')
  // A scoped registration of even the same object has a different owner token.
  agent.ctx.tools.register(definition)
  assert.equal((await execute()).isError, true)
  assert.deepEqual(starts, [])
})
