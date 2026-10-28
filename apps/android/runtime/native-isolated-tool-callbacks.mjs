import { IsolatedToolCallPort, isRecoverableToolGuestError, confirmedToolCallbackClosure } from './isolated-tool-call-port.mjs'

const MAX_PENDING_RUNS = 4
const BIND_TIMEOUT_MS = 10_000

function exactObject(value, keys) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw new TypeError('Invalid native tool callback')
  const actual = Reflect.ownKeys(value)
  if (actual.length !== keys.length || actual.some(key => !keys.includes(key)
    || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) {
    throw new TypeError('Invalid native tool callback')
  }
  return value
}

function owner(value) {
  const params = exactObject(value, ['runId', 'token'])
  if (typeof params.runId !== 'string' || typeof params.token !== 'string'
    || !params.runId || !params.token) throw new TypeError('Invalid native tool callback owner')
  return params
}

/**
 * Pairs one durably admitted isolated run with its host ToolRuntime subcalls.
 * Only trusted App host code may bind a port. The isolated guest cannot supply
 * the native token, parent execution, tool list, or authorization policy.
 */
export class NativeIsolatedToolCallbacks {
  #transport
  #journal
  #runs = new Map()
  #closed = false

  constructor(transport, journal) {
    if (!transport || typeof transport.request !== 'function') throw new TypeError('Native transport required')
    if (!journal || typeof journal.claimRun !== 'function'
      || typeof journal.prepare !== 'function'
      || typeof journal.dispatch !== 'function' || typeof journal.observe !== 'function'
      || typeof journal.confirm !== 'function') {
      throw new TypeError('Durable isolated tool callback journal required')
    }
    this.#transport = transport
    this.#journal = journal
  }

  async bind({ prepared, admission, runtime, parent, allowedToolNames, authorizeTool }) {
    if (this.#closed || this.#runs.size >= MAX_PENDING_RUNS) throw new Error('Native tool callback capacity reached')
    const { runId, token } = owner(admission)
    if (this.#runs.has(runId)) throw new Error('Native tool callback run is already bound')
    const port = new IsolatedToolCallPort({ prepared, admission, runtime, parent,
      allowedToolNames, authorizeTool, journal: this.#journal })
    // Native admission is one-use. Reserve its callback directory before the
    // Binder bind so a cold Node restart cannot reattach an old run.
    try { await this.#journal.claimRun(runId) }
    catch (error) {
      await port.close(error)
      throw error
    }
    const entry = { token, port, state: 'binding', closePromise: null }
    this.#runs.set(runId, entry)
    try {
      const accepted = await this.#transport.request('native.isolated.bindTools',
        { runId, token }, AbortSignal.timeout(BIND_TIMEOUT_MS))
      if (accepted !== true || this.#closed) throw new Error('Native tool binding was not confirmed')
      entry.state = 'active'
    } catch (error) {
      entry.state = 'closing'
      try { await port.close(error) } finally {
        if (this.#runs.get(runId) === entry) this.#runs.delete(runId)
      }
      throw error
    }
    return Object.freeze({ runId, close: () => this.#closeEntry(runId, entry) })
  }

  async call(value) {
    const params = exactObject(value, ['runId', 'token', 'callId', 'name', 'arguments'])
    const { runId, token } = owner({ runId: params.runId, token: params.token })
    const entry = this.#runs.get(runId)
    if (!entry || entry.token !== token || entry.state !== 'active') {
      throw new Error('Native tool callback has no live admitted owner')
    }
    try {
      const result = await entry.port.call({ runId, callId: params.callId,
        name: params.name, arguments: params.arguments })
      return { runId, callId: params.callId, value: result }
    } catch (error) {
      const closure = confirmedToolCallbackClosure(error, runId, params.callId)
      if (closure) return { runId, callId: params.callId, ...closure }
      // These outcomes are either rejected before dispatch or have a durable
      // terminal confirmation. Return them as guest exceptions. Any audit,
      // transport or cancellation failure still tears down the native run.
      if (!isRecoverableToolGuestError(error)) throw error
      return { runId, callId: params.callId,
        error: { code: error.code, message: error.message } }
    }
  }

  async close(value) {
    const { runId, token } = owner(value)
    const entry = this.#runs.get(runId)
    if (!entry || entry.token !== token) throw new Error('Native tool callback has no live admitted owner')
    await this.#closeEntry(runId, entry)
    return { closed: true }
  }

  #closeEntry(runId, entry) {
    if (entry.closePromise) return entry.closePromise
    entry.state = 'closing'
    entry.closePromise = Promise.resolve().then(() => entry.port.close('native run retired'))
      .finally(() => { if (this.#runs.get(runId) === entry) this.#runs.delete(runId) })
    return entry.closePromise
  }

  async dispose() {
    this.#closed = true
    const current = [...this.#runs.entries()]
    await Promise.allSettled(current.map(([runId, entry]) => this.#closeEntry(runId, entry)))
  }
}
