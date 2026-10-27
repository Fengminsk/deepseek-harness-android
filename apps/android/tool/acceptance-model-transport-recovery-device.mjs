import { carrierEvidence, requireNodeCarrierReady } from './acceptance-carrier.mjs'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const SHA = /^[0-9a-f]{64}$/u
const demand = (value, message) => { if (!value) throw new Error(message) }

/** Validate real transport recovery; the caller still owns physical panels and final process retirement. */
export function parseModelTransportRecoveryResult(output) {
  demand(typeof output === 'string' && output.length <= 2 * 1024 * 1024, 'Invalid instrumentation output')
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const rows = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)\r?$/gm)]
  demand(codes.length === 1 && codes[0][1] === '-1' && rows.length === 1, 'Transport instrumentation did not succeed exactly once')
  requireNodeCarrierReady(output, 'service')
  const carrier = carrierEvidence(output, 'service')
  for (const state of [carrier.deviceStateBefore, carrier.deviceStateReady, carrier.deviceStateAfter]) {
    demand(state.interactive === false && state.keyguardLocked === true && state.deviceLocked === true,
      'Transport recovery requires a locked noninteractive device')
  }
  const result = JSON.parse(rows[0][1])
  demand(result.passed === true && result.complete === true && result.foregroundCarrier === 'service', 'Incomplete transport execution')
  demand(result.reports?.length === 1 && result.reports[0].suite === 'model-transport-recovery'
    && result.reports[0].checks?.length === 1, 'Unexpected transport reports')
  const check = result.reports[0].checks[0]
  demand(check.name === 'shipped-android-profile-active-model-transport-recovery' && check.status === 'passed'
    && check.profile === 'android', 'Missing shipped profile recovery')
  demand(UUID.test(check.caseId) && check.sessionId === `android-acceptance-transport-${check.caseId}`, 'Invalid isolated Session identity')
  demand(check.sendCount === 1 && check.modelServerClosed === true, 'Repeated submission or unconfirmed model closure')
  demand(Number.isSafeInteger(check.appUid) && check.appUid >= 0 && Number.isSafeInteger(check.elapsedMs) && check.elapsedMs >= 0,
    'Invalid runtime evidence')
  const evidence = check.evidence
  demand(evidence?.turn === 1 && evidence.step === 1 && evidence.modelCalls === 2 && evidence.retryCount === 1
    && evidence.failureCode === 'TRANSPORT', 'Wrong recovery type or number of attempts')
  for (const field of ['partialConsumed', 'requestChangesAccountedFor', 'reconnected', 'durableRetryMatched']) {
    demand(evidence[field] === true, `Missing ${field}`)
  }
  demand(typeof evidence.retryId === 'string' && evidence.retryId.length > 0 && evidence.retryId.length <= 256
    && SHA.test(evidence.requestSha256) && SHA.test(evidence.retryRequestSha256), 'Missing retry identity or request digest')
  demand(typeof evidence.requestBodyUnchanged === 'boolean'
    && evidence.requestBodyUnchanged === (evidence.requestSha256 === evidence.retryRequestSha256)
    && Number.isSafeInteger(evidence.runtimeContextUpdates) && evidence.runtimeContextUpdates >= 0
    && evidence.runtimeContextUpdates <= 256, 'Invalid request continuation evidence')
  demand(typeof evidence.sessionLogContinuationChecked === 'boolean' && Array.isArray(evidence.sessionLogSnapshots)
    && evidence.sessionLogSnapshots.length === (evidence.sessionLogContinuationChecked ? 2 : 0), 'Invalid incremental-log observation')
  for (const [i, log] of evidence.sessionLogSnapshots.entries()) {
    demand(Number.isSafeInteger(log.afterSeq) && log.afterSeq >= -1 && Number.isSafeInteger(log.throughSeq)
      && log.throughSeq > log.afterSeq && log.eventCount === log.throughSeq - log.afterSeq && log.eventCount <= 256
      && SHA.test(log.headerSha256) && SHA.test(log.eventsSha256), 'Invalid incremental-log snapshot')
    if (i === 1) demand(log.afterSeq >= evidence.sessionLogSnapshots[0].throughSeq
      && log.headerSha256 === evidence.sessionLogSnapshots[0].headerSha256, 'Invalid incremental-log continuation')
  }
  const sequence = ['failedAttemptSeq', 'retrySeq', 'retryStartedSeq', 'finalMessageSeq', 'turnEndSeq'].map(field => evidence[field])
  demand(sequence.every((value, i) => Number.isSafeInteger(value) && value >= 0 && (i === 0 || sequence[i - 1] < value)),
    'Retry event order is invalid')
  const inputs = ['bootstrap.mjs', 'node_modules/@minnnng/dsh-android-runtime/index.mjs']
  demand(check.runtimeInputs && Object.keys(check.runtimeInputs).sort().join('|') === inputs.sort().join('|')
    && inputs.every(name => SHA.test(check.runtimeInputs[name])), 'Shipped runtime hashes are missing')
  demand(Array.isArray(check.sessionFiles) && check.sessionFiles.length === 1 && check.sessionFiles.every(file =>
    // eslint-disable-next-line no-control-regex -- Durable filenames must reject ASCII control characters.
    typeof file.path === 'string' && file.path.startsWith('sessions/') && !/[\\:\x00-\x1f]/u.test(file.path)
    && !file.path.split('/').includes('..') && file.path.endsWith('.jsonl')
    && file.path.split('/').at(-2) === check.sessionId && Number.isSafeInteger(file.bytes)
    && file.bytes > 0 && file.bytes <= 1024 * 1024 && SHA.test(file.sha256)), 'Dedicated durable Session evidence is incomplete')
  return { ...check, ...carrier, evidenceScope: 'active-model-transport-recovery',
    productionAgentServiceRadioRecovery: 'not-tested', nodeProcessRetirement: 'requires-outer-owner',
    physicalPanelEvidence: 'requires-outer-owner' }
}

/** Invoke only the locked service suite through an externally owned, awaited ADB process. */
export async function runModelTransportRecoveryAcceptance({ invoke, signal }) {
  demand(typeof invoke === 'function', 'An owned ADB invocation is required')
  signal?.throwIfAborted()
  const output = await invoke(['shell', 'am', 'instrument', '-w', '-r', '-e', 'suite', 'model-transport-recovery',
    '-e', 'foregroundCarrier', 'service',
    'com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeRuntimeToolsAcceptanceInstrumentation'], signal)
  signal?.throwIfAborted()
  return { result: parseModelTransportRecoveryResult(output), output }
}
