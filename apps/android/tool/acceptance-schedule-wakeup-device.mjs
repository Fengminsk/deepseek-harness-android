import { spawn } from 'node:child_process'
import { open, realpath } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomUUID, createHash } from 'node:crypto'
import { setTimeout as delay } from 'node:timers/promises'
import { parseInternalDisplays, parseNonInteractivePowerState, parseAcceptanceProcesses, withScreenProtection } from './device-screen-protection.mjs'

const PACKAGE = 'com.minnnng.dsh_android'
const COMPONENT = `${PACKAGE}.test/${PACKAGE}.ScheduleWakeupAcceptanceInstrumentation`
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const SHA = /^[0-9a-f]{64}$/u
const check = (value, code) => { if (!value) throw Object.assign(new Error(code), { code }) }
const hash = value => createHash('sha256').update(value).digest('hex')
const FAILURE_CODE = /^[A-Z_]{1,80}$/u
const HOST_STAGES = new Set(['main-query', 'idle-preflight', 'instrument', 'idle-cleanup', 'main-cleanup',
  'host-client-cleanup', 'instrument-cleanup', 'natural-idle', 'natural-processes', 'natural-service', 'natural-wait'])
const ownedResults = new WeakSet()
const PROGRESS_STAGES = new Map([
  ['status', new Set(['existing-service-bind'])],
  ['prepare', new Set(['existing-service-bind', 'schedule-create-request', 'waiting-without-carrier'])],
  ['observe', new Set(['existing-service-bind', 'natural-delivery-wait'])],
  ['cleanup', new Set(['existing-service-bind', 'owned-reminder-cleanup'])],
])

function progressFields(value) {
  if (!value || !PROGRESS_STAGES.get(value.phase)?.has(value.stage) ||
      !Number.isSafeInteger(value.elapsedMs) || value.elapsedMs < 0 || value.elapsedMs > 660_000) return undefined
  return { phase: value.phase, stage: value.stage, elapsedMs: value.elapsedMs }
}

/** Progress is diagnostic only; a matching phase and case cannot replace final native evidence. */
export function parseScheduleWakeProgress(output, { phase, caseId }) {
  if (typeof output !== 'string' || output.length > 2 * 1024 * 1024 || !UUID.test(caseId)) return undefined
  const rows = [...output.matchAll(/^INSTRUMENTATION_STATUS: scheduleWakeProgress=([^\r\n]{1,2048})\r?$/gmu)].slice(-32)
  let last
  for (const row of rows) {
    let value
    try { value = JSON.parse(row[1]) }
    catch (error) {
      void error /* Malformed progress cannot replace the original phase failure. */
      continue
    }
    if (value?.schema !== 1 || value.caseId !== caseId || value.phase !== phase) continue
    const selected = progressFields(value)
    if (selected && (!last || selected.elapsedMs >= last.elapsedMs)) last = selected
  }
  return last
}

