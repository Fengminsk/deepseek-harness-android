/**
 * Lifetime of one supervised child process: spawn with piped output, a 64 KiB
 * combined log tail, idempotent start/stop/restart, and a tree kill so a
 * launcher that spawned its own children releases the ports.
 *
 * The Device Interconnect bundle owns two children with this supervisor: the
 * remote host and the NAT-traversal frpc. `label` names the child in the
 * user-facing failure messages.
 *
 * The supervisor owns no timer of its own: the exit event and the stop timeout
 * are the only asynchronous edges, and disposal awaits both.
 * @module @deepseek-ai/dsh-device-interconnect/host/supervisor
 */

import { spawn } from 'node:child_process'
import type { Readable } from 'node:stream'
import type { ChildState } from '../types.ts'

/** One child launch. */
export interface LaunchCommand {
  /** Executable that starts the child. */
  readonly file: string
  /** Arguments passed to the executable. */
  readonly args: readonly string[]
  /** Working directory of the child. */
  readonly cwd: string
  /** Complete environment of the child. */
  readonly env: NodeJS.ProcessEnv
}

/** The slice of a spawned child this supervisor relies on. */
export interface ManagedChild {
  /** Operating-system process id; absent only for an instantly failed spawn. */
  readonly pid?: number | undefined
  /** stdout stream, piped by the spawn call. */
  readonly stdout: Readable | null
  /** stderr stream, piped by the spawn call. */
  readonly stderr: Readable | null
  /** Listen for one event. */
  on(event: 'exit', listener: (code: number | null, signal: NodeJS.Signals | null) => void): void
  /** Listen for one event. */
  on(event: 'error', listener: (error: Error) => void): void
  /** Signal the child process only (no descendants). */
  kill(signal?: NodeJS.Signals): boolean
}

/** Starts one child process; injectable so unit tests need no real process. */
export type SpawnChild = (command: LaunchCommand) => ManagedChild

/** Kills one process tree; injectable so unit tests need no real process. */
export type KillTree = (pid: number) => Promise<void>

/** The slice of a spawned `taskkill` {@link killProcessTree} waits on. */
export interface KillerChild {
  /** Listen for the spawn failure or the process exit. */
  on(event: 'error' | 'exit', listener: () => void): void
}

/** Spawns `taskkill`; injectable so the Windows arm is unit-testable. */
export type KillerSpawner = (
  command: string,
  args: readonly string[],
  options: { readonly stdio: 'ignore'; readonly windowsHide: true },
) => KillerChild

/** Sends the non-Windows termination signal; injectable for tests. */
export type SignalSender = (pid: number, signal: NodeJS.Signals) => void

/** How {@link killProcessTree} reaches the operating system. */
export interface KillProcessTreeOptions {
  /** Platform that selects the strategy; defaults to `process.platform`. */
  readonly platform?: NodeJS.Platform
  /** Spawner used for `taskkill` on Windows; defaults to `node:child_process.spawn`. */
  readonly spawnProcess?: KillerSpawner
  /** Signal sender used elsewhere; defaults to `process.kill`. */
  readonly signalProcess?: SignalSender
}

/** Longest combined log tail the supervisor retains. */
export const LOG_TAIL_BYTES = 64 * 1_024

/** How long a stop waits for the child to exit before reporting the failure. */
export const STOP_TIMEOUT_MS = 10_000

/** Log sink the supervisor writes lifecycle lines to. */
export interface SupervisorLogger {
  /** Ordinary lifecycle line. */
  info(message: string, ...rest: unknown[]): void
  /** A child that failed to start or exit cleanly. */
  warn(message: string, ...rest: unknown[]): void
}

/** Options of one supervisor. */
export interface SupervisorOptions {
  /** Child launcher; defaults to `node:child_process.spawn`. */
  readonly spawn?: SpawnChild
  /** Process-tree killer; defaults to `taskkill /T /F` on Windows and a signal elsewhere. */
  readonly killTree?: KillTree
  /** Clock; defaults to `Date.now`. */
  readonly now?: () => number
  /** Retained combined output bytes; defaults to {@link LOG_TAIL_BYTES}. */
  readonly logLimitBytes?: number
  /** Stop grace period; defaults to {@link STOP_TIMEOUT_MS}. */
  readonly stopTimeoutMs?: number
  /** Platform that selects the default process-tree kill; defaults to `process.platform`. */
  readonly platform?: NodeJS.Platform
  /** User-facing name of this child in failure messages; defaults to the remote host. */
  readonly label?: string
  /** Lifecycle log sink. */
  readonly logger?: SupervisorLogger
}

/** A bounded tail of combined child output. */
class LogTail {
  private chunks: string[] = []
  private bytes = 0

  /** @param limitBytes - retained byte ceiling. */
  constructor(private readonly limitBytes: number) {}

