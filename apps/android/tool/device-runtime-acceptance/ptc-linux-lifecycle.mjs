import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { setTimeout as delay } from 'node:timers/promises'
import { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import { PtcLinuxAcceptanceFailure, readPtcLinuxFailureDispatch } from './ptc-linux.mjs'

export const PTC_LINUX_CANCEL_CHECK = 'reviewed-ptc-linux-active-cancellation-and-retirement'
export const PTC_LINUX_DEADLINE_CHECK = 'reviewed-ptc-linux-shared-deadline-and-retirement'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const digest = value => createHash('sha256').update(value).digest('hex')
const dispatches = events => events.filter(event => ['tool/ptc-dispatch-start', 'tool/ptc-dispatch'].includes(event.type))
const nativeDetails = new Map([
  ['Guest death was not confirmed', 'guest-death-unconfirmed'],
  ['Host callback or capability audit did not settle; inspect run effects', 'callback-audit-unconfirmed'],
  ['Guest binding cleanup failed', 'binding-cleanup-failed'],
  ['Guest callback cleanup was interrupted', 'callback-cleanup-interrupted'],
  ['Guest callback cleanup did not finish', 'callback-cleanup-unfinished'],
  ['Guest disconnected before confirmed retirement', 'guest-disconnected'],
  ['Guest binding died', 'binding-died'],
  ['Guest returned no Binder', 'missing-binder'],
  ['Could not start isolated guest', 'guest-start-failed'],
  ['Guest exceeded total bind, execution and retirement deadline', 'retirement-deadline'],
  ['Guest result or retirement request was rejected', 'result-rejected'],
  ['Isolated tool outcome needs inspection', 'tool-outcome-unconfirmed'],
  ['Isolated tool callback was confirmed closed', 'callback-confirmed-closed'],
])

/** Fixed native diagnostics only: no guest text, request payload, nonce or callback token. */
export function ptcNativeRetirementDiagnostics(receipt, requests = [], closures = []) {
  const runId = typeof receipt?.runId === 'string' && UUID.test(receipt.runId) ? receipt.runId : null
  const allowedStates = ['ADMITTED', 'COMPLETED', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'WORKER_DIED', 'RETIRE_UNCONFIRMED', 'INTERRUPTED_UNCONFIRMED']
  const detail = nativeDetails.has(receipt?.detail) ? receipt.detail : null
  return { nativeReceipt: { runId, state: allowedStates.includes(receipt?.state) ? receipt.state : null,
    guestUid: Number.isSafeInteger(receipt?.guestUid) ? receipt.guestUid : null,
    detailCode: detail === null ? (receipt?.detail == null ? null : 'unlisted-native-detail') : nativeDetails.get(detail), detail },
    nativeRequests: requests.filter(row => row.params.runId === runId &&
      ['native.isolated.execute', 'native.isolated.cancel', 'native.isolated.settle', 'native.isolated.release'].includes(row.method))
      .slice(-8).map(row => ({ method: row.method, acknowledged: row.acknowledged === true,
        pending: row.completedAtMs === undefined })),
    callbackClosures: closures.filter(row => row.runId === runId).slice(-4).map(row => ({
      runId, closed: row.closed === true, status: ['pending', 'returned', 'rejected'].includes(row.status) ? row.status : 'unknown',
      errorCode: ['ANDROID_TOOL_DISPATCH_UNCONFIRMED', 'ANDROID_TOOL_CALLBACK_CLOSED'].includes(row.errorCode) ? row.errorCode : null })) }
}

/** The first real Linux command makes the later Linux deadline strictly later than its PTC parent. */
export function ptcLinuxLifecycleProgram(mode, caseId) {
  assert.ok(['cancel', 'deadline'].includes(mode)); assert.match(caseId, UUID)
  const prelude = `sleep 5; printf 'ptc-linux-prelude-${caseId}'`
  const command = `printf 'uncommitted-${caseId}' > /workspace/ptc-lifecycle-${caseId}.txt; while :; do sleep 1; done`
  const code = (mode === 'deadline'
    ? `const first=await tools.linux_exec(${JSON.stringify({ command: prelude, timeoutMs: 120000 })});
      if(first.status!=='completed'||first.exitCode!==0||first.retirementConfirmed!==true||first.diskCommitted!==true)throw new Error('Prelude did not settle');`
    : '') + `return await tools.linux_exec(${JSON.stringify({ command, timeoutMs: 120000 })});`
  return { code, command, prelude }
}

/** Reject substitutes for simultaneous live guests, original deadlines and durable terminal callbacks. */
export function validatePtcLinuxLifecycle(value) {
  const { mode, caseId, sessionId, appUid, result, ptc, executions, active, retired, liveEvents, durableEvents } = value
  const program = ptcLinuxLifecycleProgram(mode, caseId)
  assert.equal(result.isError, true)
  assert.equal(ptc.admit.params.kind, 'ptc'); assert.equal(ptc.admit.params.sessionId, sessionId)
  assert.equal(ptc.admit.params.deadlineMillis, 120000)
  assert.equal(ptc.execute.params.runId, ptc.admit.params.runId)
  assert.equal(ptc.settle.runId, ptc.admit.params.runId)
  assert.equal(ptc.settle.state, mode === 'cancel' ? 'CANCELLED' : 'TIMED_OUT')
  assert.equal(ptc.release.params.runId, ptc.settle.runId); assert.equal(ptc.release.acknowledged, true)
  assert.equal(executions.length, mode === 'cancel' ? 1 : 2)
  const last = executions.at(-1), receipt = last.result
  assert.equal(last.params.command, program.command)
  for (const row of executions) {
    assert.equal(row.params.sessionId, sessionId); assert.equal(row.params.timeoutMs, 120000)
    assert.equal(row.params.persistChanges, true); assert.match(row.params.id, UUID)
  }
  if (mode === 'deadline') {
    const first = executions[0]
    assert.equal(first.params.command, program.prelude)
    assert.equal(first.result.status, 'completed'); assert.equal(first.result.exitCode, 0)
    assert.equal(first.result.diskCommitted, true); assert.equal(first.result.retirementConfirmed, true)
    assert.ok(last.startedAtMs - ptc.execute.startedAtMs >= 5000, 'The nested deadline must start after the real prelude')
    assert.ok(ptc.execute.completedAtMs - ptc.execute.startedAtMs >= 119000, 'The production PTC wall deadline was shortened')
    assert.equal(value.abortRequested, false, 'Fixture cancellation cannot pass as native deadline expiry')
  } else assert.equal(value.abortRequested, true)
  assert.equal(receipt.id, last.params.id); assert.equal(receipt.sessionId, sessionId)
  assert.equal(receipt.status, 'cancelled'); assert.equal(receipt.cancelled, true)
  assert.equal(receipt.timedOut, false); assert.equal(receipt.diskCommitted, false)
  assert.equal(receipt.retirementConfirmed, true)
  assert.ok(last.completedAtMs - last.startedAtMs < 120000, 'Linux reached its own timeout instead of parent cancellation')
  for (const uid of [appUid, ptc.settle.guestUid, receipt.guestUid]) assert.ok(Number.isSafeInteger(uid) && uid > 0)
  assert.equal(new Set([appUid, ptc.settle.guestUid, receipt.guestUid]).size, 3)
  assert.ok(value.cancellations.some(row => row.params.id === receipt.id && row.result?.settled === true && row.result.cancelRequested === true))
  const observation = active.processes
  assert.equal(observation.schema, 1); assert.equal(observation.ptcRunId, ptc.settle.runId)
  assert.equal(observation.linuxRunId, receipt.id); assert.equal(observation.observedPair, true)
  assert.ok(observation.workerCpuSeconds > 0)
  assert.equal(observation.ptcPid, observation.observedPtcPid); assert.equal(observation.linuxPid, observation.observedLinuxPid)
  assert.ok(Number.isSafeInteger(observation.ptcPid) && observation.ptcPid > 0)
  assert.ok(Number.isSafeInteger(observation.linuxPid) && observation.linuxPid > 0)
  assert.equal(new Set([observation.appPid, observation.ptcPid, observation.linuxPid]).size, 3)
  assert.equal(active.inspection.sessionId, sessionId); assert.equal(active.inspection.status, 'active')
  assert.equal(active.inspection.blocked, true)
  const running = active.inspection.records.find(row => row.runId === receipt.id)
  assert.equal(running?.operation, 'execute'); assert.equal(running?.state, 'running')
  assert.equal(retired.length, 2)
  for (const row of retired) {
    assert.equal(row.ptcRunId, ptc.settle.runId); assert.equal(row.linuxRunId, receipt.id)
    assert.equal(row.appPid, observation.appPid)
    assert.equal(row.observedPtcPid, observation.ptcPid); assert.equal(row.observedLinuxPid, observation.linuxPid)
    assert.equal(row.previousPidsGone, true); assert.equal(row.ptcPid, null); assert.equal(row.linuxPid, null)
  }
  assert.ok(retired[1].observedAtElapsedMs > retired[0].observedAtElapsedMs)
  const live = dispatches(liveEvents), durable = dispatches(durableEvents)
  assert.deepEqual(durable, live, 'Callback terminal facts did not survive original Session persistence')
  const starts = durable.filter(row => row.type === 'tool/ptc-dispatch-start')
  const ends = durable.filter(row => row.type === 'tool/ptc-dispatch')
  assert.equal(starts.length, executions.length); assert.equal(ends.length, executions.length)
  for (let index = 0; index < executions.length; index++) {
    assert.equal(starts[index].data.name, 'linux_exec'); assert.equal(ends[index].data.name, 'linux_exec')
    assert.equal(starts[index].data.subCallId, ends[index].data.subCallId)
    assert.ok(starts[index].seq < ends[index].seq)
    assert.equal(starts[index].data.arguments.command, executions[index].params.command)
    const contexts = ends[index].data.additionalContexts.filter(row => row.source.kind === 'android-linux-receipt')
    assert.equal(contexts.length, 1)
    const audit = JSON.parse(contexts[0].content[0].text).linuxVmReceipt
    assert.equal(audit.tool, 'linux_exec'); assert.equal(audit.callId, ends[index].data.subCallId)
    assert.equal(audit.runId, executions[index].params.id); assert.equal(audit.sessionId, sessionId)
    for (const field of ['status', 'retirementConfirmed', 'diskCommitted']) assert.equal(audit[field], executions[index].result[field])
    if (index === executions.length - 1) {
      assert.equal(ends[index].data.isError, true); assert.equal(audit.cancelRequested, true)
      assert.ok(result.additionalContexts.some(row => row.source.kind === 'android-linux-receipt' &&
        JSON.parse(row.content[0].text).linuxVmReceipt.runId === receipt.id))
    }
  }
  return { caseId, sessionId, mode, runId: ptc.settle.runId, linuxRunId: receipt.id,
    appUid, ptcGuestUid: ptc.settle.guestUid, linuxGuestUid: receipt.guestUid,
    ptcState: ptc.settle.state, linuxState: receipt.status, diskCommitted: false,
    workerCpuSeconds: observation.workerCpuSeconds, ptcPid: observation.ptcPid, linuxPid: observation.linuxPid,
    parentElapsedMs: ptc.execute.completedAtMs - ptc.execute.startedAtMs,
    linuxElapsedMs: last.completedAtMs - last.startedAtMs, exactProcessAbsenceObservations: retired.length,
    releaseAcknowledged: true, durableDispatches: ends.length, sessionEvidenceSha256: digest(JSON.stringify(durable)) }
}

async function bounded(promise, milliseconds, reason) {
  let timer
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(reason)), milliseconds) })
  try { return await Promise.race([promise, timeout]) } finally { clearTimeout(timer) }
}

