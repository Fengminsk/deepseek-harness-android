/**
 * Internal Android admission vocabulary for a future model-facing PTC/workflow
 * provider. This module checks and copies data; only the native approval store,
 * policy owner and brokers can authorize effects. No caller of this module may
 * infer that the original Node PTC or asynchronous workflow is available.
 */

const encoder = new TextEncoder()
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}(?![\s\S])/
const OWNER = /^[A-Za-z0-9._:-]{1,128}$/
const MAX_PROGRAM_BYTES = 64 * 1024
const MAX_INPUT_BYTES = 64 * 1024
const MAX_LOG_BYTES = 16 * 1024
const MAX_DEADLINE_MS = 5000
const MAX_PTC_DEADLINE_MS = 120_000
const MAX_WORKFLOW_DEADLINE_MS = 120_000
const MAX_FILE_CALLS = 128
const MAX_NETWORK_CALLS = 64
const MAX_LEASE_MS = 300_000
const PROTECTED_WORKSPACE_SEGMENTS = new Set(['.git', '.agents', '.codex', '.aws'])

export class IsolatedExecutionContractError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'IsolatedExecutionContractError'
    Object.defineProperty(this, 'code', {
      value: code, writable: true, configurable: true, enumerable: true,
    })
  }
}

function invalid(name) {
  throw new IsolatedExecutionContractError('ANDROID_EXECUTION_INVALID', `Invalid ${name}`)
}

function record(value, name, allowed) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) invalid(name)
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string' || !allowed.includes(key)) invalid(`${name}.${String(key)}`)
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) invalid(`${name}.${key}`)
  }
  return value
}

function text(value, name, maxBytes, allowEmpty = false) {
  if (typeof value !== 'string' || (!allowEmpty && value.length === 0)
    || encoder.encode(value).length > maxBytes || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)) invalid(name)
  return value
}

function integer(value, name, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) invalid(name)
  return value
}

function uuid(value, name) {
  if (typeof value !== 'string' || !UUID.test(value)) invalid(name)
  return value
}

function sessionIdentity(value, name) {
  // App conversations and subagent Sessions use stable android-/session- IDs.
  // Preserve that identity across policy, dispatch and durable receipts.
  if (typeof value !== 'string' || !SESSION_ID.test(value)) invalid(name)
  return value
}

function jsonCopy(value, name, remaining = { count: 8192 }, depth = 0) {
  if (--remaining.count < 0 || depth > 24) invalid(name)
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number' && Number.isFinite(value) && !Object.is(value, -0)) return value
  if (Array.isArray(value)) {
    if (Object.keys(value).length !== value.length) invalid(name)
    return Array.from({ length: value.length }, (_, index) => {
      const descriptor = Object.getOwnPropertyDescriptor(value, String(index))
      if (!descriptor || !descriptor.enumerable || !Object.hasOwn(descriptor, 'value')) invalid(name)
      return jsonCopy(descriptor.value, name, remaining, depth + 1)
    })
  }
  if (value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    const copy = Object.create(null)
    for (const key of Reflect.ownKeys(value)) {
      if (typeof key !== 'string') invalid(name)
      const descriptor = Object.getOwnPropertyDescriptor(value, key)
      if (!descriptor || !descriptor.enumerable || !Object.hasOwn(descriptor, 'value')) invalid(name)
      copy[key] = jsonCopy(descriptor.value, name, remaining, depth + 1)
    }
    return copy
  }
  invalid(name)
}

function frozen(value) {
  if (value && typeof value === 'object') {
    for (const member of Object.values(value)) frozen(member)
    Object.freeze(value)
  }
  return value
}

/** Copy one bounded lossless JSON value before it crosses a workflow host boundary. */
export function snapshotIsolatedJson(value, name = 'JSON value', maxBytes = MAX_INPUT_BYTES) {
  const copy = jsonCopy(value, name)
  if (encoder.encode(JSON.stringify(copy)).length > maxBytes) invalid(`${name} size`)
  return frozen(copy)
}

function path(value) {
  text(value, 'relative grant path', 512)
  if (value.startsWith('/') || value.includes('\\') || value.includes(':')) invalid('relative grant path')
  // A trailing slash selects descendants of one directory, as in the native
  // App policy. Guest file handles still name exact files.
  const target = value.endsWith('/') ? value.slice(0, -1) : value
  const segments = target.split('/')
  if (segments.length > 16 || segments.some(segment => !segment || segment === '.' || segment === '..'
    || encoder.encode(segment).length > 180 || /[\u0000-\u001f\u007f]/u.test(segment))) invalid('relative grant path')
  return value
}

function covered(roots, target) {
  return roots.some(root => root.endsWith('/') ? target.startsWith(root) : target === root)
}

function protectedWritePath(value) {
  return value.split('/').some(segment => PROTECTED_WORKSPACE_SEGMENTS.has(segment))
}

