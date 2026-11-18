/**
 * Desktop real-time session event relay for the Plan-B loopback link.
 *
 * The remote-host child process cannot see sessions owned by the desktop DSH
 * process, so without this observer the phone learns about new messages, tool
 * steps, reasoning chunks and running state only from its slower log reads.
 * This observer batches desktop `session/event` and `agent/status` payloads and
 * posts them to the child's pairing-page control API
 * (`POST /api/session/events/relay`), which broadcasts them to already
 * authenticated phones as page-line `session.event` / `session.status`
 * notifications. Nothing here loads an App runtime into the desktop process and
 * neither the profile nor the bundle list changes.
 *
 * Batching: a flush runs {@link DEFAULT_FLUSH_INTERVAL_MS} after the first queued
 * item, keeps every batch at or below {@link MAXIMUM_EVENTS_PER_BATCH} events and
 * {@link MAXIMUM_BATCH_BYTES} bytes, and splits a larger queue into several
 * batches. A single event over the byte budget is dropped, never truncated; a
 * failed batch is dropped, never replayed, so a slow or stopped child can only
 * lose relayed events — never block the desktop Host.
 *
 * Dedupe: events of one session are relayed in ascending `seq`; a repeated or
 * lower `seq` is dropped here and again on the remote-host side. Status changes
 * are coalesced per session so only the latest status of each session enters a
 * batch.
 *
 * Isolation: every subscription callback and every post is wrapped; callback and
 * transport failures log one warning without message text, token or event body.
 * After {@link DEFAULT_FAILURE_LIMIT} consecutive failed flushes the observer
 * stops capturing and reports a {@link Diagnostic} through the bridge state while
 * the remote-host child keeps running.
 *
 * `desktop-notifications.ts` also listens to `session/event` and `agent/status`;
 * the duplication is bounded on purpose because each module owns a different
 * output (page-line §8 notifications versus the raw event relay). Neither module
 * re-registers `interactions.changed`: approvals already travel through the
 * notification relay, and relaying them twice would duplicate phone actions.
 * @module @deepseek-ai/dsh-device-interconnect/host/desktop-session-events
 */

import type { Context } from '@deepseek-ai/cordis'
import type { Diagnostic } from '../types.ts'
import { onDesktopEvent } from './desktop-events.ts'

/** Delay between the first queued event and the batch flush, in milliseconds. */
export const DEFAULT_FLUSH_INTERVAL_MS = 150

/** Largest number of session events in one posted batch. */
export const MAXIMUM_EVENTS_PER_BATCH = 32

/** Largest JSON size of one posted batch, in bytes. */
export const MAXIMUM_BATCH_BYTES = 64 * 1024

/** Backlog ceiling; beyond it the oldest pending events are dropped. */
export const MAXIMUM_PENDING_EVENTS = 512

/** Consecutive failed flushes after which the observer disables itself. */
export const DEFAULT_FAILURE_LIMIT = 20

/** How often relay availability is re-checked, in milliseconds; 0 disables the timer. */
export const DEFAULT_RECONCILE_INTERVAL_MS = 2_000

/** One session's raw desktop events. */
export interface DesktopSessionEventGroup {
  /** Desktop session the events belong to. */
  readonly sessionId: string
  /** Raw session events in ascending `seq` order. */
  readonly events: readonly Record<string, unknown>[]
}

/** One desktop agent status transition. */
export interface DesktopSessionStatusEntry {
  /** Desktop session whose agent changed status. */
  readonly sessionId: string
  /** Desktop agent status; only these two states exist on the Host. */
  readonly status: 'running' | 'idle'
}

/** One batch posted to the remote-host control API. */
export interface DesktopSessionEventsBatch {
  /** Raw events grouped by session, in arrival order. */
  readonly sessions: readonly DesktopSessionEventGroup[]
  /** Coalesced status transitions; the remote host broadcasts them as `session.status`. */
  readonly statuses: readonly DesktopSessionStatusEntry[]
}

