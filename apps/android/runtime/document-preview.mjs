import { randomUUID } from 'node:crypto'
import { isAbsolute } from 'node:path'

// A transport limit, independent of the original workspaceFiles read window.
const MAX_CHUNK_BYTES = 256 * 1024
const METHODS = {
  workspaceFiles: { stat: ['path'], list: ['path'], read: ['path', 'range'], readBytes: ['path', 'options'] },
  officeToPdf: { render: ['path', 'priority'], generation: [] },
}

function failure(code, message, details = {}) {
  return Object.assign(new Error(message), { name: 'RemoteError', isDSHRemoteError: true, code, details })
}

function identity(value, name) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 200) {
    throw failure('gateway/bad-request', `${name} must contain 1 to 200 characters`)
  }
  return value
}

function object(value, name) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw failure('gateway/bad-request', `${name} must be an object`)
  }
  return value
}

function integer(value, name, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw failure('gateway/bad-request', `${name} must be an integer between ${min} and ${max}`)
  }
  return value
}

function remoteFailure(error) {
  if (error?.isDSHRemoteError === true && typeof error.code === 'string') {
    return { ok: false, error: { name: 'RemoteError', isDSHRemoteError: true,
      code: error.code, message: error.message, details: error.details ?? {} } }
  }
  return { ok: false, error: { name: 'RemoteError', isDSHRemoteError: true,
    code: 'gateway/internal', message: 'Document preview failed. Close the preview and try again.', details: {} } }
}

/**
 * Read-only Android carrier for the original Session-scoped document services.
 * Gateway owns path resolution, permissions, input validation and source caps.
 * This owner bounds calls and retained bytes; it never opens files or Sessions.
 * Every RPC resolves to RemoteResult, including cancellation and transport errors.
 */
export class AppDocumentPreview {
  #requests = new Map()
  #leases = new Map()
  #closedOwners = new Set()
  #closed = false
  #retainedBytes = 0

  /**
   * @param options.invoke original typertGateway invocation with the App peer.
   * @param options.limits deployment budgets, resolved by the runtime Config.
   * @param options.report unexpected failures and cleanup failures, without file bytes.
   */
  constructor({ invoke, limits, mediaPolicy, report = error => console.error('Document preview:', error) }) {
    this.invoke = invoke
    this.limits = limits
    this.mediaPolicy = mediaPolicy
    this.report = report
  }