function host(value) {
  text(value, 'exact HTTPS host', 253)
  if (value.length < 4 || value !== value.toLowerCase() || value.startsWith('.') || value.endsWith('.')
    || value.includes('..') || /[/:*@]/u.test(value) || /^[0-9.]+$/u.test(value)
    || /(?:^|\.)(?:localhost|local|internal|localdomain|lan|test|invalid|example)$/u.test(value)
    || value.endsWith('.home.arpa')) invalid('exact HTTPS host')
  const labels = value.split('.')
  if (labels.length < 2 || /^[0-9]+$/u.test(labels.at(-1)) || labels.some(label => label.length > 63
    || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u.test(label))) invalid('exact HTTPS host')
  return value
}

function uniqueList(value, name, maximum, validate) {
  if (!Array.isArray(value) || value.length > maximum) invalid(name)
  const copy = value.map(validate)
  if (new Set(copy).size !== copy.length) invalid(name)
  return copy.sort()
}

/** Normalized App-selected scope. `workspaceId` is opaque, never a pathname. */
export function normalizeExecutionScope(value, parent) {
  const scope = record(value, 'execution scope', [
    'ownerId', 'sessionId', 'version', 'workspaceId', 'readablePaths', 'writablePaths',
    'exactHosts', 'fileCallLimit', 'networkCallLimit', 'leaseMillis',
  ])
  if (typeof scope.ownerId !== 'string' || !OWNER.test(scope.ownerId)) invalid('scope owner')
  const sessionId = sessionIdentity(scope.sessionId, 'scope session')
  const version = integer(scope.version, 'scope version', 1, Number.MAX_SAFE_INTEGER - 1)
  const workspaceId = scope.workspaceId === null ? null : uuid(scope.workspaceId, 'workspace identity')
  const readablePaths = uniqueList(scope.readablePaths, 'readable paths', 32, path)
  const writablePaths = uniqueList(scope.writablePaths, 'writable paths', 32, path)
  const exactHosts = uniqueList(scope.exactHosts, 'network hosts', 32, host)
  const fileCallLimit = integer(scope.fileCallLimit, 'file-call budget', 0, MAX_FILE_CALLS)
  const networkCallLimit = integer(scope.networkCallLimit, 'network-call budget', 0, MAX_NETWORK_CALLS)
  const leaseMillis = integer(scope.leaseMillis, 'lease duration', 1, MAX_LEASE_MS)
  if ((!readablePaths.length && fileCallLimit !== 0) || (readablePaths.length && fileCallLimit === 0)
    || (!exactHosts.length && networkCallLimit !== 0) || (exactHosts.length && networkCallLimit === 0)
    || (readablePaths.length && workspaceId === null)
    || (readablePaths.length && leaseMillis < 1000)
    || writablePaths.some(filename => !covered(readablePaths, filename)
      || protectedWritePath(filename))) invalid('scope grants')
  const normalized = { ownerId: scope.ownerId, sessionId, version, workspaceId,
    readablePaths, writablePaths, exactHosts, fileCallLimit, networkCallLimit, leaseMillis }
  if (parent !== undefined) {
    const base = normalizeExecutionScope(parent)
    if (normalized.ownerId !== base.ownerId || normalized.sessionId !== base.sessionId
      || normalized.version !== base.version || normalized.workspaceId !== base.workspaceId
      || normalized.leaseMillis > base.leaseMillis
      || normalized.fileCallLimit > base.fileCallLimit
      || normalized.networkCallLimit > base.networkCallLimit
      || normalized.readablePaths.some(filename => !covered(base.readablePaths, filename))
      || normalized.writablePaths.some(filename => !covered(base.writablePaths, filename))
      || normalized.exactHosts.some(name => !base.exactHosts.includes(name))) {
      throw new IsolatedExecutionContractError('ANDROID_POLICY_WIDENED', 'A child execution cannot widen its parent grant')
    }
  }
  return frozen(normalized)
}

function workflowMeta(value) {
  const meta = record(value, 'workflow meta', ['name', 'description', 'whenToUse', 'phases'])
  const normalized = {
    name: text(meta.name, 'workflow name', 128),
    description: text(meta.description, 'workflow description', 1024),
  }
  if (meta.whenToUse !== undefined) normalized.whenToUse = text(meta.whenToUse, 'workflow usage', 1024, true)
  if (meta.phases !== undefined) {
    if (!Array.isArray(meta.phases) || meta.phases.length > 32) invalid('workflow phases')
    normalized.phases = meta.phases.map(value => {
      const phase = record(value, 'workflow phase', ['title', 'detail', 'provider', 'model'])
      return { title: text(phase.title, 'phase title', 128),
        ...(phase.detail === undefined ? {} : { detail: text(phase.detail, 'phase detail', 1024, true) }),
        ...(phase.provider === undefined ? {} : { provider: text(phase.provider, 'phase provider', 128) }),
        ...(phase.model === undefined ? {} : { model: text(phase.model, 'phase model', 128) }) }
    })
  }
  return normalized
}

/**
 * Validate a DSH-shaped script or workflow start before any native admission.
 * `scope` must originate from the trusted App policy, never from model arguments.
 * This function does not start either provider or grant access.
 */