/** Options of one desktop session event observer. */
export interface DesktopSessionEventsOptions {
  /** Desktop Host plugin context; events are observed globally. */
  readonly ctx: Context
  /** Posts one batch to the remote-host control API; failures are logged only. */
  readonly post: (batch: DesktopSessionEventsBatch) => Promise<void>
  /**
   * Whether the relay path is available right now (remote-host child running and
   * its pairing page enabled). False unsubscribes and drops the backlog.
   */
  readonly available: () => boolean
  /** Lifecycle log sink; never receives message text, tokens or event bodies. */
  readonly logger: {
    info(message: string, ...rest: unknown[]): void
    warn(message: string, ...rest: unknown[]): void
  }
  /** Flush delay override; defaults to {@link DEFAULT_FLUSH_INTERVAL_MS}. */
  readonly flushIntervalMs?: number
  /** Per-batch event ceiling; defaults to {@link MAXIMUM_EVENTS_PER_BATCH}. */
  readonly maxEventsPerBatch?: number
  /** Per-batch byte ceiling; defaults to {@link MAXIMUM_BATCH_BYTES}. */
  readonly maxBatchBytes?: number
  /** Backlog ceiling; defaults to {@link MAXIMUM_PENDING_EVENTS}. */
  readonly maxPendingEvents?: number
  /** Consecutive failure ceiling; defaults to {@link DEFAULT_FAILURE_LIMIT}. */
  readonly failureLimit?: number
  /** Availability re-check interval; defaults to {@link DEFAULT_RECONCILE_INTERVAL_MS}. */
  readonly reconcileIntervalMs?: number
}

/** One queued raw event with the size measured while queuing it. */
interface PendingEvent {
  readonly sessionId: string
  readonly event: Record<string, unknown>
  readonly bytes: number
}

/** Batch builder group; entries keep their measured JSON size. */
interface MutableGroup {
  readonly sessionId: string
  readonly entries: PendingEvent[]
}

/** Rough JSON overhead of one empty group (`{"sessionId":"","events":[]}`). */
const EMPTY_GROUP_BYTES = 32

/** Rough JSON overhead of an empty batch envelope. */
const EMPTY_BATCH_BYTES = 48

/**
 * Observe desktop session activity and relay it to the remote-host child.
 *
 * `start()` is cheap and idempotent: it subscribes only while
 * {@link DesktopSessionEventsOptions.available} is true and re-checks that gate
 * on a timer, so the observer also recovers when the child is restarted. `stop()`
 * releases every listener and timer and is safe to call more than once.
 */
export class DesktopSessionEvents {
  private readonly options: DesktopSessionEventsOptions
  private readonly disposers: (() => void)[] = []
  private readonly pending: PendingEvent[] = []
  private readonly statuses = new Map<string, DesktopSessionStatusEntry['status']>()
  private readonly lastSeq = new Map<string, number>()
  private readonly lastStatus = new Map<string, DesktopSessionStatusEntry['status']>()
  private flushTimer: NodeJS.Timeout | undefined
  private reconcileTimer: NodeJS.Timeout | undefined
  private started = false
  private closed = false
  private subscribed = false
  private disabled = false
  private disabledProblem: Diagnostic | undefined
  private consecutiveFailures = 0
  private flushing = false
  private overflowed = 0

  /** @param options - context, post callback, availability gate, and limits. */
  constructor(options: DesktopSessionEventsOptions) {
    this.options = options
  }

  /**
   * Start observing; idempotent and a no-op after {@link stop}.
   * @returns no value.
   */
  start(): void {
    if (this.started || this.closed) return
    this.started = true
    this.reconcile()
    const interval = this.options.reconcileIntervalMs ?? DEFAULT_RECONCILE_INTERVAL_MS
    if (interval > 0) {
      this.reconcileTimer = setInterval(() => { this.reconcile() }, interval)
      this.reconcileTimer.unref()
    }
  }

