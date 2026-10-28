// Host-only child process: real ToolRuntime/Session/journal; native V8/Binder is explicitly simulated.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { SessionId } from '@deepseek-ai/dsh-session'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SandboxPolicy from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import { MockAdapter } from '../../../../packages/core/agent-loop/tests/mock-adapter.ts'
import AndroidFileSystem from '../../runtime/android-filesystem.mjs'
import { createAcceptanceCallbackRouting } from './callback-routing.mjs'
import { runPtcProcessDeathAcceptance } from './ptc-process-death.mjs'
import { runPtcSafAcceptance } from './ptc-saf.mjs'

const [phase, caseId, workspace] = process.argv.slice(2)
const ctx = new Context()
const timer = setInterval(() => {}, 1000)
try {
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(SandboxPolicy, { mode: 'workspace-write', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: workspace })
  await ctx.plugin(JsonlSessionPersistence, { root: join(process.env.DSH_HOME, 'sessions'), compression: 'none' })
  await ctx.plugin(AgentLoop, { agents: [] })
  ctx.llm.registerAdapter(['mock'], new MockAdapter([]))
  const identity = SessionId(`ptc-death-${caseId}`)
  const handle = phase !== 'recover'
    ? await ctx.agents.create({ sessionId: identity, agentOptions: { provider: 'mock', model: 'mock' }, meta: { cwd: workspace } })
    : await ctx.agents.resume({ resumeSessionId: identity })
  const callbackRouting = createAcceptanceCallbackRouting()
  let admitted, revoked = false
  const root = '1'.repeat(64)
  const AsyncFunction = (async () => {}).constructor
  const transport = { async request(method, params) {
    if (phase === 'recover') throw new Error(`Recovery unexpectedly used native RPC: ${method}`)
    if (phase.startsWith('saf')) {
      if (method === 'native.documents.roots') return revoked ? [] : [{ id: root, name: 'Fixture', directory: true }]
      if (method === 'native.documents.read.prepare') return { prepared: true }
      if (method === 'native.documents.read.cancel') return { cancelled: true }
      if (method === 'native.documents.read.run') return { text: `PTC SAF needle ${caseId}\n`, offset: 0,
        nextOffset: 52, truncated: false, version: 'a'.repeat(64), encoding: 'utf-8' }
      if (method === 'native.documents.search.prepare') return { prepared: true }
      if (method === 'native.documents.search.cancel') return { cancelled: true }
      if (method === 'native.documents.search.run') return { complete: phase !== 'saf-incomplete',
        matches: [{ path: 'alpha.txt', lineNumber: 1, line: `PTC SAF needle ${caseId}`, previewTruncated: false }] }
      if (method === 'acceptance.saf.revoke') { assert.equal(params.root, root); revoked = true; return { revoked: true } }
    }
    if (method === 'native.isolated.admit') {
      admitted = { ...params, token: randomUUID() }
      return { runId: params.runId, token: admitted.token }
    }
    if (method === 'native.isolated.bindTools') return true
    if (method === 'native.isolated.execute') {
      const fn = new AsyncFunction('input', 'host', admitted.program)
      try { admitted.outputJson = JSON.stringify(await fn(JSON.parse(admitted.inputJson), {
        async callAsync({ action, ...request }) {
          assert.equal(action, 'TOOL_CALL')
          const { runId, callId, ...reply } = await callbackRouting.dispatch('native.toolCallback',
            { ...request, runId: admitted.runId, token: admitted.token })
          return reply
        },
      })) } catch (error) { process.stderr.write(`Host native adapter: ${error.stack}\n`); throw error }
      return true
    }
    if (method === 'native.isolated.settle') return { runId: admitted.runId, state: 'COMPLETED', outputJson: admitted.outputJson, detail: null, guestUid: 99001 }
    if (method === 'native.isolated.release' || method === 'native.isolated.cancel') return true
    throw new Error(method)
  }, async notify(method, params) { assert.equal(method, 'acceptance.ptcDeathReady'); process.send({ kind: 'ready', ...params }) } }
  const result = phase.startsWith('saf')
    ? await runPtcSafAcceptance({ ctx, transport, agent: handle.agent, callbackRouting, root, caseId })
    : await runPtcProcessDeathAcceptance({ ctx, transport, agent: handle.agent, workspace,
      callbackRouting, configuration: { phase, caseId, processStopConfirmed: phase === 'recover' } })
  await ctx.fiber.dispose()
  process.send({ kind: 'result', result })
} catch (error) {
  await ctx.fiber.dispose()
  process.send({ kind: 'error', error: error.stack })
  process.exitCode = 1
} finally { clearInterval(timer); process.disconnect() }
