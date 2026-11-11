import { createHash } from 'node:crypto'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const SHA = /^[0-9a-f]{64}$/u
const demand = (condition, message) => { if (!condition) throw new Error(message) }
const exercises = new Set(['echo', 'ptc', 'workflow', 'workflow-linux', 'radio-linux'])
const exactKeys = (value, expected) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === expected.length && Object.keys(value).every(key => expected.includes(key))

function instrumentationResult(output) {
  demand(typeof output === 'string' && output.length <= 2 * 1024 * 1024, 'Invalid production task output')
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const rows = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)\r?$/gm)]
  demand(codes.length === 1 && codes[0][1] === '-1' && rows.length === 1,
    'Production account task did not complete exactly once')
  return JSON.parse(rows[0][1])
}

function programmaticEvidence(result, exercise) {
  const proof = result.programmatic
  demand(result.requestId === `account-request-${result.caseId}` &&
    result.markerSha256 === createHash('sha256').update(`account-acceptance-${result.caseId}`).digest('hex') &&
    !Object.keys(result).some(key => /failure(code|type)$/iu.test(key)), 'Programmatic task request or marker is invalid')
  const common = ['exercise', 'tool', 'callId', 'argumentsSha256', 'resultSha256']
  const fields = exercise === 'ptc' ? ['reviewedCallbacks', 'callbackName', 'callbackStartSeq', 'callbackEndSeq', 'children']
    : ['runId', 'childSessionId', 'memberCount', 'runEndCount', 'runStartSeq', 'runEndSeq', 'inspection', 'child']
  demand(exactKeys(proof, [...common, ...fields]) && proof.exercise === exercise &&
    proof.tool === (exercise === 'ptc' ? 'android_ptc' : 'workflow') && proof.callId === result.callId &&
    typeof proof.callId === 'string' && proof.callId.length > 0 && proof.callId.length <= 256 &&
    SHA.test(proof.argumentsSha256) && proof.argumentsSha256 === result.argumentsSha256 && SHA.test(proof.resultSha256),
  'Programmatic task identity or exact result evidence is missing')
  for (const field of ['toolStartSeq', 'toolEndSeq', 'endSeq']) demand(Number.isSafeInteger(result[field]) && result[field] >= 0,
    'Programmatic task sequence is invalid')
  demand(result.toolStartSeq < result.toolEndSeq && result.toolEndSeq < result.endSeq, 'Programmatic task result order is invalid')
  if (exercise === 'ptc') {
    demand(proof.reviewedCallbacks === 1 && proof.callbackName === 'list_agents' && proof.children === 0 &&
      Number.isSafeInteger(proof.callbackStartSeq) && Number.isSafeInteger(proof.callbackEndSeq) &&
      result.toolStartSeq < proof.callbackStartSeq && proof.callbackStartSeq < proof.callbackEndSeq && proof.callbackEndSeq < result.toolEndSeq,
    'PTC task did not complete its single reviewed callback')
    demand(!Object.hasOwn(result.cleanup, 'childArchived'), 'PTC task cannot claim workflow child cleanup')
  } else {
    const child = proof.child, observed = proof.inspection
    demand(UUID.test(proof.runId) && UUID.test(proof.childSessionId) && proof.memberCount === 1 && proof.runEndCount === 1 &&
      Number.isSafeInteger(proof.runStartSeq) && Number.isSafeInteger(proof.runEndSeq) &&
      result.toolStartSeq < proof.runStartSeq && proof.runStartSeq < proof.runEndSeq && proof.runEndSeq < result.toolEndSeq,
    'Workflow task run or member evidence is invalid')
    demand(exactKeys(observed, ['runId', 'state', 'requiresReview']) && observed.runId === proof.runId &&
      observed.state === 'completed' && observed.requiresReview === false, 'Workflow task inspection remains unconfirmed')
    const linux = exercise === 'workflow-linux'
    demand(exactKeys(child, ['sessionId', 'eventCount', 'toolCalls', 'assistantMarkerMatches', 'turnEndCount', 'completionKind', 'historySha256',
      ...(linux ? ['linuxReceipt'] : [])]) &&
      child.sessionId === proof.childSessionId && child.sessionId !== result.sessionId &&
      Number.isSafeInteger(child.eventCount) && child.eventCount > 0 && child.eventCount <= 511 &&
      child.toolCalls === (linux ? 1 : 0) && child.assistantMarkerMatches === 1 && child.turnEndCount === 1 && child.completionKind === 'completed' &&
      SHA.test(child.historySha256) && result.cleanup.childArchived === true,
    'Workflow child durable completion or dedicated cleanup is missing')
    if (linux) childLinuxEvidence(child, result)
  }
}