function failureDetails(error) {
  const pending = [{ error, depth: 0 }], seen = new Set(), failures = []
  let truncated = false, lastProgress, result, hostStage, cleanupFailureCode, cleanupNativeFailureCode, cleanupHostStage
  while (pending.length && seen.size < 16) {
    const { error: current, depth } = pending.shift()
    if (!current || typeof current !== 'object' || seen.has(current)) continue
    seen.add(current)
    const record = {}
    const code = current.code ?? current.failureCode ?? current.result?.failureCode
    const native = current.nativeFailureCode ?? current.result?.nativeFailureCode
    if (typeof code === 'string' && FAILURE_CODE.test(code)) record.failureCode = code
    if (typeof native === 'string' && FAILURE_CODE.test(native)) record.nativeFailureCode = native
    if (Object.keys(record).length) failures.push(record)
    lastProgress ??= progressFields(current.lastProgress ?? current.result?.lastProgress)
    const stage = current.hostStage ?? current.result?.hostStage
    if (hostStage === undefined && HOST_STAGES.has(stage)) hostStage = stage
    if (ownedResults.has(current.result)) {
      result ??= current.result
      const cleanupCode = current.result.cleanupFailureCode, nativeCleanup = current.result.cleanupNativeFailureCode
      if (typeof cleanupCode === 'string' && FAILURE_CODE.test(cleanupCode)) cleanupFailureCode ??= cleanupCode
      if (typeof nativeCleanup === 'string' && FAILURE_CODE.test(nativeCleanup)) cleanupNativeFailureCode ??= nativeCleanup
      if (HOST_STAGES.has(current.result.cleanupHostStage)) cleanupHostStage ??= current.result.cleanupHostStage
    }
    const nested = current instanceof AggregateError && Array.isArray(current.errors) ? current.errors : []
    if (depth < 4) {
      const children = [...nested.slice(0, 16), current.cause].filter(Boolean)
      const room = 16 - seen.size - pending.length
      pending.push(...children.slice(0, Math.max(0, room)).map(error => ({ error, depth: depth + 1 })))
      if (nested.length > 16 || children.length > room) truncated = true
    } else if (nested.length || current.cause) truncated = true
  }
  if (pending.length) truncated = true
  const first = failures.find(item => item.failureCode)
  const native = failures.find(item => item.nativeFailureCode)
  return { result, diagnostics: { failureCode: first?.failureCode ?? 'ACCEPTANCE_FAILED',
    ...(native ? { nativeFailureCode: native.nativeFailureCode } : {}),
    ...(lastProgress ? { lastProgress } : {}), ...(hostStage ? { hostStage } : {}),
    ...(cleanupFailureCode ? { cleanupFailureCode } : {}),
    ...(cleanupNativeFailureCode ? { cleanupNativeFailureCode } : {}),
    ...(cleanupHostStage ? { cleanupHostStage } : {}), failures, diagnosticsTruncated: truncated } }
}

/** Retain bounded structured codes through screen-cleanup aggregates, never exception prose or raw output. */
export function scheduleWakeFailureDiagnostics(error) {
  return failureDetails(error).diagnostics
}

/** Preserve only results created by this runner, including when the screen owner wraps its failure. */
export function scheduleWakeFailureReport(error) {
  const { result, diagnostics } = failureDetails(error)
  return { ...(result ? { result } : {}), ...diagnostics,
    protection: error?.protection, retirement: error?.retirement ?? result?.retirement }
}

async function requestPhase(io, options, signal) {
  const output = await io.phase(options, signal)
  try { return parseScheduleWakePhase(output, options) }
  catch (error) {
    const lastProgress = parseScheduleWakeProgress(output, options)
    if (lastProgress) error.lastProgress = lastProgress
    throw error
  }
}

async function bounded(promise, ms, fallback) {
  let timer
  try { return await Promise.race([promise, new Promise(resolve => { timer = setTimeout(() => resolve(fallback), ms) })]) }
  finally { clearTimeout(timer) }
}

/** Every phase preserves the pre-existing main process and its Android alarms. */
export function scheduleWakeInstrumentationArguments({ phase, caseId, mainPid, acceptRealAccountRequest = false }) {
  check(['status', 'prepare', 'observe', 'cleanup'].includes(phase) && UUID.test(caseId) &&
    Number.isSafeInteger(mainPid) && mainPid > 0, 'INVALID_PHASE_ARGUMENTS')
  check(phase !== 'prepare' || acceptRealAccountRequest === true, 'REAL_ACCOUNT_NOT_ADMITTED')
  return ['shell', 'am', 'instrument', '--no-restart', '-w', '-r', '-e', 'phase', phase, '-e', 'caseId', caseId,
    '-e', 'mainPid', String(mainPid), '-e', 'noRestart', 'true',
    ...(phase === 'prepare' ? ['-e', 'acceptRealAccountRequest', 'true'] : []), COMPONENT]
}

