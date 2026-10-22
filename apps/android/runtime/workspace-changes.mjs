const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function failure(code, message, details = {}) {
  return Object.assign(new Error(message), { name: 'RemoteError', isDSHRemoteError: true, code, details })
}

function identity(value, name) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 200 || value.includes('\0')) {
    throw failure('gateway/bad-request', `${name} must contain 1 to 200 characters.`)
  }
  return value
}

function coordinate(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) throw failure('gateway/bad-request', `${name} must be a nonnegative safe integer.`)
  return value
}

function resultError(error) {
  return { ok: false, error: { name: 'RemoteError', isDSHRemoteError: true,
    code: error.code, message: error.message, details: error.details ?? {} } }
}

/**
 * Native read-only carrier for the original ui-deliverables Fetch routes.
 * Connection retains its owner-only authorization and workspaceChanges owns
 * every snapshot. No listener, file read, Session activation, or cache is added.
 * The native Binder supplies owner; callers supply unique request IDs.
 */
export class AppWorkspaceChanges {
  #requests = new Map()
  #closedOwners = new Set()
  #closed = false

  /** fetch is Connection's shared /api handler bound to the App's explicit Peer. */
  constructor({ fetch, available, limits, report = error => console.error('Workspace changes:', error) }) {
    this.fetch = fetch
    this.available = available
    this.limits = limits
    this.report = report
  }

  /** Each RPC resolves to RemoteResult; missing records remain failures, never empty summaries. */
  async call(method, params) {
    try {
      if (!params || typeof params !== 'object' || Array.isArray(params)) throw failure('gateway/bad-request', 'Parameters must be an object.')
      const owner = identity(params.owner, 'owner')
      if (this.#closed || this.#closedOwners.has(owner)) throw failure('gateway/cancelled', 'The changes reader has disconnected.')
      if (!UUID.test(params.requestId ?? '')) throw failure('gateway/bad-request', 'requestId must be a UUID v4.')
      const allowed = ['owner', 'requestId', ...(method === 'cancel' ? [] : ['sessionId', 'seq', ...(method === 'diff' ? ['index'] : [])])]
      if (Object.keys(params).some(key => !allowed.includes(key))) throw failure('gateway/bad-request', 'Unexpected changes request arguments.')
      if (method === 'cancel') return { ok: true, value: await this.#cancel(owner, params.requestId) }
      if (method !== 'summary' && method !== 'diff') throw failure('gateway/bad-request', 'Unsupported changes operation.')
      return { ok: true, value: await this.#read(method, owner, params) }
    } catch (error) {
      if (error?.isDSHRemoteError === true) return resultError(error)
      this.report(error)
      return resultError(failure('workspace-changes/read-failed', 'The change snapshot could not be read. Retry or reopen the comparison.'))
    }
  }

  async #read(method, owner, params) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const seq = coordinate(params.seq, 'seq')
    const query = new URLSearchParams({ sessionId, seq: String(seq) })
    if (method === 'diff') query.set('index', String(coordinate(params.index, 'index')))
    if (!this.available()) throw failure('gateway/invocation-unavailable', 'The original workspace changes service is unavailable.')
    const key = JSON.stringify([owner, params.requestId])
    if (this.#requests.has(key)) throw failure('gateway/bad-request', 'The changes request ID is already in use.')
    const limits = this.limits()
    if (this.#requests.size >= limits.maxRequests
      || [...this.#requests.values()].filter(record => record.owner === owner).length >= limits.maxOwnerRequests) {
      throw failure('workspace-changes/busy', 'Too many change comparisons are open. Wait for another read to finish.',
        { maxRequests: limits.maxRequests, maxOwnerRequests: limits.maxOwnerRequests })
    }
    const controller = new AbortController()
    const record = { key, owner, controller }
    this.#requests.set(key, record)
    const aborted = Promise.withResolvers()
    const onAbort = () => aborted.reject(controller.signal.reason)
    controller.signal.addEventListener('abort', onAbort, { once: true })
    const timer = setTimeout(() => controller.abort(failure('workspace-changes/timeout',
      'Reading the change snapshot timed out. Retry the comparison.', { timeoutMs: limits.requestTimeoutMs })), limits.requestTimeoutMs)
    // Keep admission occupied until the original route settles, even after a
    // caller deadline. A late response cannot publish after cancellation.
    record.done = Promise.resolve().then(async () => {
      controller.signal.throwIfAborted()
      const response = await this.fetch(new Request(`http://pocket-harness.invalid/api/changes.${method}?${query}`, { signal: controller.signal }))
      controller.signal.throwIfAborted()
      if (!response.ok) {
        const errors = {
          400: ['gateway/bad-request', 'Invalid change snapshot coordinates.'],
          403: ['remote-access/denied', 'This caller cannot read workspace changes.'],
          404: ['workspace-changes/unavailable', 'This change snapshot is no longer available in the running service.'],
        }
        const [code, message] = errors[response.status] ?? ['workspace-changes/read-failed', 'The change snapshot could not be read. Retry or reopen the comparison.']
        // Original error bodies may contain Host details; only the status is carried.
        await response.body?.cancel()
        throw failure(code, message, { status: response.status })
      }
      const value = await response.json()
      controller.signal.throwIfAborted()
      return value
    }).finally(() => {
      clearTimeout(timer)
      controller.signal.removeEventListener('abort', onAbort)
      if (this.#requests.get(key) === record) this.#requests.delete(key)
    })
    return Promise.race([record.done, aborted.promise])
  }

  async #cancel(owner, requestId) {
    const record = this.#requests.get(JSON.stringify([owner, requestId]))
    if (!record) return { cancelled: false }
    record.controller.abort(failure('gateway/cancelled', 'The change snapshot read was cancelled.'))
    await this.#settle([record])
    return { cancelled: true }
  }

  async #settle(records) {
    if (!records.length) return
    let timer
    const timeoutMs = this.limits().closeTimeoutMs
    try {
      await Promise.race([Promise.allSettled(records.map(record => record.done)), new Promise((_, reject) => {
        timer = setTimeout(() => reject(failure('workspace-changes/cleanup-timeout',
          'The snapshot reader is still stopping. No late result will be displayed. Retry closing later.',
          { timeoutMs, pending: records.length })), timeoutMs)
      })])
    } finally { clearTimeout(timer) }
  }

  /** Revoke one Binder owner before waiting for its original route reads to settle. */
  async closeOwner(owner) {
    identity(owner, 'owner')
    this.#closedOwners.add(owner)
    const records = [...this.#requests.values()].filter(record => record.owner === owner)
    for (const record of records) record.controller.abort(failure('gateway/cancelled', 'The changes reader has disconnected.'))
    await this.#settle(records)
  }

  /** Stop admission before bounded teardown; no snapshots are retained by this carrier. */
  async close() {
    this.#closed = true
    const records = [...this.#requests.values()]
    for (const record of records) record.controller.abort(failure('gateway/cancelled', 'The changes reader is closing.'))
    await this.#settle(records)
  }
}
