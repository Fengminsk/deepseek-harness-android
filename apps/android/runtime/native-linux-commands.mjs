import { randomUUID } from 'node:crypto'

const MAX_STDIN_BYTES = 64 * 1024
const MAX_OUTPUT_BYTES = 4096
const MAX_INFLIGHT = 2
const RUN_DEADLINE_MS = 6500
const CANCEL_DEADLINE_MS = 5500
const NO_ARGUMENT = new Set(['kernel', 'identity', 'sha256', 'count_bytes', 'count_lines', 'sort_lines'])
const WITH_LITERAL = new Set(['filter_literal'])
const NO_STDIN = new Set(['kernel', 'identity'])
const KINDS = new Set(['COMPLETED', 'CANCELLED', 'TIMED_OUT', 'WORKER_DIED', 'ERROR'])

/** An App call ended without proof that its isolated command has retired. */
export class LinuxCommandOutcomeUncertainError extends Error {
  constructor(id, command, cause) {
    super('Android Linux command outcome and child retirement are unconfirmed; do not retry automatically',
      { cause })
    this.name = 'LinuxCommandOutcomeUncertainError'
    this.code = 'outcome-uncertain'
    this.runId = id
    this.command = command
  }
}

function exactRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new TypeError('Invalid Linux command request')
  }
  const keys = Reflect.ownKeys(value)
  if (keys.some(key => !['command', 'argument', 'stdin'].includes(key)
    || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))
    || !Object.hasOwn(value, 'command')) throw new TypeError('Invalid Linux command request')
  return value
}

function encodeRequest(value) {
  const request = exactRequest(value)
  const command = request.command
  if (typeof command !== 'string' || !(NO_ARGUMENT.has(command) || WITH_LITERAL.has(command))) {
    throw new TypeError('Unsupported Linux command')
  }
  const argument = request.argument ?? ''
  if (typeof argument !== 'string' || Buffer.byteLength(argument, 'utf8') > 128
    || [...argument].some(character => character.codePointAt(0) < 0x20 || character.codePointAt(0) === 0x7f)
    || (WITH_LITERAL.has(command) ? argument.length === 0 : argument.length !== 0)) {
    throw new TypeError('Invalid Linux command literal')
  }
  const input = request.stdin ?? new Uint8Array()
  if (!(input instanceof Uint8Array) || input.byteLength > MAX_STDIN_BYTES
    || (NO_STDIN.has(command) && input.byteLength !== 0)) {
    throw new TypeError('Invalid Linux command input')
  }
  return { command, argument, stdinBase64: Buffer.from(input).toString('base64') }
}

function checkedResult(result, id, command) {
  if (!result || typeof result !== 'object' || Array.isArray(result)
    || result.id !== id || result.command !== command || !KINDS.has(result.kind)
    || typeof result.output !== 'string' || Buffer.byteLength(result.output, 'utf8') > MAX_OUTPUT_BYTES
    || !Number.isInteger(result.exitCode)
    || !(result.guestUid === null || Number.isInteger(result.guestUid) && result.guestUid >= 0)
    || !(result.detail === null || typeof result.detail === 'string')
    || result.kind === 'COMPLETED' && (
      result.guestUid === null || result.exitCode !== 0
        && !(command === 'filter_literal' && result.exitCode === 1))) {
    throw new Error('Native Linux command returned an invalid receipt')
  }
  if (result.retirementConfirmed !== true) {
    throw new LinuxCommandOutcomeUncertainError(id, command)
  }
  return Object.freeze({ ...result })
}

function checkedCancellation(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))
    || Reflect.ownKeys(value).some(key => !['cancelRequested', 'settled'].includes(key))
    || typeof value.cancelRequested !== 'boolean' || typeof value.settled !== 'boolean') {
    throw new Error('Native Linux command returned an invalid cancellation receipt')
  }
  return Object.freeze({ cancelRequested: value.cancelRequested, settled: value.settled })
}

/** Internal Node-to-App command carrier; model tools are not registered here. */
export class NativeLinuxCommands {
  #transport
  #runs = new Map()
  #closed = false

  constructor(transport) {
    if (!transport || typeof transport.request !== 'function') throw new TypeError('Native transport required')
    this.#transport = transport
  }

  async execute(value, signal) {
    if (this.#closed) throw new Error('Native Linux command carrier is closed')
    if (signal !== undefined && !(signal instanceof AbortSignal)) throw new TypeError('signal must be an AbortSignal')
    if (this.#runs.size >= MAX_INFLIGHT) throw new Error('Native Linux command capacity reached')
    const request = encodeRequest(value)
    const id = randomUUID()
    const deadline = AbortSignal.timeout(RUN_DEADLINE_MS)
    const combined = signal ? AbortSignal.any([signal, deadline]) : deadline
    const run = { id, command: request.command, cancel: null, dispatched: false, stop: null }
    const cancel = () => {
      if (!run.dispatched) return Promise.resolve({ cancelRequested: false, settled: true })
      if (!run.cancel) {
        run.cancel = this.#transport.request('native.linuxCommand.cancel', { id },
          AbortSignal.timeout(CANCEL_DEADLINE_MS))
          .then(checkedCancellation)
          .catch(() => ({ cancelRequested: false, settled: false }))
      }
      return run.cancel
    }
    run.stop = cancel
    this.#runs.set(id, run)
    const onAbort = () => { void cancel() }
    combined.addEventListener('abort', onAbort, { once: true })
    try {
      if (combined.aborted) throw combined.reason
      run.dispatched = true
      const result = await this.#transport.request('native.linuxCommand.execute',
        { id, ...request }, combined)
      if (combined.aborted || this.#closed) throw combined.aborted ? combined.reason : new Error('Native Linux command carrier closed')
      const receipt = checkedResult(result, id, request.command)
      if (receipt.kind === 'WORKER_DIED') {
        throw new LinuxCommandOutcomeUncertainError(id, request.command)
      }
      return receipt
    } catch (error) {
      const cancellation = await cancel()
      if (error instanceof LinuxCommandOutcomeUncertainError || !cancellation.settled) {
        this.#closed = true
        throw error instanceof LinuxCommandOutcomeUncertainError ? error
          : new LinuxCommandOutcomeUncertainError(id, request.command, error)
      }
      throw error
    } finally {
      combined.removeEventListener('abort', onAbort)
      this.#runs.delete(id)
    }
  }

  async dispose() {
    this.#closed = true
    const runs = [...this.#runs.values()].filter(run => run.dispatched)
    const cancellations = await Promise.all(runs.map(run => run.stop()))
    const unknown = runs.find((run, index) => !cancellations[index].settled)
    if (unknown) throw new LinuxCommandOutcomeUncertainError(unknown.id, unknown.command)
  }
}