function childLinuxEvidence(child, result) {
  const receipt = child.linuxReceipt
  const fields = ['id', 'sessionId', 'callId', 'toolStartSeq', 'toolEndSeq', 'commandSha256', 'status', 'exitCode', 'retirementConfirmed',
    'guestUid', 'appUid', 'cancelled', 'timedOut', 'truncated', 'cancelRequested', 'diskCommitted', 'outputSha256',
    'fileSha256', 'fileBytes', 'archiveEntries', 'cleaned']
  const payload = `account-child-${result.caseId}\n7,11,13\n`
  demand(exactKeys(receipt, fields) && UUID.test(receipt.id) && receipt.sessionId === child.sessionId &&
    typeof receipt.callId === 'string' && receipt.callId.length > 0 && receipt.callId.length <= 256 &&
    Number.isSafeInteger(receipt.toolStartSeq) && receipt.toolStartSeq >= 0 && Number.isSafeInteger(receipt.toolEndSeq) &&
    receipt.toolEndSeq > receipt.toolStartSeq && SHA.test(receipt.commandSha256), 'Child Linux execution identity is invalid')
  demand(receipt.status === 'completed' && receipt.exitCode === 0 && receipt.retirementConfirmed === true &&
    ['cancelled', 'timedOut', 'truncated', 'cancelRequested'].every(key => receipt[key] === false) && typeof receipt.diskCommitted === 'boolean' &&
    Number.isSafeInteger(result.appUid) && result.appUid > 0 && receipt.appUid === result.appUid &&
    Number.isSafeInteger(receipt.guestUid) && receipt.guestUid > 0 && receipt.guestUid !== result.appUid,
  'Child Linux execution or independent UID is unconfirmed')
  demand(SHA.test(receipt.outputSha256) && receipt.fileSha256 === createHash('sha256').update(payload).digest('hex') &&
    receipt.fileBytes === Buffer.byteLength(payload) && receipt.archiveEntries === 1 && receipt.cleaned === true,
  'Child Linux file task or its temporary artifact cleanup is unconfirmed')
}

/**
 * Validate a completed real-account task in the production service; the outer owner verifies panel power and process retirement.
 * @param {string} output - Bounded instrumentation output after its ADB child closes.
 * @param {object} options - Explicit echo/PTC/workflow/workflow-linux selection and optional echo completion-notice evidence.
 * @returns {object} Validated task evidence, excluding credentials, prompts and response bodies.
 */
