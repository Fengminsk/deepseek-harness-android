import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { open, readFile, realpath, stat } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { workflowModelScenario } from './workflow-model-fixture.mjs'
import { WORKFLOW_DEADLINE_CHECK, WORKFLOW_DEATH_CHECK } from './workflow-checks.mjs'

import { validateWorkflowDeadline, validateWorkflowDeathMarker } from './workflow-lifecycle-evidence.mjs'
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex')
const markerName = 'workflow-death-ready.json'

/** Keep missing events distinct from malformed event data; no missing outcome is inferred. */
export function requireWorkflowDeadlineTerminal(events, runId) {
  const ends = events.filter(row => row.type === 'tool-workflow/run-end' && row.data?.runId === runId)
  assert.equal(ends.length, 1, 'Expected exactly one durable workflow run-end event')
  assert.ok(Object.hasOwn(ends[0].data, 'stopReason'), 'Durable workflow run-end is missing data.stopReason')
  assert.equal(ends[0].data.stopReason, 'error', 'Native expiry must record a failed workflow outcome')
  return ends.length
}

/** Preserve only event identities and outcome fields, never prompts or model output. */
export function summarizeWorkflowLifecycleEvents(events, runId) {
  const rows = events.filter(row => row.data?.runId === runId && row.type.startsWith('tool-workflow/'))
  return { totalEvents: events.length, runEvents: rows.length, truncated: rows.length > 32,
    events: rows.slice(-32).map(row => ({ type: row.type, eventSeq: row.seq ?? null,
      dataKeys: Object.keys(row.data).sort().slice(0, 16),
      ...Object.fromEntries(['runId', 'seq', 'childId', 'stopReason', 'outcome']
        .filter(key => Object.hasOwn(row.data, key)).map(key => [key, row.data[key]])) })) }
}

function failureText(error) { return String(error?.stack ?? error).slice(0, 2500) }

const lifecycleStages = new Set(['wait-child', 'wait-native', 'native-returned',
  'diagnostic-failed-before-cleanup', 'cleanup-pending', 'cleanup-complete'])

/** Immediate bounded observations survive a later wait; they never constitute a passing result. */
export function workflowLifecycleStage(stage, runId, elapsedMs, detail) {
  assert.ok(lifecycleStages.has(stage))
  assert.ok(runId == null || /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(runId))
  assert.ok(Number.isFinite(elapsedMs) && elapsedMs >= 0)
  const frame = { stage, runId: runId ?? null, elapsedMs, ...(detail === undefined ? {} : { detail }) }
  if (Buffer.byteLength(JSON.stringify(frame), 'utf8') > 11 * 1024) {
    frame.detail = { truncated: true, error: String(detail?.error ?? '').slice(0, 512),
      nativeState: detail?.native?.state ?? null, scriptState: detail?.native?.scriptState ?? null,
      releaseAcknowledged: detail?.releaseAcknowledged ?? null,
      memoryRunEvents: detail?.memory?.runEvents ?? null, durableRunEvents: detail?.durable?.runEvents ?? null }
  }
  // Includes the surrounding JSON-RPC notification, not just its params.
  assert.ok(Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method: 'acceptance.workflowLifecycleStage', params: frame }),
    'utf8') <= 12 * 1024)
  return frame
}

async function diagnosticRead(read) {
  const controller = new AbortController()
  let timer
  try {
    return await Promise.race([read(controller.signal), new Promise((_, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new Error('Lifecycle diagnostic read timed out')) }, 5000)
    })])
  } catch (error) { return { unavailable: failureText(error) } }
  finally { clearTimeout(timer) }
}
const snapshot = async (ctx, id) => {
  const reader = await ctx.sessionPersistence.open(id, 'read')
  try {
    const { events } = await reader.read(0, 10001)
    assert.ok(events.length > 0 && events.length <= 10000, 'Expected bounded durable Session events')
    return events
  } finally { await reader.close() }
}