/** Read only the fixture's fixed result; status needs-user-action is never delivery acceptance. */
export function parseScheduleWakePhase(output, { phase, caseId, mainPid }) {
  check(typeof output === 'string' && output.length <= 2 * 1024 * 1024, 'INVALID_PHASE_OUTPUT')
  const rows = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)\r?$/gmu)]
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gmu)]
  check(rows.length === 1 && codes.length === 1, 'PHASE_NOT_FINISHED')
  const value = JSON.parse(rows[0][1])
  check(value.schema === 1 && value.kind === 'natural-schedule-wake' && value.phase === phase &&
    value.caseId === caseId && value.mainPid === mainPid, 'PHASE_IDENTITY_MISMATCH')
  if (value.passed !== true || codes[0][1] !== '-1') {
    const error = Object.assign(new Error('NATIVE_PHASE_FAILED'), { code: 'NATIVE_PHASE_FAILED' })
    error.nativeFailureCode = typeof value.failureCode === 'string' && /^[A-Z_]{1,80}$/u.test(value.failureCode)
      ? value.failureCode : 'UNKNOWN'
    throw error
  }
  for (const state of [value.deviceStateBefore, value.deviceStateAfter])
    check(state?.locked === true && state.interactive === false, 'DEVICE_NOT_LOCKED')
  check(value.testCpuLease === false && value.serviceStartedByFixture === false && value.bindingAutoCreate === false &&
    value.bindingReleased === true && Number.isSafeInteger(value.deviceWallMs), 'CARRIER_NOT_RETIRED')
  if (phase === 'prepare') {
    check(value.sessionId === `android-schedule-acceptance-${caseId}` && value.oldAgentRetired === true &&
      value.bindingReleasedBeforeKill === true && value.oldAgentPid === value.agentPid && value.agentPid !== mainPid &&
      Number.isSafeInteger(value.agentPid) && value.agentPid > 0 && value.armedAtMs === value.dueAtMs &&
      value.dueAtMs - value.deviceWallMs >= 40_000 && SHA.test(value.recordSha256) && SHA.test(value.reminderIdSha256), 'PREPARE_EVIDENCE_INVALID')
  }
  if (phase === 'observe') {
    const proof = value.delivery
    check(value.sessionId === `android-schedule-acceptance-${caseId}` && value.agentPid !== value.oldAgentPid &&
      proof?.deliveryCount === 1 && proof.humanSubmissions === 1 && proof.toolCalls === 1 && proof.completedTurns === 2 &&
      proof.assistantMarkerMatches === 1 && proof.markerSha256 === hash(`schedule-delivered-${caseId}`) &&
      SHA.test(proof.historySha256) && Number.isSafeInteger(proof.eventCount) && proof.eventCount > 0 &&
      proof.deliveryInputSeq < proof.finalSeq && proof.finalSeq < proof.endSeq, 'DELIVERY_EVIDENCE_INVALID')
  }
  if (phase === 'cleanup') check(value.ownTaskSettled === true && value.ownReminderDeleted === true &&
    value.ownSessionArchived === true && value.preferencesChanged === false && value.permissionsChanged === false,
  'OWNED_CLEANUP_UNCONFIRMED')
  return value
}

