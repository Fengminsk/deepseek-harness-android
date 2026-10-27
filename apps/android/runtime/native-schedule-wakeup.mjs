const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const ISO_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/u
const SUPERSEDED = Symbol('superseded schedule projection')
const REPORT_CODES = new Set(['catalog_read_failed', 'invalid_catalog', 'schedule-wakeup/begin-failed',
  'schedule-wakeup/invalid-begin', 'schedule-wakeup/invalid-subscription', 'schedule-wakeup/invalid-timeout',
  'schedule-wakeup/update-uncertain', 'schedule-wakeup/close-unsettled', 'schedule-wakeup/unsubscribe-failed',
  'schedule-wakeup/revision-exhausted'])

function failure(code, cause) {
  return Object.assign(new Error(`Android schedule wake-up projection: ${code}`, { cause }), {
    code: `schedule-wakeup/${code}`,
  })
}

function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key))
}

function positiveTimeout(value) {
  if (!Number.isSafeInteger(value) || value < 1 || value > 0x7fffffff) throw failure('invalid-timeout')
  return value
}

/** Discard all reminder content and identities before crossing the native boundary. */
function project(catalog) {
  if (!Array.isArray(catalog)) throw failure('invalid-catalog')
  let activeCount = 0, nextDueAtMs = null
  for (const entry of catalog) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)
      || !['active', 'inactive'].includes(entry.status)) throw failure('invalid-catalog')
    // An inactive reminder never rearms, even if its retained timestamp is old.
    if (entry.status === 'inactive') continue
    if (typeof entry.scheduledAt !== 'string' || !ISO_INSTANT.test(entry.scheduledAt)) throw failure('invalid-catalog')
    const due = Date.parse(entry.scheduledAt)
    if (!Number.isSafeInteger(due)) throw failure('invalid-catalog')
    // Reject Date.parse's normalization of impossible dates such as February 30.
    const normalized = entry.scheduledAt.replace(/(?:\.(\d{1,3}))?Z$/u,
      (_match, fraction) => `.${(fraction ?? '').padEnd(3, '0')}Z`)
    if (new Date(due).toISOString() !== normalized) throw failure('invalid-catalog')
    activeCount++
    // A retained pre-epoch target is already due, not an invalid empty catalog.
    const target = Math.max(0, due)
    nextDueAtMs = nextDueAtMs === null ? target : Math.min(nextDueAtMs, target)
  }
  return { state: 'ready', nextDueAtMs, activeCount, reason: null }
}

/**
 * Read-only mirror of the original ScheduleService's nearest active obligation.
 * Native owns generation, alarm authorization and visible scheduling state. This
 * owner never sends Session input, changes a task, or replaces the core timer.
 */
export class NativeScheduleWakeup {
  constructor({ invoke, transport, subscribe, warn, limits }) {
    if (typeof invoke !== 'function' || typeof transport?.request !== 'function'
      || typeof subscribe !== 'function' || typeof warn !== 'function' || typeof limits !== 'function') {
      throw new TypeError('Schedule wake-up owner requires its API, native transport, events, logger and limits')
    }
    Object.assign(this, { invoke, transport, subscribe, warn, limits })
    this.closed = false
    this.stopped = false
    this.revision = 0
    this.change = 0
    this.processed = 0
    this.operations = new Set()
  }

  start() {
    if (this.closed) return Promise.reject(failure('closed'))
    if (this.started) return this.started
    this.started = Promise.resolve().then(async () => {
      if (this.closed) throw failure('closed')
      // Install before the baseline read so a committed change cannot be lost.
      this.unsubscribe = this.subscribe(() => {
        if (this.closed || this.stopped) return
        this.change++
        if (this.generation) void this.drive().catch(error => this.stop(error))
      })
      if (typeof this.unsubscribe !== 'function') throw failure('invalid-subscription')
      this.change++
      let identity
      try {
        identity = await this.operation('begin', signal => this.transport.request('native.scheduleWakeup.begin', {}, signal))
      } catch (cause) {
        if (this.closed) throw failure('closed', cause)
        throw failure('begin-failed', cause)
      }
      if (this.closed) throw failure('closed')
      if (!exactKeys(identity, ['version', 'generation']) || identity.version !== 1
        || typeof identity.generation !== 'string' || !UUID.test(identity.generation)) throw failure('invalid-begin')
      this.generation = identity.generation
      await this.drive()
    }).catch(error => {
      if (!this.closed) this.stop(error)
      throw error
    })
    return this.started
  }

  drive() {
    if (this.running) return this.running
    const running = Promise.resolve().then(() => this.drain())
    this.running = running
    void running.then(() => {
      if (this.running === running) this.running = undefined
      // A change may land between drain finishing and this settlement callback.
      if (!this.closed && !this.stopped && this.processed !== this.change) {
        void this.drive().catch(error => this.stop(error))
      }
    }, error => {
      // Close admission in the first rejection handler, before another event
      // can observe an empty work slot after an uncertain native update.
      this.stop(error)
      if (this.running === running) this.running = undefined
    })
    return running
  }

