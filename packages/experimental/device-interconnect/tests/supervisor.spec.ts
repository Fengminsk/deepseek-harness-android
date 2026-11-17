/**
 * Child supervisor: spawn arguments, status, the bounded log tail, exit
 * handling, idempotent start/stop, restart, and disposal.
 */

import { PassThrough } from 'node:stream'
import { describe, expect, it, vi } from 'vitest'
import {
  HostSupervisor, LOG_TAIL_BYTES, type KillTree, type ManagedChild, type SpawnChild, type SupervisorLogger,
} from '../src/host/supervisor.ts'

/** A child double whose streams the test drives. */
class FakeChild implements ManagedChild {
  readonly stdout = new PassThrough()
  readonly stderr = new PassThrough()
  readonly killed: (NodeJS.Signals | undefined)[] = []
  private readonly exitListeners: ((code: number | null, signal: NodeJS.Signals | null) => void)[] = []
  private readonly errorListeners: ((error: Error) => void)[] = []

  /**
   * @param pid - reported process id.
   */
  constructor(readonly pid: number | undefined) {}

  /** @param event - event name. @param listener - receiver. */
  on(event: 'exit', listener: (code: number | null, signal: NodeJS.Signals | null) => void): void
  /** @param event - event name. @param listener - receiver. */
  on(event: 'error', listener: (error: Error) => void): void
  on(
    event: 'exit' | 'error',
    listener: ((code: number | null, signal: NodeJS.Signals | null) => void) | ((error: Error) => void),
  ): void {
    if (event === 'exit') this.exitListeners.push(listener as (code: number | null, signal: NodeJS.Signals | null) => void)
    else this.errorListeners.push(listener as (error: Error) => void)
  }

  kill(signal?: NodeJS.Signals): boolean {
    this.killed.push(signal)
    return true
  }

  /**
   * Emit an exit event.
   * @param code - exit code.
   * @param signal - terminating signal.
   */
  emitExit(code: number | null, signal: NodeJS.Signals | null = null): void {
    for (const listener of this.exitListeners) listener(code, signal)
  }

  /**
   * Emit a spawn error.
   * @param error - failure.
   */
  emitError(error: Error): void {
    for (const listener of this.errorListeners) listener(error)
  }
}

/** Quiet logger double. */
function logger(): SupervisorLogger {
  return { info: () => {}, warn: () => {} }
}

/** A launch command double. */
const command = {
  file: 'C:\\node\\node.exe',
  args: ['pnpm.mjs', 'dsh', '--no-open'],
  cwd: 'D:\\repo',
  env: { DSH_HOME: 'C:\\home' },
}

/**
 * Build a supervisor over one fake child.
 * @param overrides - supervisor seams to replace.
 * @returns the supervisor, the spawned children, and the kill double.
 */
function bench(overrides: { spawned?: FakeChild[]; killTree?: KillTree; errors?: Error[]; logLimitBytes?: number; stopTimeoutMs?: number } = {}) {
  const spawned = overrides.spawned ?? []
  const spawn: SpawnChild = vi.fn(() => {
    const next = spawned.shift()
    if (next === undefined) throw new Error('no fake child left')
    return next
  })
  const killTree = overrides.killTree ?? vi.fn(async (pid: number) => {
    for (const child of children) {
      if (child.pid === pid) child.emitExit(0)
    }
  })
  const children: FakeChild[] = []
  const supervisor = new HostSupervisor({
    spawn: (launch) => {
      const child = spawn(launch) as FakeChild
      children.push(child)
      return child
    },
    killTree,
    now: () => 1_000,
    ...(overrides.logLimitBytes === undefined ? {} : { logLimitBytes: overrides.logLimitBytes }),
    ...(overrides.stopTimeoutMs === undefined ? {} : { stopTimeoutMs: overrides.stopTimeoutMs }),
    logger: logger(),
  })
  return { supervisor, spawn, killTree, children }
}

/** Wait until the next macrotask so stream data events are delivered. */
function settle(): Promise<void> {
  return new Promise(resolve => setImmediate(resolve))
}