export function prepareIsolatedExecution(request, scope, parentScope) {
  const data = record(request, 'execution request', [
    'kind', 'runId', 'sessionId', 'program', 'args', 'deadlineMillis', 'meta',
    'maxTotalAgents', 'maxConcurrentAgents',
  ])
  if (!['script', 'ptc', 'workflow'].includes(data.kind)) invalid('execution kind')
  const runId = uuid(data.runId, 'run identity')
  const sessionId = sessionIdentity(data.sessionId, 'session identity')
  const program = text(data.program, 'program', MAX_PROGRAM_BYTES)
  const deadlineMillis = integer(data.deadlineMillis, 'deadline', 1,
    data.kind === 'workflow' ? MAX_WORKFLOW_DEADLINE_MS
      : data.kind === 'ptc' ? MAX_PTC_DEADLINE_MS : MAX_DEADLINE_MS)
  const authority = normalizeExecutionScope(scope, parentScope)
  if (authority.sessionId !== sessionId || authority.leaseMillis < deadlineMillis) invalid('scope/session deadline')
  const args = data.args === undefined ? null : jsonCopy(data.args, 'JSON args')
  if (encoder.encode(JSON.stringify(args)).length > MAX_INPUT_BYTES) invalid('JSON args size')
  const prepared = { kind: data.kind, runId, sessionId, program, args, deadlineMillis, scope: authority }
  if (data.kind === 'ptc' && (authority.workspaceId !== null || authority.readablePaths.length
    || authority.writablePaths.length || authority.exactHosts.length || authority.fileCallLimit
    || authority.networkCallLimit)) invalid('PTC native grants')
  if (data.kind === 'workflow') {
    prepared.meta = workflowMeta(data.meta)
    prepared.maxTotalAgents = integer(data.maxTotalAgents, 'total child budget', 1, 128)
    prepared.maxConcurrentAgents = integer(data.maxConcurrentAgents, 'concurrent child budget', 1, 8)
    if (prepared.maxConcurrentAgents > prepared.maxTotalAgents) invalid('concurrent child budget')
  } else if (data.meta !== undefined || data.maxTotalAgents !== undefined || data.maxConcurrentAgents !== undefined) {
    invalid('script-only options')
  }
  return frozen(prepared)
}

/** Fail-closed model-facing gate until native/device and workflow parity gates pass. */
export function requireModelFacingIsolatedExecution() {
  throw new IsolatedExecutionContractError('ANDROID_PTC_UNAVAILABLE',
    'Android PTC and workflow execution are unavailable pending device and behavior acceptance')
}

/**
 * Convert one native receipt to an internal value. A completed value is never
 * returned for cancellation, audit uncertainty, worker death or a bad JSON wire.
 */
export function projectIsolatedReceipt(value, expectedRunId) {
  const receipt = record(value, 'native script receipt', ['runId', 'state', 'outputJson', 'logsJson', 'detail', 'guestUid'])
  const runId = uuid(receipt.runId, 'receipt run identity')
  if (runId !== uuid(expectedRunId, 'expected run identity')) invalid('receipt run identity')
  const state = receipt.state
  if (!['COMPLETED', 'CANCELLED', 'TIMED_OUT', 'WORKER_DIED', 'ERROR',
    'RETIRE_UNCONFIRMED', 'INTERRUPTED_UNCONFIRMED'].includes(state)) invalid('terminal receipt state')
  if (receipt.detail !== null && receipt.detail !== undefined) text(receipt.detail, 'receipt detail', 256, true)
  if (receipt.guestUid !== null && receipt.guestUid !== undefined) integer(receipt.guestUid, 'guest UID', 1, 0x7fffffff)
  if (state === 'COMPLETED') {
    if (receipt.guestUid === null || receipt.guestUid === undefined) invalid('completed guest UID')
    if (typeof receipt.outputJson !== 'string' || encoder.encode(receipt.outputJson).length > MAX_INPUT_BYTES) invalid('completed output')
    const rawLogs = receipt.logsJson === undefined ? '[]' : receipt.logsJson
    if (typeof rawLogs !== 'string' || encoder.encode(rawLogs).length > MAX_LOG_BYTES
      || encoder.encode(receipt.outputJson).length + encoder.encode(rawLogs).length > MAX_INPUT_BYTES) invalid('completed logs')
    let output
    try { output = JSON.parse(receipt.outputJson) } catch { invalid('completed JSON output') }
    let logs
    try { logs = JSON.parse(rawLogs) } catch { invalid('completed JSON logs') }
    if (!Array.isArray(logs) || logs.length > 128 || logs.some(line => typeof line !== 'string')) invalid('completed JSON logs')
    return frozen({ runId, state: 'completed', value: jsonCopy(output, 'completed JSON output'),
      logs: Object.freeze([...logs]),
      guestUid: receipt.guestUid ?? null })
  }
  if (receipt.outputJson !== null && receipt.outputJson !== undefined) invalid('failed output')
  if (receipt.logsJson !== null && receipt.logsJson !== undefined) invalid('failed logs')
  return frozen({ runId, state: 'failed', failure: state,
    requiresReview: state.endsWith('_UNCONFIRMED'), guestUid: receipt.guestUid ?? null,
    detail: receipt.detail ?? null })
}