export function parseAgentServiceTaskResult(output, { requireCompletionNotice = false, exercise = 'echo' } = {}) {
  demand(exercises.has(exercise), 'Unsupported account task exercise')
  demand(exercise === 'echo' || requireCompletionNotice === false, 'Programmatic tasks do not request completion notice acceptance')
  demand(typeof requireCompletionNotice === 'boolean', 'Completion notice requirement must be a boolean')
  const result = instrumentationResult(output)
  demand(result.passed === true && result.schema === 1 && result.kind === 'production-account-task' && UUID.test(result.caseId)
    && result.sessionId === `android-account-acceptance-${result.caseId}`,
  'Production task identity is invalid')
  demand(exercise === 'echo' ? result.exercise === undefined || result.exercise === 'echo' : result.exercise === exercise,
    'Production task exercise differs from explicit admission')
  demand(result.provider === 'deepseek-account' && typeof result.model === 'string'
    && /^[A-Za-z0-9._:/-]{1,128}$/u.test(result.model), 'Production task did not use the selected DeepSeek account model')
  demand(typeof result.generation === 'string' && result.generation.length > 0 && result.generation.length <= 128
    && Number.isSafeInteger(result.agentPid) && result.agentPid > 0, 'Production service identity is missing')
  demand(result.submittedCount === 1 && result.userMessageCount === 1 && result.assistantMarkerMatches === 1
    && result.toolCalls === (exercise === 'echo' ? 0 : 1) && result.turnEndCount === 1 && result.completionKind === 'completed',
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
  if (exercise !== 'echo') programmaticEvidence(result, exercise)
  else demand(!Object.hasOwn(result, 'programmatic'), 'Programmatic acceptance was not explicitly requested')
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
    radioRecoveryTested: false, originalConversationRenderingTested: false, completionNoticeTested: requireCompletionNotice, notificationTapTested: false,
    programmaticExercise: exercise === 'echo' ? null : exercise }
}

/**
 * Validate cleanup of one explicitly identified, previously completed workflow child; this is not a new account-task acceptance.
 * @param {string} output - Bounded output after the cleanup instrumentation closes.
 * @param {object} options - Exact previous caseId whose dedicated parent and child were revalidated.
 * @returns {object} Cleanup evidence with separate outer screen and process-retirement obligations.
 */
export function parseAgentServiceTaskCleanupResult(output, { caseId } = {}) {
  demand(UUID.test(caseId), 'An exact previous cleanup case ID is required')
  const result = instrumentationResult(output)
  demand(result.passed === true && result.schema === 1 && result.kind === 'production-account-task-cleanup' &&
    result.exercise === 'workflow-cleanup' && result.caseId === caseId && result.sessionId === `android-account-acceptance-${caseId}`,
  'Cleanup identity differs from the explicitly requested previous case')
  demand(result.submittedCount === 0 && result.archived === false && !Object.hasOwn(result, 'ownTaskRunningObserved') &&
    !Object.hasOwn(result, 'backgroundDuring') && !Object.hasOwn(result, 'requireCompletionNotice'), 'Cleanup cannot submit or claim a new task')
  demand(result.provider === 'deepseek-account' && typeof result.model === 'string' && /^[A-Za-z0-9._:/-]{1,128}$/u.test(result.model) &&
    result.userMessageCount === 1 && result.assistantMarkerMatches === 1 && result.toolCalls === 1 && result.turnEndCount === 1 &&
    result.completionKind === 'completed' && SHA.test(result.historySha256) && Number.isSafeInteger(result.eventCount) && result.eventCount > 0,
  'Cleanup lacks the original completed durable task evidence')
  demand(typeof result.generation === 'string' && result.generation.length > 0 && result.generation.length <= 128 &&
    Number.isSafeInteger(result.agentPid) && result.agentPid > 0 && Number.isSafeInteger(result.elapsedMs) && result.elapsedMs >= 0,
  'Cleanup service identity or timing is invalid')
  for (const when of ['Before', 'After']) {
    const state = result[`deviceState${when}`], background = result[`background${when}`]
    demand(state?.locked === true && state.interactive === false && result[`foreground${when}`] === true && background?.fresh === true &&
      ['running', 'queued', 'waiting', 'backgroundJobs', 'packageOperations'].every(key => background[key] === 0), 'Cleanup was not idle and locked')
  }
  demand(result.cleanup?.taskSettled === true && result.cleanup.archived === false && result.cleanup.cancelRequested === false &&
    result.cleanup.exportReleased === true && result.cleanup.disconnected === true, 'Cleanup touched a parent task or left resources unconfirmed')
  programmaticEvidence(result, 'workflow')
  return { ...result, physicalPanelEvidence: 'requires-outer-owner', processRetirement: 'requires-outer-owner', newTaskSubmitted: false }
}

