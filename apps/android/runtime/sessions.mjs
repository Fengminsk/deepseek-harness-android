import { SessionId } from '@deepseek-ai/dsh-session'

function requestedPreset(value) {
  if (value !== undefined && (typeof value !== 'string' || !value.trim())) {
    throw new TypeError('agentPreset must be a non-empty string')
  }
  return value
}

/** App submissions reuse the same controller, writer leases and inbox as the Web UI. */
export class AppSessions {
  constructor(ctx, invoke, resolveAttachments = async () => [], commands, invokePresetSelection) {
    this.ctx = ctx
    this.invoke = invoke
    this.pending = new Map()
    this.resolveAttachments = resolveAttachments
    this.commands = commands
    this.invokePresetSelection = invokePresetSelection
  }

  enqueue(sessionId, action) {
    const operation = (this.pending.get(sessionId) ?? Promise.resolve()).then(action)
    const settled = operation.then(() => {}, () => {})
    this.pending.set(sessionId, settled)
    void settled.then(() => {
      if (this.pending.get(sessionId) === settled) this.pending.delete(sessionId)
    })
    return operation
  }

  async resolve(sessionId, params) {
    const found = await this.ctx.sessionController.resolveAgent(sessionId)
    let created = false
    if ('error' in found) {
      if (found.error.code !== 'session/not-found') throw found.error
      const result = await this.invoke('create', { sessionId, cwd: process.cwd(),
        ...(params.agentPreset === undefined ? {} : { agentPreset: params.agentPreset }) })
      if (result.sessionId !== sessionId) throw new Error('Session identity changed during creation; reopen the conversation before sending.')
      created = true
    }
    if ((created || params.selectModel === true) && params.provider && params.model) {
      await this.invoke('selectModel', { sessionId, provider: params.provider, model: params.model,
        ...(params.reasoningEffort === undefined || params.reasoningEffort === null ? {} : { reasoningEffort: params.reasoningEffort }) })
    }
    return { sessionId, created }
  }

  ensure(value) {
    const params = typeof value === 'string' ? { sessionId: value } : value
    if (typeof params.sessionId !== 'string' || params.sessionId.trim().length === 0) {
      throw new TypeError('sessionId must be a non-empty string')
    }
    const agentPreset = requestedPreset(params.agentPreset)
    const sessionId = SessionId(params.sessionId)
    // Creating a conversation is also needed to configure its model, inspect
    // commands, and prepare files. Availability belongs to explicit selection
    // and prompt admission, not to this initialization operation.
    return this.enqueue(sessionId, () => this.resolve(sessionId, { agentPreset }))
  }

  /** Selection shares App admission ordering; the original service owns lock and composition rules. */
  selectPreset(params) {
    if (typeof params.sessionId !== 'string' || !params.sessionId.trim()
      || params.agentPreset === undefined) throw new TypeError('sessionId and agentPreset are required')
    const sessionId = SessionId(params.sessionId)
    const agentPreset = requestedPreset(params.agentPreset)
    return this.enqueue(sessionId, async () => {
      await this.resolve(sessionId, { agentPreset })
      return this.invokePresetSelection(sessionId, agentPreset)
    })
  }

  send(params) {
    for (const key of ['sessionId', 'requestId', 'provider', 'model']) {
      if (typeof params[key] !== 'string' || params[key].trim().length === 0) {
        throw new TypeError(`${key} must be a non-empty string`)
      }
    }
    requestedPreset(params.agentPreset)
    const attachmentIds = params.attachmentIds ?? []
    if (typeof params.text !== 'string' || !Array.isArray(attachmentIds)
      || attachmentIds.some(id => typeof id !== 'string' || id.length === 0)
      || (params.text.trim().length === 0 && attachmentIds.length === 0)) {
      throw new TypeError('A message requires text or prepared attachments')
    }
    const sessionId = SessionId(params.sessionId)
    return this.enqueue(sessionId, async () => {
      await this.resolve(sessionId, params)
      const attachments = await this.resolveAttachments(sessionId, attachmentIds)
      return this.invoke('prompt', {
        sessionId, requestId: params.requestId, mode: 'queue',
        content: [...(params.text.trim().length ? [{ type: 'text', text: params.text }] : []), ...attachments],
      })
    })
  }

  command(params) {
    if (typeof params.sessionId !== 'string' || !params.sessionId.trim()
      || typeof params.line !== 'string' || !params.line.trim()
      || !Array.isArray(params.attachmentIds ?? [])) throw new TypeError('A session and command line are required')
    const sessionId = SessionId(params.sessionId)
    return this.enqueue(sessionId, async () => {
      await this.resolve(sessionId, {})
      const submittedAttachments = await this.commands.content(sessionId, params.attachmentIds ?? [])
      return await this.commands.execute({ agentId: sessionId, line: params.line, submittedAttachments }) ?? null
    })
  }
}
