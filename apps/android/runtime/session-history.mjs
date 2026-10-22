import { randomUUID } from 'node:crypto'
import { SessionId } from '@deepseek-ai/dsh-session'
import { presentSessionEvent } from './live-state.mjs'

const PAGE_SIZE = 200
const DEFAULT_LEASE_MS = 120_000
const DEFAULT_RETAINED_BYTES = 128 * 1024 * 1024

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

    const inspection = await this.controller.inspect(SessionId(sessionId))
    if (this.#closed) throw historyError('SESSION_HISTORY_UNAVAILABLE', 'Session history reader has closed.')
    const events = inspection.events.slice()
    const visible = page(events, offset)
    // Offset-only reads remain compatible with diagnostic callers. Only an
    // opening page needs a lease; short histories release immediately.
    if (offset !== 0 || visible.length < PAGE_SIZE) return { events: visible }
    return { events: visible, snapshot: this.#retain(sessionId, events) }
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
  const inspection = await controller.inspect(SessionId(sessionId))
  return { events: page(inspection.events, offset) }
}
