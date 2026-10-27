import { randomUUID } from 'node:crypto'
import { HarnessError } from '@deepseek-ai/dsh-llm'

const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}(?![\s\S])/
const TERMINAL = new Set(['completed', 'cancelled', 'timed_out', 'failed', 'worker_died', 'outcome_uncertain'])
export const LINUX_VM_COMMAND_BYTES = 32 * 1024
export const LINUX_VM_OUTPUT_BYTES = 64 * 1024
export const LINUX_VM_TIMEOUT_MS = 120_000
export const LINUX_VM_IMPORT_BYTES = 64 * 1024 * 1024

function object(value, fields) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))
    || Reflect.ownKeys(value).some(key => !fields.includes(key)
      || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) {
    throw new TypeError('Invalid Linux VM request')
  }
  return value
}

/**
 * Validate model text before it crosses into the native Linux execution owner.
 * @param args - Model command and optional timeout.
 * @returns The bounded command; host policy is supplied separately.
 */
export function prepareLinuxVmCommand(args) {
  object(args, ['command', 'timeoutMs'])
  if (typeof args.command !== 'string' || args.command.trim().length === 0
    || args.command.includes('\0') || Buffer.byteLength(args.command) > LINUX_VM_COMMAND_BYTES) {
    throw new TypeError('Linux command must contain 1–32768 UTF-8 bytes without NUL')
  }
  const timeoutMs = args.timeoutMs === undefined ? LINUX_VM_TIMEOUT_MS : args.timeoutMs
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > LINUX_VM_TIMEOUT_MS) {
    throw new TypeError('Linux command timeout must be 1000–120000 milliseconds')
  }
  return Object.freeze({ command: args.command, timeoutMs })
}

/**
 * Import names remain relative to fixed host and guest roots, never model-selected roots.
 * @param args - Relative source and destination names and optional timeout.
 * @returns Validated import parameters without host policy or session identity.
 */
export function prepareLinuxVmImport(args) {
  object(args, ['source', 'destination', 'timeoutMs'])
  const path = value => typeof value === 'string' && value.length > 0
    && Buffer.byteLength(value) <= 4096 && !/[\\\x00-\x1f\x7f:]/u.test(value)
    && value.split('/').every(part => part !== '' && part !== '.' && part !== '..')
  if (!path(args.source) || !path(args.destination)) throw new TypeError('Linux import requires relative source and destination file paths')
  const timeoutMs = args.timeoutMs === undefined ? LINUX_VM_TIMEOUT_MS : args.timeoutMs
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > LINUX_VM_TIMEOUT_MS) {
    throw new TypeError('Linux import timeout must be 1000–120000 milliseconds')
  }
  return Object.freeze({ source: args.source, destination: args.destination, timeoutMs })
}

function hostPolicy(policy) {
  object(policy, ['persistChanges'])
  if (typeof policy.persistChanges !== 'boolean') throw new TypeError('Linux execution requires an explicit host persistence policy')
  return policy.persistChanges
}

/** Final execution and disk publication were not confirmed. This owner stops accepting new commands. */
export class LinuxVmOutcomeUncertainError extends HarnessError {
  constructor(runId, cause, facts = {}) {
    super('Linux 客体执行结果未确认，已停止后续命令。请先查看任务记录，勿自动重试。',
      'linux-vm/outcome-uncertain', { cause })
    this.runId = runId
    this.diskCommitted = facts.diskCommitted ?? null
    if (Object.hasOwn(facts, 'filePublished')) this.filePublished = facts.filePublished
    this.receipt = Object.freeze({ runId, status: 'outcome_uncertain',
      diskCommitted: this.diskCommitted, retirementConfirmed: facts.retirementConfirmed ?? null,
      ...Object.hasOwn(facts, 'filePublished') ? { filePublished: facts.filePublished } : {},
      ...facts.nativeStatus === undefined ? {} : { nativeStatus: facts.nativeStatus },
      ...facts.sessionId === undefined ? {} : { sessionId: facts.sessionId },
      ...facts.operation === undefined ? {} : { operation: facts.operation },
      cancelRequested: facts.cancelRequested === true })
  }
}

