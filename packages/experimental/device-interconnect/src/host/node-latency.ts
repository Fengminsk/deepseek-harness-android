/**
 * TCP latency probe for SakuraFrp nodes.
 *
 * The automatic provision ranks candidate nodes by the time a TCP connection to
 * the node's frps port takes, so a user in one city does not keep the node that
 * happened to be first in the service list. Only a connect measurement is made:
 * no application data, no external service. A node that refuses or times out is
 * reported as unreachable and ranked last.
 * @module @deepseek-ai/dsh-device-interconnect/host/node-latency
 */

import { connect } from 'node:net'

/** frps TCP port every SakuraFrp node listens on. */
export const NODE_LATENCY_PORT = 7_000

/** Deadline of one node's connect measurement. */
export const NODE_LATENCY_TIMEOUT_MS = 1_200

/** How many measurements run at the same time. */
export const NODE_LATENCY_CONCURRENCY = 32

/** One node to measure. */
export interface LatencyTarget {
  /** Node id, echoed into the sample. */
  readonly nodeId: number
  /** Node host to connect to. */
  readonly host: string
}

/** One measurement result; `ms` is absent when the node was unreachable. */
export interface LatencySample {
  /** Node id the sample belongs to. */
  readonly nodeId: number
  /** Node host that was measured. */
  readonly host: string
  /** Connect time in milliseconds, or absent for an unreachable node. */
  readonly ms?: number
}

/**
 * One host measurement; resolves the connect time or undefined on failure.
 * Injectable so tests never open a socket.
 */
export type LatencyProbe = (host: string, port: number, timeoutMs: number) => Promise<number | undefined>

/** Options of {@link createTcpLatencyProbe}. */
export interface TcpLatencyProbeOptions {
  /** frps port; defaults to {@link NODE_LATENCY_PORT}. */
  readonly port?: number
  /** Per-node deadline; defaults to {@link NODE_LATENCY_TIMEOUT_MS}. */
  readonly timeoutMs?: number
  /** Concurrent measurement ceiling; defaults to {@link NODE_LATENCY_CONCURRENCY}. */
  readonly concurrency?: number
  /** Measurement seam; defaults to a real TCP connect. */
  readonly probe?: LatencyProbe
}

/**
 * Measure one host with a plain TCP connect.
 * @param host - node host.
 * @param port - frps port.
 * @param timeoutMs - measurement deadline.
 * @returns the connect time in milliseconds, or undefined when unreachable.
 */
export async function probeTcpLatency(host: string, port: number, timeoutMs: number): Promise<number | undefined> {
  return new Promise<number | undefined>((resolve) => {
    const startedAt = Date.now()
    let settled = false
    const settle = (value: number | undefined): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      resolve(value)
    }
    const socket = connect({ host, port })
    const timer = setTimeout(() => { settle(undefined) }, timeoutMs)
    socket.once('connect', () => { settle(Date.now() - startedAt) })
    socket.once('error', () => { settle(undefined) })
  })
}

/**
 * Build a probe that measures every target with bounded concurrency and keeps
 * the target order in its result.
 * @param options - port, deadline, concurrency, and the measurement seam.
 * @returns the measuring function.
 */
export function createTcpLatencyProbe(
  options: TcpLatencyProbeOptions = {},
): (targets: readonly LatencyTarget[]) => Promise<readonly LatencySample[]> {
  const port = options.port ?? NODE_LATENCY_PORT
  const timeoutMs = options.timeoutMs ?? NODE_LATENCY_TIMEOUT_MS
  const concurrency = Math.max(1, options.concurrency ?? NODE_LATENCY_CONCURRENCY)
  const measure = options.probe ?? probeTcpLatency
  return async (targets: readonly LatencyTarget[]): Promise<readonly LatencySample[]> => {
    const samples: LatencySample[] = targets.map(target => ({ nodeId: target.nodeId, host: target.host }))
    let next = 0
    const worker = async (): Promise<void> => {
      for (;;) {
        const index = next
        next += 1
        const target = targets[index]
        if (target === undefined) return
        const ms = await measure(target.host, port, timeoutMs)
        samples[index] = { nodeId: target.nodeId, host: target.host, ...(ms === undefined ? {} : { ms }) }
      }
    }
    await Promise.all(Array.from({ length: Math.min(concurrency, targets.length) }, worker))
    return samples
  }
}