async function readyFile(path, marker) {
  const file = await open(path, 'wx', 0o600)
  try { await file.writeFile(JSON.stringify(marker) + '\n'); await file.sync() }
  finally { await file.close() }
  const directory = await open(dirname(path), 'r')
  try { await directory.sync() } finally { await directory.close() }
}

async function waitForEntry(model, pending) {
  let timer
  try {
    await Promise.race([model.entered, pending.then(() => { throw new Error('Workflow ended before its child model entered') }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Workflow child model did not enter')), 30000) })])
  } finally { clearTimeout(timer) }
}

async function waitForChildResult(workflow, runId, pending) {
  const entered = Promise.withResolvers()
  const observe = value => { if (value.runId === runId && value.action === 'WORKFLOW_CHILD_RESULT') entered.resolve() }
  const stop = workflow.observeCallbackStarts(observe)
  for (const value of workflow.callbackStarts) observe(value)
  try { await waitForEntry({ entered: entered.promise }, pending) }
  finally { stop() }
}

/** Exercise the original tool and real child while only the provider stream is held. */
export async function runWorkflowLifecycle({ ctx, agent, adapter, workflow, transport, configuration }) {
  if (configuration.suite === 'workflow-process-death' && configuration.workflowDeath.phase === 'recover') {
    return recover({ ctx, agent, adapter, workflow, transport, configuration: configuration.workflowDeath })
  }
  const death = configuration.suite === 'workflow-process-death'
  const controller = new AbortController()
  // The production native deadline is 120 s; this fallback must not win the expiry test.
  const fallback = setTimeout(() => controller.abort(new Error('Workflow lifecycle fallback expired')), 175000)
  const model = workflowModelScenario(), childHandles = []
  adapter.scriptedStream = model.stream
  const unlisten = ctx.on('subagent/start', info => childHandles.push(ctx.agents.get(info.id)))
  const before = agent.session.seq, started = performance.now()
  let runId, result, native, durableEvents, observed, stageFailure
  const stage = async (name, detail) => {
    try {
      await transport.notify?.('acceptance.workflowLifecycleStage',
        workflowLifecycleStage(name, runId, performance.now() - started, detail))
    } catch (error) { stageFailure ??= error }
  }
  const pending = ctx.tools.execute({ name: 'workflow', callId: `workflow-lifecycle-${randomUUID()}`, agent,
    signal: controller.signal, arguments: { script: "return await agent('workflow-fixture:hold-lifecycle')",
      meta: { name: death ? 'death-acceptance' : 'deadline-acceptance', description: 'Bounded lifecycle acceptance' } } })
  pending.catch(() => {})
  try {
    await stage('wait-child')
    await waitForEntry(model, pending)
    assert.equal(model.active, 1)
    const start = agent.session.snapshotEvents().filter(row => row.seq >= before && row.type === 'tool-workflow/run-start')
    assert.equal(start.length, 1)
    runId = start[0].data.runId
    // CHILD_RESULT follows the acknowledged, durable agent-start progress event.
    await waitForChildResult(workflow, runId, pending)
    await stage('wait-native')
    assert.equal(workflow.admissions.get(runId)?.deadlineMillis, 120000)
    assert.equal(childHandles.length, 1)
    const child = childHandles[0]
    assert.ok(child && ctx.agents.get(child.id) === child)
    if (death) {
      const { caseId, phase, processStopConfirmed } = configuration.workflowDeath
      assert.equal(phase, 'prepare'); assert.equal(processStopConfirmed, false)
      const home = await realpath(resolveDshHome())
      assert.equal(basename(home), caseId)
      assert.equal(agent.session.id, `workflow-death-${caseId}`)
      assert.equal(await ctx.sessions.flush(agent.session), true)
      assert.equal(await ctx.sessions.flush(child.session), true)
      const [parentEvents, childEvents, native] = await Promise.all([snapshot(ctx, agent.session.id),
        snapshot(ctx, child.session.id), transport.request('acceptance.workflow.observe', { runId })])
      assert.equal(native.state, 'ADMITTED'); assert.equal(native.outputAbsent, true)
      assert.equal(native.leaseObservation, 'LIVE')
      assert.deepEqual(native.children, [{ childId: child.id, state: 'LAUNCHING' }])
      assert.equal(model.active, 1)
      const marker = validateWorkflowDeathMarker({ schema: 1, caseId, runId, agentPid: process.pid,
        sessionId: agent.session.id, childId: child.id, childSessionId: child.session.id,
        processLeaseId: native.processLeaseId, parentHash: hash(parentEvents), parentEvents: parentEvents.length,
        childHash: hash(childEvents), childEvents: childEvents.length }, caseId)
      assert.equal(parentEvents.filter(row => row.type === 'tool-workflow/agent-start'
        && row.data.runId === runId && row.data.childId === child.id).length, 1)
      await readyFile(join(home, markerName), marker)
      await transport.notify('acceptance.workflowDeathReady', marker)
      await pending
      throw new Error('Workflow returned before the host stopped its active process')
    }
    result = await pending
    await stage('native-returned', { isError: result.isError })
    assert.equal(result.isError, true)
    assert.equal(await ctx.sessions.flush(agent.session), true)
    native = await transport.request('acceptance.workflow.observe', { runId })
    durableEvents = await snapshot(ctx, agent.session.id)
    const terminalCount = requireWorkflowDeadlineTerminal(durableEvents, runId)
    observed = await workflow.owner.inspectRun({ sessionId: agent.session.id, runId })
    assert.equal(observed.state, 'failed'); assert.equal(observed.requiresReview, false)
    const evidence = validateWorkflowDeadline({ runId, childId: child.id, childSessionId: child.session.id,
      deadlineMillis: workflow.admissions.get(runId).deadlineMillis, elapsedMs: performance.now() - started,
      outerAborted: controller.signal.aborted, nativeState: native.state, scriptState: native.scriptState,
      outputAbsent: native.outputAbsent, released: workflow.releases.has(runId), activeModels: model.active,
      modelAborted: model.aborted.includes('hold-lifecycle'), terminalCount,
      childRetired: native.children.length === 1 && native.children[0].childId === child.id
        && native.children[0].state === 'RETIRED' && ctx.agents.get(child.id) === undefined })
    return { suite: 'workflow-deadline', checks: [{ name: WORKFLOW_DEADLINE_CHECK, status: 'passed', ...evidence }] }
  } catch (error) {
    if (death) throw error
    // Inspect the same run without retrying, settling or releasing it. Fixture
    // finally cleanup is separate and cannot turn these observations into a pass.
    const memory = summarizeWorkflowLifecycleEvents(agent.session.snapshotEvents(), runId)
    const saved = durableEvents ?? await diagnosticRead(() => snapshot(ctx, agent.session.id))
    const observation = {
      phase: 'before-fixture-finally', runId: runId ?? null,
      elapsedMs: performance.now() - started, outerAborted: controller.signal.aborted,
      toolResult: result === undefined ? null : { isError: result.isError,
        error: result.error ? { message: String(result.error.message).slice(0, 1500), info: result.error.info ?? null } : null },
      memory, durable: Array.isArray(saved) ? summarizeWorkflowLifecycleEvents(saved, runId) : saved,
      native: native ?? (runId ? await diagnosticRead(signal =>
        transport.request('acceptance.workflow.observe', { runId }, signal)) : null),
      sessionState: observed ?? (runId ? await diagnosticRead(() =>
        workflow.owner.inspectRun({ sessionId: agent.session.id, runId })) : null),
      nativeReceipt: workflow.receipts.has(runId) ? {
        state: workflow.receipts.get(runId).state, requiresReview: workflow.receipts.get(runId).requiresReview,
        outputAbsent: workflow.receipts.get(runId).outputJson == null,
      } : null,
      nativeFailures: workflow.nativeFailures.filter(row => row.runId === runId).slice(-8),
      releaseAcknowledged: workflow.releases.has(runId),
      activeModels: model.active, modelAborted: model.aborted.includes('hold-lifecycle'),
      callbacks: workflow.callbackStarts.filter(row => row.runId === runId).slice(-16),
      callbackFailures: workflow.callbackFailures.filter(row => row.runId === runId).slice(-8),
      callbackClosures: workflow.callbackClosures.filter(row => row.runId === runId).slice(-8),
    }
    await stage('diagnostic-failed-before-cleanup', { error: failureText(error), ...observation })
    return { suite: 'workflow-deadline', failed: true,
      checks: [{ name: WORKFLOW_DEADLINE_CHECK, status: 'failed', error: failureText(error), observed: observation }] }
  } finally {
    clearTimeout(fallback)
    controller.abort(new Error('Lifecycle fixture finished'))
    await stage('cleanup-pending')
    await pending.catch(() => {})
    unlisten(); adapter.scriptedStream = null
    await stage('cleanup-complete')
    // Required evidence publication failure overrides the result only after pending-call cleanup.
    // eslint-disable-next-line no-unsafe-finally -- An unconfirmed progress notification cannot publish a pass.
    if (stageFailure) throw stageFailure
  }
}

async function recover({ ctx, agent, adapter, workflow, transport, configuration }) {
  const { caseId, processStopConfirmed } = configuration
  assert.equal(processStopConfirmed, true)
  const home = await realpath(resolveDshHome())
  assert.equal(basename(home), caseId)
  const path = join(home, markerName), info = await stat(path)
  assert.ok(info.isFile() && info.size > 0 && info.size < 16384)
  const marker = validateWorkflowDeathMarker(JSON.parse(await readFile(path, 'utf8')), caseId)
  assert.notEqual(marker.agentPid, process.pid)
  assert.notEqual(agent.session.id, marker.sessionId)
  const parent = await snapshot(ctx, marker.sessionId), child = await snapshot(ctx, marker.childSessionId)
  assert.equal(hash(parent), marker.parentHash); assert.equal(parent.length, marker.parentEvents)
  assert.equal(hash(child), marker.childHash); assert.equal(child.length, marker.childEvents)
  assert.equal(parent.filter(row => row.type === 'tool-workflow/run-end' && row.data.runId === marker.runId).length, 0)
  const observed = await workflow.owner.inspectRun({ sessionId: marker.sessionId, runId: marker.runId })
  assert.equal(observed.state, 'interrupted-unconfirmed'); assert.equal(observed.requiresReview, true)
  const native = await transport.request('acceptance.workflow.observe', { runId: marker.runId })
  assert.equal(native.state, 'INTERRUPTED_UNCONFIRMED'); assert.equal(native.outputAbsent, true)
  assert.equal(native.processLeaseId, marker.processLeaseId); assert.equal(native.leaseObservation, 'STOPPED')
  assert.notEqual(native.currentLeaseId, marker.processLeaseId)
  assert.deepEqual(native.children, [{ childId: marker.childId, state: 'RETIRED' }])
  assert.equal(ctx.agents.get(marker.childId), undefined)
  assert.equal(adapter.calls, 0); assert.equal(workflow.callbackStarts.length, 0)
  assert.equal(workflow.admissions.size, 0)
  assert.equal(hash(await snapshot(ctx, marker.sessionId)), marker.parentHash)
  assert.equal(hash(await snapshot(ctx, marker.childSessionId)), marker.childHash)
  return { suite: 'workflow-process-death', checks: [{ name: WORKFLOW_DEATH_CHECK, status: 'passed', ...marker,
    oldAgentPid: marker.agentPid, newAgentPid: process.pid, currentLeaseId: native.currentLeaseId,
    nativeState: native.state, nativeOutputAbsent: true, oldLeaseStopped: true, childRetired: true,
    sessionState: observed.state, requiresReview: true, unchangedParentLog: true, unchangedChildLog: true,
    replayedModelCalls: adapter.calls, replayedCallbacks: workflow.callbackStarts.length, newAdmissions: workflow.admissions.size }] }
}
