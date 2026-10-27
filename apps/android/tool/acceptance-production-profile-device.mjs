import { carrierEvidence, requireNodeCarrierReady } from './acceptance-carrier.mjs'

const CHECK = 'shipped-android-profile-model-ptc-and-offline-linux'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const SHA = /^[0-9a-f]{64}$/u
const demand = (value, message) => { if (!value) throw new Error(message) }

/**
 * Validate native completion independently from physical-panel and final process retirement evidence.
 * @param {string} output - Complete, bounded Android instrumentation output after the owned ADB client closes.
 * @param {boolean} expectWorkflow - Whether this build must expose and execute one real workflow child.
 * @returns {object} Validated profile evidence; the caller must still retire Node and inspect physical panels.
 */
export function parseProductionProfileResult(output, expectWorkflow = false) {
  demand(typeof expectWorkflow === 'boolean', 'Workflow expectation must be boolean')
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const rows = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)\r?$/gm)]
  demand(codes.length === 1 && codes[0][1] === '-1' && rows.length === 1, 'Production profile instrumentation did not succeed exactly once')
  requireNodeCarrierReady(output, 'service')
  const carrier = carrierEvidence(output, 'service')
  for (const state of [carrier.deviceStateBefore, carrier.deviceStateReady, carrier.deviceStateAfter]) {
    demand(state.interactive === false && state.keyguardLocked === true && state.deviceLocked === true,
      'Production profile requires the device to stay locked and noninteractive')
  }
  const result = JSON.parse(rows[0][1])
  demand(result.passed === true && result.complete === true && result.foregroundCarrier === 'service', 'Production profile reported incomplete execution')
  demand(result.reports?.length === 1 && result.reports[0].suite === 'production-profile'
    && result.reports[0].checks?.length === 1, 'Unexpected production profile reports')
  const check = result.reports[0].checks[0]
  demand(check.name === CHECK && check.status === 'passed' && check.profile === 'android', 'Shipped Android profile evidence is missing')
  demand(UUID.test(check.caseId) && check.sessionId === `android-acceptance-production-${check.caseId}`, 'Production Session identity differs from its isolated home')
  demand(check.modelCalls === (expectWorkflow ? 4 : 3) && check.ptcRead === true && check.linuxPython === true
    && check.networkSchemaAbsent === true && check.modelServerClosed === true && check.retirementConfirmed === true,
  'Production tool execution or model listener retirement is incomplete')
  demand(check.expectWorkflow === expectWorkflow && check.workflowCompleted === expectWorkflow
    && check.childCalls === (expectWorkflow ? 1 : 0), 'Production workflow expectation is not satisfied')
  demand(expectWorkflow ? typeof check.childSessionId === 'string' && check.childSessionId.length > 0 && check.childSessionId !== check.sessionId
    : check.childSessionId === null, 'Unexpected workflow child Session')
  demand(Number.isInteger(check.appUid) && check.appUid >= 0 && Number.isInteger(check.guestUid) && check.guestUid >= 0
    && check.appUid !== check.guestUid, 'Linux must run under a different Android UID')
  demand(Number.isSafeInteger(check.elapsedMs) && check.elapsedMs >= 0 && SHA.test(check.toolSchemaSha256), 'Model schema evidence is incomplete')
  const inputs = ['bootstrap.mjs', 'node_modules/@minnnng/dsh-android-runtime/index.mjs']
  demand(check.runtimeInputs && Object.keys(check.runtimeInputs).sort().join('|') === inputs.sort().join('|')
    && inputs.every(name => SHA.test(check.runtimeInputs[name])), 'Shipped bootstrap/runtime hashes are missing')
  demand(Array.isArray(check.sessionFiles) && check.sessionFiles.length > 0 && check.sessionFiles.length <= 8
    && check.sessionFiles.every(file => typeof file.path === 'string' && file.path.startsWith('sessions/')
      // eslint-disable-next-line no-control-regex -- Durable filenames must reject ASCII control characters.
      && !/[\\:\x00-\x1f]/u.test(file.path) && !file.path.split('/').includes('..')
      && file.path.endsWith('.jsonl') && Number.isSafeInteger(file.bytes) && file.bytes > 0
      && file.bytes <= 8 * 1024 * 1024 && SHA.test(file.sha256)), 'Durable Session hash evidence is incomplete')
  demand(new Set(check.sessionFiles.map(file => file.path)).size === check.sessionFiles.length, 'Duplicate Session file evidence')
  return { ...check, ...carrier, nodeProcessRetirement: 'requires-outer-owner', physicalPanelEvidence: 'requires-outer-owner' }
}

/**
 * Run inside the existing OLED protection/process-retirement owner; never starts an Activity or changes settings.
 * @param {object} options - Owned invoke(args, signal), abort signal, and explicit workflow expectation.
 * @returns {Promise<object>} Validated native result and retained instrumentation output, not final device cleanup proof.
 */
export async function runProductionProfileAcceptance({ invoke, signal, expectWorkflow = false }) {
  demand(typeof invoke === 'function' && typeof expectWorkflow === 'boolean', 'An owned ADB invocation and boolean expectation are required')
  signal?.throwIfAborted()
  const output = await invoke(['shell', 'am', 'instrument', '-w', '-r', '-e', 'suite', 'production-profile',
    '-e', 'foregroundCarrier', 'service', '-e', 'expectWorkflow', String(expectWorkflow),
    'com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeRuntimeToolsAcceptanceInstrumentation'], signal)
  signal?.throwIfAborted()
  demand(typeof output === 'string' && output.length <= 2 * 1024 * 1024, 'Invalid or oversized instrumentation output')
  return { result: parseProductionProfileResult(output, expectWorkflow), output }
}
