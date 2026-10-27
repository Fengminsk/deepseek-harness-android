import { createHash } from 'node:crypto'
import { validateRecoveryNetworks } from './agent-service-recovery-driver.mjs'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const TOKEN = /^[0-9a-f]{32}$/u
const SHA = /^[0-9a-f]{64}$/u
const uuid = value => typeof value === 'string' && UUID.test(value)
const digest = value => typeof value === 'string' && SHA.test(value)
const validToken = value => typeof value === 'string' && TOKEN.test(value)
const demand = (value, message) => { if (!value) throw new Error(`Radio task ${message}`) }
const integer = (value, max = 0x7fffffff) => Number.isSafeInteger(value) && value >= 0 && value <= max
const hash = value => createHash('sha256').update(value, 'utf8').digest('hex')
const bounded = (value, maximum) => typeof value === 'string' && value.trim().length > 0 &&
  value.length <= maximum && [...value].every(character => character.charCodeAt(0) >= 32 && character.charCodeAt(0) !== 127)
const pick = (value, fields) => Object.fromEntries(fields.map(key => [key, value[key]]))
function object(value) { demand(value && typeof value === 'object' && !Array.isArray(value), 'object is missing'); return value }
function exact(value, fields) {
  object(value)
  demand(Object.keys(value).length === fields.length && Object.keys(value).every(key => fields.includes(key)), 'fields are unsupported')
}
function outputBound(output) {
  demand(typeof output === 'string' && Buffer.byteLength(output, 'utf8') <= 2 * 1024 * 1024, 'output exceeded its bound')
}
function parseJson(text, max = 32768) {
  demand(Buffer.byteLength(text, 'utf8') <= max, 'JSON exceeded its bound')
  try { return object(JSON.parse(text)) } catch { throw new Error('Radio task JSON is invalid') }
}
function finalRow(output) {
  outputBound(output)
  const rows = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=([^\r\n]*)(?:\r?\n|$)/gm)]
  demand(rows.length <= 1, 'has duplicate final results')
  return rows.length ? parseJson(rows[0][1]) : undefined
}

// Independent host reconstruction: the native fixture must request exactly this offline-only command.
function commandHash(caseId) {
  return hash(["python3 - <<'PY'", 'import hashlib,json,time', `marker='account-acceptance-${caseId}'`,
    'started=time.monotonic()', 'time.sleep(40)',
    "print(json.dumps({'marker':marker,'sha256':hashlib.sha256(marker.encode()).hexdigest(),'waitMs':int((time.monotonic()-started)*1000)}))", 'PY'].join('\n'))
}
const IDENTITY = ['token', 'caseId', 'sessionId', 'generation', 'agentPid', 'callId', 'toolStartSeq', 'commandSha256']
function identity(value, token) {
  object(value)
  demand(value.schema === 1 && validToken(token) && value.token === token && uuid(value.caseId) &&
    value.sessionId === `android-account-acceptance-${value.caseId}`, 'identity is invalid')
  demand(bounded(value.generation, 128) && integer(value.agentPid) && value.agentPid > 0 &&
    bounded(value.callId, 256) && integer(value.toolStartSeq) && value.commandSha256 === commandHash(value.caseId),
  'service, call or command identity is invalid')
}
const BACKGROUND_FIELDS = ['keepAwakeWhileWorking', 'wakeLockHeld', 'fresh', 'running', 'queued', 'waiting', 'failed',
  'backgroundJobs', 'packageOperations', 'taskState', 'powerErrorPresent', 'notificationErrorPresent']
