import assert from 'node:assert/strict'
import test from 'node:test'
import { classifyWorkflowObservation, inspectWorkflowColdRun } from '../runtime/workflow-cold-observation.mjs'

const sessionId = 'parent-1'
const runId = '00000000-0000-4000-8000-000000000001'
const start = { type: 'tool-workflow/run-start', data: { runId, name: 'Review' } }
const member = { type: 'tool-workflow/agent-start', data: { runId, seq: 1, childId: 'child-1' } }
const endMember = { type: 'tool-workflow/agent-end', data: { runId, seq: 1, outcome: 'completed' } }
const end = reason => ({ type: 'tool-workflow/run-end', data: { runId, stopReason: reason } })
const classify = (events, attached = false, active = false) =>
  classifyWorkflowObservation({ sessionId, runId, events, attached, active })

test('cold open run is unconfirmed without a fabricated terminal event', () => {
  const events = [start, member, endMember]
  assert.deepEqual(classify(events), { runId, state: 'interrupted-unconfirmed',
    reason: 'previous-host', requiresReview: true })
  assert.equal(events.length, 3)
  assert.deepEqual(classify(events, true, true), { runId, state: 'running', requiresReview: false })
  assert.deepEqual(classify(events, true, false), { runId, state: 'unconfirmed',
    reason: 'owner-not-confirmed', requiresReview: true })
})

test('a durable run-end remains authoritative, and corrupt order fails closed', () => {
  assert.deepEqual(classify([start, end('completed')]),
    { runId, state: 'completed', requiresReview: false })
  assert.deepEqual(classify([start, end('error')]),
    { runId, state: 'failed', requiresReview: false })
  assert.deepEqual(classify([start, end('cancelled')]),
    { runId, state: 'cancelled', requiresReview: false })
  assert.deepEqual(classify([end('completed'), start]).state, 'unconfirmed')
  assert.deepEqual(classify([start, start]).state, 'unconfirmed')
  assert.deepEqual(classify([start, member, member]).state, 'unconfirmed')
  assert.deepEqual(classify([start, member, end('completed')]).state, 'unconfirmed')
  assert.deepEqual(classify([{ type: 'turn/start', data: {} }]).state, 'missing')
})

test('inspection closes a bounded read handle and rejects changing ownership', async () => {
  let closed = 0
  const sessions = new Map()
  const ctx = { sessions, sessionPersistence: { async open() {
    return { async read() { sessions.set(sessionId, {})
      return { events: [start] } }, async close() { closed++ } }
  } } }
  assert.deepEqual(await inspectWorkflowColdRun(ctx, { sessionId, runId }, new Set()),
    { runId, state: 'unconfirmed', reason: 'ownership-changed', requiresReview: true })
  assert.equal(closed, 1)
  await assert.rejects(inspectWorkflowColdRun(ctx, { sessionId, runId: '../bad' }, new Set()),
    /identity/)
})

test('cold inspection joins Session history to the native receipt without replay or false success', async () => {
  const events = [start, member]
  const ctx = { sessions: new Map(), sessionPersistence: { async open() {
    return { async read() { return { events } }, async close() {} }
  } } }
  const request = { sessionId, runId }
  const childId = '00000000-0000-4000-8000-000000000002'
  const native = state => ({ async request(method, params) {
    assert.equal(method, 'native.workflow.inspect')
    assert.deepEqual(params, { runId })
    return { runId, state, children: [{ childId, state: 'INTERRUPTED_UNCONFIRMED' }] }
  } })
  assert.deepEqual(await inspectWorkflowColdRun(ctx, request, new Set(),
    native('INTERRUPTED_UNCONFIRMED')),
  { runId, state: 'interrupted-unconfirmed', reason: 'native-interrupted',
    nativeState: 'INTERRUPTED_UNCONFIRMED', pendingChildren: 1, requiresReview: true })
  assert.deepEqual(await inspectWorkflowColdRun(ctx, request, new Set(), native('COMPLETED')),
    { runId, state: 'unconfirmed', reason: 'session-terminal-missing',
      nativeState: 'COMPLETED', pendingChildren: 1, requiresReview: true })
  assert.equal(events.some(event => event.type === 'tool-workflow/run-end'), false)
  assert.deepEqual(await inspectWorkflowColdRun(ctx, request, new Set(), {
    async request() { throw new Error('unreadable native receipt') },
  }), { runId, state: 'interrupted-unconfirmed', reason: 'native-receipt-unavailable',
    requiresReview: true })
})

test('invalid native child evidence cannot turn an open Session run into completion', async () => {
  const ctx = { sessions: new Map(), sessionPersistence: { async open() {
    return { async read() { return { events: [start] } }, async close() {} }
  } } }
  const result = await inspectWorkflowColdRun(ctx, { sessionId, runId }, new Set(), {
    async request() { return { runId, state: 'COMPLETED',
      children: [{ childId: '../foreign', state: 'RETIRED' }] } },
  })
  assert.deepEqual(result, { runId, state: 'unconfirmed',
    reason: 'native-receipt-invalid', requiresReview: true })
})

test('an attached run checks native ownership before reporting running', async () => {
  const session = {}
  const ctx = { sessions: new Map([[sessionId, session]]), sessionPersistence: { async open() {
    return { async read() { return { events: [start] } }, async close() {} }
  } } }
  const native = state => ({ async request() {
    return { runId, state, children: [] }
  } })
  const request = { sessionId, runId }
  const active = new Set([runId])
  assert.deepEqual(await inspectWorkflowColdRun(ctx, request, active, native('ADMITTED')),
    { runId, state: 'running', nativeState: 'ADMITTED', pendingChildren: 0,
      requiresReview: false })
  assert.deepEqual(await inspectWorkflowColdRun(ctx, request, active,
    native('INTERRUPTED_UNCONFIRMED')),
  { runId, state: 'interrupted-unconfirmed', reason: 'native-interrupted',
    nativeState: 'INTERRUPTED_UNCONFIRMED', pendingChildren: 0, requiresReview: true })
})
