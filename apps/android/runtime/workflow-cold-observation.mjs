const RUN_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const MAX_EVENTS = 50_000
const MAX_CHILDREN = 128
const NATIVE_STATES = new Set(['ADMITTED', 'CANCEL_REQUESTED', 'COMPLETED',
  'CANCELLED', 'FAILED', 'INTERRUPTED_UNCONFIRMED'])
const CHILD_STATES = new Set(['RESERVED', 'LAUNCHING', 'RETIRED', 'INTERRUPTED_UNCONFIRMED'])

function address(sessionId, runId) {
  if (typeof sessionId !== 'string' || !sessionId || sessionId.length > 128
    || typeof runId !== 'string' || !RUN_ID.test(runId)) {
    throw new TypeError('Workflow observation requires a Session and run identity')
  }
  return { sessionId, runId }
}

/** A read-only Session observation. A missing run-end never becomes success. */
export function classifyWorkflowObservation({ sessionId, runId, events, attached, active }) {
  address(sessionId, runId)
  if (!Array.isArray(events) || typeof attached !== 'boolean' || typeof active !== 'boolean') {
    throw new TypeError('Workflow observation requires a stable Session event prefix')
  }
  if (events.length > MAX_EVENTS) return { runId, state: 'unconfirmed', reason: 'history-limit', requiresReview: true }
  let start = -1, end = -1, stopReason
  const members = new Set()
  let conflict = false
  for (let i = 0; i < events.length; i++) {
    const event = events[i]
    if (event?.data?.runId !== runId) continue
    switch (event.type) {
      case 'tool-workflow/run-start':
        if (start >= 0 || typeof event.data.name !== 'string' || !event.data.name) conflict = true
        else start = i
        break
      case 'tool-workflow/agent-start':
        if (start < 0 || end >= 0 || !Number.isSafeInteger(event.data.seq)
          || members.has(event.data.seq)) conflict = true
        else members.add(event.data.seq)
        break
      case 'tool-workflow/agent-end':
        if (start < 0 || end >= 0 || !members.delete(event.data.seq)) conflict = true
        break
      case 'tool-workflow/run-end':
        if (start < 0 || end >= 0 || !['completed', 'error', 'cancelled'].includes(event.data.stopReason)) {
          conflict = true
        } else {
          end = i
          stopReason = event.data.stopReason
        }
        break
    }
  }
  if (conflict || (end >= 0 && members.size > 0)) {
    return { runId, state: 'unconfirmed', reason: 'conflicting-history', requiresReview: true }
  }
  if (start < 0) return { runId, state: 'missing', requiresReview: false }
  if (end >= 0) {
    return { runId, state: stopReason === 'completed' ? 'completed'
      : stopReason === 'cancelled' ? 'cancelled' : 'failed', requiresReview: false }
  }
  if (active && attached) return { runId, state: 'running', requiresReview: false }
  return { runId, state: attached ? 'unconfirmed' : 'interrupted-unconfirmed',
    reason: attached ? 'owner-not-confirmed' : 'previous-host', requiresReview: true }
}

/** Read a single bounded physical prefix; never resume an Agent or repair a log. */
export async function inspectWorkflowColdRun(ctx, request, activeRunIds, transport) {
  const { sessionId, runId } = address(request?.sessionId, request?.runId)
  if (typeof ctx?.sessionPersistence?.open !== 'function'
    || typeof ctx?.sessions?.get !== 'function' || !(activeRunIds instanceof Set)) {
    throw new TypeError('Workflow observation requires Session persistence and live owner state')
  }
  const ownerBefore = ctx.sessions.get(sessionId)
  const reader = await ctx.sessionPersistence.open(sessionId, 'read')
  let events
  try { ({ events } = await reader.read(0, MAX_EVENTS + 1)) }
  finally { await reader.close() }
  const ownerAfter = ctx.sessions.get(sessionId)
  if (ownerBefore !== ownerAfter) {
    return { runId, state: 'unconfirmed', reason: 'ownership-changed', requiresReview: true }
  }
  const observed = classifyWorkflowObservation({ sessionId, runId, events,
    attached: ownerAfter !== undefined, active: activeRunIds.has(runId) })
  // A flushed run-end is published only after native terminal settlement and
  // release. An open Session record must never turn a persisted native guest
  // result into a fabricated Session completion.
  if (!transport || ['completed', 'cancelled', 'failed', 'missing'].includes(observed.state)
    || observed.reason === 'conflicting-history') return observed
  let receipt
  try { receipt = await transport.request('native.workflow.inspect', { runId }) }
  catch { return { runId, state: observed.state,
    reason: 'native-receipt-unavailable', requiresReview: true } }
  if (!receipt || receipt.runId !== runId || !NATIVE_STATES.has(receipt.state)
    || !Array.isArray(receipt.children) || receipt.children.length > MAX_CHILDREN
    || receipt.children.some(child => typeof child?.childId !== 'string'
      || !RUN_ID.test(child.childId) || !CHILD_STATES.has(child.state))) {
    return { runId, state: 'unconfirmed', reason: 'native-receipt-invalid', requiresReview: true }
  }
  const pendingChildren = receipt.children.filter(child => child.state !== 'RETIRED').length
  if (receipt.state === 'INTERRUPTED_UNCONFIRMED') {
    return { runId, state: 'interrupted-unconfirmed', reason: 'native-interrupted',
      nativeState: receipt.state, pendingChildren, requiresReview: true }
  }
  if (observed.state === 'running'
    && ['ADMITTED', 'CANCEL_REQUESTED'].includes(receipt.state)) {
    return { ...observed, nativeState: receipt.state, pendingChildren }
  }
  return { runId, state: 'unconfirmed',
    reason: ['COMPLETED', 'CANCELLED', 'FAILED'].includes(receipt.state)
      ? 'session-terminal-missing' : 'native-owner-not-active',
    nativeState: receipt.state, pendingChildren, requiresReview: true }
}
