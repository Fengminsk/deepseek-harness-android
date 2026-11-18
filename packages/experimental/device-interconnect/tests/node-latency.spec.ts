/**
 * Node latency probe: bounded concurrency, order preservation, unreachable
 * nodes, and the real TCP connect measurement against a local listener.
 */

import { createServer } from 'node:net'
import type { AddressInfo } from 'node:net'
import { describe, expect, it } from 'vitest'
import {
  createTcpLatencyProbe, NODE_LATENCY_CONCURRENCY, NODE_LATENCY_PORT, NODE_LATENCY_TIMEOUT_MS,
  probeTcpLatency,
} from '../src/host/node-latency.ts'

/** Wait until one asynchronous condition holds. */
async function waitFor(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 2_000
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`)
    await new Promise(resolve => setTimeout(resolve, 5))
  }
}

describe('createTcpLatencyProbe', () => {
  it('uses the documented defaults and keeps target order', async () => {
    const calls: { host: string; port: number; timeoutMs: number }[] = []
    const probe = createTcpLatencyProbe({
      probe: async (host, port, timeoutMs) => {
        calls.push({ host, port, timeoutMs })
        return host === 'dead.test' ? undefined : host.length
      },
    })
    const samples = await probe([
      { nodeId: 3, host: 'ccc.test' },
      { nodeId: 1, host: 'a.test' },
      { nodeId: 2, host: 'dead.test' },
    ])
    expect(samples).toEqual([
      { nodeId: 3, host: 'ccc.test', ms: 8 },
      { nodeId: 1, host: 'a.test', ms: 6 },
      { nodeId: 2, host: 'dead.test' },
    ])
    expect(calls.every(call => call.port === NODE_LATENCY_PORT)).toBe(true)
    expect(calls.every(call => call.timeoutMs === NODE_LATENCY_TIMEOUT_MS)).toBe(true)
  })

  it('runs at most the configured number of probes at once', async () => {
    let active = 0
    let peak = 0
    const releases: (() => void)[] = []
    const probe = createTcpLatencyProbe({
      concurrency: 2,
      probe: async () => {
        active += 1
        peak = Math.max(peak, active)
        await new Promise<void>((resolve) => {
          releases.push(() => { active -= 1; resolve() })
        })
        return 5
      },
    })
    const targets = [1, 2, 3, 4].map(nodeId => ({ nodeId, host: `h${String(nodeId)}.test` }))
    const running = probe(targets)
    await waitFor(() => releases.length === 2, 'first two probes')
    expect(peak).toBe(2)
    releases.splice(0).forEach((release) => { release() })
    await waitFor(() => releases.length === 2, 'second two probes')
    expect(peak).toBe(2)
    releases.splice(0).forEach((release) => { release() })
    await expect(running).resolves.toHaveLength(4)
    expect(NODE_LATENCY_CONCURRENCY).toBe(32)
  })
})

describe('probeTcpLatency', () => {
  it('measures a local listener and reports a closed port as unreachable', async () => {
    const server = createServer()
    await new Promise<void>((resolve) => { server.listen(0, '127.0.0.1', resolve) })
    const port = (server.address() as AddressInfo).port
    try {
      const ms = await probeTcpLatency('127.0.0.1', port, 1_200)
      expect(typeof ms).toBe('number')
      expect(ms).toBeGreaterThanOrEqual(0)
      await new Promise<void>((resolve) => { server.close(() => { resolve() }) })
      await expect(probeTcpLatency('127.0.0.1', port, 1_200)).resolves.toBeUndefined()
    } finally {
      server.close()
    }
  })
})
