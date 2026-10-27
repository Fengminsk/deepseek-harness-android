import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { mkdtemp, mkdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import Include from '@deepseek-ai/cordis-plugin-include'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentPresets from '@deepseek-ai/dsh-agent-preset-registry'
import { SessionId } from '@deepseek-ai/dsh-session'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SubagentRuntime from '@deepseek-ai/dsh-subagent'
import * as Spawn from '@deepseek-ai/dsh-subagent-spawn-in-process'
import SandboxPolicy from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import Subprocess from '@deepseek-ai/dsh-subprocess-local'
import { TestSessionQuery } from '../../../packages/subagent/subagent/tests/test-session-query.ts'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { createWorkflowSubagentBackend, installWorkflowSubagentPreset } from '../runtime/workflow-subagent-backend.mjs'
import { WorkflowGuestHostPort } from '../runtime/workflow-guest-host-port.mjs'
import { FixtureAdapter, workflowModelScenario } from './device-runtime-acceptance/workflow-model-fixture.mjs'

// This host test exercises real AgentLoop/ToolRuntime/Session child behavior.
// It invokes the production child port directly and produces no native or device receipt.
async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-workflow-device-model-'))
  const workspace = join(root, 'workspace')
  await mkdir(workspace)
  const ctx = new Context()
  let port, backend, uninstall
  t.after(async () => {
    try { await port?.close() }
    finally {
      backend?.close()
      try { await uninstall?.() }
      finally { try { await ctx.fiber.dispose() } finally { await rm(root, { recursive: true, force: true }) } }
    }
  })
  await ctx.plugin(Loader)
  ctx.loader.builtins.include = Include
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(SandboxPolicy, { mode: 'workspace-write', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: workspace })
  await ctx.plugin(Subprocess)
  await ctx.plugin(JsonlSessionPersistence, { root: join(root, 'sessions'), compression: 'none' })
  await ctx.plugin(TestSessionQuery)
  await ctx.plugin(SubagentRuntime)
  await ctx.plugin(Spawn, { providerName: 'spawn' })
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(AgentPresets, { default: 'device-model-parent' })
  await ctx.agentPresets.register({ id: 'device-model-parent', plugins: [] })
  const adapter = new FixtureAdapter()
  const scenario = workflowModelScenario(options)
  adapter.scriptedStream = scenario.stream
  ctx.llm.registerAdapter(['device-acceptance'], adapter)
  const handle = await ctx.agents.create({ sessionId: SessionId(`parent-${randomUUID()}`), meta: { cwd: workspace },
    agentOptions: { provider: 'device-acceptance', model: 'fixture' },
    setup: async parentCtx => { await ctx.agentPresets.mount(parentCtx, 'device-model-parent') } })
  const parent = handle.agent
  uninstall = await installWorkflowSubagentPreset(ctx)
  const runId = randomUUID()
  backend = createWorkflowSubagentBackend({ ctx, parent, runId,
    authorize: async (_request, _signal, _parent, _runId, childId) => ({ runId, parentId: parent.id, childId }) })
  port = new WorkflowGuestHostPort({ prepared: { kind: 'workflow', runId, program: 'return 1', args: {},
    deadlineMillis: 10000, meta: { name: 'host-fixture-model', description: 'Validate scripted model behavior' },
    maxTotalAgents: 8, maxConcurrentAgents: 2 },
  authorizeChild: backend.authorizeChild, activateChild: backend.activateChild, onProgress: async () => {} })
  port.begin({})
  const children = new Map()
  ctx.on('subagent/start', info => { children.set(info.id, ctx.agents.get(info.id)) })
  async function child(key, fields = {}) {
    const published = await port.startChild({ prompt: `workflow-fixture:${key}`, ...fields }, randomUUID())
    try { return await port.childResult({ callId: published.callId }) }
    finally { await port.disposeChild({ callId: published.callId }) }
  }
  async function durableChildren(count) {
    assert.equal(children.size, count)
    for (const [id, child] of children) {
      assert.equal(ctx.agents.get(id), undefined)
      assert.notEqual(child.session.id, parent.session.id)
      const reader = await ctx.sessionPersistence.open(child.session.id, 'read')
      let events
      try { ({ events } = await reader.read(0, 10000)) } finally { await reader.close() }
      assert.ok(events.length > 0)
    }
    assert.equal(scenario.active, 0)
  }
  return { ctx, adapter, scenario, child, children, durableChildren, port }
}

