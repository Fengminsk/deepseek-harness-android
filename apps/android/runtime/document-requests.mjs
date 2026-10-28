import { randomUUID } from 'node:crypto'

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
function abortError() { return Object.assign(new Error('文件操作已取消'), { name: 'AbortError' }) }

/** Own prepared native requests until cancellation is acknowledged; App owners come from Binder. */
export class DocumentRequests {
  constructor(transport, { method, validate, execute, maxRequests, prepareParams = () => ({}) }) {
    this.transport = transport
    this.method = method
    this.validate = validate
    this.execute = execute
    this.prepareParams = prepareParams
    this.maxRequests = maxRequests
    this.active = new Map()
    this.closedOwners = new Set()
    this.closed = false
  }

  /** App owner is injected by Binder; tools use their own session/call owner. */
  async run(params, { owner, signal } = {}) {
    this.validate(params)
    if (typeof owner !== 'string' || owner === '' || owner.length > 200) throw new TypeError('Document request owner is required')
    if (this.closed) throw new Error('File request service is closed')
    if (this.closedOwners.has(owner)) throw new Error('File request owner is disconnected')
    if (signal?.aborted) throw abortError()
    const key = `${owner}\0${params.requestId}`
    if (this.active.has(key)) throw new Error('Document request is already running')
    const maximum = this.maxRequests()
    if (!Number.isInteger(maximum) || maximum < 1 || maximum > 4) throw new Error('Invalid document concurrency limit')
    if (this.active.size >= maximum) throw new Error('文件请求过多，请等待已有请求结束')
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
      this.transport.request(`${this.method}.prepare`, { id: entry.id, ...this.prepareParams(params) }))
    signal?.addEventListener('abort', onAbort, { once: true })
    if (signal?.aborted) onAbort()
    let failure, result
    try {
      await entry.prepared
      if (entry.cancelled) throw abortError()
      result = await this.execute(params, payload => this.transport.request(
        `${this.method}.run`, { ...payload, id: entry.id }))
      if (entry.cancelled || signal?.aborted) throw abortError()
    } catch (error) {
      failure = error
      throw error
    } finally {
      signal?.removeEventListener('abort', onAbort)
      // Both completed runs and preparation-only requests require retirement
      // acknowledgement before this owner releases its admission slot.
      try { await this.stop(entry) }
      catch (cleanup) {
        entry.finished = true
        if (failure) throw new AggregateError([failure, cleanup], `${failure.message}; ${cleanup.message}`)
        throw cleanup
      }
      this.active.delete(key)
      entry.finished = true
    }
    if (entry.cancelled || signal?.aborted) throw abortError()
    return result
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
      const result = await this.transport.request(`${this.method}.cancel`, { id: entry.id })
      if (result?.cancelled !== true) throw new Error('文件提供方仍在停止读取，请稍后重试取消；尚未确认取消完成')
      if (entry.finished) this.active.delete(entry.key)
      return { cancelled: true }
    })()
    entry.stopping = operation
    try { return await operation }
    catch (error) { entry.stopping = null; throw error }
  }

  /** Returns only after the native request owner confirms termination. */
  async cancel(params, { owner } = {}) {
    if (!uuid.test(params.requestId ?? '') || typeof owner !== 'string' || owner === '') throw new TypeError('Invalid document cancellation')
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