  /**
   * Stop observing, drop the backlog, and clear every timer; idempotent.
   * @returns no value.
   */
  stop(): void {
    if (this.closed) return
    this.closed = true
    if (this.reconcileTimer !== undefined) {
      clearInterval(this.reconcileTimer)
      this.reconcileTimer = undefined
    }
    this.unsubscribe()
    this.dropPending()
  }

  /**
   * The problem the Settings page reports while the observer is disabled.
   * @returns the diagnostic, or undefined while the observer is active.
   */
  problem(): Diagnostic | undefined {
    return this.disabledProblem
  }

  /**
   * Apply the availability gate: subscribe while the relay path is usable,
   * unsubscribe and drop the backlog while it is not or after a disable.
   * Exposed for tests that drive the gate without waiting on the timer.
   * @returns no value.
   */
  reconcile(): void {
    if (!this.started || this.closed) return
    if (this.available() && !this.disabled) {
      if (!this.subscribed) this.subscribe()
      return
    }
    if (this.subscribed) this.unsubscribe()
    this.dropPending()
  }

  /** Read the availability gate; a throwing gate counts as unavailable. */
  private available(): boolean {
    try {
      return this.options.available()
    } catch (error) {
      this.warn('availability gate failed', error)
      return false
    }
  }

  /** Subscribe to the desktop events this observer relays; idempotent by caller. */
  private subscribe(): void {
    this.subscribed = true
    const ctx = this.options.ctx
    const digest = (callback: () => void): void => {
      try {
        callback()
      } catch (error) {
        this.warn('desktop event observer failed', error)
      }
    }
    const register = (event: string, listener: (...args: readonly unknown[]) => void): void => {
      try {
        this.disposers.push(onDesktopEvent(ctx, event, listener))
      } catch (error) {
        this.warn('desktop event subscription failed', error)
      }
    }
    register('session/event', (session, event) => {
      digest(() => { this.onSessionEvent(session, event) })
    })
    register('agent/status', (value) => {
      digest(() => { this.onAgentStatus(value) })
    })
    register('agent/disposed', (value) => {
      digest(() => { this.onAgentDisposed(value) })
    })
  }

  /** Release the subscription; idempotent. */
  private unsubscribe(): void {
    this.subscribed = false
    this.clearFlushTimer()
    for (const dispose of this.disposers.splice(0).reverse()) {
      try {
        dispose()
      } catch {
        // Observer disposal must not escape into the desktop Host.
      }
    }
  }

  /** Cancel the pending flush, if any. */
  private clearFlushTimer(): void {
    if (this.flushTimer === undefined) return
    clearTimeout(this.flushTimer)
    this.flushTimer = undefined
  }

  /** Drop queued events and statuses without posting them. */
  private dropPending(): void {
    this.pending.length = 0
    this.statuses.clear()
    this.overflowed = 0
  }

