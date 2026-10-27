import { createHash } from 'node:crypto'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const SHA = /^[0-9a-f]{64}$/u
const demand = (condition, message) => { if (!condition) throw new Error(message) }

/**
 * Validate a completed real-account task in the production service; the outer owner verifies panel power and process retirement.
 * @param {string} output - Bounded instrumentation output after its ADB child closes.
 * @param {object} options - Explicit completion-notice evidence requirement, disabled by default.
 * @returns {object} Validated task evidence, excluding credentials, prompts and response bodies.
 */
export function parseAgentServiceTaskResult(output, { requireCompletionNotice = false } = {}) {
  demand(typeof requireCompletionNotice === 'boolean', 'Completion notice requirement must be a boolean')
  demand(typeof output === 'string' && output.length <= 2 * 1024 * 1024, 'Invalid production task output')
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const rows = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)\r?$/gm)]
  demand(codes.length === 1 && codes[0][1] === '-1' && rows.length === 1,
    'Production account task did not complete exactly once')
  const result = JSON.parse(rows[0][1])
  demand(result.passed === true && result.schema === 1 && result.kind === 'production-account-task' && UUID.test(result.caseId)
    && result.sessionId === `android-account-acceptance-${result.caseId}`,
  'Production task identity is invalid')
  demand(result.provider === 'deepseek-account' && typeof result.model === 'string'
    && /^[A-Za-z0-9._:/-]{1,128}$/u.test(result.model), 'Production task did not use the selected DeepSeek account model')
  demand(typeof result.generation === 'string' && result.generation.length > 0 && result.generation.length <= 128
    && Number.isSafeInteger(result.agentPid) && result.agentPid > 0, 'Production service identity is missing')
  demand(result.submittedCount === 1 && result.userMessageCount === 1 && result.assistantMarkerMatches === 1
    && result.toolCalls === 0 && result.turnEndCount === 1 && result.completionKind === 'completed',
  'Production task lacks one completed durable response or invoked a tool')
  demand(SHA.test(result.markerSha256) && SHA.test(result.historySha256)
    && Number.isSafeInteger(result.eventCount) && result.eventCount > 0,
  'Production task durable evidence is missing')
  demand(Number.isSafeInteger(result.elapsedMs) && result.elapsedMs >= 0 && result.archived === true,
    'Production task timing or dedicated Session cleanup is incomplete')
  for (const state of [result.deviceStateBefore, result.deviceStateAfter]) {
    demand(state?.locked === true && state.interactive === false, 'Production task lost the locked noninteractive condition')
  }
  demand(result.ownTaskRunningObserved === true && result.foregroundBefore === true && result.foregroundDuring === true && result.foregroundAfter === true
    && result.backgroundDuring?.fresh === true && Number.isSafeInteger(result.backgroundDuring.running)
    && result.backgroundDuring.running > 0, 'Production foreground execution was not observed')
  demand(result.cleanup?.taskSettled === true && result.cleanup.archived === true
    && result.cleanup.exportReleased === true && result.cleanup.disconnected === true
    && result.cleanup.cancelRequested === false, 'Production task cleanup is unconfirmed or cancelled')
  if (requireCompletionNotice) {
    const notice = result.completionNotice
    const fields = ['schema', 'observed', 'matchingCount', 'notificationId', 'channelId', 'tagSha256', 'previewSha256',
      'visibilityPrivate', 'autoCancel', 'contentIntentPresent', 'contentIntentCreatorMatches']
    const hash = value => createHash('sha256').update(value, 'utf8').digest('hex')
    demand(result.requireCompletionNotice === true && notice && typeof notice === 'object' && !Array.isArray(notice) &&
      Object.keys(notice).length === fields.length && Object.keys(notice).every(key => fields.includes(key)),
    'Explicit production completion notice evidence is missing')
    demand(notice.schema === 1 && notice.observed === true && notice.matchingCount === 1 && notice.notificationId === 3 &&
      notice.channelId === 'task-completed' && notice.tagSha256 === hash(`pocket-completed:${result.sessionId}`) &&
      notice.previewSha256 === hash(`account-acceptance-${result.caseId}`) && notice.previewSha256 === result.markerSha256 &&
      notice.visibilityPrivate === true && notice.autoCancel === true && notice.contentIntentPresent === true && notice.contentIntentCreatorMatches === true,
    'Production completion notice identity or Android presentation is invalid')
    demand(result.cleanup.completionNoticeCancelled === true && !Object.hasOwn(result, 'notificationCleanupFailureCode'),
      'Production completion notice cleanup is unconfirmed')
  } else {
    demand(result.requireCompletionNotice !== true && !Object.hasOwn(result, 'completionNotice') &&
      !Object.hasOwn(result.cleanup, 'completionNoticeCancelled'), 'Completion notice evidence was not explicitly requested')
  }
  return { ...result, physicalPanelEvidence: 'requires-outer-owner', processRetirement: 'requires-outer-owner',
    radioRecoveryTested: false, originalConversationRenderingTested: false, completionNoticeTested: requireCompletionNotice, notificationTapTested: false }
}

/**
 * Submit one synthetic prompt through the existing account, without changing global model settings or launching an Activity.
 * @param {object} options - Owned invoke(args, signal), cancellation signal and explicit real-account admission.
 * @returns {Promise<object>} Task evidence and bounded instrumentation output; the outer owner must retire the service.
 */
export async function runAgentServiceTaskAcceptance({ invoke, signal, acceptRealAccountRequest, requireCompletionNotice = false }) {
  demand(typeof invoke === 'function' && acceptRealAccountRequest === true, 'Explicit real-account request admission is required')
  demand(typeof requireCompletionNotice === 'boolean', 'Completion notice requirement must be a boolean')
  signal?.throwIfAborted()
  const output = await invoke(['shell', 'am', 'instrument', '-w', '-r', '-e', 'acceptRealAccountRequest', 'true',
    ...(requireCompletionNotice ? ['-e', 'requireCompletionNotice', 'true'] : []),
    'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'], signal)
  signal?.throwIfAborted()
  return { result: parseAgentServiceTaskResult(output, { requireCompletionNotice }), output }
}
