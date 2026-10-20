import { randomUUID } from 'node:crypto'

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const rootId = /^[0-9a-f]{64}$/

function validate(params) {
  if (typeof params.requestId !== 'string' || !uuid.test(params.requestId)) throw new TypeError('Invalid search request id')
  if (typeof params.root !== 'string' || !rootId.test(params.root)) throw new TypeError('Invalid document grant')
  if (typeof params.path !== 'string' || params.path.length > 4096 || (params.path !== '' && params.path.split('/').some(
    part => part === '' || part === '.' || part === '..' || part.includes('\\')))) throw new TypeError('Invalid relative document path')
  if (typeof params.query !== 'string' || params.query.length < 1 || params.query.length > 256
    || /[\r\n\0]/u.test(params.query) || !params.query.isWellFormed()) throw new TypeError('Search needs 1–256 characters on one line')
  if (typeof params.caseSensitive !== 'boolean') throw new TypeError('caseSensitive is required')
}

function abortError() { return Object.assign(new Error('文件搜索已取消'), { name: 'AbortError' }) }

/**
 * One native search owner for App and tool entry points. No content URI or path
 * outside the persisted root crosses this API. Bounds come from deployment config.
 */
export class AppDocumentSearch {
  constructor(transport, { limits, maxRequests }) {
    this.transport = transport
    this.limits = limits
    this.maxRequests = maxRequests
    this.active = new Map()
    this.closedOwners = new Set()
    this.closed = false
  }

  /** App owner is injected by Binder; tools use their own session/call owner. */
  async run(params, { owner, signal } = {}) {
    validate(params)
    if (typeof owner !== 'string' || owner === '' || owner.length > 200) throw new TypeError('Search owner is required')
    if (this.closed) throw new Error('File search service is closed')
    if (this.closedOwners.has(owner)) throw new Error('File search owner is disconnected')
    if (signal?.aborted) throw abortError()
    const key = `${owner}\0${params.requestId}`
    if (this.active.has(key)) throw new Error('Search request is already running')
    const maximum = this.maxRequests()
    if (!Number.isInteger(maximum) || maximum < 1 || maximum > 4) throw new Error('Invalid search concurrency limit')
    if (this.active.size >= maximum) throw new Error('搜索任务过多，请等待已有搜索结束')
    const entry = { id: randomUUID(), key, owner, cancelled: false, finished: false, prepared: null, stopping: null }
    this.active.set(key, entry)
    const onAbort = () => {
      entry.cancelled = true
      // run() observes cancellation before publishing. Keep failure visible to
      // an explicit cancel/retry; the fire-and-forget signal must not reject globally.
      void this.stop(entry).catch(error => { entry.stopError = error })
    }
    // Establish the prepare acknowledgement before observing cancellation, even
    // if transport.request synchronously invokes an abort listener.
    entry.prepared = Promise.resolve().then(() =>
      this.transport.request('native.documents.search.prepare', { id: entry.id }))
    signal?.addEventListener('abort', onAbort, { once: true })
    if (signal?.aborted) onAbort()
    try {
      await entry.prepared
      if (entry.cancelled) throw abortError()
      const result = await this.transport.request('native.documents.search.run', {
        id: entry.id, root: params.root, path: params.path, query: params.query,
        caseSensitive: params.caseSensitive, limits: this.limits(),
      })
      if (entry.cancelled || signal?.aborted) throw abortError()
      return result
    } finally {
      signal?.removeEventListener('abort', onAbort)
      // Native run removes its own job. This also retires a prepared job if the
      // caller cancelled before run or failed to submit the run request.
      entry.finished = true
      await this.stop(entry)
      this.active.delete(key)
    }
  }

  async stop(entry) {
    if (entry.stopping) return entry.stopping
    const operation = (async () => {
      if (entry.prepared) {
        try { await entry.prepared }
        catch (error) {
          // A lost response may follow a successful native registration. Always
          // ask native to retire this opaque id instead of leaking its slot.
          entry.prepareError = error
        }
      }
      const result = await this.transport.request('native.documents.search.cancel', { id: entry.id })
      if (result?.cancelled !== true) throw new Error('文件提供方仍在停止搜索，请等待；尚未确认取消完成')
      if (entry.finished) this.active.delete(entry.key)
      return { cancelled: true }
    })()
    entry.stopping = operation
    try { return await operation }
    catch (error) { entry.stopping = null; throw error }
  }

  /** Returns only after the native scanning owner confirms termination. */
  async cancel(params, { owner } = {}) {
    if (!uuid.test(params.requestId ?? '') || typeof owner !== 'string' || owner === '') throw new TypeError('Invalid search cancellation')
    const entry = this.active.get(`${owner}\0${params.requestId}`)
    if (!entry) return { cancelled: true }
    entry.cancelled = true
    return this.stop(entry)
  }

  async closeOwner(owner) {
    this.closedOwners.add(owner)
    const entries = [...this.active.values()].filter(entry => entry.owner === owner)
    for (const entry of entries) entry.cancelled = true
    const outcomes = await Promise.allSettled(entries.map(entry => this.stop(entry)))
    const failed = outcomes.find(result => result.status === 'rejected')
    if (failed) throw failed.reason
  }

  async close() {
    this.closed = true
    const entries = [...this.active.values()]
    for (const entry of entries) entry.cancelled = true
    const outcomes = await Promise.allSettled(entries.map(entry => this.stop(entry)))
    const failed = outcomes.find(result => result.status === 'rejected')
    if (failed) throw failed.reason
  }
}
