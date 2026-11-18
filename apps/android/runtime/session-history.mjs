import { randomUUID } from 'node:crypto'
import { SessionId } from '@deepseek-ai/dsh-session'
import { presentSessionEvent } from './live-state.mjs'

const PAGE_SIZE = 200
const MAX_WHOLE_LOG_PAGES = 200
const DEFAULT_LEASE_MS = 120_000
const DEFAULT_RETAINED_BYTES = 128 * 1024 * 1024
const WINDOW_MESSAGES = 80
const WINDOW_MAX_MESSAGES = 200
const WINDOW_MAX_EVENTS = 500
const WINDOW_MAX_BYTES = 4 * 1024 * 1024
/** Incremental (afterSeq) defaults: one small newest chunk per poll. */
const INCREMENTAL_MAX_EVENTS = 120
const INCREMENTAL_MAX_BYTES = 1024 * 1024
/** Upper bound of older pages scanned to bridge a large afterSeq gap. */
const MAX_INCREMENTAL_SCAN_PAGES = 20

function validateAddress(params) {
  if (typeof params?.sessionId !== 'string' || !params.sessionId.trim()) {
    throw new TypeError('sessionId must be a non-empty string')
  }
  const offset = params.offset ?? 0
  if (!Number.isSafeInteger(offset) || offset < 0) {
    throw new TypeError('offset must be a non-negative integer')
  }
  if (params.snapshot !== undefined && (typeof params.snapshot !== 'string'
    || params.snapshot.length === 0 || params.snapshot.length > 128)) {
    throw new TypeError('snapshot must be a non-empty token')
  }
  return { sessionId: params.sessionId, offset, snapshot: params.snapshot }
}

function page(events, offset) {
  // Session seq is normally dense, but finding the first matching event also
  // keeps this carrier correct for a nonzero inherited event prefix.
  let left = 0, right = events.length
  while (left < right) {
    const middle = left + Math.floor((right - left) / 2)
    if (events[middle].seq < offset) left = middle + 1
    else right = middle
  }
  return events.slice(left, left + PAGE_SIZE).map(presentSessionEvent)
}

function historyError(code, message) {
  return Object.assign(new Error(message), { code })
}

function validateWindowAddress(params) {
  if (typeof params?.sessionId !== 'string' || !params.sessionId.trim()) {
    throw new TypeError('sessionId must be a non-empty string')
  }
  for (const field of ['beforeSeq', 'throughSeq', 'afterSeq']) {
    const value = params[field]
    if (value !== undefined && (!Number.isSafeInteger(value) || value < 0 || Object.is(value, -0))) {
      throw new TypeError(`${field} must be a non-negative safe integer`)
    }
  }
  if (params.beforeSeq !== undefined && params.throughSeq === undefined) {
    throw new TypeError('throughSeq is required when reading an older window')
  }
  if (params.afterSeq !== undefined && params.beforeSeq !== undefined) {
    throw new TypeError('afterSeq and beforeSeq are mutually exclusive')
  }
  if (params.afterSeq !== undefined && params.throughSeq !== undefined) {
    throw new TypeError('afterSeq reads to the observed log end; omit throughSeq')
  }
  const limits = windowLimits(params, params.afterSeq !== undefined)
  return { ...params, ...limits }
}

/**
 * Resolve optional per-request window limits.
 * @param params - request parameters.
 * @param incremental - whether this is an afterSeq read (smaller defaults).
 * @returns validated maxEvents/maxBytes.
 */
function windowLimits(params, incremental) {
  const maxEvents = params.maxEvents === undefined
    ? (incremental ? INCREMENTAL_MAX_EVENTS : WINDOW_MAX_EVENTS)
    : params.maxEvents
  const maxBytes = params.maxBytes === undefined
    ? (incremental ? INCREMENTAL_MAX_BYTES : WINDOW_MAX_BYTES)
    : params.maxBytes
  if (!Number.isSafeInteger(maxEvents) || maxEvents < 1 || maxEvents > WINDOW_MAX_EVENTS) {
    throw new TypeError(`maxEvents must be an integer in 1..${WINDOW_MAX_EVENTS}`)
  }
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > WINDOW_MAX_BYTES) {
    throw new TypeError(`maxBytes must be an integer in 1..${WINDOW_MAX_BYTES}`)
  }
  return { maxEvents, maxBytes }
}