const PHASES = ['starting', 'ready', 'failed', 'restarting', 'maintenance', 'maintenance-checking', 'maintenance-blocked', 'unknown']
const TASK_STATES = new Set([...PHASES, 'stopped', 'unconfirmed', 'partial', 'running', 'packages', 'waiting', 'queued', 'attention', 'idle'])
function background(value, active = false) {
  exact(value, BACKGROUND_FIELDS)
  demand(['keepAwakeWhileWorking', 'wakeLockHeld', 'fresh', 'powerErrorPresent', 'notificationErrorPresent']
    .every(key => typeof value[key] === 'boolean') && ['running', 'queued', 'waiting', 'failed'].every(key => integer(value[key])) &&
    ['backgroundJobs', 'packageOperations'].every(key => value[key] === null || integer(value[key])) && TASK_STATES.has(value.taskState),
  'background facts are invalid')
  if (active) demand(value.fresh && value.wakeLockHeld && value.running > 0, 'background task is not active')
  return pick(value, BACKGROUND_FIELDS)
}
const NETWORK_FIELDS = ['schema', 'appDefaultNetworkHandle', 'validatedNetworks', 'validatedInternetNetworks',
  'validatedVpnInternetNetworks', 'usableUnderlyingInternetNetworks', 'unvalidatedUnderlyingInternetNetworks', 'unknownCapabilityNetworks']
const NETWORK_FACT_FIELDS = ['handle', 'capabilitiesKnown', 'internet', 'validated', 'vpn', 'notSuspended', 'appDefault', 'transportTypes']
function networks(value, stage) {
  const counts = validateRecoveryNetworks(value)
  demand(counts.unknownCapabilityNetworks === 0, 'network capabilities are unknown')
  if (stage === 'offline') demand(counts.usableUnderlyingInternetNetworks === 0 &&
    counts.unvalidatedUnderlyingInternetNetworks === 0, 'offline checkpoint still has underlying internet')
  if (stage === 'ready' || stage === 'restored') demand(counts.usableUnderlyingInternetNetworks > 0, 'online checkpoint lacks underlying internet')
  // Do not retain arbitrary network properties such as SSIDs, addresses or application identifiers.
  return { ...pick(value, NETWORK_FIELDS), networks: value.networks.map(fact => ({ ...pick(fact, NETWORK_FACT_FIELDS),
    transportTypes: [...fact.transportTypes] })) }
}
function snapshot(value, token, stage) {
  identity(value, token)
  demand(value.stage === stage && ['ready', 'observe', 'offline', 'restored'].includes(stage) && value.locked === true &&
    value.interactive === false && value.ownTaskRunning === true && value.toolPending === true && integer(value.elapsedMs, 360000),
  'checkpoint lost its stage, lock or active tool')
  return { schema: 1, ...pick(value, IDENTITY), stage, locked: true, interactive: false, ownTaskRunning: true, toolPending: true,
    networkEvidence: networks(value.networkEvidence, stage), background: background(value.background, true), elapsedMs: value.elapsedMs }
}
function ready(value, token) { return snapshot(value, token, 'ready') }
function checkpoint(value, initial, stage) {
  ready(initial, initial?.token)
  const result = snapshot(value, initial.token, stage)
  demand(IDENTITY.every(key => result[key] === initial[key]) && result.elapsedMs >= initial.elapsedMs, 'checkpoint changed its original task or clock')
  return result
}

const CLEANUP_FIELDS = ['cancelRequested', 'taskSettled', 'archived', 'exportReleased', 'disconnected']
const RECEIPT_FIELDS = ['id', 'status', 'exitCode', 'retirementConfirmed', 'cancelled', 'timedOut', 'truncated',
  'cancelRequested', 'diskCommitted', 'guestUid', 'waitMs', 'outputSha256']
const FAILURE_FIELDS = ['failureCode', 'cleanupFailureCode', 'exportCleanupFailureCode', 'disconnectFailureCode',
  'screenFailureCode', 'receiverCleanupFailureCode']
