/** Read a desktop-owned Session through its owning controller. */
const MAX_EVENTS = 500
const MAX_BYTES = 4 * 1024 * 1024
const MAX_SCAN_PAGES = 20

interface EventRecord { readonly event: Record<string, unknown> & { readonly seq: number } }
interface Page { readonly records: readonly EventRecord[]; readonly hasMore: boolean }
interface Projection { readonly kind: string; readonly asOfSeq?: number; readonly values?: { readonly turnOutline?: unknown } }
/**
 * Desktop-owned Session controller the relay reads through.
 *
 * A sequenced projection supplies the newest readable sequence number; a page
 * returns retained events ending at or before a requested sequence number.
 */
export interface DesktopSessionController {
  /** Turn outline plus `asOfSeq` for one session. */
  projections(request: { sessionId: string }, signal: AbortSignal): Promise<Projection>
  /** One page of retained events up to `throughSeq`, and before `beforeSeq`. */
  page(request: {
    address: { kind: 'session'; sessionId: string }; throughSeq: number; beforeSeq?: number
    maxMessages: number; turnWindow: { minMessages: number; minTurns: number }
  }, signal: AbortSignal): Promise<Page>
}

/**
 * Cursor and budget of one Session event window.
 *
 * `afterSeq` streams forward and cannot be combined with another cursor;
 * `beforeSeq` reads backward and requires `throughSeq`.
 */
export interface WindowRequest {
  /** Session whose events are read. */
  readonly sessionId: string
  /** Return events after this sequence number; a forward read. */
  readonly afterSeq?: number
  /** Return events before this sequence number; requires `throughSeq`. */
  readonly beforeSeq?: number
  /** Newest sequence number the window may include; defaults to the projection's `asOfSeq`. */
  readonly throughSeq?: number
  /** Event cap; defaults to 500 for a backward read and 120 for a forward read. */
  readonly maxEvents?: number
  /** Byte cap over serialized events; defaults to 4 MiB backward and 1 MiB forward. */
  readonly maxBytes?: number
}

function validCursor(value: unknown): value is number {
  return Number.isSafeInteger(value) && typeof value === 'number' && value >= 0 && !Object.is(value, -0)
}

function pageRequest(sessionId: string, throughSeq: number, beforeSeq?: number) {
  return {
    address: { kind: 'session' as const, sessionId }, throughSeq,
    ...(beforeSeq === undefined ? {} : { beforeSeq }),
    maxMessages: 200, turnWindow: { minMessages: 80, minTurns: 2 },
  }
}

function turnsOf(snapshot: Projection): unknown[] {
  const turns = snapshot.values?.turnOutline
  return Array.isArray(turns) ? turns : []
}

/**
 * The same cursor and byte-budget semantics as the Android facade's readWindow.
 *
 * Invalid cursors, budgets, or an event over the byte cap reject the read.
 * @param controller - controller that owns the desktop Session.
 * @param request - cursor and budget of the window to read.
 * @returns the window's events with `throughSeq` and `firstSeq`; a forward
 * read also reports `hasMore` and `truncated`, or `resetRequired` when the gap
 * from `afterSeq` exceeds the page scan limit, while a backward read adds the
 * session's `turns`.
 */
export async function readDesktopSessionWindow(controller: DesktopSessionController, request: WindowRequest): Promise<unknown> {
  if (typeof request.sessionId !== 'string' || request.sessionId.trim() === '') throw new Error('sessionId is required')
  for (const cursor of [request.afterSeq, request.beforeSeq, request.throughSeq]) {
    if (cursor !== undefined && !validCursor(cursor)) throw new Error('invalid Session cursor')
  }
  if (request.beforeSeq !== undefined && request.throughSeq === undefined) throw new Error('throughSeq is required')
  if (request.afterSeq !== undefined && (request.beforeSeq !== undefined || request.throughSeq !== undefined)) {
    throw new Error('afterSeq cannot be combined with another cursor')
  }
  const maxEvents = request.maxEvents ?? (request.afterSeq === undefined ? 500 : 120)
  const maxBytes = request.maxBytes ?? (request.afterSeq === undefined ? MAX_BYTES : 1024 * 1024)
  if (!Number.isSafeInteger(maxEvents) || maxEvents < 1 || maxEvents > MAX_EVENTS) throw new Error('invalid maxEvents')
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > MAX_BYTES) throw new Error('invalid maxBytes')

  const signal = new AbortController().signal
  const snapshot = request.throughSeq === undefined
    ? await controller.projections({ sessionId: request.sessionId }, signal)
    : undefined
  const throughSeq = request.throughSeq ?? snapshot?.asOfSeq
  if (snapshot !== undefined && snapshot.kind !== 'sequenced') throw new Error('Session projection unavailable')
  if (typeof throughSeq !== 'number' || !Number.isSafeInteger(throughSeq) || throughSeq < -1) {
    throw new Error('Session cursor unavailable')
  }
  if (request.afterSeq !== undefined) {
    let page = await controller.page(pageRequest(request.sessionId, throughSeq), signal)
    let records = [...page.records]
    let first = records[0]?.event.seq
    let scans = 0
    while (first !== undefined && first > request.afterSeq + 1 && page.hasMore && scans < MAX_SCAN_PAGES) {
      page = await controller.page(pageRequest(request.sessionId, throughSeq, first), signal)
      if (page.records.length === 0 || page.records[0]!.event.seq >= first) break
      records = [...page.records, ...records]
      first = records[0]?.event.seq
      scans++
    }
    if (first !== undefined && first > request.afterSeq + 1 && page.hasMore) {
      return { events: [], throughSeq, firstSeq: null, hasMore: true, resetRequired: true }
    }
    const events: EventRecord['event'][] = []
    let bytes = 0
    let truncated = false
    for (const record of records) {
      const event = record.event
      if (event.seq <= request.afterSeq) continue
      const size = Buffer.byteLength(JSON.stringify(event), 'utf8')
      if (size > maxBytes) throw new Error('Session event exceeds window budget')
      if (events.length >= maxEvents || bytes + size > maxBytes) { truncated = true; break }
      events.push(event)
      bytes += size
    }
    return { events, throughSeq, firstSeq: events[0]?.seq ?? null, hasMore: page.hasMore,
      ...(truncated ? { truncated: true } : {}) }
  }

  const page = await controller.page(pageRequest(request.sessionId, throughSeq, request.beforeSeq), signal)
  const events: EventRecord['event'][] = []
  let bytes = 0
  for (const record of [...page.records].reverse()) {
    const event = record.event
    const size = Buffer.byteLength(JSON.stringify(event), 'utf8')
    if (size > maxBytes) throw new Error('Session event exceeds window budget')
    if (events.length >= maxEvents || bytes + size > maxBytes) break
    events.push(event)
    bytes += size
  }
  events.reverse()
  return { events, throughSeq, firstSeq: events[0]?.seq ?? null,
    hasMore: page.hasMore || events.length < page.records.length,
    ...(snapshot === undefined ? {} : { turns: turnsOf(snapshot) }) }
}