  /** Dispatch one document.* RPC; owner must be the native Binder identity. */
  async call(method, params) {
    try {
      object(params, 'params')
      const owner = identity(params.owner, 'owner')
      if (this.#closed || this.#closedOwners.has(owner)) {
        throw failure('gateway/cancelled', 'The document preview owner has disconnected.')
      }
      switch (method) {
        case 'mediaPolicy': {
          if (typeof params.path !== 'string' || params.path.length > 8192
            || params.path.includes('\0') || !isAbsolute(params.path)) {
            throw failure('gateway/bad-request', 'An absolute media path is required.')
          }
          if (!this.mediaPolicy) throw failure('gateway/invocation-unavailable', 'Document media policy is unavailable.')
          const policy = this.mediaPolicy(params.path)
          if (!Number.isSafeInteger(policy?.maxBytes) || policy.maxBytes <= 0
            || typeof policy.mimeType !== 'string' || !policy.mimeType.includes('/')) {
            throw failure('gateway/invocation-unavailable', 'Document media policy is unavailable.')
          }
          return { ok: true, value: policy }
        }
        case 'call': return { ok: true, value: await this.#invoke(owner, params) }
        case 'bytes': return { ok: true, value: this.#bytes(owner, params) }
        case 'cancel': return { ok: true, value: await this.#cancel(owner, params) }
        case 'release': return { ok: true, value: this.#release(owner, params) }
        default: throw failure('gateway/bad-request', 'Unsupported document operation.')
      }
    } catch (error) {
      if (error?.isDSHRemoteError !== true) this.report(error)
      return remoteFailure(error)
    }
  }

  #resolve(params) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const requestId = identity(params.requestId, 'requestId')
    const { namespace, method } = params
    const service = Object.hasOwn(METHODS, namespace) ? METHODS[namespace] : undefined
    const allowed = service && Object.hasOwn(service, method) ? service[method] : undefined
    if (!allowed) throw failure('gateway/bad-request', 'This document method is not allowed.')
    const supplied = params.args === undefined ? {} : object(params.args, 'args')
    if (Object.keys(supplied).some(key => !allowed.includes(key))) {
      throw failure('gateway/bad-request', 'Document arguments must not override the Session or method scope.')
    }
    const args = { ...supplied }
    if (namespace === 'workspaceFiles' || method === 'render') args.workspaceFileScopeId = sessionId
    if (namespace === 'workspaceFiles' && method === 'read' && args.range === undefined) args.range = {}
    if (namespace === 'workspaceFiles' && method === 'readBytes' && args.options === undefined) args.options = {}
    if (namespace === 'officeToPdf' && method === 'render' && args.priority === undefined) args.priority = 'foreground'
    return { requestId, sessionId, namespace, method, args }
  }

  async #invoke(owner, params) {
    const request = this.#resolve(params)
    const key = JSON.stringify([owner, request.requestId])
    if (this.#requests.has(key) || [...this.#leases.values()].some(lease => lease.key === key)) {
      throw failure('gateway/bad-request', 'Document requestId is already in use.')
    }
    const limits = this.limits()
    if (this.#requests.size >= limits.maxRequests
      || [...this.#requests.values()].filter(record => record.owner === owner).length >= limits.maxOwnerRequests) {
      throw failure('document-preview/busy', 'Too many document reads. Close another preview and retry.',
        { maxRequests: limits.maxRequests, maxOwnerRequests: limits.maxOwnerRequests })
    }
    const controller = new AbortController()
    const record = { key, owner, ...request, controller }
    this.#requests.set(key, record)
    const aborted = Promise.withResolvers()
    const onAbort = () => aborted.reject(controller.signal.reason)
    controller.signal.addEventListener('abort', onAbort, { once: true })
    const timeout = setTimeout(() => controller.abort(failure('document-preview/timeout',
      'Document read timed out. Close the preview and try again.', { timeoutMs: limits.requestTimeoutMs })), limits.requestTimeoutMs)
    // Keep admission occupied until the original service really settles, even
    // when a non-cooperative provider outlives the caller's deadline.
    record.done = Promise.resolve().then(async () => {
      controller.signal.throwIfAborted()
      const value = await this.invoke(request.namespace, request.method, request.args, controller.signal)
      controller.signal.throwIfAborted()
      if (this.#closed || this.#closedOwners.has(owner)) throw failure('gateway/cancelled', 'The document preview owner has disconnected.')
      if ((request.namespace === 'workspaceFiles' && request.method === 'readBytes')
        || (request.namespace === 'officeToPdf' && request.method === 'render')) {
        if (!(value?.data instanceof Uint8Array)) throw new Error('Document service returned invalid binary data')
        return { ...value, data: this.#lease(record, value.data) }
      }
      return value
    }).finally(() => {
      clearTimeout(timeout)
      controller.signal.removeEventListener('abort', onAbort)
      if (this.#requests.get(key) === record) this.#requests.delete(key)
    })
    return Promise.race([record.done, aborted.promise])
  }

  #lease(record, data) {
    const limits = this.limits()
    if (this.#leases.size >= limits.maxLeases || data.byteLength > limits.maxLeaseBytes - this.#retainedBytes) {
      throw failure('document-preview/capacity', 'Document preview memory is full. Close another preview and retry.',
        { maxLeaseBytes: limits.maxLeaseBytes, retainedBytes: this.#retainedBytes, requestedBytes: data.byteLength,
          maxLeases: limits.maxLeases })
    }
    const id = randomUUID()
    // Retain exactly the returned window, never a larger backing ArrayBuffer.
    const bytes = Buffer.from(data)
    const lease = { id, key: record.key, owner: record.owner, bytes }
    lease.timer = setTimeout(() => this.#drop(lease), limits.leaseTimeoutMs)
    lease.timer.unref?.()
    this.#leases.set(id, lease)
    this.#retainedBytes += bytes.byteLength
    return { encoding: 'android-byte-lease', id, length: bytes.byteLength }
  }

  #ownedLease(owner, id) {
    identity(id, 'id')
    const lease = this.#leases.get(id)
    if (!lease || lease.owner !== owner) {
      throw failure('document-preview/lease-unavailable', 'This document preview has expired or was released. Reopen it.')
    }
    return lease
  }

  #bytes(owner, params) {
    const lease = this.#ownedLease(owner, params.id)
    const offset = integer(params.offset, 'offset', 0, lease.bytes.byteLength)
    const length = integer(params.length, 'length', 1, MAX_CHUNK_BYTES)
    const end = Math.min(offset + length, lease.bytes.byteLength)
    // offset/eof here refer to the lease window; original file cursors are kept
    // unchanged in document.call's WorkspaceFileBytes value.
    return { offset, data: lease.bytes.subarray(offset, end).toString('base64'), eof: end === lease.bytes.byteLength }
  }

  #drop(lease) {
    if (this.#leases.get(lease.id) !== lease) return
    clearTimeout(lease.timer)
    this.#leases.delete(lease.id)
    this.#retainedBytes -= lease.bytes.byteLength
  }

  #release(owner, params) {
    const id = identity(params.id, 'id')
    if (!this.#leases.has(id)) return { released: false }
    const lease = this.#ownedLease(owner, id)
    this.#drop(lease)
    return { released: true }
  }

  async #cancel(owner, params) {
    const key = JSON.stringify([owner, identity(params.requestId, 'requestId')])
    const record = this.#requests.get(key)
    let cancelled = false
    for (const lease of this.#leases.values()) if (lease.key === key) { this.#drop(lease); cancelled = true }
    if (record) {
      cancelled = true
      record.controller.abort(failure('gateway/cancelled', 'The document preview was cancelled.'))
      await this.#settle([record])
    }
    return { cancelled }
  }

  async #settle(records) {
    if (records.length === 0) return
    let timer
    const timeoutMs = this.limits().closeTimeoutMs
    try {
      await Promise.race([Promise.allSettled(records.map(record => record.done)), new Promise((_, reject) => {
        timer = setTimeout(() => reject(failure('document-preview/cleanup-timeout',
          'Document cancellation has not settled; no bytes will be published. Close the preview and retry later.',
          { pending: records.length, timeoutMs })), timeoutMs)
      })])
    } finally { clearTimeout(timer) }
  }

  /** Disconnect revokes every owned byte lease before awaiting cancelled reads. */
  async closeOwner(owner) {
    identity(owner, 'owner')
    this.#closedOwners.add(owner)
    const records = [...this.#requests.values()].filter(record => record.owner === owner)
    for (const record of records) record.controller.abort(failure('gateway/cancelled', 'The document preview owner has disconnected.'))
    for (const lease of this.#leases.values()) if (lease.owner === owner) this.#drop(lease)
    await this.#settle(records)
  }

  /** Stop admission, revoke leases, and await provider quiescence within budget. */
  async close() {
    this.#closed = true
    const records = [...this.#requests.values()]
    for (const record of records) record.controller.abort(failure('gateway/cancelled', 'The document preview service is closing.'))
    for (const lease of this.#leases.values()) this.#drop(lease)
    await this.#settle(records)
  }
}