function result(output, initial) {
  ready(initial, initial?.token)
  const value = finalRow(output)
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)[ \t]*(?:\r?\n|$)/gm)]
  const passes = [...output.matchAll(/^INSTRUMENTATION_RESULT: passed=([^\r\n]*)(?:\r?\n|$)/gm)]
  demand(codes.length === 1 && codes[0][1] === '-1' && passes.length === 1 && passes[0][1] === 'true', 'instrumentation did not pass exactly once')
  identity(value, initial.token)
  demand(IDENTITY.every(key => value[key] === initial[key]) && value.passed === true && value.kind === 'production-account-task' &&
    value.exercise === 'radio-linux' && value.requestId === `account-request-${value.caseId}`, 'final task identity changed')
  demand(!FAILURE_FIELDS.some(key => Object.hasOwn(value, key) || Object.hasOwn(value, `${key}Type`)), 'final result contains a failure')
  demand(value.provider === 'deepseek-account' && typeof value.model === 'string' && /^[A-Za-z0-9._:/-]{1,128}$/u.test(value.model), 'model identity is invalid')
  demand(value.submittedCount === 1 && value.userMessageCount === 1 && value.assistantMarkerMatches === 1 && value.toolCalls === 1 &&
    value.turnEndCount === 1 && value.completionKind === 'completed', 'durable turn or tool counts are invalid')
  demand(value.markerSha256 === hash(`account-acceptance-${value.caseId}`) && digest(value.historySha256) &&
    integer(value.eventCount, 511) && value.eventCount > 0 && integer(value.toolEndSeq) && integer(value.endSeq) &&
    value.toolStartSeq < value.toolEndSeq && value.toolEndSeq < value.endSeq && integer(value.retryEventCount), 'durable identity or event order is invalid')
  demand(value.radioRestoredObserved === true && integer(value.offlineCheckpointElapsedMs, 360000) &&
    integer(value.restoredCheckpointElapsedMs, 360000) && integer(value.elapsedMs, 360000) &&
    initial.elapsedMs <= value.offlineCheckpointElapsedMs && value.restoredCheckpointElapsedMs - value.offlineCheckpointElapsedMs >= 15000 &&
    value.restoredCheckpointElapsedMs <= value.elapsedMs, 'offline dwell or restoration evidence is invalid')
  for (const state of [value.deviceStateBefore, value.deviceStateAfter]) {
    exact(state, ['locked', 'interactive'])
    demand(state.locked === true && state.interactive === false, 'lost its locked noninteractive state')
  }
  demand(value.ownTaskRunningObserved === true && value.foregroundBefore === true && value.foregroundDuring === true && value.foregroundAfter === true,
    'foreground execution was not observed')
  const before = background(value.backgroundBefore), during = background(value.backgroundDuring, true), after = background(value.backgroundAfter)
  exact(value.cleanup, CLEANUP_FIELDS)
  demand(value.archived === true && value.cleanup.cancelRequested === false &&
    CLEANUP_FIELDS.filter(key => key !== 'cancelRequested').every(key => value.cleanup[key] === true), 'cleanup or own task settlement is unconfirmed')
  const receipt = value.linuxReceipt
  exact(receipt, RECEIPT_FIELDS)
  demand(uuid(receipt.id) && receipt.status === 'completed' && receipt.exitCode === 0 && receipt.retirementConfirmed === true &&
    ['cancelled', 'timedOut', 'truncated', 'cancelRequested'].every(key => receipt[key] === false) && typeof receipt.diskCommitted === 'boolean' &&
    integer(receipt.guestUid) && receipt.guestUid > 0 && integer(receipt.waitMs, 120000) && receipt.waitMs >= 39000 &&
    receipt.waitMs <= value.elapsedMs && digest(receipt.outputSha256),
  'Linux execution or guest retirement is unconfirmed')
  return { ...pick(value, ['schema', 'kind', 'exercise', ...IDENTITY, 'requestId', 'provider', 'model', 'passed', 'submittedCount',
    'userMessageCount', 'assistantMarkerMatches', 'toolCalls', 'turnEndCount', 'completionKind', 'markerSha256', 'historySha256', 'eventCount',
    'toolEndSeq', 'endSeq', 'elapsedMs', 'archived', 'ownTaskRunningObserved', 'foregroundBefore', 'foregroundDuring', 'foregroundAfter',
    'radioRestoredObserved', 'offlineCheckpointElapsedMs', 'restoredCheckpointElapsedMs', 'retryEventCount']),
  deviceStateBefore: { locked: true, interactive: false }, deviceStateAfter: { locked: true, interactive: false },
  backgroundBefore: before, backgroundDuring: during, backgroundAfter: after, cleanup: pick(value.cleanup, CLEANUP_FIELDS),
  linuxReceipt: pick(receipt, RECEIPT_FIELDS), physicalPanelEvidence: 'requires-outer-owner', processRetirement: 'requires-outer-owner',
  modelRequestRetryTested: false, originalConversationRenderingTested: false }
}