/**
 * Clean only an explicitly identified previous workflow child's archive state, without admitting a model request.
 * @param {object} options - Owned invocation, cancellation and exact prior caseId.
 * @returns {Promise<object>} Validated cleanup and raw bounded output.
 */
export async function runAgentServiceTaskCleanup({ invoke, signal, caseId, acceptRealAccountRequest = false }) {
  demand(typeof invoke === 'function' && UUID.test(caseId) && acceptRealAccountRequest === false, 'Explicit cleanup identity without real-account admission is required')
  signal?.throwIfAborted()
  const output = await invoke(['shell', 'am', 'instrument', '-w', '-r', '-e', 'acceptRealAccountRequest', 'false',
    '-e', 'exercise', 'workflow-cleanup', '-e', 'cleanupCaseId', caseId,
    'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'], signal)
  signal?.throwIfAborted()
  return { result: parseAgentServiceTaskCleanupResult(output, { caseId }), output }
}

/**
 * Validate one read-only diagnostic of a named dedicated Session; this never certifies its original task or permits cleanup.
 * @param {string} output - Bounded output after the diagnostic carrier closes.
 * @param {object} options - Exact previous caseId and original workflow exercise.
 * @returns {object} Bounded field fingerprints and independently checked lineage observations.
 */
export function parseAgentServiceTaskDiagnosticResult(output, { caseId, originalExercise } = {}) {
  demand(UUID.test(caseId) && ['workflow', 'workflow-linux'].includes(originalExercise), 'Explicit diagnostic identity is required')
  const result = instrumentationResult(output)
  demand(result.passed === true && result.schema === 1 && result.kind === 'production-account-task-diagnostic' &&
    result.exercise === 'workflow-diagnose' && result.caseId === caseId && result.sessionId === `android-account-acceptance-${caseId}` &&
    result.requestId === `account-request-${caseId}`, 'Diagnostic identity differs from the named previous case')
  demand(result.submittedCount === 0 && result.archived === false && !Object.hasOwn(result, 'programmatic') &&
    !Object.hasOwn(result, 'backgroundDuring') && !Object.hasOwn(result, 'ownTaskRunningObserved') && !Object.hasOwn(result, 'requireCompletionNotice'),
  'Read-only diagnostic cannot submit, archive, or certify a task')
  demand(typeof result.generation === 'string' && result.generation.length > 0 && result.generation.length <= 128 &&
    Number.isSafeInteger(result.agentPid) && result.agentPid > 0 && Number.isSafeInteger(result.elapsedMs) && result.elapsedMs >= 0,
  'Diagnostic service identity is invalid')
  for (const when of ['Before', 'After']) {
    const state = result[`deviceState${when}`], background = result[`background${when}`]
    demand(state?.locked === true && state.interactive === false && result[`foreground${when}`] === true && background?.fresh === true &&
      ['running', 'queued', 'waiting', 'backgroundJobs', 'packageOperations'].every(key => background[key] === 0), 'Diagnostic must remain idle and locked')
  }
  demand(exactKeys(result.cleanup, ['cancelRequested', 'taskSettled', 'archived', 'exportReleased', 'disconnected']) &&
    result.cleanup.cancelRequested === false && result.cleanup.taskSettled === true && result.cleanup.archived === false &&
    result.cleanup.exportReleased === true && result.cleanup.disconnected === true, 'Read-only diagnostic left resources or mutated Session state')
  const proof = result.diagnostic
  const boundedCount = (value, max) => Number.isSafeInteger(value) && value >= 0 && value <= max
  demand(exactKeys(proof, ['schema', 'originalExercise', 'parentEventCount', 'parentHistorySha256', 'toolStartSeq', 'arguments', 'cleanupAuthorized', 'lineage']) &&
    proof.schema === 1 && proof.originalExercise === originalExercise && boundedCount(proof.parentEventCount, 511) && proof.parentEventCount > 0 &&
    SHA.test(proof.parentHistorySha256) && boundedCount(proof.toolStartSeq, Number.MAX_SAFE_INTEGER) && proof.cleanupAuthorized === false,
  'Diagnostic parent evidence is invalid')
  const args = proof.arguments
  demand(exactKeys(args, ['schema', 'exercise', 'parsed', 'matches', 'rawBytes', 'rawSha256', 'expectedSha256', 'actualSha256',
    'unexpectedFields', 'unexpectedMetaFields', 'fields', 'script']) && args.schema === 2 && args.exercise === originalExercise &&
    typeof args.parsed === 'boolean' && typeof args.matches === 'boolean' && boundedCount(args.rawBytes, 262144) && SHA.test(args.rawSha256) &&
    SHA.test(args.expectedSha256) && (args.parsed ? SHA.test(args.actualSha256) : args.actualSha256 === null) &&
    boundedCount(args.unexpectedFields, 262144) && boundedCount(args.unexpectedMetaFields, 262144), 'Argument diagnostic fields are invalid')
  const fieldNames = ['script', 'meta', 'meta.name', 'meta.description']
  demand(Array.isArray(args.fields) && args.fields.length === fieldNames.length, 'Argument diagnostic field count differs')
  for (const [index, field] of args.fields.entries()) {
    demand(exactKeys(field, ['field', 'expected', 'actual', 'matches']) && field.field === fieldNames[index] && typeof field.matches === 'boolean',
      'Argument diagnostic contains an unknown field')
    for (const value of [field.expected, field.actual]) {
      demand(exactKeys(value, ['present', 'type', 'bytes', 'sha256']) && typeof value.present === 'boolean' &&
        ['missing', 'null', 'string', 'object', 'array', 'boolean', 'number', 'unknown'].includes(value.type) && boundedCount(value.bytes, 1048576) &&
        (value.present ? value.type !== 'missing' && SHA.test(value.sha256) : value.type === 'missing' && value.bytes === 0 && value.sha256 === null),
      'Argument fingerprint is invalid or contains raw content')
    }
    demand(field.matches === (field.expected.present === field.actual.present && field.expected.type === field.actual.type &&
      field.expected.bytes === field.actual.bytes && field.expected.sha256 === field.actual.sha256), 'Argument field match contradicts its fingerprint')
  }
  const script = args.script
  demand(exactKeys(script, ['wrapperMatches', 'promptBytes', 'promptSha256', 'expectedPromptBytes', 'expectedPromptSha256',
    'proseMatches', 'argumentsMatches', 'argumentsSha256', 'expectedArgumentsSha256', 'matches']) &&
    ['wrapperMatches', 'proseMatches', 'argumentsMatches', 'matches'].every(key => typeof script[key] === 'boolean') &&
    boundedCount(script.promptBytes, 262144) && boundedCount(script.expectedPromptBytes, 262144) && script.expectedPromptBytes > 0 &&
    SHA.test(script.expectedPromptSha256) && (script.promptSha256 === null || SHA.test(script.promptSha256)) &&
    (script.promptSha256 !== null || script.promptBytes === 0) &&
    (script.argumentsSha256 === null || SHA.test(script.argumentsSha256)) &&
    (script.expectedArgumentsSha256 === null || SHA.test(script.expectedArgumentsSha256)) &&
    script.wrapperMatches === (script.promptSha256 !== null) && (!script.proseMatches || script.wrapperMatches) &&
    script.matches === (script.wrapperMatches && script.proseMatches && script.argumentsMatches), 'Script evidence is invalid')
  const linux = originalExercise === 'workflow-linux'
  demand(linux ? SHA.test(script.expectedArgumentsSha256) : script.expectedArgumentsSha256 === null,
    'Script argument evidence contradicts the exercise')
  if (linux) demand(script.argumentsMatches === (script.argumentsSha256 !== null && script.argumentsSha256 === script.expectedArgumentsSha256),
    'Script argument match contradicts its digests')
  else demand(script.argumentsSha256 === null && script.argumentsMatches === script.matches, 'Plain workflow prompt evidence is invalid')
  const metaMatches = args.fields.slice(1).every(field => field.matches)
  demand(args.matches === (args.parsed && args.unexpectedFields === 0 && args.unexpectedMetaFields === 0 && metaMatches && script.matches),
    'Argument match contradicts semantic script evidence')
  const lineage = proof.lineage
  const verified = lineage?.state === 'verified'
  demand(exactKeys(lineage, ['state', 'runCount', 'memberCount', ...(verified ? ['runId', 'childSessionId', 'childEventCount', 'childHistorySha256', 'childTerminal'] : [])]) &&
    ['verified', 'unconfirmed', 'no_member_record', 'child_read_unconfirmed'].includes(lineage.state) &&
    boundedCount(lineage.runCount, 511) && boundedCount(lineage.memberCount, 511), 'Lineage diagnostic is invalid')
  if (verified) demand(lineage.runCount === 1 && lineage.memberCount === 1 && UUID.test(lineage.runId) && UUID.test(lineage.childSessionId) &&
    boundedCount(lineage.childEventCount, 511) && lineage.childEventCount > 0 && SHA.test(lineage.childHistorySha256) &&
    ['completed', 'cancelled', 'error', 'aborted', 'unconfirmed'].includes(lineage.childTerminal), 'Verified lineage lacks the exported child identity')
  if (lineage.state === 'no_member_record') demand(lineage.memberCount === 0, 'Missing-member claim contradicts the recorded count')
  return { ...result, taskAcceptancePassed: false, cleanupAuthorized: false, newTaskSubmitted: false,
    physicalPanelEvidence: 'requires-outer-owner', processRetirement: 'requires-outer-owner' }
}

