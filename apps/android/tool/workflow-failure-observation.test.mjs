import assert from 'node:assert/strict'
import test from 'node:test'
import { runWorkflowAcceptance } from './device-runtime-acceptance/workflow.mjs'
import { runWorkflowLifecycle, workflowLifecycleStage } from './device-runtime-acceptance/workflow-lifecycle.mjs'
import { summarizeAcceptance } from './device-runtime-acceptance/report.mjs'

// These are report failure-path checks, not simulated successful device acceptance.
const runId = '00000000-0000-4000-8000-000000000101'
const childId = '00000000-0000-4000-8000-000000000102'

function fixture(inspectNative) {
  const events = []
  const live = new Map([[childId, {}]])
  const agent = { id: 'fixture-parent', session: { id: 'fixture-session', snapshotEvents: () => events } }
  const ctx = {
    on: () => () => {}, agents: { get: id => live.get(id) },
    sessions: { flush: async () => true },
    tools: { execute: async () => {
      events.push({ type: 'tool-workflow/run-start', data: { runId } })
      return { isError: false, value: { runId, result: 42 } }
    } },
  }
  const workflow = {
    owner: { inspectRun: async () => ({ state: 'interrupted-unconfirmed', requiresReview: true }) },
    receipts: new Map([[runId, { state: 'INTERRUPTED_UNCONFIRMED', requiresReview: true }]]),
    releases: new Set(),
    callbackFailures: [{ runId, action: 'WORKFLOW_START_CHILD', message: 'route denied' }],
    callbackClosures: [{ runId, closed: true }],
    inspectNative,
  }
  return { ctx, agent, adapter: {}, workflow }
}

test('failure diagnostics preserve unconfirmed receipt, actual child liveness and close separately', async () => {
  const report = await runWorkflowAcceptance(fixture(async (_runId, signal) => {
    assert.equal(_runId, runId)
    assert.ok(signal instanceof AbortSignal)
    return { state: 'INTERRUPTED_UNCONFIRMED', children: [{ childId, state: 'RETIRED' }] }
  }))
  assert.equal(report.passed, 0)
  assert.equal(report.failed, 1)
  assert.equal(report.checks[0].status, 'failed')
  assert.ok(report.checks.slice(1).every(row => row.status === 'unverified'))
  const observed = report.checks[0].observedRuns[0]
  assert.equal(observed.releaseAcknowledged, false)
  assert.equal(observed.nativeReceipt.requiresReview, true)
  assert.deepEqual(observed.nativeInspection.children, [{ childId, state: 'RETIRED', liveAgent: true, activated: false }])
  assert.deepEqual(observed.callbackClosures, [{ runId, closed: true }])
  assert.deepEqual(observed.callbackFailures.map(row => row.message), ['route denied'])
  assert.deepEqual(observed.sessionTerminal, [])
})

test('inspection failure remains explicit and does not hide the original assertion or invent retirement', async () => {
  const report = await runWorkflowAcceptance(fixture(async () => { throw Error('native channel unavailable') }))
  assert.equal(report.failed, 1)
  const failed = report.checks[0]
  assert.match(failed.error, /interrupted-unconfirmed/)
  assert.deepEqual(failed.observedRuns[0].nativeInspection, { unavailable: 'Error: native channel unavailable' })
  assert.equal(failed.observedRuns[0].releaseAcknowledged, false)
})

test('a nonsettling diagnostic read is bounded and leaves subsequent checks unverified', { timeout: 7000 }, async () => {
  const report = await runWorkflowAcceptance(fixture(() => new Promise(() => {})))
  assert.equal(report.failed, 1)
  assert.match(report.checks[0].observedRuns[0].nativeInspection.unavailable, /inspection timed out/)
  assert.ok(report.checks.slice(1).every(row => row.status === 'unverified'))
})

test('deadline fixture reports an actual early failure instead of silently omitting its required check', async () => {
  const events = [{ type: 'session/header', data: {} }]
  const ctx = { on: () => () => {},
    tools: { execute: async () => ({ isError: true, error: { message: 'fixture admission refused' } }) },
    sessionPersistence: { open: async () => ({ read: async () => ({ events }), close: async () => {} }) },
  }
  const adapter = {}
  const workflow = { receipts: new Map(), releases: new Set(), nativeFailures: [],
    callbackStarts: [], callbackFailures: [], callbackClosures: [] }
  const stages = []
  const report = await runWorkflowLifecycle({ ctx, adapter, workflow,
    agent: { session: { id: 'deadline-failure-fixture', seq: 0, snapshotEvents: () => events } },
    transport: { request: async () => { throw Error('No native request is authorized before admission') },
      notify: async (method, frame) => { assert.equal(method, 'acceptance.workflowLifecycleStage'); stages.push(frame.stage) } },
    configuration: { suite: 'workflow-deadline' } })
  assert.equal(report.failed, true)
  assert.equal(report.checks.length, 1)
  assert.equal(report.checks[0].status, 'failed')
  assert.match(report.checks[0].error, /ended before its child model entered/)
  assert.equal(report.checks[0].observed.native, null)
  assert.equal(report.checks[0].observed.releaseAcknowledged, false)
  assert.deepEqual(report.checks[0].observed.durable.events, [])
  assert.equal(adapter.scriptedStream, null)
  const summary = summarizeAcceptance('workflow-deadline', [report])
  assert.equal(summary.passed, false); assert.equal(summary.complete, false)
  assert.equal(summary.coverage.failed.length, 1)
  assert.equal(summary.coverage.issues.includes('No checks executed'), false)
  assert.deepEqual(stages, ['wait-child', 'diagnostic-failed-before-cleanup', 'cleanup-pending', 'cleanup-complete'])
})

test('lifecycle notifications bind fixed stages and stay below the whole-frame limit', () => {
  const frame = workflowLifecycleStage('diagnostic-failed-before-cleanup', runId, 123,
    { error: 'x'.repeat(50000), native: { state: 'INTERRUPTED_UNCONFIRMED' }, releaseAcknowledged: false })
  assert.equal(frame.detail.truncated, true)
  assert.equal(frame.detail.nativeState, 'INTERRUPTED_UNCONFIRMED')
  assert.ok(Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method: 'acceptance.workflowLifecycleStage', params: frame })) <= 12288)
  assert.throws(() => workflowLifecycleStage('passed', runId, 1))
  assert.throws(() => workflowLifecycleStage('wait-native', 'user-session', 1))
  for (const elapsed of [-1, NaN, Infinity]) assert.throws(() => workflowLifecycleStage('wait-native', runId, elapsed))
})
