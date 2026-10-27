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