/**
 * Read one named previous workflow case without account admission or cleanup.
 * @param {object} options - Owned invocation, cancellation, caseId and originalExercise.
 * @returns {Promise<object>} Diagnostic observations and bounded carrier output.
 */
export async function runAgentServiceTaskDiagnostic({ invoke, signal, caseId, originalExercise, acceptRealAccountRequest = false }) {
  demand(typeof invoke === 'function' && UUID.test(caseId) && ['workflow', 'workflow-linux'].includes(originalExercise) &&
    acceptRealAccountRequest === false, 'Explicit diagnostic identity without account admission is required')
  signal?.throwIfAborted()
  const output = await invoke(['shell', 'am', 'instrument', '-w', '-r', '-e', 'acceptRealAccountRequest', 'false',
    '-e', 'exercise', 'workflow-diagnose', '-e', 'diagnosticCaseId', caseId, '-e', 'originalExercise', originalExercise,
    'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'], signal)
  signal?.throwIfAborted()
  return { result: parseAgentServiceTaskDiagnosticResult(output, { caseId, originalExercise }), output }
}

/**
 * Submit one synthetic prompt through the existing account, without changing global model settings or launching an Activity.
 * @param {object} options - Owned invoke(args, signal), cancellation, explicit real-account admission and exercise.
 * @returns {Promise<object>} Task evidence and bounded instrumentation output; the outer owner must retire the service.
 */
export async function runAgentServiceTaskAcceptance({ invoke, signal, acceptRealAccountRequest, requireCompletionNotice = false, exercise = 'echo' }) {
  demand(typeof invoke === 'function' && acceptRealAccountRequest === true, 'Explicit real-account request admission is required')
  demand(typeof requireCompletionNotice === 'boolean', 'Completion notice requirement must be a boolean')
  demand(exercises.has(exercise), 'Unsupported account task exercise')
  demand(exercise === 'echo' || requireCompletionNotice === false, 'Programmatic tasks do not request completion notice acceptance')
  signal?.throwIfAborted()
  const output = await invoke(['shell', 'am', 'instrument', '-w', '-r', '-e', 'acceptRealAccountRequest', 'true',
    ...(requireCompletionNotice ? ['-e', 'requireCompletionNotice', 'true'] : []),
    ...(exercise === 'echo' ? [] : ['-e', 'exercise', exercise]),
    'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'], signal)
  signal?.throwIfAborted()
  return { result: parseAgentServiceTaskResult(output, { requireCompletionNotice, exercise }), output }
}