  /** Track one desktop session event: filter duplicates, bound its size, queue it. */
  private onSessionEvent(session: unknown, event: unknown): void {
    const sessionId = sessionIdOf(session)
    if (sessionId === undefined || !isRecord(event)) return
    const seq = event['seq']
    if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 0) return
    const previous = this.lastSeq.get(sessionId)
    if (previous !== undefined && seq <= previous) return
    let bytes: number
    try {
      bytes = Buffer.byteLength(JSON.stringify(event), 'utf8')
    } catch (error) {
      this.lastSeq.set(sessionId, seq)
      this.warn('session event is not serializable', error)
      return
    }
    this.lastSeq.set(sessionId, seq)
    if (bytes > (this.options.maxBatchBytes ?? MAXIMUM_BATCH_BYTES)) {
      this.warn('session event exceeds the relay batch size and was dropped')
      return
    }
    this.pending.push({ sessionId, event, bytes })
    const ceiling = this.options.maxPendingEvents ?? MAXIMUM_PENDING_EVENTS
    while (this.pending.length > ceiling) {
      this.pending.shift()
      this.overflowed += 1
    }
    this.scheduleFlush()
  }

  /** Track one desktop agent status transition; identical consecutive states are dropped. */
  private onAgentStatus(value: unknown): void {
    if (!isRecord(value)) return
    const status = value['status']
    if (status !== 'running' && status !== 'idle') return
    const sessionId = sessionIdOfAgent(value['agent'])
    if (sessionId === undefined) return
    this.recordStatus(sessionId, status)
  }

  /** Treat a disposed agent as idle so a vanished agent cannot leave a stale running state. */
  private onAgentDisposed(value: unknown): void {
    if (!isRecord(value)) return
    const sessionId = sessionIdOfAgent(value['agent'])
    if (sessionId === undefined) return
    this.recordStatus(sessionId, 'idle')
  }

  /** Queue one status transition unless it repeats the last delivered state. */
  private recordStatus(sessionId: string, status: DesktopSessionStatusEntry['status']): void {
    if (this.lastStatus.get(sessionId) === status) return
    this.statuses.set(sessionId, status)
    this.scheduleFlush()
  }

  /** Schedule one flush unless a timer or an in-flight flush already owns the queue. */
  private scheduleFlush(): void {
    if (this.flushTimer !== undefined || this.flushing) return
    this.flushTimer = setTimeout(() => {
      this.flushTimer = undefined
      void this.flush()
    }, this.options.flushIntervalMs ?? DEFAULT_FLUSH_INTERVAL_MS)
    this.flushTimer.unref()
  }

  /** Post the queued batches in order; failures drop the rest of this flush. */
  private async flush(): Promise<void> {
    this.flushing = true
    try {
      if (!this.available()) {
        this.dropPending()
        this.reconcile()
        return
      }
      const events = this.pending.splice(0)
      const statuses: DesktopSessionStatusEntry[] = [...this.statuses]
        .map(([sessionId, status]) => ({ sessionId, status }))
      this.statuses.clear()
      const overflowed = this.overflowed
      this.overflowed = 0
      const batches = buildBatches(events, statuses, this.options)
      for (const batch of batches) {
        try {
          await this.options.post(batch)
          this.consecutiveFailures = 0
          for (const entry of batch.statuses) this.lastStatus.set(entry.sessionId, entry.status)
        } catch (error) {
          this.consecutiveFailures += 1
          this.warn('relay batch post failed', error)
          if (this.consecutiveFailures >= (this.options.failureLimit ?? DEFAULT_FAILURE_LIMIT)) {
            this.disable()
          }
          return
        }
      }
      if (overflowed > 0) {
        this.options.logger.warn(
          'device-interconnect: desktop session event relay dropped %s event(s) over the backlog ceiling',
          String(overflowed),
        )
      }
    } finally {
      this.flushing = false
      if (this.closed || this.disabled) return
      if (this.pending.length > 0 || this.statuses.size > 0) this.scheduleFlush()
    }
  }

  /** Stop capturing and report through the bridge state; the child keeps running. */
  private disable(): void {
    this.disabled = true
    this.disabledProblem = {
      code: 'desktop-session-events-disabled',
      message: '桌面实时会话事件中继已停用（连续投递失败）。手机仍可通过增量读取同步；重新启用远程宿主或重启 DSH 后恢复。',
    }
    this.unsubscribe()
    this.dropPending()
    this.options.logger.warn(
      'device-interconnect: desktop session event relay disabled after %s consecutive failed flushes',
      String(this.consecutiveFailures),
    )
  }

  /** Log a warning with no event content, token, or message text. */
  private warn(message: string, error?: unknown): void {
    if (error === undefined) {
      this.options.logger.warn('device-interconnect: %s', message)
      return
    }
    this.options.logger.warn('device-interconnect: %s: %s', message, describeThrown(error))
  }
}

/** Render a caught value without relying on `Object#toString`. */
function describeThrown(error: unknown): string {
  if (error instanceof Error) return error.message
  return typeof error === 'string' ? error : 'non-Error failure'
}

