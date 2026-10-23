function completionPreview(content) {
  const first = content?.filter(part => part?.type === 'text' && typeof part.text === 'string')
    .map(part => part.text).join(' ').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ')
    .replace(/^(?:[#>*-]+\s*)+/, '').trim()
  if (!first) return undefined
  const sentence = first.match(/^.{1,100}?[。！？!?]/u)?.[0] ?? first.slice(0, 100)
  return sentence.trim() || undefined
}

/** Live whole-driver completion; history reads and disconnected status never produce notices. */
export class AppTaskCompletion {
  constructor(ctx, transport) {
    this.ctx = ctx
    this.transport = transport
    this.running = new Map()
    this.closed = false
    this.disposers = [
      ctx.on('agent/status', value => this.status(value)),
      ctx.on('session/event', (session, event) => this.event(session, event)),
      ctx.on('agent/disposed', ({ agent }) => this.forget(agent)),
      ctx.on('agent/error', ({ agent }) => this.forget(agent)),
    ]
  }

  forget(agent) {
    const id = String(agent.session.id)
    if (this.running.get(id)?.agent === agent) this.running.delete(id)
  }

  event(session, event) {
    if (this.closed) return
    const record = this.running.get(String(session.id))
    if (!record || record.agent.session !== session) return
    if (event.type === 'turn/start') {
      record.turn = event.data.turn
      record.startSeq = event.seq
      record.hasStep = false
      record.preview = undefined
    } else if (event.type === 'step/start' && record.turn === event.data.turn) {
      record.hasStep = true
    } else if (event.type === 'assistant/message' && record.turn === event.data.turn) {
      record.preview = completionPreview(event.data.message?.content) ?? record.preview
    }
  }

  status({ agent, status }) {
    if (this.closed || agent.session.header.origin === 'subagent') return
    const sessionId = String(agent.session.id)
    if (status === 'running') {
      if (this.running.get(sessionId)?.agent !== agent) this.running.set(sessionId, { agent, hasStep: false })
      return
    }
    if (status !== 'idle') return
    const record = this.running.get(sessionId)
    if (!record || record.agent !== agent) return
    this.running.delete(sessionId)
    if (!record.hasStep || agent.inbox.nextTurn.length || agent.inbox.nextStep.length) return
    // The registered projection decides the ending; idle alone is not success.
    try {
      const snapshot = this.ctx.sessionProjections.snapshot(agent.session, ['pocketTasks'])
      const turn = snapshot.values.pocketTasks?.turns.at(-1)
      if (!turn || turn.turn !== record.turn || turn.seq !== record.startSeq
        || turn.reason?.kind !== 'completed' || !Number.isSafeInteger(turn.endSeq)) return
      const goal = this.ctx.get('goals')?.get(agent)
      if (goal && goal.phase !== 'complete') return
      this.transport.notify('task.completed', { sessionId, turn: turn.turn, endSeq: turn.endSeq,
        ...(record.preview ? { preview: record.preview } : {}) })
    } catch (error) {
      // A failed read/notification cannot convert an unknown result into success or stop the Agent.
      try { this.transport.notify('notifications.error', { message: '任务提醒未能确认，请在会话中查看结果' }) }
      catch (notificationError) { console.warn('Task completion notification transport is unavailable') }
    }
  }

  close() {
    if (this.closed) return
    this.closed = true
    for (const dispose of this.disposers.reverse()) dispose()
    this.running.clear()
  }
}