const PROGRESS_STAGES = new Set(['instrumentation-start', 'service-start-requested', 'service-started', 'bind-requested', 'bound', 'connected',
  'runtime-ready-wait', 'runtime-ready', 'runtime-info', 'background-preflight', 'catalog-read', 'session-ensure', 'session-rename',
  'catalog-recheck', 'ready', 'send-requested', 'submitted', 'completed', 'durable', 'cleanup'])
const BOOT_STAGES = new Set(['service-created', 'checking-app-processes', 'maintenance', 'process-check-blocked', 'preparing-assets',
  'preparing-storage', 'recovering-workflows', 'starting-node', 'ready', 'unknown'])
const PROGRESS_FIELDS = ['schema', 'kind', 'token', 'caseId', 'stage', 'lastStage', 'pulse', 'sequence', 'pid', 'elapsedMs', 'uptimeMs', 'runtimeObservedAtMs', 'runtime']
function progress(output, token) {
  outputBound(output)
  demand(validToken(token), 'progress token is invalid')
  let last, count = 0
  // Only complete lines are observable while the child is writing its transcript.
  for (const row of output.matchAll(/^INSTRUMENTATION_STATUS: progress=([^\r\n]*)\r?\n/gm)) {
    demand(++count <= 1024, 'progress count exceeded its bound')
    const value = parseJson(row[1], 1024)
    exact(value, PROGRESS_FIELDS)
    demand(value.schema === 1 && value.kind === 'production-account-task' && value.token === token && uuid(value.caseId) &&
      PROGRESS_STAGES.has(value.stage) && value.lastStage === value.stage && typeof value.pulse === 'boolean' && integer(value.sequence, 1024) &&
      value.sequence > 0 && integer(value.pid) && value.pid > 0 && integer(value.elapsedMs, 360000) && integer(value.uptimeMs, 360000), 'progress identity or stage is invalid')
    if (last) demand(value.sequence > last.sequence && value.caseId === last.caseId && value.pid === last.pid &&
      value.elapsedMs >= last.elapsedMs && value.uptimeMs >= last.uptimeMs, 'progress identity, sequence or clock changed')
    if (value.runtime === null) demand(value.runtimeObservedAtMs === null, 'progress runtime time has no observation')
    else {
      exact(value.runtime, ['phase', 'bootStage', 'nodeStarted'])
      demand(integer(value.runtimeObservedAtMs, value.elapsedMs) && PHASES.includes(value.runtime.phase) && BOOT_STAGES.has(value.runtime.bootStage) &&
        (typeof value.runtime.nodeStarted === 'boolean' || value.runtime.nodeStarted === null), 'progress runtime summary is invalid')
    }
    last = pick(value, PROGRESS_FIELDS)
  }
  return last
}