/** Run only in the dedicated device profile; native observations are required, never synthesized. */
export async function runPtcLinuxLifecycle({ mode, ctx, agent, transport, nativeModule, invoke, settlements, ptcRequests, callbackClosures = [] }) {
  const caseId = randomUUID(), program = ptcLinuxLifecycleProgram(mode, caseId)
  const [{ NativeLinuxVm }, { registerLinuxVmTool }] = await Promise.all([
    nativeModule('native-linux-vm.mjs'), nativeModule('tool-linux-vm.mjs'),
  ])
  const requests = [], liveEvents = [], initialRequests = ptcRequests.length, initialSettlements = settlements.length
  const before = agent.session.seq, controller = new AbortController()
  const started = performance.now(), originalMode = ctx.sandboxPolicy.resolve({ session: agent.session }).mode
  const owner = new NativeLinuxVm({ async request(method, params, signal) {
    const row = { method, params, startedAtMs: performance.now(), result: null }; requests.push(row)
    try { row.result = await transport.request(method, params, signal); return row.result }
    finally { row.completedAtMs = performance.now() }
  } })
  let fiber, pending, result, proof, settled = false, active, failure, phase = 'registration', abortRequested = false
  const stop = ctx.on('session/event', (session, event) => { if (session === agent.session) liveEvents.push(event) })
  const executions = () => requests.filter(row => row.method === 'native.linuxVm.execute')
  const stages = () => ptcRequests.slice(initialRequests)
  try {
    fiber = await ctx.plugin({ name: `ptc-linux-lifecycle-${mode}`, inject: ['tools', 'agents', 'sandboxPolicy'], apply(scope) {
      assert.equal(scope.tools.get('linux_exec', agent), undefined)
      registerLinuxVmTool(scope, owner, true)
    } })
    setSandboxMode(agent.session, 'workspace-write')
    phase = 'waiting-for-two-live-guests'
    pending = invoke(program.code, controller.signal).finally(() => { settled = true })
    pending.catch(() => {})
    const readyEnd = performance.now() + 90000
    while (!active && !settled && performance.now() < readyEnd) {
      const last = executions().find(row => row.params.command === program.command)
      const parent = stages().find(row => row.method === 'native.isolated.execute')
      if (last && parent && !last.completedAtMs) {
        const processes = await transport.request('acceptance.ptcLinux.observe',
          { ptcRunId: parent.params.runId, linuxRunId: last.params.id }, AbortSignal.timeout(30000))
        if (processes.observedPair && processes.ptcPid && processes.linuxPid && processes.workerCpuSeconds > 0) {
          const inspection = await transport.request('native.linuxVm.inspect',
            { sessionId: String(agent.session.id), id: last.params.id }, AbortSignal.timeout(10000))
          if (!settled && !last.completedAtMs && inspection.status === 'active' && inspection.records.some(row => row.runId === last.params.id && row.state === 'running')) {
            active = { processes, inspection }
          }
        }
      }
      if (!active) await delay(100)
    }
    assert.ok(active && !settled, 'Both native guests must be active, with observed Linux CPU, before interruption')
    phase = mode === 'cancel' ? 'parent-cancel' : 'native-parent-deadline'
    if (mode === 'cancel') { abortRequested = true; controller.abort(new Error('PTC lifecycle explicit cancellation')) }
    result = await bounded(pending, Math.max(1, 170000 - (performance.now() - started)), 'Parent PTC did not settle within its native limit and retirement allowance')
    phase = 'exact-process-retirement'
    assert.equal(settlements.length, initialSettlements + 1)
    const parent = stages().find(row => row.method === 'native.isolated.execute'), last = executions().at(-1), retired = []
    const retirementEnd = performance.now() + 12000
    while (retired.length < 2 && performance.now() < retirementEnd) {
      const row = await transport.request('acceptance.ptcLinux.observe',
        { ptcRunId: parent.params.runId, linuxRunId: last.params.id }, AbortSignal.timeout(30000))
      if (row.previousPidsGone) retired.push(row); else retired.length = 0
      if (retired.length < 2) await delay(100)
    }
    assert.equal(retired.length, 2, 'Both exact guest processes must disappear after their receipts')
    const cancelEnd = performance.now() + 10000
    while (requests.some(row => row.method === 'native.linuxVm.cancel' && !row.completedAtMs) && performance.now() < cancelEnd) {
      await delay(50)
    }
    phase = 'durable-terminal-audit'
    assert.equal(await ctx.sessions.flush(agent.session), true)
    const reader = await ctx.sessionPersistence.open(agent.session.id, 'read')
    let durableEvents
    try { ({ events: durableEvents } = await reader.read(before, 10000)) } finally { await reader.close() }
    const validated = validatePtcLinuxLifecycle({ mode, caseId, sessionId: String(agent.session.id), appUid: process.getuid(),
      result, active, retired, abortRequested, liveEvents, durableEvents, executions: executions(),
      cancellations: requests.filter(row => row.method === 'native.linuxVm.cancel'),
      ptc: { admit: stages().find(row => row.method === 'native.isolated.admit'), execute: parent,
        release: stages().find(row => row.method === 'native.isolated.release'), settle: settlements.at(-1) } })
    phase = 'owner-close'
    await bounded(owner.dispose(), 15000, 'Linux owner disposal was not confirmed')
    await fiber.dispose(); fiber = null
    proof = { ...validated, linuxOwnerClosed: true, registrationsClosed: true }
  } catch (error) {
    const durable = await readPtcLinuxFailureDispatch(ctx, agent.session, before)
    failure = new PtcLinuxAcceptanceFailure(error, { phase, mode, caseId,
      elapsedMs: performance.now() - started, parentState: settlements.at(-1)?.state ?? null,
      ...ptcNativeRetirementDiagnostics(settlements.length > initialSettlements ? settlements.at(-1) : null,
        stages(), callbackClosures),
      linuxStates: executions().map(row => row.result?.status ?? 'pending'),
      activeObserved: Boolean(active), terminalAudits: dispatches(durable.events).filter(row => row.type === 'tool/ptc-dispatch').length,
      durableRead: durable.state, cleanup: {} })
  } finally {
    controller.abort(new Error('PTC lifecycle fixture closing'))
    const cleanup = async (name, action) => {
      try { await bounded(action(), 35000, `${name} cleanup was not confirmed`); if (failure) failure.diagnostics.cleanup[name] = 'closed' }
      catch (error) {
        failure ??= new PtcLinuxAcceptanceFailure(error, { mode, caseId, phase: 'cleanup', cleanup: {} })
        failure.diagnostics.cleanup[name] = 'unconfirmed'
      }
    }
    if (pending && !settled) await cleanup('parent', () => pending)
    await cleanup('linuxOwner', () => owner.dispose())
    await cleanup('registrations', async () => { await fiber?.dispose() })
    stop(); setSandboxMode(agent.session, originalMode)
  }
  if (failure) throw failure
  return proof
}
