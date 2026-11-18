/**
 * Desktop real-time session event relay: availability gating, batching and
 * splitting, per-session dedupe, status coalescing, failure containment, and
 * observer exception isolation.
 */

import { describe, expect, it, vi } from 'vitest'
import type { Context } from '@deepseek-ai/cordis'
import {
  DesktopSessionEvents,
  type DesktopSessionEventsBatch,
} from '../src/host/desktop-session-events.ts'

/** Minimal event-emitting context; records listeners so gating is observable. */
function context(): {
  readonly ctx: Context
  emit(event: string, ...args: unknown[]): void
  listenerCount(event: string): number
} {
  const listeners = new Map<string, ((...args: unknown[]) => void)[]>()
  const fake = {
    on(event: string, callback: (...args: unknown[]) => void) {
      const list = listeners.get(event) ?? []
      list.push(callback)
      listeners.set(event, list)
      return () => {
        const current = listeners.get(event) ?? []
        listeners.set(event, current.filter(entry => entry !== callback))
      }
    },
  }
  return {
    ctx: fake as never,
    emit(event, ...args) {
      for (const listener of [...(listeners.get(event) ?? [])]) listener(...args)
    },
    listenerCount(event) {
      return listeners.get(event)?.length ?? 0
    },
  }
}

/** Wait for pending timers/microtasks of one flush interval. */
function settle(milliseconds = 25): Promise<void> {
  return new Promise((resolve) => { setTimeout(resolve, milliseconds) })
}

/** Collect batches posted by one observer. */
function collector(): {
  readonly post: (batch: DesktopSessionEventsBatch) => Promise<void>
  readonly batches: DesktopSessionEventsBatch[]
} {
  const batches: DesktopSessionEventsBatch[] = []
  return {
    batches,
    post: async (batch) => { batches.push(batch) },
  }
}

/** Build one desktop session payload. */
function session(id: string): { readonly id: string } {
  return { id }
}

/** Build one desktop agent payload. */
function agent(id: string): { readonly session: { readonly id: string } } {
  return { session: { id } }
}

/** Flat event list of one batch. */
function eventsOf(batch: DesktopSessionEventsBatch): number[] {
  return batch.sessions.flatMap(group => group.events.map(event => (
    typeof event['seq'] === 'number' ? event['seq'] : -1
  )))
}

