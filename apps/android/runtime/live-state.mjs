import { assembleAssistantStream, BlockAssembler } from '@deepseek-ai/dsh-llm'

/** Derive a visible canceled/failed prefix without modifying the original durable event. */
export function presentSessionEvent(event) {
  if (event.type !== 'assistant/attempt') return event
  try {
    return { ...event, assistantContent: assembleAssistantStream(event.data.stream).interruptedBlocks() }
  } catch (error) {
    // Presentation failure does not invalidate or rewrite the durable record.
    return { ...event, assistantContentError: `Unable to present the recorded assistant attempt: ${error.message}` }
  }
}

/** Reconnect baseline for the App carrier; durable messages remain in the Session log. */
export class AppLiveState {
  constructor(ctx, transport, { streamPublishMs = () => 50 } = {}) {
    this.ctx = ctx
    this.transport = transport
    this.streamPublishMs = streamPublishMs
    this.revision = 0
    this.streaming = new Map()
    this.errors = new Map()
    this.attempts = new Map()
    this.closed = false
    ctx.on('agent/status', ({ agent, status }) => {
      if (this.closed) return
      if (status === 'running') this.errors.delete(String(agent.session.id))
      transport.notify('session.status', { sessionId: String(agent.session.id), status, revision: ++this.revision })
    })
    ctx.on('api-session/error', (id, error) => {
      if (this.closed) return
      const sessionId = String(id)
      this.errors.set(sessionId, error)
      transport.notify('session.error', { sessionId, error, revision: ++this.revision })
    })
    ctx.on('agent/assistant-stream', ({ agent, frame }) => this.receive(agent, frame))
    ctx.on('agent/disposed', ({ agent }) => {
      if (this.closed) return
      const id = String(agent.session.id)
      const record = this.attempts.get(id)
      if (record && record.agent !== agent) return
      if (record?.agent === agent && !record.ended) {
        record.ended = true
        record.interrupted = true
        this.flush(id, record)
      }
      this.streaming.delete(id)
      // Agent membership must match the reconnect snapshot, which only lists
      // attached Agents. Idle alone would make a released Session look live.
      transport.notify('session.status', { sessionId: id, status: 'idle', attached: false, revision: ++this.revision })
    })
  }

  view(record) {
    return { attemptId: record.attemptId, revision: record.revision, turn: record.turn, step: record.step,
      // The canonical safe prefix keeps text/reasoning and omits unfinished tool calls.
      content: record.assembler.interruptedBlocks(), interrupted: record.interrupted }
  }

  flush(id, record) {
    clearTimeout(record.timer)
    record.timer = undefined
    if (this.closed || this.attempts.get(id) !== record) return
    this.transport.notify('session.live', { sessionId: id, value: this.view(record), revision: ++this.revision })
  }

  receive(agent, frame) {
    if (this.closed) return
    const id = String(agent.session.id)
    let record = this.attempts.get(id)
    if (frame.type === 'start') {
      if (record?.agent === agent && frame.revision <= record.revision) return
      clearTimeout(record?.timer)
      record = { agent, attemptId: frame.attemptId, revision: frame.revision, turn: frame.turn,
        step: frame.step, nextIndex: 0, assembler: new BlockAssembler(), interrupted: false, ended: false }
      this.attempts.set(id, record)
      this.streaming.set(id, '')
      this.flush(id, record)
    } else {
      if (!record || record.agent !== agent || record.ended || record.attemptId !== frame.attemptId
        || frame.revision <= record.revision || frame.index !== record.nextIndex) return
      record.revision = frame.revision
      if (frame.type === 'chunk') {
        record.nextIndex++
        record.assembler.push(frame.chunk)
        if (frame.chunk.type === 'text-delta') {
          this.streaming.set(id, (this.streaming.get(id) ?? '') + frame.chunk.text)
        }
        record.timer ??= setTimeout(() => this.flush(id, record), this.streamPublishMs())
        record.timer.unref()
      } else if (frame.type === 'end') {
        record.ended = true
        clearTimeout(record.timer)
        this.streaming.delete(id)
        if (frame.outcome.kind === 'abandoned') {
          record.interrupted = true
          this.flush(id, record)
        } else {
          this.attempts.delete(id)
          this.transport.notify('session.live', { sessionId: id, value: null, revision: ++this.revision })
        }
      }
    }
    // Only the coalesced block projection crosses Binder. The original stream
    // remains owned by the Agent; forwarding every delta would defeat batching.
  }

  snapshot() {
    return {
      revision: this.revision,
      statuses: Object.fromEntries(this.ctx.agents.list().map(agent => [String(agent.session.id), agent.status])),
      streaming: Object.fromEntries(this.streaming),
      errors: Object.fromEntries(this.errors),
      liveMessages: Object.fromEntries([...this.attempts].map(([id, record]) => [id, this.view(record)])),
    }
  }

  close() {
    this.closed = true
    for (const record of this.attempts.values()) clearTimeout(record.timer)
    this.attempts.clear()
    this.streaming.clear()
    this.errors.clear()
  }
}