function outlineFrom(snapshot) {
  if (snapshot?.kind !== 'sequenced') return []
  const value = snapshot.values?.turnOutline
  if (!Array.isArray(value)) return []
  const turns = []
  let previousTurn = -1
  let previousSeq = -1
  for (const item of value) {
    if (!item || !Number.isSafeInteger(item.turn) || item.turn < 0
      || !Number.isSafeInteger(item.seq) || item.seq < 0
      || item.turn <= previousTurn || item.seq <= previousSeq) return []
    turns.push({ turn: item.turn, seq: item.seq,
      prompt: typeof item.prompt === 'string' ? item.prompt : '',
      response: typeof item.response === 'string' ? item.response : '' })
    previousTurn = item.turn
    previousSeq = item.seq
  }
  return turns
}

function boundedWindow(records, hasMore, maxEvents = WINDOW_MAX_EVENTS, maxBytes = WINDOW_MAX_BYTES) {
  const events = []
  let bytes = 0
  let nextSeq = Number.MAX_SAFE_INTEGER
  for (let index = records.length - 1; index >= 0; index--) {
    const event = records[index]?.event
    if (!event || !Number.isSafeInteger(event.seq) || event.seq < 0 || event.seq >= nextSeq) {
      throw historyError('SESSION_HISTORY_INVALID_PAGE', 'The original Session page contains an invalid event.')
    }
    const presented = presentSessionEvent(event)
    const size = Buffer.byteLength(JSON.stringify(presented), 'utf8')
    if (size > maxBytes) {
      throw historyError('SESSION_HISTORY_EVENT_TOO_LARGE', 'One Session event exceeds the reading window budget.')
    }
    if (events.length >= maxEvents || bytes + size > maxBytes) break
    events.push(presented)
    bytes += size
    nextSeq = event.seq
  }
  events.reverse()
  if (events.length === 0 && records.length > 0) {
    throw historyError('SESSION_HISTORY_INVALID_PAGE', 'The original Session page made no progress.')
  }
  if (events.length === 0 && hasMore) {
    throw historyError('SESSION_HISTORY_INVALID_PAGE', 'The original Session page has no cursor for older events.')
  }
  return { events, hasMore: hasMore || events.length < records.length,
    firstSeq: events[0]?.seq ?? null }
}

/**
 * Hold one original-controller observation across all UI pages. This avoids
 * repeating a full persistence read for every 200 events. The controller's
 * readonly interrupted-history repair remains the sole source of history.
 */
export class AppSessionHistory {
  #leases = new Map()
  #retainedBytes = 0
  #closed = false

  constructor(controller, {
    leaseMs = DEFAULT_LEASE_MS,
    maxLeases = 4,
    maxRetainedBytes = DEFAULT_RETAINED_BYTES,
    now = Date.now,
  } = {}) {
    if (!Number.isSafeInteger(leaseMs) || leaseMs < 1
      || !Number.isSafeInteger(maxLeases) || maxLeases < 1
      || !Number.isSafeInteger(maxRetainedBytes) || maxRetainedBytes < 1) {
      throw new TypeError('History lease limits must be positive integers')
    }
    this.controller = controller
    this.leaseMs = leaseMs
    this.maxLeases = maxLeases
    this.maxRetainedBytes = maxRetainedBytes
    this.now = now
  }

