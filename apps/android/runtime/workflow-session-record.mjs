/**
 * Record one App-owned workflow using the original tool-workflow Session
 * events. Each accepted progress callback is appended before acknowledgement;
 * only a confirmed native terminal outcome closes the visible run.
 */
export function createWorkflowSessionRecord(ctx, prepared, parent) {
  const session = parent?.session
  if (prepared?.kind !== 'workflow' || typeof prepared.runId !== 'string'
    || typeof prepared.meta?.name !== 'string' || !prepared.meta.name
    || typeof prepared.sessionId !== 'string' || session?.id !== prepared.sessionId
    || typeof session.append !== 'function'
    || typeof ctx?.sessions?.flush !== 'function') {
    throw new TypeError('Workflow record requires the exact parent Session and prepared run')
  }
  let started = false
  let ended = false
  let uncertain = false
  let agentsStarted = 0
  const live = new Map()
  async function commit(type, data) {
    try {
      session.append(type, data)
      if (await ctx.sessions.flush(session) !== true) {
        throw new Error('Workflow Session has no durable storage listener')
      }
    } catch (error) {
      uncertain = true
      throw error
    }
  }
  return Object.freeze({
    get agentsStarted() { return agentsStarted },
    async start() {
      if (started) throw new Error('Workflow record already started')
      await commit('tool-workflow/run-start',
        { runId: prepared.runId, name: prepared.meta.name })
      started = true
    },
    async progress(event) {
      if (!started || ended || uncertain || !event || typeof event !== 'object') {
        throw new Error('Workflow progress has no open Session record')
      }
      if (event.type === 'agent-start') {
        const info = event.info
        if (!Number.isSafeInteger(info?.seq) || info.seq < 1 || live.has(info.seq)) {
          throw new Error('Workflow member start is not unique')
        }
        await commit('tool-workflow/agent-start', {
          runId: prepared.runId, seq: info.seq, label: info.label,
          ...(info.phase === undefined ? {} : { phase: info.phase }),
          childId: info.childId,
        })
        live.set(info.seq, info.childId)
        agentsStarted += 1
      } else if (event.type === 'agent-end') {
        const info = event.info
        if (live.get(info?.seq) !== info?.childId) {
          throw new Error('Workflow member end has no matching start')
        }
        await commit('tool-workflow/agent-end', {
          runId: prepared.runId, seq: info.seq, outcome: info.outcome,
        })
        live.delete(info.seq)
      } else if (event.type !== 'phase' && event.type !== 'log') {
        throw new Error('Workflow progress type is invalid')
      }
    },
    async finish(stopReason) {
      if (!started || ended || uncertain || live.size
        || !['completed', 'error', 'cancelled'].includes(stopReason)) {
        throw new Error('Workflow record cannot settle before its members')
      }
      await commit('tool-workflow/run-end', { runId: prepared.runId, stopReason })
      ended = true
    },
  })
}