/**
 * Build ordered batches from one flushed queue.
 *
 * Events are grouped by session in first-arrival order, split into chunks that
 * fit both ceilings (a single event over the byte ceiling was already dropped
 * before it could enter the queue), and packed into as few batches as both
 * ceilings allow. Statuses ride on the first batch so one flush emits one
 * page-line status value per session even when it needs several event batches.
 * @param events - queued events in arrival order.
 * @param statuses - coalesced status transitions of this flush.
 * @param options - limits; both ceilings fall back to their module defaults.
 * @returns at least one batch when the queue was not empty.
 */
function buildBatches(
  events: readonly PendingEvent[],
  statuses: readonly DesktopSessionStatusEntry[],
  options: Pick<DesktopSessionEventsOptions, 'maxEventsPerBatch' | 'maxBatchBytes'>,
): DesktopSessionEventsBatch[] {
  const maxEvents = options.maxEventsPerBatch ?? MAXIMUM_EVENTS_PER_BATCH
  const maxBytes = options.maxBatchBytes ?? MAXIMUM_BATCH_BYTES
  const batches: DesktopSessionEventsBatch[] = []
  let currentGroups: MutableGroup[] = []
  let currentEvents = 0
  let currentBytes = EMPTY_BATCH_BYTES

  const closeBatch = (): void => {
    if (currentEvents === 0) return
    batches.push({
      sessions: currentGroups.map(group => ({
        sessionId: group.sessionId,
        events: group.entries.map(entry => entry.event),
      })),
      statuses: batches.length === 0 ? statuses : [],
    })
    currentGroups = []
    currentEvents = 0
    currentBytes = EMPTY_BATCH_BYTES
  }

  const pushChunk = (sessionId: string, entries: PendingEvent[], bytes: number): void => {
    if (currentEvents > 0 && (currentEvents + entries.length > maxEvents || currentBytes + bytes > maxBytes)) {
      closeBatch()
    }
    currentGroups.push({ sessionId, entries })
    currentEvents += entries.length
    currentBytes += bytes
  }

  for (const group of groupBySession(events)) {
    let chunk: PendingEvent[] = []
    let chunkBytes = EMPTY_GROUP_BYTES + group.sessionId.length
    for (const entry of group.entries) {
      if (chunk.length >= maxEvents || (chunk.length > 0 && chunkBytes + entry.bytes > maxBytes)) {
        pushChunk(group.sessionId, chunk, chunkBytes)
        chunk = []
        chunkBytes = EMPTY_GROUP_BYTES + group.sessionId.length
      }
      chunk.push(entry)
      chunkBytes += entry.bytes
    }
    pushChunk(group.sessionId, chunk, chunkBytes)
  }
  closeBatch()
  if (batches.length === 0 && statuses.length > 0) {
    batches.push({ sessions: [], statuses })
  }
  return batches
}

/** Group queued events by session in first-arrival order. */
function groupBySession(events: readonly PendingEvent[]): MutableGroup[] {
  const groups: MutableGroup[] = []
  const bySession = new Map<string, MutableGroup>()
  for (const item of events) {
    const existing = bySession.get(item.sessionId)
    if (existing !== undefined) {
      existing.entries.push(item)
      continue
    }
    const created: MutableGroup = { sessionId: item.sessionId, entries: [item] }
    bySession.set(item.sessionId, created)
    groups.push(created)
  }
  return groups
}

/** Session id of a `session/event` session payload. */
function sessionIdOf(session: unknown): string | undefined {
  if (!isRecord(session)) return undefined
  return idText(session['id'])
}

/** Session id of an `agent/status` or `agent/disposed` agent payload. */
function sessionIdOfAgent(agent: unknown): string | undefined {
  if (!isRecord(agent)) return undefined
  const session = agent['session']
  if (!isRecord(session)) return undefined
  return idText(session['id'])
}

/** Convert a Host id value to text; only strings and numbers are ids here. */
function idText(value: unknown): string | undefined {
  if (typeof value === 'string' && value !== '') return value
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return undefined
}

/** Record guard for wire and Host event values. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