  #drop(token) {
    const lease = this.#leases.get(token)
    if (!lease) return false
    clearTimeout(lease.timer)
    this.#retainedBytes -= lease.bytes
    this.#leases.delete(token)
    return true
  }

  #sweep() {
    const time = this.now()
    for (const [token, lease] of this.#leases) {
      if (lease.expiresAt <= time) this.#drop(token)
    }
  }

  #touch(token, lease) {
    clearTimeout(lease.timer)
    lease.expiresAt = this.now() + this.leaseMs
    lease.timer = setTimeout(() => this.#drop(token), this.leaseMs)
    lease.timer.unref?.()
  }

  #retain(sessionId, events) {
    // A few JSON event payloads can dwarf the array. Bound their cumulative
    // retained size rather than merely counting leases or event references.
    let bytes = 0
    for (const event of events) {
      bytes += Buffer.byteLength(JSON.stringify(event), 'utf8')
      if (bytes > this.maxRetainedBytes) break
    }
    if (bytes > this.maxRetainedBytes) {
      throw historyError('SESSION_HISTORY_TOO_LARGE', 'Session history exceeds the temporary reading budget.')
    }
    this.#sweep()
    while (this.#leases.size >= this.maxLeases || this.#retainedBytes + bytes > this.maxRetainedBytes) {
      const oldest = this.#leases.keys().next().value
      if (oldest === undefined) break
      this.#drop(oldest)
    }
    const token = randomUUID()
    const lease = { sessionId, events, bytes, expiresAt: 0, timer: undefined }
    this.#leases.set(token, lease)
    this.#retainedBytes += bytes
    this.#touch(token, lease)
    return token
  }

  /** One page of a stable, read-only original-controller observation. */
  async read(params) {
    const { sessionId, offset, snapshot } = validateAddress(params)
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    this.#sweep()
    if (snapshot !== undefined) {
      const lease = this.#leases.get(snapshot)
      if (!lease || lease.sessionId !== sessionId) {
        throw historyError('SESSION_HISTORY_SNAPSHOT_EXPIRED', 'Session history page expired. Reload the conversation.')
      }
      const events = page(lease.events, offset)
      if (events.length < PAGE_SIZE) this.#drop(snapshot)
      else this.#touch(snapshot, lease)
      return { events, ...(events.length === PAGE_SIZE ? { snapshot } : {}) }
    }

    const events = await this.readWholeLog(sessionId)
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    const visible = page(events, offset)
    // Offset-only reads remain compatible with diagnostic callers. Only an
    // opening page needs a lease; short histories release immediately.
    if (offset !== 0 || visible.length < PAGE_SIZE) return { events: visible }
    return { events: visible, snapshot: this.#retain(sessionId, events) }
  }

  /**
   * Read every recorded event at one projection cut through the original
   * message-aligned page service. Backward pages pin the same `throughSeq`, so
   * concurrent appends cannot shift the cut between requests.
   * @param {string} sessionId - durable Session identity.
   * @returns {Promise<object[]>} the recorded events in log order.
   */
  async readWholeLog(sessionId) {
    const signal = new AbortController().signal
    const address = { kind: 'session', sessionId: SessionId(sessionId) }
    const baseline = await this.controller.projections({ sessionId: SessionId(sessionId) }, signal)
    if (baseline?.kind !== 'sequenced') {
      throw historyError('SESSION_HISTORY_PROJECTION_UNAVAILABLE', 'An exact Session history cursor is unavailable.')
    }
    const collected = []
    let beforeSeq
    for (let pages = 0; pages < MAX_WHOLE_LOG_PAGES; pages += 1) {
      const result = await this.controller.events({
        address,
        throughSeq: baseline.asOfSeq,
        ...(beforeSeq === undefined ? {} : { beforeSeq }),
        maxMessages: PAGE_SIZE,
      }, signal)
      const records = result?.records ?? []
      if (records.length === 0) break
      collected.unshift(...records.map(record => record.event))
      if (!result.hasMore) return collected
      const oldest = records[0].event.seq
      if (beforeSeq !== undefined && oldest >= beforeSeq) {
        throw historyError('SESSION_HISTORY_INVALID_PAGE', 'An older Session page did not move backward.')
      }
      beforeSeq = oldest
    }
    if (collected.length === 0) return collected
    throw historyError('SESSION_HISTORY_TOO_LARGE', 'Session history exceeds the complete-read page budget.')
  }

  /** Exact original whole-session projection, without scanning the event log. */
  async turnOutline(params) {
    const { sessionId } = validateWindowAddress(params)
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    const snapshot = await this.controller.projections({ sessionId: SessionId(sessionId) }, new AbortController().signal)
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    return { turns: outlineFrom(snapshot), asOfSeq: snapshot?.kind === 'sequenced' ? snapshot.asOfSeq : null }
  }

  /** A bounded native window from the original cold-safe, Turn-aware page service. */
  async readWindow(params) {
    const { sessionId, beforeSeq, afterSeq, maxEvents, maxBytes } = validateWindowAddress(params)
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    if (afterSeq !== undefined) {
      return this.readNewerWindow({ sessionId, afterSeq, maxEvents, maxBytes })
    }
    let throughSeq = params.throughSeq
    let turns
    if (throughSeq === undefined) {
      const snapshot = await this.controller.projections({ sessionId: SessionId(sessionId) }, new AbortController().signal)
      if (snapshot?.kind !== 'sequenced') {
        throw historyError('SESSION_HISTORY_PROJECTION_UNAVAILABLE', 'An exact Session history cursor is unavailable.')
      }
      throughSeq = snapshot.asOfSeq
      turns = outlineFrom(snapshot)
    }
    if (throughSeq < -1 || !Number.isSafeInteger(throughSeq)) {
      throw historyError('SESSION_HISTORY_INVALID_CURSOR', 'The Session projection cursor is invalid.')
    }
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    const page = await this.controller.page({
      address: { kind: 'session', sessionId: SessionId(sessionId) },
      throughSeq,
      ...(beforeSeq === undefined ? {} : { beforeSeq }),
      maxMessages: WINDOW_MAX_MESSAGES,
      turnWindow: { minMessages: WINDOW_MESSAGES, minTurns: 2 },
    }, new AbortController().signal)
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    const bounded = boundedWindow(page.records, page.hasMore, maxEvents, maxBytes)
    if (beforeSeq !== undefined && bounded.firstSeq !== null && bounded.firstSeq >= beforeSeq) {
      throw historyError('SESSION_HISTORY_INVALID_PAGE', 'An older Session page did not move backward.')
    }
    return { ...bounded, throughSeq, ...(turns === undefined ? {} : { turns }) }
  }


  /**
   * Read the contiguous newer events after `afterSeq` without re-reading the
   * window the App already has. Newest page first, then older pages only when
   * the newest page does not reach `afterSeq`; a gap that cannot be bridged is
   * reported as `resetRequired` so the App falls back to a full first page.
   * @param params - validated session, afterSeq and per-request limits.
   * @returns `{events, throughSeq, firstSeq, hasMore, truncated?, resetRequired?}`.
   */
  async readNewerWindow({ sessionId, afterSeq, maxEvents, maxBytes }) {
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    const signal = new AbortController().signal
    const snapshot = await this.controller.projections({ sessionId: SessionId(sessionId) }, signal)
    if (snapshot?.kind !== 'sequenced') {
      throw historyError('SESSION_HISTORY_PROJECTION_UNAVAILABLE', 'An exact Session history cursor is unavailable.')
    }
    const throughSeq = snapshot.asOfSeq
    if (!Number.isSafeInteger(throughSeq) || throughSeq < -1) {
      throw historyError('SESSION_HISTORY_INVALID_CURSOR', 'The Session projection cursor is invalid.')
    }
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    const address = { kind: 'session', sessionId: SessionId(sessionId) }
    const turnWindow = { minMessages: WINDOW_MESSAGES, minTurns: 2 }
    let page = await this.controller.page({
      address, throughSeq, maxMessages: WINDOW_MAX_MESSAGES, turnWindow,
    }, signal)
    let records = page?.records ?? []
    let moreOlder = page?.hasMore === true
    let scans = 0
    let first = records[0]?.event?.seq
    while (first !== undefined && first > afterSeq + 1 && moreOlder && scans < MAX_INCREMENTAL_SCAN_PAGES) {
      const older = await this.controller.page({
        address, throughSeq, beforeSeq: first, maxMessages: WINDOW_MAX_MESSAGES, turnWindow,
      }, signal)
      const olderRecords = older?.records ?? []
      if (olderRecords.length === 0) break
      const olderFirst = olderRecords[0].event.seq
      if (olderFirst >= first) {
        throw historyError('SESSION_HISTORY_INVALID_PAGE', 'An older Session page did not move backward.')
      }
      records = [...olderRecords, ...records]
      moreOlder = older.hasMore === true
      first = olderFirst
      scans += 1
    }
    if (first !== undefined && first > afterSeq + 1 && moreOlder) {
      return { events: [], throughSeq, firstSeq: null, hasMore: true, resetRequired: true }
    }
    const events = []
    let bytes = 0
    let truncated = false
    for (const record of records) {
      const event = record?.event
      if (!event || !Number.isSafeInteger(event.seq) || event.seq < 0) {
        throw historyError('SESSION_HISTORY_INVALID_PAGE', 'The original Session page contains an invalid event.')
      }
      if (event.seq <= afterSeq) continue
      const presented = presentSessionEvent(event)
      const size = Buffer.byteLength(JSON.stringify(presented), 'utf8')
      if (size > maxBytes) {
        throw historyError('SESSION_HISTORY_EVENT_TOO_LARGE', 'One Session event exceeds the reading window budget.')
      }
      if (events.length >= maxEvents || bytes + size > maxBytes) {
        truncated = true
        break
      }
      events.push(presented)
      bytes += size
    }
    return {
      events,
      throughSeq,
      firstSeq: events[0]?.seq ?? null,
      hasMore: moreOlder,
      ...(truncated ? { truncated: true } : {}),
    }
  }
  release(params) {
    const { sessionId, snapshot } = validateAddress(params)
    if (snapshot === undefined) throw new TypeError('snapshot is required')
    const lease = this.#leases.get(snapshot)
    if (lease?.sessionId === sessionId) this.#drop(snapshot)
    return { released: lease?.sessionId === sessionId }
  }

  releaseAll() {
    for (const token of this.#leases.keys()) this.#drop(token)
  }

  close() {
    this.#closed = true
    this.releaseAll()
  }
}

/** Compatibility helper for one-page callers and narrow incident tests. */
export async function readSessionHistory(controller, params) {
  const { sessionId, offset } = validateAddress(params)
  const history = new AppSessionHistory(controller)
  try {
    const events = await history.readWholeLog(sessionId)
    return { events: page(events, offset) }
  } finally {
    history.close()
  }
}
