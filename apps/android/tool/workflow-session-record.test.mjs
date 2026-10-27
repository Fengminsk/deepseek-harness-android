import assert from 'node:assert/strict'
import test from 'node:test'
import { createWorkflowSessionRecord } from '../runtime/workflow-session-record.mjs'

const prepared = () => ({
  kind: 'workflow', runId: 'run-1', sessionId: 'android-1793060921975320-627842147',
  meta: { name: 'Review' },
})

function harness(flush) {
  const events = []
  const session = {
    id: 'android-1793060921975320-627842147',
    append(type, data) { events.push({ type, data }) },
  }
  return {
    events, session,
    ctx: { sessions: { flush: flush ?? (async () => true) } },
  }
}

test('Session record pairs member events and flushes each durable event', async () => {
  let flushes = 0
  const { ctx, session, events } = harness(async seen => {
    assert.equal(seen, session)
    flushes++
    return true
  })
  const record = createWorkflowSessionRecord(ctx, prepared(), { session })
  await record.start()
  await record.progress({ type: 'phase', title: 'Read' })
  await record.progress({ type: 'agent-start',
    info: { seq: 1, label: 'One', childId: 'child-1' } })
  assert.equal(record.agentsStarted, 1)
  await assert.rejects(record.finish('completed'), /cannot settle/)
  await assert.rejects(record.progress({ type: 'agent-end',
    info: { seq: 1, childId: 'another', outcome: 'completed' } }), /matching start/)
  await record.progress({ type: 'agent-end',
    info: { seq: 1, childId: 'child-1', outcome: 'completed' } })
  await record.finish('completed')
  assert.equal(flushes, 4)
  assert.deepEqual(events.map(event => event.type), [
    'tool-workflow/run-start', 'tool-workflow/agent-start',
    'tool-workflow/agent-end', 'tool-workflow/run-end',
  ])
  await assert.rejects(record.progress({ type: 'log', message: 'late' }), /no open/)
})

test('missing durability confirmation leaves an open run and denies progress', async () => {
  const { ctx, session, events } = harness(async () => false)
  const record = createWorkflowSessionRecord(ctx, prepared(), { session })
  await assert.rejects(record.start(), /no durable storage listener/)
  assert.deepEqual(events.map(event => event.type), ['tool-workflow/run-start'])
  await assert.rejects(record.progress({ type: 'log', message: 'late' }), /no open/)
  await assert.rejects(record.finish('completed'), /cannot settle/)
})

test('failed member flush prevents a false terminal record', async () => {
  let count = 0
  const { ctx, session, events } = harness(async () => ++count === 1)
  const record = createWorkflowSessionRecord(ctx, prepared(), { session })
  await record.start()
  await assert.rejects(record.progress({ type: 'agent-start',
    info: { seq: 1, label: 'One', childId: 'child-1' } }), /no durable storage listener/)
  await assert.rejects(record.finish('completed'), /cannot settle/)
  assert.deepEqual(events.map(event => event.type),
    ['tool-workflow/run-start', 'tool-workflow/agent-start'])
})
