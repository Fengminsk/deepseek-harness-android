import { defineTool } from '@deepseek-ai/dsh-tools'
import { runShell } from './shell.mjs'

/**
 * Register the app-UID shell and its per-call approval request.
 *
 * This Android deployment requests approval for each command; it does not claim
 * that desktop DSH asks for every command or that Android confines a command to
 * its working directory. The original tool pipeline and ApprovalService own
 * policy, audit, answer routing and cancellation. In particular, `never` rejects
 * an ask; it does not grant unattended execution.
 *
 * @param {import('@deepseek-ai/cordis').Context} ctx - Tool-owning plugin context.
 * @param {{shellTimeoutMs: {get(): number}, shellOutputLimit: {get(): number}}} config - Live process budgets, applied only after approval.
 * @returns {{context(sessionId: string, callId: string): {cwd: string} | undefined}} The directory fixed before this exact approval.
 */
export function registerAndroidShell(ctx, config) {
  const prepared = new Map()
  ctx.on('tools/result', execution => { prepared.delete(execution.token) })
  ctx.effect(() => () => prepared.clear())
  ctx.on('tools/pre-execute', async (execution, next) => {
    const downstream = await next()
    if (execution.name !== 'android_shell' || !['allow', 'ask'].includes(downstream.kind)) return downstream
    if (!execution.agent) return { kind: 'deny', reason: 'Android shell requires an Agent session.' }
    const cwd = await ctx.workingDirectory.ensure(execution.agent, execution.signal)
    execution.signal.throwIfAborted()
    prepared.set(execution.token, { cwd, sessionId: String(execution.agent.session.id), callId: String(execution.callId) })
    if (downstream.kind === 'ask') return downstream
    return {
      kind: 'ask',
      reason: 'Android shell commands require approval for this invocation.',
      displayReason: {
        en: 'Allow this shell command once with this app’s existing Android permissions? The working directory does not confine file access.',
        zh: '是否允许这条 Shell 命令使用本 App 已有的 Android 权限执行一次？工作目录不构成文件访问沙箱。',
      },
    }
  })
  ctx.effect(() => ctx.tools.register(defineTool({
    name: 'android_shell',
    description: 'Run a non-interactive Android shell command after one-time user approval. Runs as this app, without root or adb privileges. Starts in the session working directory shown with the approval; that directory does not restrict file access. No approval means no execution.',
    parameters: { command: { type: 'string', required: true } },
    output: {
      schema: { type: 'json' },
      render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }],
    },
    execute(args, execution) {
      const context = prepared.get(execution.token)
      if (!context) throw new Error('Shell execution directory was not prepared for this approval.')
      return runShell(args.command, context.cwd, {
        timeoutMs: config.shellTimeoutMs.get(),
        outputLimit: config.shellOutputLimit.get(),
        signal: execution.signal,
      })
    },
  })))
  return {
    context(sessionId, callId) {
      for (const value of prepared.values()) {
        if (value.sessionId === sessionId && value.callId === callId) return { cwd: value.cwd }
      }
      return undefined
    },
  }
}