  /**
   * Append output, dropping the oldest retained text past the ceiling.
   * @param chunk - one decoded output chunk.
   */
  append(chunk: string): void {
    if (chunk === '') return
    if (Buffer.byteLength(chunk, 'utf8') >= this.limitBytes) {
      // A single chunk at or over the ceiling keeps only its own tail.
      const tail = Buffer.from(chunk, 'utf8').subarray(-this.limitBytes).toString('utf8')
      this.chunks = [tail]
      this.bytes = Buffer.byteLength(tail, 'utf8')
      return
    }
    this.chunks.push(chunk)
    this.bytes += Buffer.byteLength(chunk, 'utf8')
    while (this.bytes > this.limitBytes && this.chunks.length > 0) {
      const dropped = this.chunks.shift()
      /* v8 ignore next -- the loop condition guarantees a retained chunk. */
      if (dropped === undefined) break
      this.bytes -= Buffer.byteLength(dropped, 'utf8')
    }
  }

  /** @returns the retained text, oldest first. */
  text(): string {
    return this.chunks.join('')
  }
}

/** The supervisor actions the bridge drives; {@link ChildSupervisor} is the production implementation. */
export interface SupervisorApi {
  /** @returns the current child state with its log tail. */
  status(): ChildState
  /**
   * Start the child unless one is already running.
   * @param command - launch command.
   */
  start(command: LaunchCommand): void
  /** Stop the child and its process tree. */
  stop(): Promise<void>
  /**
   * Stop then start again.
   * @param command - launch command of the new generation.
   */
  restart(command: LaunchCommand): Promise<void>
  /** Stop the child and refuse later starts. */
  dispose(): Promise<void>
}

/** The supervised child's lifetime. */
export class ChildSupervisor implements SupervisorApi {
  private readonly spawnChild: SpawnChild
  private readonly killTree: KillTree
  private readonly now: () => number
  private readonly stopTimeoutMs: number
  private readonly label: string
  private readonly logger: SupervisorLogger
  private readonly logs: LogTail
  private child: ManagedChild | undefined
  private startedAt: number | undefined
  private exitCode: number | undefined
  private exitedAt: number | undefined
  private error: string | undefined
  private disposed = false
  private exitWaiters: (() => void)[] = []

  /** @param options - launch, kill, clock, and log seams. */
  constructor(options: SupervisorOptions = {}) {
    this.spawnChild = options.spawn ?? spawnChild
    this.killTree = options.killTree ?? (pid => killProcessTree(pid, {
      ...(options.platform === undefined ? {} : { platform: options.platform }),
    }))
    this.now = options.now ?? Date.now
    this.stopTimeoutMs = options.stopTimeoutMs ?? STOP_TIMEOUT_MS
    this.label = options.label ?? '远程宿主'
    this.logger = options.logger ?? console
    this.logs = new LogTail(options.logLimitBytes ?? LOG_TAIL_BYTES)
  }

  /** @returns the current child state with its log tail. */
  status(): ChildState {
    const base: { -readonly [K in keyof ChildState]: ChildState[K] } = {
      running: this.child !== undefined,
      logsTail: this.logs.text(),
    }
    if (this.child !== undefined) {
      const pid = this.child.pid
      if (pid !== undefined) base.pid = pid
      if (this.startedAt !== undefined) base.startedAt = this.startedAt
    } else {
      if (this.startedAt !== undefined) base.startedAt = this.startedAt
      if (this.exitCode !== undefined) base.exitCode = this.exitCode
      if (this.exitedAt !== undefined) base.exitedAt = this.exitedAt
      if (this.error !== undefined) base.error = this.error
    }
    return base
  }

  /**
   * Start the child unless one is already running.
   * @param command - launch command.
   * @returns completion once the spawn was attempted; a failure is recorded in {@link status}.
   */
  start(command: LaunchCommand): void {
    if (this.disposed || this.child !== undefined) return
    this.exitCode = undefined
    this.exitedAt = undefined
    this.error = undefined
    this.startedAt = this.now()
    let child: ManagedChild
    try {
      child = this.spawnChild(command)
    } catch (error) {
      this.recordFailure(describeError(error))
      return
    }
    this.child = child
    this.logger.info('device-interconnect: supervised child started (pid %s)', String(child.pid ?? 'unknown'))
    child.stdout?.on('data', (chunk: Buffer | string) => {
      this.logs.append(typeof chunk === 'string' ? chunk : chunk.toString('utf8'))
    })
    child.stderr?.on('data', (chunk: Buffer | string) => {
      this.logs.append(typeof chunk === 'string' ? chunk : chunk.toString('utf8'))
    })
    child.on('exit', (code, signal) => {
      if (this.child !== child) return
      this.child = undefined
      this.exitCode = code ?? undefined
      this.exitedAt = this.now()
      if (code !== 0 && code !== null) {
        this.error = `${this.label}子进程退出（代码 ${String(code)}）`
        this.logger.warn('device-interconnect: child exited with code %s', String(code))
      } else if (signal !== null) {
        this.error = `${this.label}子进程被信号 ${signal} 结束`
        this.logger.warn('device-interconnect: child exited by signal %s', signal)
      }
      this.settleExit()
    })
    child.on('error', (cause) => {
      if (this.child !== child) return
      this.logs.append(`\n[device-interconnect] ${cause.message}\n`)
      this.recordFailure(cause.message)
    })
  }

