function failure(code, message) {
  return Object.assign(new Error(message), { code })
}

function identity(value, label) {
  if (typeof value !== 'string' || !value || value.length > 200 || /[\u0000-\u001f]/u.test(value)) {
    throw failure('gateway/bad-request', `Invalid ${label}`)
  }
  return value
}

function resultError(error) {
  return { ok: false, error: { code: typeof error?.code === 'string' ? error.code : 'gateway/internal',
    message: String(error?.message ?? error) } }
}

/** Cancellable native discovery over the two original @ reference services. */
export class AppReferenceDiscovery {
  constructor({ invoke, limits }) {
    this.invoke = invoke
    this.limits = limits
    this.active = new Map()
    this.closedOwners = new Set()
    this.closed = false
  }

  /** Binder owns owner; each composer query owns a fresh requestId. */
  async call(method, params) {
    const owner = identity(params.owner, 'owner')
    const requestId = identity(params.requestId, 'requestId')
    const key = `${owner}\0${requestId}`
    if (method === 'cancel') {
      await this.stop(this.active.get(key))
      return { cancelled: true }
    }
    if (method !== 'list') throw failure('gateway/not-found', 'Unknown reference operation')
    if (this.closed || this.closedOwners.has(owner)) throw failure('gateway/cancelled', 'Reference owner disconnected')
    const sessionId = identity(params.sessionId, 'sessionId')
    if (typeof params.query !== 'string' || params.query.length > 8192 || /[\u0000-\u001f]/u.test(params.query)
      || typeof params.quoted !== 'boolean') throw failure('gateway/bad-request', 'Invalid reference query')
    if (this.active.has(key)) throw failure('gateway/bad-request', 'Reference request is already running')
    const limits = this.limits()
    if (this.active.size >= limits.maxRequests) throw failure('gateway/unavailable', '引用查询繁忙，请稍后重试')
    const abort = new AbortController()
    const entry = { owner, abort, done: null }
    this.active.set(key, entry)
    const aborted = Promise.withResolvers()
    const onAbort = () => aborted.reject(abort.signal.reason)
    abort.signal.addEventListener('abort', onAbort, { once: true })
    const timeout = setTimeout(() => abort.abort(failure('gateway/timeout', '引用查询超时，请重试')), limits.requestTimeoutMs)
    const read = async (namespace, method) => {
      try {
        abort.signal.throwIfAborted()
        return { ok: true, value: await this.invoke(namespace, method, { agentId: sessionId, query: params.query }, abort.signal) }
      } catch (error) { return resultError(error) }
    }
    // Register the owner before invoking providers. Both reads must settle even
    // if one fails, so cancellation/disconnect cannot strand the other call.
    entry.done = Promise.resolve().then(async () => {
      const [files, sessions] = await Promise.all([
        read('fileReferences', 'list'),
        params.quoted ? { ok: true, value: [] } : read('sessionReferenceResolver', 'candidates'),
      ])
      if (abort.signal.aborted) throw abort.signal.reason
      return { files, sessions }
    }).finally(() => {
      clearTimeout(timeout)
      abort.signal.removeEventListener('abort', onAbort)
      this.active.delete(key)
    })
    // Deadline/cancel answers promptly while the slot remains owned until both
    // providers actually settle. Late content can never become a new result.
    return Promise.race([entry.done, aborted.promise])
  }

  async stop(entry) {
    if (!entry) return
    entry.abort.abort(failure('gateway/cancelled', '引用查询已取消'))
    let timeout
    const settled = entry.done.then(() => {}, () => {})
    try {
      await Promise.race([settled, new Promise((_, reject) => {
        timeout = setTimeout(() => reject(failure('gateway/timeout', '引用提供方尚未停止')), this.limits().closeTimeoutMs)
      })])
    } finally { clearTimeout(timeout) }
  }

  async closeOwner(owner) {
    this.closedOwners.add(owner)
    await this.stopAll([...this.active.values()].filter(entry => entry.owner === owner))
  }

  async stopAll(entries) {
    const outcomes = await Promise.allSettled(entries.map(entry => this.stop(entry)))
    const rejected = outcomes.find(result => result.status === 'rejected')
    if (rejected) throw rejected.reason
  }

  async close() {
    this.closed = true
    await this.stopAll([...this.active.values()])
  }
}