/** Match the current ServiceRecord's process and start intent, not a historical wake log line. */
export function naturalWakeServiceEvidence(text, pid) {
  check(typeof text === 'string' && text.length <= 4 * 1024 * 1024 && Number.isSafeInteger(pid) && pid > 0, 'INVALID_SERVICE_DUMP')
  const records = text.split(/(?=\* ServiceRecord\{)/u).filter(block =>
    /^\* ServiceRecord\{[^\n]*com\.minnnng\.dsh_android\/(?:\.AgentService|com\.minnnng\.dsh_android\.AgentService)\}/u.test(block.trimStart()))
  check(records.length === 1, 'SERVICE_RECORD_NOT_UNIQUE')
  const block = records[0]
  const process = new RegExp(`^\\s*app=ProcessRecord\\{[^\\n]*\\s${pid}:com\\.minnnng\\.dsh_android:agent/[^\\n]*\\}`, 'mu')
  check(process.test(block), 'WAKE_PROCESS_NOT_BOUND')
  check(/^\s*intent=\{[^\n]*\bact=com\.minnnng\.dsh_android\.SCHEDULE_WAKE(?:\s|\})/mu.test(block), 'WAKE_INTENT_NOT_OBSERVED')
  return { agentPid: pid, actionWakeObserved: true, serviceDumpSha256: hash(block) }
}

/** Unknown or failed dumpsys output cannot establish that instrumentation has retired. */
export function scheduleWakeInstrumentationIdle(text) {
  check(typeof text === 'string' && text.length <= 2 * 1024 * 1024 &&
    /^ACTIVITY MANAGER RUNNING PROCESSES \(dumpsys activity processes\)\s*$/mu.test(text), 'INSTRUMENTATION_STATE_UNKNOWN')
  return !/Active instrumentation:|ActiveInstrumentation\{/u.test(text)
}

/** A failed read-only status can retire its fixture while the original App and alarms remain alive. */
export async function runScheduleWakePhaseAcceptance(io, { phase, caseId, signal }) {
  check(['status', 'cleanup'].includes(phase) && UUID.test(caseId), 'INVALID_PHASE_ARGUMENTS')
  const result = { phase: undefined, naturalWakeAccepted: false, passed: false,
    retirement: { confirmed: false, mainPreserved: false, wholeAppRetired: false } }
  ownedResults.add(result)
  let mainPid, failure, hostStage = 'main-query'
  try {
    signal.throwIfAborted()
    const mains = (await io.processes(signal)).filter(item => item.name === PACKAGE)
    check(mains.length === 1, 'PREEXISTING_MAIN_REQUIRED')
    mainPid = mains[0].pid
    hostStage = 'idle-preflight'
    check(await io.instrumentationIdle(signal), 'INSTRUMENTATION_STILL_ACTIVE')
    const options = { phase, caseId, mainPid }
    hostStage = 'instrument'
    result.phase = await requestPhase(io, options, signal)
  } catch (error) { failure = error; result.hostStage = hostStage }
  finally {
    const cleanup = new AbortController()
    const timer = setTimeout(() => cleanup.abort(Object.assign(new Error('CLEANUP_DEADLINE'),
      { code: 'CLEANUP_DEADLINE' })), 60_000)
    let cleanupStage = 'idle-cleanup'
    try {
      check(await io.instrumentationIdle(cleanup.signal), 'INSTRUMENTATION_RETIREMENT_UNCONFIRMED')
      cleanupStage = 'main-cleanup'
      const mains = (await io.processes(cleanup.signal)).filter(item => item.name === PACKAGE)
      check(mainPid && mains.length === 1 && mains[0].pid === mainPid, 'PREEXISTING_MAIN_REQUIRED')
      cleanupStage = 'host-client-cleanup'
      check(io.childrenClosed(), 'HOST_CLIENT_RETIREMENT_UNCONFIRMED')
      // A status request creates no task. Failed explicit cleanup still leaves its task effects unconfirmed.
      result.retirement = { confirmed: phase === 'status' || !failure,
        fixtureInstrumentationRetired: true, hostClientsClosed: true, mainPreserved: true, wholeAppRetired: false,
        ...(phase === 'cleanup' ? { ownedTaskSettled: result.phase?.ownTaskSettled === true } : {}) }
    } catch (error) {
      const diagnostic = scheduleWakeFailureDiagnostics(error)
      result.cleanupFailureCode = diagnostic.failureCode
      result.cleanupHostStage = cleanupStage
      if (diagnostic.nativeFailureCode) result.cleanupNativeFailureCode = diagnostic.nativeFailureCode
      if (!failure) result.hostStage = cleanupStage
      failure ??= error
    } finally { clearTimeout(timer) }
  }
  if (failure) {
    Object.assign(result, scheduleWakeFailureDiagnostics(failure))
    throw Object.assign(new Error(result.failureCode, { cause: failure }),
      { code: result.failureCode, nativeFailureCode: result.nativeFailureCode, hostStage: result.hostStage,
        result, retirement: result.retirement })
  }
  result.passed = true
  return result
}

/** Keep the natural waiting interval free of instrumentation, service bindings and fixture CPU leases. */
export async function runNaturalWakeAcceptance(io, { caseId, signal, acceptRealAccountRequest = false }) {
  check(UUID.test(caseId) && acceptRealAccountRequest === true, 'REAL_ACCOUNT_NOT_ADMITTED')
  const result = { schema: 1, kind: 'natural-schedule-wake-device', caseId, passed: false, phases: {}, samples: [],
    retirement: { confirmed: false, mainPreserved: true, wholeAppRetired: false } }
  ownedResults.add(result)
  let mainPid, preparationAttempted = false, failure, hostStage = 'main-query'
  const inspect = async scope => {
    const processes = await io.processes(scope)
    const mains = processes.filter(item => item.name === PACKAGE)
    check(mains.length === 1 && (!mainPid || mains[0].pid === mainPid), 'PREEXISTING_MAIN_REQUIRED')
    mainPid = mains[0].pid
    const agents = processes.filter(item => item.name === `${PACKAGE}:agent`)
    check(agents.length <= 1, 'AGENT_PROCESS_AMBIGUOUS')
    return agents[0]?.pid ?? null
  }
  const phase = async (name, scope) => {
    hostStage = name === 'cleanup' ? 'main-cleanup' : 'main-query'
    await inspect(scope)
    hostStage = name === 'cleanup' ? 'idle-cleanup' : 'idle-preflight'
    check(await io.instrumentationIdle(scope), 'INSTRUMENTATION_STILL_ACTIVE')
    const options = { phase: name, caseId, mainPid, acceptRealAccountRequest }
    hostStage = name === 'cleanup' ? 'instrument-cleanup' : 'instrument'
    return requestPhase(io, options, scope)
  }
  try {
    signal.throwIfAborted()
    await inspect(signal)
    result.mainPid = mainPid
    result.phases.status = await phase('status', signal)
    check(result.phases.status.needsUserAction === false && result.phases.status.wake?.enabled === true &&
      result.phases.status.wake.exactAlarmsAllowed === true, 'USER_PERMISSION_OR_ENABLE_REQUIRED')
    preparationAttempted = true
    const prepared = await phase('prepare', signal); result.phases.prepare = prepared
    const dueAt = io.now() + prepared.dueAtMs - prepared.deviceWallMs
    let emptyCount = 0, observed
    const until = dueAt + 150_000
    while (io.now() < until) {
      signal.throwIfAborted()
      hostStage = 'natural-idle'
      check(await io.instrumentationIdle(signal), 'WAIT_INTERVAL_HAS_INSTRUMENTATION')
      hostStage = 'natural-processes'
      const pid = await inspect(signal), elapsedToDueMs = io.now() - dueAt
      check(pid !== prepared.oldAgentPid, 'OLD_AGENT_STILL_PRESENT')
      result.samples.push({ elapsedToDueMs, agentPid: pid, instrumentationIdle: true })
      check(result.samples.length <= 400, 'WAIT_SAMPLE_LIMIT')
      if (pid) {
        check(emptyCount >= 2 && elapsedToDueMs >= -1000, 'AGENT_STARTED_BEFORE_ALARM')
        hostStage = 'natural-service'
        observed = naturalWakeServiceEvidence(await io.services(signal), pid)
        result.naturalStart = observed
        break
      }
      emptyCount++
      hostStage = 'natural-wait'
      await io.delay(1000, signal)
    }
    check(observed, 'NATURAL_WAKE_NOT_OBSERVED')
    const observation = await phase('observe', signal)
    check(observation.agentPid === observed.agentPid && observation.oldAgentPid === prepared.oldAgentPid &&
      observation.generation !== prepared.generation && observation.dueAtMs === prepared.dueAtMs, 'OBSERVATION_IDENTITY_MISMATCH')
    result.phases.observe = observation
  } catch (error) { failure = error; result.hostStage = hostStage }
  finally {
    const cleanup = new AbortController()
    const timer = setTimeout(() => cleanup.abort(new Error('CLEANUP_DEADLINE')), 60_000)
    try {
      if (preparationAttempted) result.phases.cleanup = await phase('cleanup', cleanup.signal)
      hostStage = 'idle-cleanup'
      check(await io.instrumentationIdle(cleanup.signal), 'INSTRUMENTATION_RETIREMENT_UNCONFIRMED')
      hostStage = 'host-client-cleanup'
      check(io.childrenClosed(), 'HOST_CLIENT_RETIREMENT_UNCONFIRMED')
      hostStage = 'main-cleanup'
      await inspect(cleanup.signal)
      result.retirement = { confirmed: true, fixtureInstrumentationRetired: true, hostClientsClosed: true,
        ownedTaskSettled: !preparationAttempted || result.phases.cleanup.ownTaskSettled,
        mainPreserved: true, wholeAppRetired: false }
    } catch (error) {
      const diagnostic = scheduleWakeFailureDiagnostics(error)
      result.cleanupFailureCode = diagnostic.failureCode
      result.cleanupHostStage = hostStage
      if (diagnostic.nativeFailureCode) result.cleanupNativeFailureCode = diagnostic.nativeFailureCode
      if (!failure) result.hostStage = hostStage
      failure ??= error
    } finally { clearTimeout(timer) }
  }
  if (failure) {
    Object.assign(result, scheduleWakeFailureDiagnostics(failure))
    throw Object.assign(new Error(result.failureCode, { cause: failure }),
      { code: result.failureCode, nativeFailureCode: result.nativeFailureCode, hostStage: result.hostStage,
        result, retirement: result.retirement })
  }
  result.passed = true
  return result
}

function deviceIo(adb, serial) {
  const children = new Set()
  async function command(args, signal, timeoutMs = 10_000, cancelPhase, fixtureOwned = true, phaseOptions) {
    const child = spawn(adb, ['-s', serial, ...args], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
    if (fixtureOwned) children.add(child)
    let output = '', stopping
    const closed = new Promise((resolve, reject) => {
      child.once('error', reject)
      child.once('close', code => { children.delete(child); resolve(code) })
    })
    const collect = bytes => {
      if (output.length > 2 * 1024 * 1024) return
      output += bytes.toString().slice(0, 2 * 1024 * 1024 + 1 - output.length)
      if (output.length > 2 * 1024 * 1024) abort()
    }
    child.stdout.on('data', collect); child.stderr.on('data', collect)
    const stop = () => stopping ??= (async () => {
      if (cancelPhase) {
        try { await command(['shell', 'am', 'broadcast', '-a', `${PACKAGE}.scheduleAcceptance.${cancelPhase}`,
          '--receiver-foreground'], undefined, 8000) } catch (error) { void error /* Native completion remains required below. */ }
        const ended = await bounded(closed.then(() => true, () => true), 40_000, false)
        if (ended) return
      }
      child.kill('SIGKILL')
      const ended = await bounded(closed.then(() => true, () => true), 8000, false)
      if (!ended) { child.unref(); check(false, 'HOST_CLIENT_RETIREMENT_UNCONFIRMED') }
    })()
    const abort = () => { void stop().catch(error => { void error /* The awaited stop below preserves unknown retirement. */ }) }
    const timer = setTimeout(abort, timeoutMs)
    signal?.addEventListener('abort', abort, { once: true })
    if (signal?.aborted) abort()
    try {
      const code = await bounded(closed, timeoutMs + 50_000, null)
      if (code === null) { await stop(); check(false, 'HOST_CLIENT_DEADLINE') }
      if (stopping) { await stopping; throw signal?.reason ?? Object.assign(new Error('COMMAND_DEADLINE'), { code: 'COMMAND_DEADLINE' }) }
      check(code === 0, 'COMMAND_FAILED'); signal?.throwIfAborted(); return output
    } catch (error) {
      const lastProgress = phaseOptions && parseScheduleWakeProgress(output, phaseOptions)
      if (lastProgress) error.lastProgress = lastProgress
      throw error
    } finally { clearTimeout(timer); signal?.removeEventListener('abort', abort) }
  }
  const shell = (args, signal, fixtureOwned = true) => command(['shell', ...args], signal, 10_000, undefined, fixtureOwned)
  return {
    now: () => performance.now(), delay: (ms, signal) => delay(ms, undefined, { signal }), childrenClosed: () => children.size === 0,
    processes: async signal => parseAcceptanceProcesses(await shell(['ps', '-A', '-w', '-o', 'PID,ARGS'], signal)),
    instrumentationIdle: async signal => scheduleWakeInstrumentationIdle(await shell(['dumpsys', 'activity', 'processes', PACKAGE], signal)),
    services: signal => shell(['dumpsys', 'activity', 'services', `${PACKAGE}.AgentService`], signal),
    phase: (options, signal) => command(scheduleWakeInstrumentationArguments(options), signal,
      options.phase === 'prepare' ? 260_000 : options.phase === 'observe' ? 170_000 : 60_000, options.caseId, true, options),
    // The guard joins its own ADB reads after the fixture retires; they are not fixture clients.
    inspect: async signal => parseInternalDisplays(
      await shell(['cmd', 'display', 'get-displays', '--ids-only', '--type', 'internal', '--category', 'android.hardware.display.category.ALL_INCLUDING_DISABLED'], signal, false),
      await shell(['dumpsys', 'display'], signal, false), await shell(['dumpsys', 'SurfaceFlinger'], signal, false)),
    powerOff: (id, signal) => shell(['cmd', 'display', 'power-off', id], signal, false),
    powerReset: (id, signal) => shell(['cmd', 'display', 'power-reset', id], signal, false),
    sleep: signal => shell(['input', 'keyevent', '223'], signal, false),
    nonInteractive: async signal => parseNonInteractivePowerState(await shell(['dumpsys', 'power'], signal, false)),
  }
}

/** Keep the display override opt-in explicit; omitted options retain normal cleanup. */
export function parseScheduleWakeArguments(args) {
  const values = new Map()
  for (let i = 0; i < args.length; i += 2) {
    check(['--adb', '--serial', '--report', '--mode', '--case-id', '--accept-real-account-request', '--keep-display-off'].includes(args[i]) &&
      !values.has(args[i]) && args[i + 1], 'INVALID_ARGUMENTS')
    values.set(args[i], args[i + 1])
  }
  const adb = values.get('--adb'), serial = values.get('--serial'), report = values.get('--report')
  check(adb && serial && report && /^[A-Za-z0-9._:-]{1,128}$/u.test(serial), 'ADB_SERIAL_REPORT_REQUIRED')
  const mode = values.get('--mode') ?? 'status', caseId = values.get('--case-id') ?? randomUUID()
  check(['status', 'run', 'cleanup'].includes(mode) && UUID.test(caseId), 'INVALID_MODE')
  check(mode !== 'run' || values.get('--accept-real-account-request') === 'true', 'REAL_ACCOUNT_NOT_ADMITTED')
  check(!values.has('--keep-display-off') || values.get('--keep-display-off') === 'true', 'INVALID_KEEP_DISPLAY_OFF')
  return { adb, serial, report, mode, caseId, keepDisplayOff: values.has('--keep-display-off') }
}

/** The natural-wake owner keeps its original main process even when retaining physical panel Off. */
export function runProtectedScheduleWakeAcceptance(io, { mode, caseId, keepDisplayOff = false, signal }) {
  return withScreenProtection(io, async scope => {
    if (mode === 'run') return runNaturalWakeAcceptance(io, { caseId, signal: scope, acceptRealAccountRequest: true })
    return runScheduleWakePhaseAcceptance(io, { phase: mode, caseId, signal: scope })
  }, { timeoutMs: mode === 'run' ? 660_000 : 200_000, restoreDisplayPower: !keepDisplayOff, signal })
}

async function main() {
  const { adb, serial, report, mode, caseId, keepDisplayOff } = parseScheduleWakeArguments(process.argv.slice(2))
  const handle = await open(resolve(report), 'wx')
  const controller = new AbortController()
  const interrupt = () => controller.abort(Object.assign(new Error('HOST_INTERRUPTED'), { code: 'HOST_INTERRUPTED' }))
  process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt)
  const io = deviceIo(resolve(adb), serial)
  let result, failure
  try {
    result = await runProtectedScheduleWakeAcceptance(io, { mode, caseId, keepDisplayOff, signal: controller.signal })
  } catch (error) { failure = error; result = scheduleWakeFailureReport(error) }
  finally {
    process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt)
    await handle.writeFile(JSON.stringify({ schema: 1, serial, mode, caseId, keepDisplayOff, ...result }, null, 2) + '\n')
    await handle.close()
  }
  if (failure) throw new Error('Schedule acceptance failed; inspect the reserved report')
}

if (process.argv[1] && await realpath(resolve(process.argv[1])).catch(() => '') ===
    await realpath(fileURLToPath(import.meta.url))) await main()