  /**
   * Stop the child and its process tree, waiting for the exit within the
   * configured grace period. Idempotent.
   * @returns completion once the child is gone or the grace period elapsed.
   */
  async stop(): Promise<void> {
    const child = this.child
    if (child === undefined) return
    const exited = new Promise<void>((resolve) => { this.exitWaiters.push(resolve) })
    const pid = child.pid
    if (pid === undefined) {
      killQuietly(child)
    } else {
      try {
        await this.killTree(pid)
      } catch (error) {
        this.logger.warn('device-interconnect: process-tree kill failed: %s', describeError(error))
      }
    }
    const withinGrace = await this.waitForExit(exited)
    if (!withinGrace) {
      this.logger.warn('device-interconnect: child did not exit within %s ms; stopping supervision', String(this.stopTimeoutMs))
      this.child = undefined
      this.exitedAt = this.now()
      this.error = `${this.label}子进程未在停止等待时间内退出`
      this.settleExit()
    }
  }

  /**
   * Stop then start again; used after a configuration change.
   * @param command - launch command of the new generation.
   * @returns completion once the old child exited and the new spawn was attempted.
   */
  async restart(command: LaunchCommand): Promise<void> {
    await this.stop()
    this.start(command)
  }

  /**
   * Stop the child and refuse later starts.
   * @returns completion once the child is gone.
   */
  async dispose(): Promise<void> {
    this.disposed = true
    await this.stop()
  }

  /** Record a spawn failure and settle waiters. */
  private recordFailure(message: string): void {
    this.child = undefined
    this.exitCode = undefined
    this.exitedAt = this.now()
    this.error = message
    this.logger.warn('device-interconnect: child failed: %s', message)
    this.settleExit()
  }

  /** Resolve every waiter currently observing the exit. */
  private settleExit(): void {
    const waiters = this.exitWaiters
    this.exitWaiters = []
    for (const waiter of waiters) waiter()
  }

  /**
   * Race the exit against the grace period.
   * @param exited - promise resolved by the exit callback.
   * @returns whether the exit happened within the grace period.
   */
  private waitForExit(exited: Promise<void>): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let settled = false
      const timer = setTimeout(() => {
        if (settled) return
        settled = true
        resolve(false)
      }, this.stopTimeoutMs)
      void exited.then(() => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(true)
      })
    })
  }
}

/** Default child launcher: piped stdio, hidden console window, no shell. */
function spawnChild(command: LaunchCommand): ManagedChild {
  return spawn(command.file, [...command.args], {
    cwd: command.cwd,
    env: command.env,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  })
}

/** Default Windows `taskkill` spawner: forwards the two events the killer waits on. */
function spawnKiller(
  command: string,
  args: readonly string[],
  options: { readonly stdio: 'ignore'; readonly windowsHide: true },
): KillerChild {
  const killer = spawn(command, [...args], options)
  return {
    on(event: 'error' | 'exit', listener: () => void) {
      if (event === 'error') killer.on('error', () => { listener() })
      else killer.on('exit', () => { listener() })
    },
  }
}

/**
 * Kill one process tree: `taskkill /T /F` on Windows, so a launcher's own
 * children are terminated too, and SIGTERM elsewhere.
 * @param pid - process id to terminate.
 * @param options - platform and operating-system seams.
 * @returns completion once `taskkill` answered or the signal was sent.
 */
export async function killProcessTree(pid: number, options: KillProcessTreeOptions = {}): Promise<void> {
  if ((options.platform ?? process.platform) === 'win32') {
    const spawnProcess = options.spawnProcess ?? spawnKiller
    await new Promise<void>((resolve) => {
      const killer = spawnProcess('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true })
      killer.on('error', () => { resolve() })
      killer.on('exit', () => { resolve() })
    })
    return
  }
  const signalProcess = options.signalProcess ?? ((target, signal) => { process.kill(target, signal) })
  try {
    signalProcess(pid, 'SIGTERM')
  } catch (error) {
    // A child that already exited needs no signal; permission failures are reported by the caller's timeout.
    if (!isMissingProcess(error)) throw error
  }
}

/** Fallback kill for a child whose pid never became known. */
function killQuietly(child: ManagedChild): void {
  try {
    child.kill('SIGKILL')
  } catch (error) {
    // The child is already gone when the fallback kill throws ESRCH.
    if (!isMissingProcess(error)) return
  }
}

/** Whether a caught process error means the process no longer exists. */
function isMissingProcess(error: unknown): boolean {
  return typeof error === 'object' && error !== null && 'code' in error
    && (error as { readonly code?: unknown }).code === 'ESRCH'
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