function receipt(value, request, method) {
  const importing = method === 'native.linuxVm.importFile'
  const exporting = method === 'native.linuxVm.exportFile'
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || value.id !== request.id || value.sessionId !== request.sessionId
    || !TERMINAL.has(value.status) || typeof value.output !== 'string'
    || Buffer.byteLength(value.output) > LINUX_VM_OUTPUT_BYTES
    || !(value.exitCode === null || Number.isInteger(value.exitCode) && value.exitCode >= 0 && value.exitCode <= 255)
    || !['timedOut', 'cancelled', 'truncated', 'retirementConfirmed']
      .every(key => typeof value[key] === 'boolean')
    || !(typeof value.diskCommitted === 'boolean' || value.status === 'outcome_uncertain' && value.diskCommitted === null)
    || !(value.guestUid === null || Number.isInteger(value.guestUid) && value.guestUid >= 0)
    || !(value.detail === null || typeof value.detail === 'string' && value.detail.length <= 512)
    || value.status === 'completed' && (value.exitCode === null || value.guestUid === null
      || value.timedOut || value.cancelled
      || value.diskCommitted !== (exporting ? false : importing ? value.exitCode === 0 : request.persistChanges))
    || value.status !== 'completed' && value.diskCommitted) {
    throw new Error('Linux VM returned an invalid execution receipt')
  }
  if (exporting && (!(typeof value.filePublished === 'boolean'
      || value.status === 'outcome_uncertain' && value.filePublished === null)
    || value.status === 'completed' && value.filePublished !== (value.exitCode === 0)
    || !['completed', 'outcome_uncertain'].includes(value.status) && value.filePublished)) {
    throw new Error('Linux VM returned an invalid export publication receipt')
  }
  if (!value.retirementConfirmed || value.status === 'outcome_uncertain') {
    throw new LinuxVmOutcomeUncertainError(request.id, undefined, {
      nativeStatus: value.status, diskCommitted: value.diskCommitted,
      retirementConfirmed: value.retirementConfirmed,
      ...exporting ? { filePublished: value.filePublished } : {},
    })
  }
  if ((importing || exporting) && value.status === 'completed' && value.exitCode === 0
    && (value.source !== request.source || value.destination !== request.destination
      || !Number.isSafeInteger(value.bytes) || value.bytes < 0 || value.bytes > LINUX_VM_IMPORT_BYTES
      || typeof value.sha256 !== 'string' || !/^[0-9a-f]{64}$/u.test(value.sha256))) {
    throw new Error(`Linux VM returned an invalid ${exporting ? 'export' : 'import'} receipt`)
  }
  return Object.freeze({ ...value })
}

// Cancellation of the caller must not erase a native receipt after its disk
// pointer was published. Only a separate finite RPC deadline ends this wait.
async function boundedRequest(transport, method, params, signal) {
  signal.throwIfAborted()
  let rejectDeadline
  const expired = new Promise((_resolve, reject) => { rejectDeadline = reject })
  const onAbort = () => rejectDeadline(signal.reason)
  signal.addEventListener('abort', onAbort, { once: true })
  try { return await Promise.race([transport.request(method, params, signal), expired]) }
  finally { signal.removeEventListener('abort', onAbort) }
}

/** Each call uses only its live Agent session; callers cannot choose a host path or image. */
export class NativeLinuxVm {
  #transport
  #runs = new Map()
  #closed = false

  constructor(transport) {
    if (!transport || typeof transport.request !== 'function') throw new TypeError('Native transport required')
    this.#transport = transport
  }

  /**
   * @param sessionId - Current registered Agent's session identity.
   * @param args - Model command arguments.
   * @param signal - Tool execution cancellation signal.
   * @param policy - Host-resolved persistence policy, never model input.
   * @returns Confirmed execution receipt; uncertainty closes the owner.
   */
  async execute(sessionId, args, signal, policy) {
    const persistChanges = hostPolicy(policy)
    return this.#run(sessionId, { ...prepareLinuxVmCommand(args), persistChanges }, signal, 'native.linuxVm.execute')
  }

