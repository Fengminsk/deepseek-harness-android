/** Reconnect baseline for the App carrier; durable messages remain in the Session log. */
export class AppLiveState {
  constructor(ctx, transport) {
    this.ctx = ctx
    this.revision = 0
    this.streaming = new Map()
    ctx.on('agent/status', ({ agent, status }) => {
      transport.notify('session.status', { sessionId: String(agent.session.id), status, revision: ++this.revision })
    })
    ctx.on('agent/assistant-stream', ({ agent, frame }) => {
      const sessionId = String(agent.session.id)
      if (frame.type === 'start') this.streaming.set(sessionId, '')
      if (frame.type === 'chunk' && frame.chunk.type === 'text-delta') {
        this.streaming.set(sessionId, (this.streaming.get(sessionId) ?? '') + frame.chunk.text)
      }
      if (frame.type === 'end') this.streaming.delete(sessionId)
      transport.notify('session.stream', { sessionId, frame, revision: ++this.revision })
    })
    ctx.on('agent/disposed', ({ agent }) => {
      this.streaming.delete(String(agent.session.id))
      transport.notify('session.status', { sessionId: String(agent.session.id), status: 'idle', revision: ++this.revision })
    })
  }
  snapshot() {
    return {
      revision: this.revision,
      statuses: Object.fromEntries(this.ctx.agents.list().map(agent => [String(agent.session.id), agent.status])),
      streaming: Object.fromEntries(this.streaming),
    }
  }
}
