import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import Include from '@deepseek-ai/cordis-plugin-include'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId } from '@deepseek-ai/dsh-session'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import AgentPresets from '@deepseek-ai/dsh-agent-preset-registry'
import Subagents from '@deepseek-ai/dsh-subagent'
import * as Spawn from '@deepseek-ai/dsh-subagent-spawn-in-process'
import SandboxPolicy from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { MockAdapter, textResponse } from '../../../packages/core/agent-loop/tests/mock-adapter.ts'
import { TestSessionQuery } from '../../../packages/subagent/subagent/tests/test-session-query.ts'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedPtcOwner } from '../runtime/model-ptc-reviewed-owner.mjs'
import { registerAndroidPtcTool } from '../runtime/tool-model-ptc.mjs'
import { createWorkflowSubagentBackend, installWorkflowSubagentPreset } from '../runtime/workflow-subagent-backend.mjs'
import { inPtcAcceptanceTurn } from './device-runtime-acceptance/ptc.mjs'

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-ptc-session-'))
  const workspace = join(root, 'workspace')
  await mkdir(workspace)
  await writeFile(join(workspace, 'fixture.txt'), 'persisted PTC callback\n')
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await ctx.plugin(Loader)
  ctx.loader.builtins.include = Include
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(SandboxPolicy, { mode: 'read-only', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: workspace })
  await ctx.plugin(FsTools, { readImage: false })
  await ctx.plugin(JsonlSessionPersistence, { root: join(root, 'sessions'), compression: 'none' })
  await ctx.plugin(TestSessionQuery)
  await ctx.plugin(Subagents)
  await ctx.plugin(Spawn, { providerName: 'spawn' })
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(AgentPresets, { default: 'acceptance-parent' })
  await ctx.agentPresets.register({ id: 'acceptance-parent', plugins: [] })
  const adapter = new MockAdapter([textResponse('continued parent'), textResponse('real child answer')])
  ctx.llm.registerAdapter(['mock'], adapter)
  const handle = await ctx.agents.create({ sessionId: SessionId(`ptc-parent-${randomUUID()}`),
    agentOptions: { provider: 'mock', model: 'mock' }, meta: { cwd: workspace },
    setup: async agentCtx => void await ctx.agentPresets.mount(agentCtx, 'acceptance-parent') })
  const agent = handle.agent
  let current, callbacks
  const AsyncFunction = (async () => {}).constructor
  const transport = { async request(method, params) {
    if (method === 'native.isolated.admit') {
      current = { ...params, token: randomUUID() }
      return { runId: params.runId, token: current.token }
    }
    if (method === 'native.isolated.bindTools') return true
    if (method === 'native.isolated.execute') {
      const script = new AsyncFunction('input', 'host', current.program)
      current.outputJson = JSON.stringify(await script(JSON.parse(current.inputJson), {
        async callAsync({ action, ...request }) {
          assert.equal(action, 'TOOL_CALL')
          const { runId, callId, ...reply } = await callbacks.call({ ...request,
            runId: current.runId, token: current.token })
          return reply
        },
      }))
      return true
    }
    if (method === 'native.isolated.settle') return { runId: current.runId, state: 'COMPLETED',
      outputJson: current.outputJson, detail: null, guestUid: 99001 }
    if (method === 'native.isolated.release' || method === 'native.isolated.cancel') return true
    throw new Error(method)
  } }
  callbacks = new NativeIsolatedToolCallbacks(transport, new IsolatedToolCallJournal(join(root, 'journal')))
  const owner = createAppOwnedPtcOwner({ bridge: createNativeIsolatedExecutionBridge(transport),
    callbacks, runtime: ctx.tools, services: { agents: ctx.agents, subagents: ctx.subagents,
      sessions: ctx.sessions, sandboxPolicy: ctx.sandboxPolicy } })
  t.after(async () => { await owner.close(); await callbacks.dispose() })
  registerAndroidPtcTool(ctx, { owner, available: () => true })
  const invoke = () => ctx.tools.execute({ name: 'android_ptc', callId: `ptc-${randomUUID()}`,
    arguments: { code: "return (await tools.read({file_path:'fixture.txt'})).lines[0].text", description: 'Read fixture' },
    agent, signal: new AbortController().signal })
  const readStored = async () => {
    const reader = await ctx.sessionPersistence.open(agent.session.id, 'read')
    try { return (await reader.read(0)).events }
    finally { await reader.close() }
  }
  return { ctx, agent, invoke, readStored }
}