test('fixture barrier observes two actual simultaneous model streams and preserves four retired Sessions', { timeout: 20000 }, async t => {
  const f = await fixture(t, { barrier: true })
  const results = await Promise.all(['first', 'second', 'third', 'fourth'].map(key => f.child(key)))
  assert.deepEqual(results.map(row => row.stopReason), ['completed', 'completed', 'completed', 'completed'])
  assert.deepEqual(results.map(row => row.output[0].text), ['answer:first', 'answer:second', 'answer:third', 'answer:fourth'])
  assert.equal(f.scenario.maxActive, 2)
  await f.durableChildren(4)
})

test('fixture model exception is an ordinary child failure and does not replace a successful sibling result', { timeout: 20000 }, async t => {
  const f = await fixture(t)
  const [failure, survivor] = await Promise.all([f.child('failure'), f.child('survivor')])
  assert.equal(failure.stopReason, 'error')
  assert.equal(survivor.stopReason, 'completed')
  assert.equal(survivor.output[0].text, 'answer:survivor')
  assert.equal(f.scenario.failed.length, 1)
  await f.durableChildren(2)
})

test('fixture structured stream invokes the real structured_output tool and preserves nested JSON', { timeout: 20000 }, async t => {
  const f = await fixture(t)
  const result = await f.child('structured', { schema: { type: 'object', properties: {
    label: { type: 'string' }, nested: { type: 'object' }, list: { type: 'array', items: {} } },
  required: ['label', 'nested', 'list'], additionalProperties: false } })
  assert.equal(result.stopReason, 'completed')
  assert.deepEqual(JSON.parse(JSON.stringify(result.structured)),
    { label: 'verified', nested: { count: 3, unicode: '中文' }, list: [true, null, 2] })
  const child = [...f.children.values()][0]
  const tools = child.session.snapshotEvents().filter(row => row.type === 'tool/result')
  const calls = child.session.snapshotEvents().filter(row => row.type === 'tool/call')
  assert.equal(tools.length, 1)
  assert.equal(tools[0].data.message.isError, false)
  assert.equal(calls.length, 1)
  assert.equal(calls[0].data.name, 'structured_output')
  assert.equal(tools[0].data.message.source.callId, calls[0].data.callId)
  await f.durableChildren(1)
})

test('a held actual model stream observes cancellation and is retired before port close resolves', { timeout: 20000 }, async t => {
  const f = await fixture(t)
  const running = f.child('hold-host')
  const rejected = assert.rejects(running)
  await Promise.race([f.scenario.entered, running.then(() => { throw new Error('Child finished before entering its model') })])
  await f.port.close()
  await rejected
  assert.deepEqual(f.scenario.aborted, ['hold-host'])
  await f.durableChildren(1)
})

test('real child authorization rejects a model-route widening before another model request starts', { timeout: 20000 }, async t => {
  const f = await fixture(t)
  const running = f.child('hold-host')
  const rejected = assert.rejects(running)
  await Promise.race([f.scenario.entered, running.then(() => { throw new Error('Child finished before entering its model') })])
  await assert.rejects(f.child('denied', { provider: 'not-the-parent-provider' }), /model route/)
  await f.port.close()
  await rejected
  assert.deepEqual(f.scenario.prompts, ['hold-host'])
  await f.durableChildren(1)
})

test('eight real child activations complete but a ninth cannot create a model call or Session', { timeout: 20000 }, async t => {
  const f = await fixture(t)
  for (let index = 0; index < 8; index++) assert.equal((await f.child(`limit-${index}`)).stopReason, 'completed')
  await assert.rejects(f.child('ninth'), /total child limit/)
  assert.equal(f.scenario.prompts.length, 8)
  await f.durableChildren(8)
})
