/**
 * Desktop notification observer: task-completion mapping from desktop agents
 * and projections, approval/asked mapping, dedupe, and contained failures.
 */

import { describe, expect, it, vi } from 'vitest'
import type { Context } from '@deepseek-ai/cordis'
import {
  DesktopNotifications,
  completionPreview,
  type RelayNotification,
} from '../src/host/desktop-notifications.ts'

/** Minimal event-emitting context with optional services. */
function context(services: Record<string, unknown> = {}): {
  readonly ctx: Context
  emit(event: string, ...args: unknown[]): void
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
    get(name: string) {
      return services[name]
    },
  }
  return {
    ctx: fake as never,
    emit(event, ...args) {
      for (const listener of listeners.get(event) ?? []) listener(...args)
    },
  }
}

/** One desktop agent shape read by the observer. */
function agent(sessionId: string): {
  id: string
  status: string
  session: { id: string; header: { origin: string } }
  inbox: { nextTurn: unknown[]; nextStep: unknown[] }
} {
  return {
    id: sessionId,
    status: 'running',
    session: { id: sessionId, header: { origin: 'ordinary' } },
    inbox: { nextTurn: [], nextStep: [] },
  }
}

describe('DesktopNotifications', () => {
  it('maps a completed desktop turn to a task.completed page-line notice', async () => {
    const posts: RelayNotification[][] = []
    const projection = {
      snapshot: vi.fn(() => ({
        values: {
          pocketTasks: {
            turns: [{ turn: 1, seq: 1, reason: { kind: 'completed' }, endSeq: 9 }],
          },
        },
      })),
    }
    const harness = context({ sessionProjections: projection, goals: undefined })
    const desktop = new DesktopNotifications({
      ctx: harness.ctx,
      post: async notifications => { posts.push([...notifications]) },
      logger: { info: vi.fn(), warn: vi.fn() },
    })
    desktop.start()
    const desktopAgent = agent('s-1')
    harness.emit('agent/status', { agent: desktopAgent, status: 'running' })
    harness.emit('session/event', desktopAgent.session, {
      seq: 1, type: 'turn/start', data: { turn: 1 },
    })
    harness.emit('session/event', desktopAgent.session, {
      seq: 2, type: 'step/start', data: { turn: 1, step: 1 },
    })
    harness.emit('session/event', desktopAgent.session, {
      seq: 3, type: 'assistant/message',
      data: { turn: 1, message: { content: [{ type: 'text', text: '已完成测试。' }] } },
    })
    harness.emit('agent/status', { agent: desktopAgent, status: 'idle' })
    await vi.waitFor(() => { expect(posts.length).toBe(1) })
    expect(posts[0]).toEqual([{
      method: 'task.completed',
      params: { sessionId: 's-1', turn: 1, endSeq: 9, preview: '已完成测试。' },
    }])
    desktop.stop()
  })

  it('does not post incomplete turns or subagent sessions', async () => {
    const posts: RelayNotification[][] = []
    const harness = context({ sessionProjections: { snapshot: () => ({ values: {} }) } })
    const desktop = new DesktopNotifications({
      ctx: harness.ctx,
      post: async notifications => { posts.push([...notifications]) },
      logger: { info: vi.fn(), warn: vi.fn() },
    })
    desktop.start()
    const child = agent('child')
    child.session.header.origin = 'subagent'
    harness.emit('agent/status', { agent: child, status: 'running' })
    harness.emit('agent/status', { agent: child, status: 'idle' })
    const incomplete = agent('s-2')
    harness.emit('agent/status', { agent: incomplete, status: 'running' })
    harness.emit('agent/status', { agent: incomplete, status: 'idle' })
    await new Promise(resolve => setTimeout(resolve, 10))
    expect(posts).toEqual([])
    desktop.stop()
  })

  it('maps desktop approvals once and dedupes repeated events', async () => {
    const posts: RelayNotification[][] = []
    const harness = context()
    const desktop = new DesktopNotifications({
      ctx: harness.ctx,
      post: async notifications => { posts.push([...notifications]) },
      logger: { info: vi.fn(), warn: vi.fn() },
    })
    desktop.start()
    const approval = {
      seq: 1,
      type: 'approval/asked',
      data: { id: 'i-1', toolName: 'shell', reason: '需要执行命令' },
    }
    harness.emit('session/event', { id: 's-1', header: {} }, approval)
    harness.emit('session/event', { id: 's-1', header: {} }, approval)
    await vi.waitFor(() => { expect(posts.length).toBe(1) })
    expect(posts[0]).toEqual([{
      method: 'interactions.changed',
      params: {
        requests: [{
          id: 'i-1', sessionId: 's-1', kind: 'approval',
          toolName: 'shell', reason: '需要执行命令',
        }],
      },
    }])
    desktop.stop()
  })

  it('contains post failures and never escapes into the host', async () => {
    const warn = vi.fn()
    const harness = context()
    const desktop = new DesktopNotifications({
      ctx: harness.ctx,
      post: async () => { throw new Error('control plane down') },
      logger: { info: vi.fn(), warn },
    })
    desktop.start()
    harness.emit('session/event', { id: 's-1' }, {
      seq: 1, type: 'approval/asked', data: { id: 'i-2', toolName: 'shell' },
    })
    await vi.waitFor(() => { expect(warn).toHaveBeenCalled() })
    desktop.stop()
    // No throw reached this point.
  })

  it('extracts a short preview from text content', () => {
    expect(completionPreview([{ type: 'text', text: '完成了。' }])).toBe('完成了。')
    expect(completionPreview([{ type: 'image' }])).toBeUndefined()
  })
})