describe('DesktopSessionEvents', () => {
  it('does not subscribe while the relay is unavailable and resumes after reconcile', async () => {
    const harness = context()
    const sink = collector()
    let available = false
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => available,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    expect(harness.listenerCount('session/event')).toBe(0)
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'assistant/message' })
    await settle()
    expect(sink.batches).toEqual([])

    available = true
    observer.reconcile()
    expect(harness.listenerCount('session/event')).toBe(1)
    harness.emit('session/event', session('s-1'), { seq: 2, type: 'assistant/message' })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    expect(eventsOf(sink.batches[0]!)).toEqual([2])

    observer.stop()
    expect(harness.listenerCount('session/event')).toBe(0)
    expect(harness.listenerCount('agent/status')).toBe(0)
  })

  it('splits large queues into ordered batches and groups events by session', async () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    for (let seq = 1; seq <= 40; seq += 1) {
      harness.emit('session/event', session('s-1'), { seq, type: 'step/start' })
    }
    harness.emit('session/event', session('s-2'), { seq: 1, type: 'turn/start' })
    harness.emit('agent/status', { agent: agent('s-1'), status: 'running' })
    await vi.waitFor(() => { expect(sink.batches.length).toBeGreaterThanOrEqual(2) })
    const events = sink.batches.flatMap(eventsOf)
    expect(events.slice(0, 40)).toEqual(Array.from({ length: 40 }, (_value, index) => index + 1))
    expect(events).toContain(1)
    for (const batch of sink.batches) expect(eventsOf(batch).length).toBeLessThanOrEqual(32)
    expect(sink.batches.at(-1)?.sessions.some(group => group.sessionId === 's-2')).toBe(true)
    expect(sink.batches[0]?.statuses).toEqual([{ sessionId: 's-1', status: 'running' }])
    expect(sink.batches[1]?.statuses).toEqual([])
    observer.stop()
  })

  it('drops repeated and lower seq values within one session', async () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 5, type: 'assistant/message' })
    harness.emit('session/event', session('s-1'), { seq: 5, type: 'assistant/message' })
    harness.emit('session/event', session('s-1'), { seq: 3, type: 'tool/call' })
    harness.emit('session/event', session('s-1'), { seq: 6, type: 'tool/result' })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    expect(eventsOf(sink.batches[0]!)).toEqual([5, 6])
    observer.stop()
  })

  it('coalesces status transitions and treats a disposed agent as idle', async () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('agent/status', { agent: agent('s-1'), status: 'running' })
    harness.emit('agent/status', { agent: agent('s-1'), status: 'running' })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    expect(sink.batches[0]?.statuses).toEqual([{ sessionId: 's-1', status: 'running' }])
    harness.emit('agent/status', { agent: agent('s-1'), status: 'running' })
    harness.emit('agent/disposed', { agent: agent('s-1') })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(2) })
    expect(sink.batches[1]?.statuses).toEqual([{ sessionId: 's-1', status: 'idle' }])
    observer.stop()
  })

  it('drops one oversized event but relays the rest', async () => {
    const harness = context()
    const sink = collector()
    const warn = vi.fn()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn },
      flushIntervalMs: 5,
      maxBatchBytes: 200,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'tool/result', data: { text: 'x'.repeat(500) } })
    harness.emit('session/event', session('s-1'), { seq: 2, type: 'tool/call' })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    expect(eventsOf(sink.batches[0]!)).toEqual([2])
    expect(warn).toHaveBeenCalled()
    observer.stop()
  })

  it('drops the oldest events over the backlog ceiling', async () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      maxPendingEvents: 2,
      reconcileIntervalMs: 0,
    })
    observer.start()
    for (let seq = 1; seq <= 4; seq += 1) {
      harness.emit('session/event', session('s-1'), { seq, type: 'step/start' })
    }
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    expect(eventsOf(sink.batches[0]!)).toEqual([3, 4])
    observer.stop()
  })

  it('contains subscription callback exceptions and keeps observing', async () => {
    const harness = context()
    const sink = collector()
    const warn = vi.fn()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    const explosive = { get id(): string { throw new Error('id getter failed') } }
    expect(() => { harness.emit('session/event', explosive, { seq: 1, type: 'turn/start' }) }).not.toThrow()
    harness.emit('session/event', session('s-1'), { seq: 2, type: 'turn/start' })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    expect(eventsOf(sink.batches[0]!)).toEqual([2])
    expect(warn).toHaveBeenCalled()
    observer.stop()
  })

  it('drops the backlog and unsubscribes when the relay becomes unavailable', async () => {
    const harness = context()
    const sink = collector()
    let available = true
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => available,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 1_000,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'turn/start' })
    available = false
    observer.reconcile()
    expect(harness.listenerCount('session/event')).toBe(0)
    await settle(40)
    expect(sink.batches).toEqual([])
    observer.stop()
  })

  it('disables itself after consecutive post failures and reports a problem', async () => {
    const harness = context()
    const warn = vi.fn()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: async () => { throw { reason: 'control plane down' } },
      available: () => true,
      logger: { info: vi.fn(), warn },
      flushIntervalMs: 5,
      failureLimit: 2,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'turn/start' })
    await vi.waitFor(() => { expect(warn).toHaveBeenCalled() })
    harness.emit('session/event', session('s-1'), { seq: 2, type: 'step/start' })
    await vi.waitFor(() => { expect(observer.problem()).toBeDefined() })
    expect(observer.problem()?.code).toBe('desktop-session-events-disabled')
    expect(harness.listenerCount('session/event')).toBe(0)
    observer.reconcile()
    expect(harness.listenerCount('session/event')).toBe(0)
    observer.stop()
  })

  it('reports no problem while active and stops cleanly', () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
    })
    observer.start()
    observer.start()
    expect(observer.problem()).toBeUndefined()
    observer.stop()
    observer.stop()
    expect(harness.listenerCount('agent/status')).toBe(0)
  })

  it('accepts numeric session ids and ignores malformed Host payloads', async () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', { id: 42 }, { seq: 1, type: 'turn/start' })
    harness.emit('session/event', 'not-a-session', { seq: 1, type: 'turn/start' })
    harness.emit('session/event', [1, 2], { seq: 1, type: 'turn/start' })
    harness.emit('session/event', session('s-1'), 'not-an-event')
    harness.emit('session/event', session('s-1'), { type: 'turn/start' })
    harness.emit('session/event', session('s-1'), { seq: 1.5, type: 'turn/start' })
    harness.emit('session/event', session('s-1'), { seq: -1, type: 'turn/start' })
    harness.emit('session/event', session('s-1'), { seq: '3', type: 'turn/start' })
    harness.emit('session/event', { id: Number.POSITIVE_INFINITY }, { seq: 2, type: 'turn/start' })
    harness.emit('agent/status', { status: 'running' })
    harness.emit('agent/status', 'not-a-record')
    harness.emit('agent/status', { agent: agent('s-2'), status: 'paused' })
    harness.emit('agent/status', { agent: { session: 'not-a-session' }, status: 'running' })
    harness.emit('agent/disposed', 12)
    harness.emit('agent/disposed', { agent: { session: 'not-a-session' } })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    expect(sink.batches[0]?.sessions).toHaveLength(1)
    expect(sink.batches[0]?.sessions[0]?.sessionId).toBe('42')
    expect(eventsOf(sink.batches[0]!)).toEqual([1])
    observer.stop()
  })

  it('treats a throwing availability gate as unavailable and re-checks on its timer', async () => {
    const harness = context()
    const warn = vi.fn()
    let healthy = false
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: async () => {},
      available: () => {
        // A gate failure may be any thrown value; the observer must contain it.
        if (!healthy) throw 'gate failed'
        return true
      },
      logger: { info: vi.fn(), warn },
      flushIntervalMs: 5,
      reconcileIntervalMs: 10,
    })
    observer.start()
    expect(harness.listenerCount('session/event')).toBe(0)
    await vi.waitFor(() => { expect(warn).toHaveBeenCalled() })
    healthy = true
    await vi.waitFor(() => { expect(harness.listenerCount('session/event')).toBe(1) })
    observer.stop()
  })

  it('drops unserializable events without escaping into the Host', () => {
    const harness = context()
    const sink = collector()
    const warn = vi.fn()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    const circular: Record<string, unknown> = { seq: 1, type: 'turn/start' }
    circular['self'] = circular
    expect(() => { harness.emit('session/event', session('s-1'), circular) }).not.toThrow()
    expect(warn).toHaveBeenCalled()
    observer.stop()
  })

  it('splits batches by the byte ceiling', async () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      maxBatchBytes: 80,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'tool/call' })
    harness.emit('session/event', session('s-1'), { seq: 2, type: 'tool/call' })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(2) })
    expect(sink.batches.map(eventsOf)).toEqual([[1], [2]])
    observer.stop()
  })

  it('drops the queue when availability drops before the scheduled flush', async () => {
    const harness = context()
    const sink = collector()
    let available = true
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => available,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'turn/start' })
    available = false
    await settle(40)
    expect(sink.batches).toEqual([])
    expect(harness.listenerCount('session/event')).toBe(0)
    observer.stop()
  })

  it('schedules a follow-up flush for events queued during an in-flight post', async () => {
    const harness = context()
    const posts: DesktopSessionEventsBatch[] = []
    let release: (() => void) | undefined
    const gate = new Promise<void>((resolve) => { release = resolve })
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: async (batch) => {
        posts.push(batch)
        await gate
      },
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'turn/start' })
    await vi.waitFor(() => { expect(posts.length).toBe(1) })
    harness.emit('session/event', session('s-1'), { seq: 2, type: 'step/start' })
    release?.()
    await vi.waitFor(() => { expect(posts.length).toBe(2) })
    expect(eventsOf(posts[1]!)).toEqual([2])
    observer.stop()
  })

  it('stops during an in-flight post without scheduling another flush', async () => {
    const harness = context()
    const posts: DesktopSessionEventsBatch[] = []
    let release: (() => void) | undefined
    const gate = new Promise<void>((resolve) => { release = resolve })
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: async (batch) => {
        posts.push(batch)
        await gate
      },
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'turn/start' })
    await vi.waitFor(() => { expect(posts.length).toBe(1) })
    harness.emit('session/event', session('s-1'), { seq: 2, type: 'step/start' })
    observer.stop()
    release?.()
    await settle(40)
    expect(posts).toHaveLength(1)
    expect(harness.listenerCount('session/event')).toBe(0)
  })

  it('is a no-op before start and after stop', () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      reconcileIntervalMs: 0,
    })
    observer.reconcile()
    expect(harness.listenerCount('session/event')).toBe(0)
    const unused = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      reconcileIntervalMs: 0,
    })
    unused.stop()
    unused.start()
    unused.reconcile()
    expect(harness.listenerCount('session/event')).toBe(0)
    observer.start()
    observer.stop()
    observer.reconcile()
    expect(harness.listenerCount('session/event')).toBe(0)
  })

  it('contains a throwing listener disposer', () => {
    const listeners: ((...args: unknown[]) => void)[] = []
    const ctx = {
      on(_event: string, callback: (...args: unknown[]) => void) {
        listeners.push(callback)
        return () => { throw new Error('dispose failed') }
      },
    } as never
    const observer = new DesktopSessionEvents({
      ctx,
      post: async () => {},
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    expect(listeners).toHaveLength(3)
    expect(() => { observer.stop() }).not.toThrow()
  })

  it('contains subscription registration failures', () => {
    const ctx = {
      on() { throw new Error('subscribe failed') },
    } as never
    const warn = vi.fn()
    const observer = new DesktopSessionEvents({
      ctx,
      post: async () => {},
      available: () => true,
      logger: { info: vi.fn(), warn },
      reconcileIntervalMs: 0,
    })
    expect(() => { observer.start() }).not.toThrow()
    expect(warn).toHaveBeenCalledTimes(3)
    observer.stop()
  })

  it('uses the default flush interval when none is configured', async () => {
    const harness = context()
    const sink = collector()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: sink.post,
      available: () => true,
      logger: { info: vi.fn(), warn: vi.fn() },
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'turn/start' })
    await vi.waitFor(() => { expect(sink.batches.length).toBe(1) })
    observer.stop()
  })

  it('keeps observing below the default failure limit', async () => {
    const harness = context()
    const warn = vi.fn()
    const observer = new DesktopSessionEvents({
      ctx: harness.ctx,
      post: async () => { throw new Error('control plane down') },
      available: () => true,
      logger: { info: vi.fn(), warn },
      flushIntervalMs: 5,
      reconcileIntervalMs: 0,
    })
    observer.start()
    harness.emit('session/event', session('s-1'), { seq: 1, type: 'turn/start' })
    await vi.waitFor(() => { expect(warn).toHaveBeenCalled() })
    expect(observer.problem()).toBeUndefined()
    expect(harness.listenerCount('session/event')).toBe(1)
    observer.stop()
  })
})