// Fixed fixture codes only. Never return Java exception messages, model output, arbitrary RPC data or stack traces.
const FAILURE_CODES = new Set(`ACCOUNT_UNAVAILABLE ACTIVE_BACKGROUND_NOT_OBSERVED ASSISTANT_BLOCK_INVALID ASSISTANT_INTERRUPTED
ASSISTANT_MARKER_MISMATCH BIND_FAILED COMPLETION_ORDER_INVALID COMPLETION_SIGNAL_MISMATCH DEADLINE_EXCEEDED DEFAULT_CHANGED
DEFAULT_NOT_ACCOUNT DEVICE_INTERACTIVE DOMAIN_FAILED DUPLICATE_TOOL_CALL DUPLICATE_TOOL_RESULT DUPLICATE_TURN_END DURABLE_MISMATCH
EVENT_COUNT_INVALID EVENT_ORDER_INVALID EVIDENCE_UNCONFIRMED EXERCISE_INVALID EXPORT_EMPTY EXPORT_ENTRY_INVALID EXPORT_EVENTS_INVALID
EXPORT_INVALID EXPORT_OVERSIZED EXPORT_PATH_INVALID EXPORT_RELEASE_UNCONFIRMED EXPORT_SESSION_MISMATCH EXPORT_TRUNCATED
EXPORT_UNEXPECTED_ENTRY GENERATION_CHANGED HISTORY_REQUIRES_PAGING HISTORY_SIZE_INVALID LIVE_END_MISMATCH MODEL_CHANGED
MODEL_EVIDENCE_MISSING MODEL_ID_INVALID MODEL_UNAVAILABLE NETWORK_INVENTORY_INVALID NETWORK_NOT_OFFLINE NETWORK_NOT_RESTORED
NETWORK_UNKNOWN OTHER_WORK_ACTIVE_OR_UNKNOWN PROFILE_MISMATCH PROGRESS_OVERSIZED RADIO_ARGUMENTS_CHANGED RADIO_BACKGROUND_NOT_ACTIVE
RADIO_CALL_ID_INVALID RADIO_CALL_INVALID RADIO_CALL_MISSING RADIO_EXECUTION_FAILED RADIO_FINAL_BEFORE_RESULT RADIO_GUEST_INVALID
RADIO_GUEST_NOT_ISOLATED RADIO_LIVE_DURABLE_MISMATCH RADIO_OFFLINE_DWELL_SHORT RADIO_OFFLINE_REPEATED RADIO_OUTPUT_MISMATCH
RADIO_OUTPUT_OVERSIZED RADIO_RECEIPT_INVALID RADIO_RECEIPT_SESSION_MISMATCH RADIO_RESULT_INVALID RADIO_RESULT_SOURCE_MISMATCH
RADIO_RUN_ID_INVALID RADIO_STAGE_INVALID RADIO_STAGE_OUT_OF_ORDER RADIO_TASK_NOT_RUNNING RADIO_TOOL_FAILED RADIO_TOOL_FINISHED_EARLY
RADIO_TOOL_INVALID REAL_ACCOUNT_NOT_ADMITTED REPLY_INVALID REQUEST_ID_MISMATCH RPC_FAILED RUNTIME_FAILED SERVICE_DISCONNECTED
SERVICE_NOT_FOREGROUND SERVICE_NOT_RUNNING SERVICE_PID_CHANGED SESSION_FAILED SESSION_NOT_NEW SUBMISSION_NOT_ACCEPTED TASK_NOT_SETTLED
TOOL_INVOKED TURN_CHANGED TURN_NOT_COMPLETED USER_CONTENT_MISMATCH USER_COUNT_INVALID`.split(/\s+/u))
const FAILURE_TYPES = new Set(['EvidenceRejected', 'TimeoutException', 'JSONException', 'IOException', 'RuntimeFailure'])
function failure(output, token) {
  demand(validToken(token), 'failure token is invalid')
  const value = finalRow(output)
  if (!value) return undefined
  demand(value.schema === 1 && value.kind === 'production-account-task' && value.exercise === 'radio-linux' && value.token === token &&
    uuid(value.caseId) && value.sessionId === `android-account-acceptance-${value.caseId}`, 'failure belongs to a different task')
  if (value.passed === true) return undefined
  demand(value.passed === false, 'failure disposition is invalid')
  const summary = { schema: 1, kind: value.kind, exercise: value.exercise, token, caseId: value.caseId, sessionId: value.sessionId, passed: false }
  for (const key of FAILURE_FIELDS) {
    if (!Object.hasOwn(value, key) && !Object.hasOwn(value, `${key}Type`)) continue
    demand(FAILURE_CODES.has(value[key]) && FAILURE_TYPES.has(value[`${key}Type`]), 'failure code or type is unsupported')
    summary[key] = value[key]; summary[`${key}Type`] = value[`${key}Type`]
  }
  return summary
}

/** Native facts only: the recovery owner samples the offline interval and independently verifies retirement and panel power. */
export const radioTaskProtocol = Object.freeze({ ready, checkpoint, result, progress, failure })
