import { describe, expect, it, vi } from 'vitest'
import { DesktopInteractions } from '../src/host/desktop-interactions.ts'

describe('DesktopInteractions', () => {
  it('reattaches when Gateway services become available after plugin activation', async () => {
    let available = false
    const warn = vi.fn()
    const ctx = {
      get(name: string) {
        if (!available) return undefined
        if (name === 'connection') return { createPeer: () => ({ dispose: async () => {} }) }
        if (name === 'typertGateway') return { wireStream: {
          open: async (_method: string, _params: unknown, _uplink: unknown, _peer: unknown, signal: AbortSignal) => ({
            async *[Symbol.asyncIterator]() {
              yield { type: 'ready', clientId: 'late-owner' }
              yield { type: 'waterfall', event: 'approval/request', eventId: 'late-event',
                agentId: 'late-session', request: { toolName: 'shell' } }
              await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
            },
          }),
        } }
        return undefined
      },
    }
    const bridge = new DesktopInteractions({ ctx: ctx as never, post: async () => {}, warn })
    bridge.start()
    await vi.waitFor(() => expect(warn).toHaveBeenCalled())
    available = true
    await vi.waitFor(() => expect(bridge.diagnostics()).toMatchObject({ ready: true, pending: 1 }),
      { timeout: 2_000 })
    expect(bridge.snapshot('late-session')['requests']).toHaveLength(1)
    await bridge.stop()
  })

  it('publishes an answerable approval and sends the result to the desktop Gateway', async () => {
    let push: ((frame: Record<string, unknown>) => void) | undefined
    const sent: unknown[] = []
    const notifications: unknown[] = []
    const stream = {
      async *[Symbol.asyncIterator]() {
        const queue: Record<string, unknown>[] = []
        let wake: (() => void) | undefined
        push = frame => { queue.push(frame); wake?.() }
        while (true) {
          if (queue.length === 0) await new Promise<void>(resolve => { wake = resolve })
          yield queue.shift()!
        }
      },
    }
    const ctx = {
      get(name: string) {
        if (name === 'connection') return {
          createPeer: () => ({ dispose: async () => {} }),
          createSharedFetchHandler: () => ({
            fetch: async (request: Request) => {
              sent.push(await request.json())
              return Response.json({ result: { ok: true } })
            },
          }),
        }
        if (name === 'typertGateway') return { wireStream: { open: async () => stream } }
        if (name === 'agents') return { get: () => undefined }
        return undefined
      },
    }
    const bridge = new DesktopInteractions({
      ctx: ctx as never,
      post: async batch => { notifications.push(batch) },
      warn: vi.fn(),
    })
    bridge.start()
    expect(bridge.diagnostics().ready).toBe(false)
    await vi.waitFor(() => expect(push).toBeDefined())
    push!({ type: 'ready', clientId: 'owner-client' })
    push!({ type: 'waterfall', event: 'approval/request', eventId: 'event-1', agentId: 'session-1',
      request: { callId: 'call-1', toolName: 'shell', reason: 'run command' } })
    await vi.waitFor(() => expect(bridge.snapshot('session-1')['requests']).toHaveLength(1))
    expect(bridge.diagnostics()).toMatchObject({ ready: true, pending: 1 })
    const snapshot = bridge.snapshot('session-1')
    expect(snapshot['sessionId']).toBe('session-1')
    expect(snapshot['revision']).toEqual(expect.any(Number))
    const request = (snapshot['requests'] as Record<string, unknown>[])[0]
    expect(request).toMatchObject({ id: 'event-1', version: 1, sessionId: 'session-1', kind: 'approval', toolName: 'shell' })
    expect(await bridge.reply({ id: 'event-1', version: 1, sessionId: 'session-1', response: 'allowed-once' }))
      .toMatchObject({ accepted: true })
    expect(sent).toEqual([expect.objectContaining({
      method: '$events/result', payload: { args: { clientId: 'owner-client', eventId: 'event-1',
        outcome: { kind: 'result', value: 'allowed-once' } } },
    })])
    expect(bridge.snapshot('session-1')['requests']).toEqual([])
    expect(notifications).toHaveLength(2)
    await bridge.stop()
  })
})
