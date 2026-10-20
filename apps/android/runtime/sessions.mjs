import { SessionId } from '@deepseek-ai/dsh-session'

/** App submissions reuse the same controller, writer leases and inbox as the Web UI. */
export class AppSessions {
  constructor(ctx, invoke) {
    this.ctx = ctx
    this.invoke = invoke
    this.pending = new Map()
  }

  send(params) {
    for (const key of ['sessionId', 'requestId', 'text', 'provider', 'model']) {
      if (typeof params[key] !== 'string' || params[key].trim().length === 0) {
        throw new TypeError(`${key} must be a non-empty string`)
      }
    }
    const sessionId = SessionId(params.sessionId)
    const operation = (this.pending.get(sessionId) ?? Promise.resolve()).then(async () => {
      const found = await this.ctx.sessionController.resolveAgent(sessionId)
      let created = false
      if ('error' in found) {
        if (found.error.code !== 'session/not-found') throw found.error
        const result = await this.invoke('create', { sessionId, cwd: process.cwd() })
        if (result.sessionId !== sessionId) throw new Error('Session identity changed during creation; reopen the conversation before sending.')
        created = true
      }
      if (created || params.selectModel === true) {
        await this.invoke('selectModel', { sessionId, provider: params.provider, model: params.model })
      }
      return this.invoke('prompt', {
        sessionId, requestId: params.requestId, mode: 'queue',
        content: [{ type: 'text', text: params.text }],
      })
    })
    const settled = operation.then(() => {}, () => {})
    this.pending.set(sessionId, settled)
    void settled.then(() => {
      if (this.pending.get(sessionId) === settled) this.pending.delete(sessionId)
    })
    return operation
  }
}