describe('HostSupervisor', () => {
  it('spawns the command and reports a running child', () => {
    const child = new FakeChild(4_242)
    const { supervisor, spawn } = bench({ spawned: [child] })
    supervisor.start(command)
    expect(spawn).toHaveBeenCalledWith(command)
    expect(supervisor.status()).toMatchObject({ running: true, pid: 4_242, startedAt: 1_000, logsTail: '' })
  })

  it('is idempotent while a child runs', () => {
    const { supervisor, spawn } = bench({ spawned: [new FakeChild(4_242), new FakeChild(4_242)] })
    supervisor.start(command)
    supervisor.start(command)
    expect(spawn).toHaveBeenCalledTimes(1)
  })

  it('retains stdout and stderr in the combined tail', async () => {
    const child = new FakeChild(4_242)
    const { supervisor } = bench({ spawned: [child] })
    supervisor.start(command)
    child.stdout.write('listening on 4777\n')
    child.stderr.write('warn: port busy\n')
    await settle()
    expect(supervisor.status().logsTail).toBe('listening on 4777\nwarn: port busy\n')
  })

  it('bounds the retained tail to its byte limit', async () => {
    const child = new FakeChild(4_242)
    const { supervisor } = bench({ spawned: [child], logLimitBytes: 8 })
    supervisor.start(command)
    child.stdout.write('0123456789abcdef')
    await settle()
    expect(Buffer.byteLength(supervisor.status().logsTail)).toBeLessThanOrEqual(8)
    expect(supervisor.status().logsTail.endsWith('def')).toBe(true)
  })

  it('records a clean exit', () => {
    const child = new FakeChild(4_242)
    const { supervisor } = bench({ spawned: [child] })
    supervisor.start(command)
    child.emitExit(0)
    expect(supervisor.status()).toMatchObject({ running: false, exitCode: 0, exitedAt: 1_000 })
    expect(supervisor.status().error).toBeUndefined()
  })

  it('records a failed exit', () => {
    const child = new FakeChild(4_242)
    const { supervisor } = bench({ spawned: [child] })
    supervisor.start(command)
    child.emitExit(17)
    expect(supervisor.status().error).toContain('代码 17')
  })

  it('records a signal termination', () => {
    const child = new FakeChild(4_242)
    const { supervisor } = bench({ spawned: [child] })
    supervisor.start(command)
    child.emitExit(null, 'SIGTERM')
    expect(supervisor.status()).toMatchObject({ running: false })
    expect(supervisor.status().error).toContain('SIGTERM')
  })

  it('records a spawn throw without leaving a running child', () => {
    const { supervisor } = bench()
    supervisor.start(command)
    expect(supervisor.status()).toMatchObject({ running: false, exitedAt: 1_000 })
    expect(supervisor.status().error).toContain('no fake child left')
  })

  it('records an asynchronous spawn error', () => {
    const child = new FakeChild(undefined)
    const { supervisor } = bench({ spawned: [child] })
    supervisor.start(command)
    child.emitError(new Error('spawn ENOENT'))
    expect(supervisor.status()).toMatchObject({ running: false })
    expect(supervisor.status().logsTail).toContain('spawn ENOENT')
    expect(supervisor.status().error).toBe('spawn ENOENT')
  })

  it('kills the process tree and waits for the exit', async () => {
    const child = new FakeChild(4_242)
    const { supervisor, killTree } = bench({ spawned: [child] })
    supervisor.start(command)
    await supervisor.stop()
    expect(killTree).toHaveBeenCalledWith(4_242)
    expect(supervisor.status().running).toBe(false)
    await supervisor.stop()
    expect(killTree).toHaveBeenCalledTimes(1)
  })

  it('kills the child directly when no pid is known', async () => {
    const child = new FakeChild(undefined)
    const killTree = vi.fn(async () => {})
    const { supervisor } = bench({ spawned: [child], killTree, stopTimeoutMs: 10 })
    supervisor.start(command)
    await supervisor.stop()
    expect(killTree).not.toHaveBeenCalled()
    expect(child.killed).toEqual(['SIGKILL'])
    expect(supervisor.status().running).toBe(false)
  })

  it('reports a child that outlives the stop grace period', async () => {
    const child = new FakeChild(4_242)
    const { supervisor } = bench({ spawned: [child], killTree: async () => {}, stopTimeoutMs: 10 })
    supervisor.start(command)
    await supervisor.stop()
    expect(supervisor.status()).toMatchObject({ running: false, exitedAt: 1_000 })
    expect(supervisor.status().error).toContain('停止等待时间')
  })

  it('survives a process-tree kill that throws', async () => {
    const child = new FakeChild(4_242)
    const killTree = vi.fn(async () => { throw new Error('taskkill failed') })
    const { supervisor } = bench({ spawned: [child], killTree, stopTimeoutMs: 10 })
    supervisor.start(command)
    await supervisor.stop()
    expect(supervisor.status().running).toBe(false)
  })

  it('restarts by stopping the old child and spawning a new one', async () => {
    const first = new FakeChild(4_242)
    const second = new FakeChild(4_242)
    const { supervisor, spawn } = bench({ spawned: [first, second] })
    supervisor.start(command)
    await supervisor.restart(command)
    expect(spawn).toHaveBeenCalledTimes(2)
    expect(supervisor.status()).toMatchObject({ running: true, pid: 4_242 })
  })

  it('refuses later starts after disposal', async () => {
    const child = new FakeChild(4_242)
    const { supervisor, spawn } = bench({ spawned: [child] })
    supervisor.start(command)
    await supervisor.dispose()
    supervisor.start(command)
    expect(spawn).toHaveBeenCalledTimes(1)
    expect(supervisor.status().running).toBe(false)
  })

  it('keeps the documented default log ceiling', () => {
    expect(LOG_TAIL_BYTES).toBe(64 * 1_024)
  })
})
