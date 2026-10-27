import { readFileSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { randomUUID } from 'node:crypto'
import LlmRuntime, { LlmAdapter } from '@deepseek-ai/dsh-llm'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import SessionProjections from '@deepseek-ai/dsh-session-projection'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import SandboxPolicy from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import SubprocessLocal from '@deepseek-ai/dsh-subprocess-local'
import SessionQuery from '@deepseek-ai/dsh-session-query-sqlite'
import Subagents from '@deepseek-ai/dsh-subagent'
import * as Spawn from '@deepseek-ai/dsh-subagent-spawn-in-process'
import AgentPresets from '@deepseek-ai/dsh-agent-preset-registry'
import Jobs from '@deepseek-ai/dsh-jobs-local'
import * as JobTools from '@deepseek-ai/dsh-tool-jobs'
import { summarizeAcceptance } from './report.mjs'

export const name = 'device-runtime-acceptance'
const configuration = JSON.parse(readFileSync(new URL('./configuration.json', import.meta.url), 'utf8'))
const nativeModule = name => import(pathToFileURL(join(realpathSync(configuration.runtime),
  'node_modules/@minnnng/dsh-android-runtime', name)).href)

export class FixtureAdapter extends LlmAdapter {
  mode = 'answer'
  calls = 0
  entered = null
  scriptedStream = null
  async resolveModel(provider, model) { return { provider, id: model, name: model } }
  async *stream(options) {
    this.calls++
    if (this.scriptedStream) { yield* this.scriptedStream(options); return }
    if ((options.tools ?? []).length !== 0) throw new Error('Confined child received unexpected tools')
    this.entered?.()
    if (this.mode === 'hold') {
      await new Promise((resolve, reject) => {
        if (options.signal.aborted) reject(options.signal.reason)
        else options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })
      })
      return
    }
    const text = 'device child answer'
    yield { type: 'block-start', index: 0, blockType: 'text' }
    yield { type: 'text-delta', index: 0, text }
    yield { type: 'block-end', index: 0, block: { type: 'text', text } }
    yield { type: 'finish', reason: { kind: 'stop' } }
  }
}

export async function apply(ctx) {
  const { createRuntimeTransport } = await nativeModule('transport.mjs')
  const ipc = createRuntimeTransport()
  const { transport } = ipc
  transport.onRequest(async (method, params) => {
    if (method === 'native.workflowCallback') return ctx.get('nativeWorkflowGuestCallbacks').call(params)
    if (method === 'native.workflowCallback.cancel') return ctx.get('nativeWorkflowGuestCallbacks').close(params)
    if (method === 'native.toolCallback') return ctx.get('nativeIsolatedToolCallbacks').call(params)
    if (method === 'native.toolCallback.cancel') return ctx.get('nativeIsolatedToolCallbacks').close(params)
    throw new Error(`Unexpected acceptance callback: ${method}`)
  })
  transport.start()
  const finish = result => transport.notify('acceptance.result', result)
  const reports = []
  try {
    await ctx.plugin(LlmRuntime)
    await ctx.plugin(SessionStore)
    await ctx.plugin(SessionProjections)
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(AgentRegistry)
    await ctx.plugin(SandboxPolicy, { mode: 'workspace-write', workspaceRoot: process.cwd() })
    const { default: AndroidFileSystem } = await nativeModule('android-filesystem.mjs')
    await ctx.plugin(AndroidFileSystem)
    await ctx.plugin(WorkingDirectory)
    await ctx.plugin(SubprocessLocal)
    await ctx.plugin(await nativeModule('android-session-persistence.mjs'), {
      root: join(process.env.DSH_HOME, 'sessions'), compression: 'none' })
    await ctx.plugin(SessionQuery, { path: join(process.env.DSH_HOME, 'query.sqlite'), openAt: 'never' })
    await ctx.plugin(Subagents)
    await ctx.plugin(Spawn, { providerName: 'spawn' })
    await ctx.plugin(AgentLoop, { agents: [] })
    await ctx.plugin(AgentPresets, { default: 'device-acceptance-parent' })
    await ctx.plugin(Jobs, {})
    await ctx.plugin(JobTools, {})
    await new Promise((resolve, reject) => ctx.inject(['llm', 'agents', 'sessions', 'jobs', 'sessionQuery',
      'sessionPersistence', 'subagents', 'agentPresets', 'tools', 'workingDirectory', 'systemPrompt',
      'sessionProjections', 'fs', 'subprocess', 'loader', 'sandboxPolicy'], async ctx => {
      try {
        await ctx.agentPresets.register({ id: 'device-acceptance-parent', plugins: [] })
        const adapter = new FixtureAdapter()
        ctx.llm.registerAdapter(['device-acceptance'], adapter)
        const handle = await ctx.agents.create({ sessionId: SessionId(`android-acceptance-${randomUUID()}`),
          agentOptions: { provider: 'device-acceptance', model: 'fixture' },
          meta: { cwd: process.cwd() },
          setup: async agentCtx => { await ctx.agentPresets.mount(agentCtx, 'device-acceptance-parent') },
        })
        const agent = handle.agent
        let workflow
        try {
          if (['workflow', 'linux', 'all'].includes(configuration.suite)) {
            const { createWorkflowAcceptance } = await import('./workflow.mjs')
            workflow = await createWorkflowAcceptance({ ctx, transport, agent, nativeModule })
          }
          if (configuration.suite === 'workflow' || configuration.suite === 'all') {
            const { runWorkflowAcceptance } = await import('./workflow.mjs')
            reports.push(await runWorkflowAcceptance({ ctx, agent, adapter, workflow }))
          }
          if (configuration.suite === 'ptc' || configuration.suite === 'all') {
            const { runPtcAcceptance } = await import('./ptc.mjs')
            reports.push(await runPtcAcceptance({ ctx, transport, agent, workspace: process.cwd() }))
          }
          if (configuration.suite === 'linux' || configuration.suite === 'all') {
            const { runLinuxAcceptance } = await import('./linux.mjs')
            reports.push(await runLinuxAcceptance({ ctx, transport, agent, workspace: process.cwd(),
              appWorkspaceRoot: configuration.appWorkspaceRoot, nativeModule, adapter, workflow }))
          }
          if (await ctx.sessions.flush(agent.session) !== true) throw new Error('Acceptance Session did not flush')
        } finally { await workflow?.dispose() }
        finish({ ...summarizeAcceptance(configuration.suite, reports),
          sessionId: agent.session.id, reports })
        resolve()
      } catch (error) { reject(error) }
    }))
  } catch (error) {
    finish({ ...summarizeAcceptance(configuration.suite, reports), passed: false, complete: false,
      reports, failure: String(error?.stack ?? error).slice(0, 6000) })
  }
  ctx.effect(() => () => ipc.close())
}