  async drain() {
    while (!this.closed && !this.stopped && this.processed !== this.change) {
      const observed = this.change
      let projection, readTimedOut = false
      try {
        projection = project(await this.operation('catalog', signal => this.invoke('schedule', 'catalog', {}, signal)))
      } catch (cause) {
        if (this.closed) return
        readTimedOut = cause?.code === 'schedule-wakeup/catalog-timeout'
        projection = { state: 'unavailable', nextDueAtMs: null, activeCount: null,
          reason: cause?.code === 'schedule-wakeup/invalid-catalog' ? 'invalid_catalog' : 'catalog_read_failed' }
      }
      if (this.closed || this.stopped) return
      // A read that crossed a committed change cannot rearm an obsolete target.
      // An unretired timed-out provider cannot be replaced with another read.
      if (observed !== this.change && !readTimedOut) continue
      if (this.revision === Number.MAX_SAFE_INTEGER) throw failure('revision-exhausted')
      const request = { version: 1, generation: this.generation, revision: ++this.revision, ...projection }
      let acknowledgment
      try {
        acknowledgment = await this.operation('update', signal => {
          // operation enters asynchronously; recheck at the actual send point.
          if (this.closed || observed !== this.change && !readTimedOut) return SUPERSEDED
          return this.transport.request('native.scheduleWakeup.update', request, signal)
        })
      } catch (cause) {
        this.updateUncertain = true
        throw failure('update-uncertain', cause)
      }
      if (acknowledgment === SUPERSEDED) continue
      if (!exactKeys(acknowledgment, ['version', 'generation', 'revision', 'accepted'])
        || acknowledgment.version !== 1 || acknowledgment.generation !== this.generation
        || acknowledgment.revision !== request.revision || acknowledgment.accepted !== true) {
        this.updateUncertain = true
        throw failure('update-uncertain')
      }
      this.processed = observed
      if (projection.state === 'unavailable') this.report(projection.reason)
      if (readTimedOut) {
        this.stopped = true
        return
      }
    }
  }

  /** Deadline abandonment does not prove that a native write was cancelled. */
  async operation(kind, work) {
    const milliseconds = positiveTimeout(this.limits().requestTimeoutMs)
    const abort = new AbortController()
    const entry = { kind, abort, done: null }
    this.operations.add(entry)
    let timeout, rejectAborted
    const abandoned = new Promise((_resolve, reject) => { rejectAborted = reject })
    const onAbort = () => rejectAborted(abort.signal.reason)
    abort.signal.addEventListener('abort', onAbort, { once: true })
    entry.done = Promise.resolve().then(() => {
      abort.signal.throwIfAborted()
      return work(abort.signal)
    }).finally(() => { this.operations.delete(entry) })
    timeout = setTimeout(() => abort.abort(failure(`${kind}-timeout`)), milliseconds)
    try { return await Promise.race([entry.done, abandoned]) }
    finally {
      clearTimeout(timeout)
      abort.signal.removeEventListener('abort', onAbort)
    }
  }

  report(code) {
    // Never log raw catalog/provider failures: they can contain reminder text.
    const safeCode = REPORT_CODES.has(code) ? code : 'schedule-wakeup/failed'
    try { this.warn(`Android schedule wake-up projection unavailable (${safeCode}); inspect scheduled-task status before relying on background delivery.`) }
    catch { console.error('Android schedule wake-up projection unavailable; diagnostic logger failed.') }
  }

  stop(error) {
    if (this.stopped) return
    this.stopped = true
    this.report(error?.code ?? 'schedule-wakeup/failed')
  }

  close() {
    if (this.closing) return this.closing
    this.closed = true
    this.closing = this.finishClose()
    return this.closing
  }

  async finishClose() {
    let unsubscribeFailure
    try { this.unsubscribe?.() } catch (cause) { unsubscribeFailure = cause }
    // Preserve accepted future alarms. Closing is not an empty task catalog.
    for (const entry of this.operations) if (entry.kind !== 'update') entry.abort.abort(failure('closed'))
    const pending = [...this.operations].map(entry => entry.done)
    if (this.started) pending.push(this.started)
    if (this.running) pending.push(this.running)
    let timeout
    try {
      const outcomes = await Promise.race([
        Promise.allSettled(pending),
        new Promise((_resolve, reject) => {
          timeout = setTimeout(() => reject(failure('close-unsettled')), positiveTimeout(this.limits().closeTimeoutMs))
        }),
      ])
      if (this.updateUncertain || outcomes.some(result => result.status === 'rejected'
        && result.reason?.code === 'schedule-wakeup/update-uncertain')) {
        throw failure('update-uncertain')
      }
      if (unsubscribeFailure) throw failure('unsubscribe-failed', unsubscribeFailure)
    } catch (error) {
      // Service disposal must revoke this generation. Local RPC abandonment
      // alone cannot establish whether an unanswered update armed an alarm.
      for (const entry of this.operations) entry.abort.abort(failure('closed'))
      this.report(error?.code ?? 'schedule-wakeup/close-failed')
      throw error
    } finally { clearTimeout(timeout) }
  }
}