test('the old direct PTC fixture writes a log rejected by the real Session reader', async t => {
  const { ctx, agent, invoke, readStored } = await fixture(t)
  assert.equal((await invoke()).isError, false)
  assert.equal(await ctx.sessions.flush(agent.session), true)
  await assert.rejects(readStored(), /tool\/ptc-dispatch-start is outside an open turn/)
})

test('PTC acceptance turns reload and a later real parent turn and workflow child remain usable', async t => {
  const { ctx, agent, invoke, readStored } = await fixture(t)
  for (let i = 0; i < 2; i++) {
    const result = await inPtcAcceptanceTurn(ctx, agent, invoke)
    assert.equal(result.isError, false)
    assert.equal(result.value.result, 'persisted PTC callback')
  }
  const events = await readStored()
  assert.deepEqual(events.filter(event => event.type === 'turn/start').map(event => event.data.turn), [1, 2])
  assert.equal(events.filter(event => event.type === 'turn/end').length, 2)
  assert.equal(events.filter(event => event.type === 'tool/ptc-dispatch-start').length, 2)
  assert.equal(events.filter(event => event.type === 'tool/ptc-dispatch').length, 2)
  agent.followup(createUserMessage({ content: [{ type: 'text', text: 'Continue normally.' }], source: { kind: 'user' } }))
  await agent.whenIdle()
  assert.equal(await ctx.sessions.flush(agent.session), true)
  assert.equal((await readStored()).filter(event => event.type === 'turn/start').at(-1).data.turn, 3)
  await installWorkflowSubagentPreset(ctx)
  const runId = randomUUID(), childId = randomUUID(), signal = new AbortController().signal
  const backend = createWorkflowSubagentBackend({ ctx, parent: agent, runId,
    authorize: async () => ({ runId, parentId: agent.id, childId }) })
  try {
    const request = { prompt: 'Use the persisted parent context.' }
    assert.equal(await backend.authorizeChild(request, signal, childId), true)
    const child = await backend.activateChild(request, signal)
    try {
      const result = await child.result
      assert.equal(result.stopReason, 'completed')
      assert.ok(JSON.stringify(result.output).includes('real child answer'))
    } finally { await child.dispose() }
    const reader = await ctx.sessionPersistence.open(SessionId(childId), 'read')
    try {
      const childEvents = (await reader.read(0)).events
      assert.ok(childEvents.some(event => event.type === 'assistant/message'
        && JSON.stringify(event.data).includes('real child answer')))
      assert.equal(childEvents.filter(event => event.type === 'turn/end').at(-1).data.reason.kind, 'completed')
    } finally { await reader.close() }
  } finally { backend.close() }
})

test('an exception after a PTC callback closes an error turn, persists it and preserves the exception', async t => {
  const { ctx, agent, invoke, readStored } = await fixture(t)
  const failure = new Error('acceptance assertion failed after callback')
  await assert.rejects(inPtcAcceptanceTurn(ctx, agent, async () => {
    assert.equal((await invoke()).isError, false)
    throw failure
  }), error => error === failure)
  const events = await readStored()
  const end = events.find(event => event.type === 'turn/end')
  assert.equal(end.data.reason.kind, 'error')
  assert.match(end.data.reason.error.message, /acceptance assertion failed after callback/)
  assert.equal(events.filter(event => event.type === 'tool/ptc-dispatch').length, 1)
  assert.equal(agent.status, 'idle')
  assert.equal((await inPtcAcceptanceTurn(ctx, agent, invoke)).isError, false)
  assert.deepEqual((await readStored()).filter(event => event.type === 'turn/start').map(event => event.data.turn), [1, 2])
})