  /**
   * @param sessionId - Current registered Agent's session identity.
   * @param args - Authorized App-relative source and guest-relative destination.
   * @param signal - Tool execution cancellation signal.
   * @param policy - Host-resolved writable policy.
   * @returns Confirmed import receipt including content identity on success.
   */
  async importFile(sessionId, args, signal, policy) {
    if (!hostPolicy(policy)) throw new Error('Linux import requires a writable session policy')
    return this.#run(sessionId, prepareLinuxVmImport(args), signal, 'native.linuxVm.importFile')
  }

  /**
   * @param sessionId - Current registered Agent's session identity.
   * @param args - Guest-relative source and authorized App-relative destination.
   * @param signal - Tool execution cancellation signal.
   * @param policy - Host write authorization; export never commits guest disks.
   * @returns Confirmed file publication and content identity, or closes on uncertainty.
   */
  async exportFile(sessionId, args, signal, policy) {
    if (!hostPolicy(policy)) throw new Error('Linux export requires a writable session policy')
    return this.#run(sessionId, prepareLinuxVmImport(args), signal, 'native.linuxVm.exportFile')
  }

  async #run(sessionId, prepared, signal, method) {
    if (this.#closed) throw new Error('Linux VM owner is closed')
    if (typeof sessionId !== 'string' || !SESSION_ID.test(sessionId)) throw new TypeError('Invalid Agent session ID')
    if (!(signal instanceof AbortSignal)) throw new TypeError('An execution signal is required')
    signal.throwIfAborted()
    if (this.#runs.size !== 0) throw new Error('Linux 客体正在执行其他命令，请等待该命令结束。')
    const request = { id: randomUUID(), sessionId, ...prepared }
    const deadline = AbortSignal.timeout(request.timeoutMs + 30_000)
    const run = { dispatched: false, cancellation: null, done: null, cancelRequested: false }
    const cancel = () => {
      if (!run.dispatched) return Promise.resolve(true)
      return run.cancellation ??= boundedRequest(this.#transport, 'native.linuxVm.cancel', { id: request.id },
        AbortSignal.timeout(10_000)).then(result => Boolean(result && result.settled === true
          && typeof result.cancelRequested === 'boolean'), () => false)
    }
    const onAbort = () => { run.cancelRequested = true; void cancel() }
    signal.addEventListener('abort', onAbort, { once: true })
    this.#runs.set(request.id, { run, cancel })
    run.done = (async () => {
      try {
        signal.throwIfAborted()
        deadline.throwIfAborted()
        run.dispatched = true
        const result = await boundedRequest(this.#transport, method, request, deadline)
        return Object.freeze({ ...receipt(result, request, method), cancelRequested: run.cancelRequested })
      } catch (error) {
        if (!run.dispatched) throw error
        await cancel()
        // A cancel acknowledgement proves retirement, not whether an earlier
        // publication succeeded. Without the final receipt both stay unknown.
        this.#closed = true
        const known = error instanceof LinuxVmOutcomeUncertainError ? error.receipt : {}
        throw new LinuxVmOutcomeUncertainError(request.id,
          error instanceof LinuxVmOutcomeUncertainError ? error.cause : error, {
            ...method === 'native.linuxVm.exportFile' ? { filePublished: null } : {},
            ...known, sessionId: request.sessionId, operation: method,
            cancelRequested: run.cancelRequested,
          })
      } finally {
        signal.removeEventListener('abort', onAbort)
        this.#runs.delete(request.id)
      }
    })()
    return run.done
  }

  async dispose() {
    this.#closed = true
    const running = [...this.#runs.entries()]
    const outcomes = await Promise.all(running.map(async ([id, { run, cancel }]) => {
      run.cancelRequested = true
      void cancel()
      const [outcome] = await Promise.allSettled([run.done])
      return { id, outcome }
    }))
    const uncertain = outcomes.find(value => value.outcome.status === 'rejected')
    if (uncertain) throw uncertain.outcome.reason instanceof LinuxVmOutcomeUncertainError
      ? uncertain.outcome.reason : new LinuxVmOutcomeUncertainError(uncertain.id, uncertain.outcome.reason)
  }
}
