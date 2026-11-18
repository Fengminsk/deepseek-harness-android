/**
 * The Settings page's server bridge: it composes the persisted configuration,
 * the two supervised children (the remote host and the NAT-traversal frpc), and
 * the remote host's loopback control API into one snapshot, and turns each page
 * action into the corresponding effect.
 *
 * The tunnel is started only after the remote host is ready, and stopped before
 * the remote host stops; a tunnel failure never stops the remote host.
 *
 * Reads are cached for one second so several open pages polling at 2 s cannot
 * multiply loopback requests; actions invalidate the cache.
 * @module @deepseek-ai/dsh-device-interconnect/host/bridge
 */

import { existsSync } from 'node:fs'
import { dirname } from 'node:path'
import type {
  ControlPlaneState, DeviceInterconnectConfig, DeviceInterconnectView, Diagnostic, PairingView, ProvisionRequest,
  ProvisionStep, RuntimeState, TunnelAccount, TunnelFrpcInfo, TunnelInfo, TunnelNodeInfo, TunnelReadiness,
  TunnelSettings, TunnelSettingsView, TunnelState,
} from '../types.ts'
import { QR_ROUTE } from '../api.ts'
import { ConfigStore, ConfigValidationError, isDeviceId } from './config.ts'
import { ControlPlaneError, type ControlPlane } from './control-plane.ts'
import { downloadFrpc as downloadFrpcBinary } from './frpc-download.ts'
import { createTcpLatencyProbe, type LatencySample, type LatencyTarget } from './node-latency.ts'
import { overlayPath, writeOverlay } from './overlay.ts'
import { provisionSakuraFrpTunnel, withPendingSteps } from './provision.ts'
import { createSakuraFrpApi, type SakuraFrpApi } from './sakurafrp-api.ts'
import type { LaunchCommand, SupervisorApi } from './supervisor.ts'
import {
  TunnelError, TunnelProvisionError, derivePublicOrigin, frpcInstallPath, tunnelLaunchCommand, tunnelReadiness,
  withTunnelOrigin,
} from './tunnel.ts'

/** How often the tunnel startup waits for the remote host's listener. */
export const HOST_READY_POLL_MS = 500

/** How long the tunnel startup waits for the remote host's listener before giving up. */
export const HOST_READY_TIMEOUT_MS = 20_000

/** Options of one bridge. */
export interface BridgeOptions {
  /** Bundle data directory holding the configuration and the generated overlay. */
  readonly dataDir: string
  /** Persisted configuration. */
  readonly store: ConfigStore
  /** Remote-host child-process supervisor. */
  readonly supervisor: SupervisorApi
  /** frpc tunnel child-process supervisor. */
  readonly tunnelSupervisor: SupervisorApi
  /** Builds the control client for one loopback pairing page. */
  readonly controlPlane: (baseUrl: string) => ControlPlane
  /** Environment inherited by both children; defaults to this process's. */
  readonly env?: NodeJS.ProcessEnv
  /** Clock; defaults to `Date.now`. */
  readonly now?: () => number
  /** Control-plane read cache lifetime; defaults to 1000 ms. */
  readonly stateCacheMs?: number
  /** Existence probe for runner and tunnel readiness; defaults to `existsSync`. */
  readonly exists?: (path: string) => boolean
  /** Host-readiness poll interval; defaults to {@link HOST_READY_POLL_MS}. */
  readonly readinessPollMs?: number
  /** Host-readiness wait ceiling; defaults to {@link HOST_READY_TIMEOUT_MS}. */
  readonly readinessTimeoutMs?: number
  /** Builds the SakuraFrp API client of one access key; defaults to the real service. */
  readonly sakurafrpApi?: (token: string) => SakuraFrpApi
  /** Downloads frpc for the automatic provision; defaults to the SakuraFrp download. */
  readonly downloadFrpc?: (dataDir: string) => Promise<{ readonly path: string; readonly version: string }>
  /** Node latency probe used by the automatic provision; defaults to a TCP connect probe. */
  readonly latencyProbe?: (targets: readonly LatencyTarget[]) => Promise<readonly LatencySample[]>
  /** Platform used for the frpc install path; defaults to `process.platform`. */
  readonly platform?: NodeJS.Platform
  /** CPU architecture used for the frpc download; defaults to `process.arch`. */
  readonly arch?: string
  /** Auto-restart backoff for an unexpected child exit; defaults to 2s→4s→…→30s. */
  readonly restartDelaysMs?: readonly number[]
  /** A restarted child is considered healthy after this long; defaults to 10s. */
  readonly restartHealthyMs?: number
  /** Lifecycle log sink. */
  readonly logger?: {
    info(message: string, ...rest: unknown[]): void
    warn(message: string, ...rest: unknown[]): void
    error(message: string, ...rest: unknown[]): void
  }
}

/** One cached control-plane read, either the state or the failure that replaced it. */
type ControlPlaneRead =
  | { readonly ok: true; readonly state: ControlPlaneState }
  | { readonly ok: false; readonly error: Diagnostic }

/** Default auto-restart backoff: 2s, 4s, 8s, 16s, 30s (cap). */
const DEFAULT_RESTART_DELAYS_MS: readonly number[] = [2_000, 4_000, 8_000, 16_000, 30_000]
/** Consecutive restart attempts allowed before giving up. */
const MAX_RESTART_ATTEMPTS = 5
/** A restarted child that stays up this long resets the failure chain. */
const DEFAULT_RESTART_HEALTHY_MS = 10_000

/** One child's auto-restart bookkeeping. */
interface ChildRecovery {
  restartCount: number
  attempts: number
  nextRetryAt: number | undefined
  exhausted: boolean
  timer: NodeJS.Timeout | undefined
  healthyTimer: NodeJS.Timeout | undefined
}

/** The Settings page bridge. */
export class Bridge {
  private readonly dataDir: string
  private readonly store: ConfigStore
  private readonly supervisor: SupervisorApi
  private readonly tunnelSupervisor: SupervisorApi
  private readonly controlPlane: (baseUrl: string) => ControlPlane
  private readonly env: NodeJS.ProcessEnv
  private readonly now: () => number
  private readonly stateCacheMs: number
  private readonly readinessPollMs: number
  private readonly readinessTimeoutMs: number
  private readonly exists: (path: string) => boolean
  private readonly logger: NonNullable<BridgeOptions['logger']>
  private readonly sakurafrpApi: (token: string) => SakuraFrpApi
  private readonly downloadFrpcDependency: (dataDir: string) => Promise<{ readonly path: string; readonly version: string }>
  private readonly latencyProbe: (targets: readonly LatencyTarget[]) => Promise<readonly LatencySample[]>
  private readonly platform: NodeJS.Platform
  private readonly arch: string
  private readonly restartDelaysMs: readonly number[]
  private readonly restartHealthyMs: number
  private readonly hostRecovery: ChildRecovery = Bridge.recovery()
  private readonly tunnelRecovery: ChildRecovery = Bridge.recovery()
  /** Intent state: true when the child is supposed to run (unexpected exit means restart). */
  private hostDesired = false
  private tunnelDesired = false
  /** Set while the bridge itself stops/restarts a child, so the exit is expected. */
  private hostProgrammatic = false
  private tunnelProgrammatic = false
  private readonly activationProblems: Diagnostic[]
  private cachedRead: { readonly at: number; readonly read: ControlPlaneRead } | undefined
  private appliedPublicOrigin: string | undefined
  private disposed = false
  private tunnelStartup: AbortController | undefined
  private tunnelStartupTask: Promise<void> | undefined
  private provisionInFlight: Promise<RuntimeState> | undefined
  private provisionAccount: TunnelAccount | undefined
  private provisionNode: TunnelNodeInfo | undefined
  private provisionTunnelInfo: TunnelInfo | undefined
  private provisionFrpc: { readonly path: string; readonly downloaded: boolean; readonly version?: string } | undefined
  private provisionSteps: readonly ProvisionStep[] = []
  private provisionError: Diagnostic | undefined
  private provisionWarning: string | undefined

  /** @param options - the composed services and seams. */
  constructor(options: BridgeOptions) {
    this.dataDir = options.dataDir
    this.store = options.store
    this.supervisor = options.supervisor
    this.tunnelSupervisor = options.tunnelSupervisor
    this.controlPlane = options.controlPlane
    this.env = options.env ?? process.env
    this.now = options.now ?? Date.now
    this.stateCacheMs = options.stateCacheMs ?? 1_000
    this.readinessPollMs = options.readinessPollMs ?? HOST_READY_POLL_MS
    this.readinessTimeoutMs = options.readinessTimeoutMs ?? HOST_READY_TIMEOUT_MS
    this.exists = options.exists ?? existsSync
    this.logger = options.logger ?? console
    this.sakurafrpApi = options.sakurafrpApi ?? (token => createSakuraFrpApi({ token }))
    this.platform = options.platform ?? process.platform
    this.arch = options.arch ?? process.arch
    this.downloadFrpcDependency = options.downloadFrpc ?? (dataDir => downloadFrpcBinary({
      dataDir,
      platform: this.platform,
      arch: this.arch,
    }))
    this.latencyProbe = options.latencyProbe ?? createTcpLatencyProbe()
    this.restartDelaysMs = options.restartDelaysMs ?? DEFAULT_RESTART_DELAYS_MS
    this.restartHealthyMs = options.restartHealthyMs ?? DEFAULT_RESTART_HEALTHY_MS
    this.activationProblems = this.store.problems().map(message => ({ code: 'config-unreadable', message }))
    this.supervisor.on('exit', () => { this.onChildExit('host') })
    this.tunnelSupervisor.on('exit', () => { this.onChildExit('tunnel') })
  }

  /**
   * Apply the persisted configuration at activation: start the remote host when
   * the switch is on, then the tunnel once that host is ready. A start failure
   * is reported by {@link state}, never thrown into the plugin activation.
   * @returns completion once the start was attempted; the tunnel start keeps
   * waiting in the background.
   */
  async initialize(): Promise<void> {
    try {
      await this.apply(false)
    } catch (error) {
      const problem: Diagnostic = { code: 'config-apply-failed', message: `应用设备互联配置失败：${describeError(error)}` }
      this.activationProblems.push(problem)
      this.logger.error('device-interconnect: %s', problem.message)
    }
    this.deferTunnelStart()
  }

  /**
   * Build the runtime snapshot the page renders.
   * @returns configuration, both child states, control-plane facts, pairing view, devices, and problems.
   */
  async state(): Promise<RuntimeState> {
    const config = this.store.current()
    const read = await this.readControlPlane(config)
    return this.snapshot(config, read)
  }

  /**
   * Switch the supervised remote host on or off. Turning it off stops the
   * tunnel first; turning it on starts the tunnel once the host is ready.
   * @param enabled - the requested switch position.
   * @returns the snapshot after the change.
   * @throws {ConfigValidationError} when the body is not a boolean.
   */
  async setEnabled(enabled: unknown): Promise<RuntimeState> {
    if (typeof enabled !== 'boolean') throw new ConfigValidationError(['enabled 必须是 true 或 false。'])
    const candidate = { ...this.store.current(), enabled }
    await this.store.save(candidate)
    await this.apply(false)
    if (enabled) this.deferTunnelStart()
    this.cachedRead = undefined
    return this.state()
  }

  /**
   * Start or stop the managed tunnel without touching the remote host switch.
   * @param enabled - whether the frpc child should run.
   * @returns the snapshot after the change.
   * @throws {ConfigValidationError} when the body is not a boolean.
   * @throws {TunnelError} when the tunnel cannot start yet.
   */
  async setTunnelEnabled(enabled: unknown): Promise<RuntimeState> {
    if (typeof enabled !== 'boolean') throw new ConfigValidationError(['tunnel.enabled 必须是 true 或 false。'])
    this.cachedRead = undefined
    if (!enabled) {
      this.tunnelDesired = false
      this.cancelTunnelStartup()
      await this.stopTunnelChild()
      return this.state()
    }
    const { task } = this.startTunnelStartup(signal => this.startTunnelNow(signal))
    await task
    return this.state()
  }

  /**
   * Validate the access key, then create or reuse a SakuraFrp TCP tunnel, align
   * the public origin, and start frpc.
   *
   * Only one provision runs at a time: a concurrent or repeated request joins
   * the attempt in flight instead of creating a second tunnel. The submitted
   * fields are persisted before the first API call so a retry can reuse the same
   * access key; a failed attempt keeps the previous tunnel settings and only
   * records the steps it reached.
   * @param candidate - optional fields from the page, overriding saved settings.
   * @returns the snapshot after the attempt, including the provision steps.
   * @throws {ConfigValidationError} when a submitted field has the wrong type.
   */
  async provisionTunnel(candidate: unknown): Promise<RuntimeState> {
    const inFlight = this.provisionInFlight
    if (inFlight !== undefined) return inFlight
    const task = this.runProvision(candidate)
    this.provisionInFlight = task
    try {
      return await task
    } finally {
      if (this.provisionInFlight === task) this.provisionInFlight = undefined
    }
  }

  /**
   * One provision attempt; {@link provisionTunnel} guarantees it never overlaps
   * another attempt.
   * @param candidate - optional fields from the page.
   * @returns the snapshot after the attempt.
   */
  private async runProvision(candidate: unknown): Promise<RuntimeState> {
    const request = readProvisionRequest(candidate)
    this.cachedRead = undefined
    const current = this.store.current()
    const token = request.token === undefined ? current.tunnel.token : request.token
    const submitted: TunnelSettings = {
      ...current.tunnel,
      provider: 'sakurafrp',
      autoProvision: true,
      ...(token === null ? { token: '' } : { token }),
      ...(request.frpcPath === undefined ? {} : { frpcPath: request.frpcPath }),
      ...(request.frpcAutoDownload === undefined ? {} : { frpcAutoDownload: request.frpcAutoDownload }),
      ...(request.nodeId === undefined ? {} : { nodeId: request.nodeId }),
      ...(request.tunnelName === undefined ? {} : { tunnelName: request.tunnelName }),
    }
    if (token === '' || token === null) {
      this.provisionSteps = withPendingSteps([], 'verify-token', '未配置 SakuraFrp 访问密钥。')
      this.provisionError = { code: 'tunnel-token-missing', message: '未配置 SakuraFrp 访问密钥：请先填写访问密钥。' }
      return this.state()
    }
    // Persist the access key and mode now, so the API calls and a retry have them.
    await this.store.save({ ...current, enabled: true, tunnel: submitted })
    const result = await this.tryProvision(this.store.current().tunnel, token, request)
    this.provisionSteps = result.steps
    this.provisionError = result.error
    this.cachedRead = undefined
    return this.state()
  }

  /**
   * Run one provision attempt, then start the tunnel when it succeeded.
   * @param tunnel - settings in force at the start of the attempt.
   * @param token - effective access key.
   * @param request - page submission controlling reuse and the local target.
   * @returns the complete step list and the failure when one occurred.
   */
  private async tryProvision(
    tunnel: TunnelSettings,
    token: string,
    request: ReturnType<typeof readProvisionRequest>,
  ): Promise<{ readonly steps: readonly ProvisionStep[]; readonly error?: Diagnostic }> {
    try {
      const explicitNodeId = request.nodeId !== undefined && request.nodeId !== null && request.nodeId > 0
        ? request.nodeId
        : undefined
      const result = await provisionSakuraFrpTunnel(tunnel, {
        api: this.sakurafrpApi(token),
        localPort: this.store.current().host.port,
        ...(request.reuseExisting === undefined ? {} : { reuseExisting: request.reuseExisting }),
        ...(explicitNodeId === undefined ? {} : { explicitNodeId }),
        probeLatency: targets => this.latencyProbe(targets),
        resolveFrpcPath: () => this.frpcPathFor(this.store.current().tunnel),
        downloadFrpc: () => this.downloadFrpcDependency(this.dataDir),
        // Persist the resolved tunnel id before the remaining steps can fail, so
        // a retry reuses it even after a rename and never leaves an orphan.
        onTunnelResolved: async resolved => {
          const saved = this.store.current()
          await this.store.save({
            ...saved,
            tunnel: {
              ...saved.tunnel,
              provider: 'sakurafrp',
              autoProvision: true,
              tunnelId: resolved.id,
              nodeId: resolved.nodeId,
              tunnelIds: String(resolved.id),
            },
          })
          this.logger.info('device-interconnect: provisioned SakuraFrp tunnel %s persisted', String(resolved.id))
        },
      })
      this.provisionAccount = result.account
      this.provisionNode = result.node
      this.provisionTunnelInfo = result.tunnel
      this.provisionFrpc = result.frpc
      this.provisionWarning = result.warning
      await this.store.save({ ...this.store.current(), enabled: true, tunnel: result.settings })
      // Restart the remote host so the new derived origin reaches its overlay.
      await this.apply(true)
      return await this.startTunnelAfterProvision(result.steps)
    } catch (error) {
      if (error instanceof TunnelProvisionError) {
        return { steps: error.steps, error: { code: error.code, message: error.message } }
      }
      const message = describeError(error)
      return { steps: withPendingSteps([], 'verify-token', message), error: { code: 'provision-failed', message } }
    }
  }

  /**
   * Append the start step to a successful provision by starting the tunnel.
   * @param steps - steps recorded by the provision.
   * @returns the complete step list and the start failure when it occurred.
   */
  private async startTunnelAfterProvision(
    steps: readonly ProvisionStep[],
  ): Promise<{ readonly steps: readonly ProvisionStep[]; readonly error?: Diagnostic }> {
    const withoutStart = steps.filter(step => step.id !== 'start-tunnel')
    try {
      const { task } = this.startTunnelStartup(signal => this.startTunnelNow(signal))
      await task
      return { steps: [...withoutStart, { id: 'start-tunnel', status: 'done', message: 'frpc 隧道已启动，配对链接使用新的公网地址。' }] }
    } catch (error) {
      const message = describeError(error)
      return {
        steps: [...withoutStart, { id: 'start-tunnel', status: 'failed', message }],
        error: error instanceof TunnelError
          ? { code: error.code, message: error.message }
          : { code: 'tunnel-start-failed', message },
      }
    }
  }

  /**
   * Validate and persist a complete configuration, applying it to a running
   * child; the tunnel is restarted after the remote host applies the new origin.
   * @param candidate - submitted configuration document.
   * @returns the snapshot after the change.
   * @throws {ConfigValidationError} when the document is unusable.
   */
  async saveConfig(candidate: unknown): Promise<RuntimeState> {
    const saved = await this.store.save(candidate)
    await this.apply(saved.enabled)
    if (saved.enabled) this.deferTunnelStart()
    this.cachedRead = undefined
    return this.state()
  }

  /**
   * Reopen the long-term pairing window on the running remote host.
   * @returns the snapshot after the new window opened.
   * @throws {ControlPlaneError} when the control API refuses or is unreachable.
   */
  async pair(): Promise<RuntimeState> {
    const config = this.store.current()
    await this.controlPlaneFor(config).pair()
    this.cachedRead = undefined
    return this.state()
  }

  /**
   * Revoke one paired device.
   * @param deviceId - device id from the page.
   * @returns the snapshot after the revocation.
   * @throws {ControlPlaneError} when the id is malformed or the control API refuses.
   */
  async revoke(deviceId: unknown): Promise<RuntimeState> {
    if (!isDeviceId(deviceId)) throw new ControlPlaneError('invalid-device-id', '设备 id 不合法。')
    const config = this.store.current()
    await this.controlPlaneFor(config).revoke(deviceId)
    this.cachedRead = undefined
    return this.state()
  }

  /**
   * Permanently delete one paired device record. An active device is revoked
   * first by the remote host (its connections close and it must pair again), then
   * the record is removed; the page keeps both actions distinct.
   * @param deviceId - device id from the page.
   * @returns the snapshot after the deletion.
   * @throws {ControlPlaneError} when the id is malformed or the control API refuses.
   */
  async deleteDevice(deviceId: unknown): Promise<RuntimeState> {
    if (!isDeviceId(deviceId)) throw new ControlPlaneError('invalid-device-id', '设备 id 不合法。')
    const config = this.store.current()
    await this.controlPlaneFor(config).deleteDevice(deviceId)
    this.cachedRead = undefined
    return this.state()
  }

  /**
   * The remote-host child's combined output tail, for the page's log disclosure.
   * @returns the retained output text.
   */
  logs(): string {
    return this.supervisor.status().logsTail
  }

  /**
   * The frpc child's combined output tail.
   * @returns the retained output text.
   */
  tunnelLogs(): string {
    return this.tunnelSupervisor.status().logsTail
  }

  /**
   * Proxy the QR SVG of the currently open pairing window so the page loads it
   * from its own origin, with no cross-origin image request.
   * @returns the SVG document.
   * @throws {ControlPlaneError} when no window is open or the control API is unreachable.
   */
  async qrSvg(): Promise<string> {
    return this.controlPlaneFor(this.store.current()).qrSvg()
  }

  /**
   * Stop the tunnel and then the remote host.
   * @returns completion once both children are gone.
   */
  async dispose(): Promise<void> {
    this.disposed = true
    this.hostDesired = false
    this.tunnelDesired = false
    for (const recovery of [this.hostRecovery, this.tunnelRecovery]) {
      if (recovery.timer !== undefined) clearTimeout(recovery.timer)
      recovery.timer = undefined
      recovery.nextRetryAt = undefined
      if (recovery.healthyTimer !== undefined) clearTimeout(recovery.healthyTimer)
      recovery.healthyTimer = undefined
    }
    this.cancelTunnelStartup()
    const pending = this.tunnelStartupTask
    if (pending !== undefined) await pending
    await this.tunnelSupervisor.dispose()
    await this.supervisor.dispose()
  }

  /** Empty auto-restart bookkeeping for one child. */
  private static recovery(): ChildRecovery {
    return { restartCount: 0, attempts: 0, nextRetryAt: undefined, exhausted: false, timer: undefined, healthyTimer: undefined }
  }

  private recoveryOf(kind: 'host' | 'tunnel'): ChildRecovery {
    return kind === 'host' ? this.hostRecovery : this.tunnelRecovery
  }

  /**
   * One supervised child ended. Unexpected exits of a child the configuration
   * wants running are restarted with capped exponential backoff; intentional
   * stops (user switch, restart, dispose) carry `programmatic` and are ignored.
   * @param kind - which child ended.
   */
  private onChildExit(kind: 'host' | 'tunnel'): void {
    if (this.disposed) return
    const desired = kind === 'host' ? this.hostDesired : this.tunnelDesired
    const programmatic = kind === 'host' ? this.hostProgrammatic : this.tunnelProgrammatic
    if (!desired || programmatic) return
    const info = this.recoveryOf(kind)
    if (info.exhausted || info.timer !== undefined) return
    if (info.attempts >= MAX_RESTART_ATTEMPTS) {
      info.exhausted = true
      info.nextRetryAt = undefined
      this.logger.error('device-interconnect: %s child crashed %s times; auto-restart stopped', kind, String(info.attempts))
      return
    }
    const delay = this.restartDelaysMs[Math.min(info.attempts, this.restartDelaysMs.length - 1)] ?? 30_000
    info.attempts += 1
    info.restartCount += 1
    info.nextRetryAt = this.now() + delay
    info.timer = setTimeout(() => { void this.attemptRestart(kind) }, delay)
    info.timer.unref?.()
    this.logger.warn('device-interconnect: %s child exited unexpectedly; restart in %s ms (attempt %s)', kind, String(delay), String(info.attempts))
  }

  /**
   * Execute one scheduled auto-restart. The host restarts first, then the tunnel
   * waits for host readiness again; the tunnel child restarts on its own.
   * @param kind - which child to restart.
   */
  private async attemptRestart(kind: 'host' | 'tunnel'): Promise<void> {
    const info = this.recoveryOf(kind)
    info.timer = undefined
    info.nextRetryAt = undefined
    if (this.disposed || info.exhausted) return
    const config = this.store.current()
    try {
      if (kind === 'host') {
        if (!config.enabled || !this.runnerReadiness(config).ready) {
          this.hostDesired = false
          info.attempts = 0
          return
        }
        await this.applyOverlay(config)
        if (this.disposed) return
        this.supervisor.start(this.launchCommand(config))
        this.hostDesired = this.supervisor.status().running
        if (!this.hostDesired) {
          this.onChildExit('host')
          return
        }
        this.scheduleHealthyReset('host')
        // The new host generation has a fresh origin/listener: the tunnel waits again.
        this.tunnelDesired = false
        this.cancelTunnelStartup()
        await this.stopTunnelChild()
        if (this.tunnelWanted(config)) this.deferTunnelStart()
        return
      }
      if (!this.tunnelWanted(config) || !this.supervisor.status().running) {
        this.tunnelDesired = false
        info.attempts = 0
        return
      }
      this.tunnelSupervisor.start(tunnelLaunchCommand(config.tunnel, this.dataDir, this.env, this.frpcPathFor(config.tunnel)))
      this.tunnelDesired = this.tunnelSupervisor.status().running
      if (this.tunnelDesired) this.scheduleHealthyReset('tunnel')
      else this.onChildExit('tunnel')
    } catch (error) {
      this.logger.warn('device-interconnect: %s auto-restart failed: %s', kind, describeError(error))
      this.onChildExit(kind)
    }
  }

  /** Reset the consecutive-failure chain once a restarted child stays up. */
  private scheduleHealthyReset(kind: 'host' | 'tunnel'): void {
    const info = this.recoveryOf(kind)
    if (info.healthyTimer !== undefined) clearTimeout(info.healthyTimer)
    info.healthyTimer = setTimeout(() => {
      info.healthyTimer = undefined
      const status = kind === 'host' ? this.supervisor.status() : this.tunnelSupervisor.status()
      if (!this.disposed && status.running) {
        info.attempts = 0
        info.nextRetryAt = undefined
      }
    }, this.restartHealthyMs)
    info.healthyTimer.unref?.()
  }

  /** Stop the host child without letting the exit trigger auto-restart. */
  private async stopHostChild(): Promise<void> {
    this.hostProgrammatic = true
    try {
      await this.supervisor.stop()
    } finally {
      this.hostProgrammatic = false
    }
  }

  /** Restart the host child without letting the old exit trigger auto-restart. */
  private async restartHostChild(command: LaunchCommand): Promise<void> {
    this.hostProgrammatic = true
    try {
      await this.supervisor.restart(command)
    } finally {
      this.hostProgrammatic = false
    }
  }

  /** Stop the tunnel child without letting the exit trigger auto-restart. */
  private async stopTunnelChild(): Promise<void> {
    this.tunnelProgrammatic = true
    try {
      await this.tunnelSupervisor.stop()
    } finally {
      this.tunnelProgrammatic = false
    }
  }

  /** Start, stop, or restart both children so the current configuration is in force. */
  private async apply(restart: boolean): Promise<void> {
    const config = this.store.current()
    // A restarted or disabled remote host invalidates the tunnel mapping, so the
    // tunnel always stops first; the callers start it again once the host is ready.
    if (restart || !this.tunnelWanted(config)) {
      this.tunnelDesired = false
      this.cancelTunnelStartup()
      await this.stopTunnelChild()
    }
    if (!config.enabled) {
      this.hostDesired = false
      await this.stopHostChild()
      return
    }
    const readiness = this.runnerReadiness(config)
    if (!readiness.ready) {
      this.hostDesired = false
      return
    }
    await this.applyOverlay(config)
    const command = this.launchCommand(config)
    if (restart) {
      this.hostDesired = true
      await this.restartHostChild(command)
      if (this.supervisor.status().running) this.scheduleHealthyReset('host')
      return
    }
    if (!this.supervisor.status().running) this.supervisor.start(command)
    this.hostDesired = this.supervisor.status().running
    if (this.hostDesired) this.scheduleHealthyReset('host')
  }

  /** Write the generated overlay, recording the origin the child will announce. */
  private async applyOverlay(config: DeviceInterconnectConfig): Promise<void> {
    const effective = withTunnelOrigin(config)
    await writeOverlay(overlayPath(this.dataDir), effective)
    this.appliedPublicOrigin = effective.host.publicOrigin
  }

  /** Assemble the snapshot from one configuration and control-plane read. */
  private snapshot(config: DeviceInterconnectConfig, read: ControlPlaneRead): RuntimeState {
    const cpState = read.ok ? read.state : undefined
    const controlPlane: RuntimeState['controlPlane'] = read.ok
      ? { reachable: true, ...(cpState?.host === undefined ? {} : { host: cpState.host }) }
      : { reachable: false, error: read.error }
    return {
      config: this.view(config),
      child: this.supervisor.status(),
      tunnel: this.tunnelState(config),
      controlPlane,
      pairing: this.pairingView(config, cpState),
      devices: cpState?.devices ?? [],
      runner: this.runnerReadiness(config),
      recovery: {
        host: this.recoveryView(this.hostRecovery),
        tunnel: this.recoveryView(this.tunnelRecovery),
      },
      problems: [...this.activationProblems, ...this.recoveryProblems()],
    }
  }

  /** Project one child's auto-restart bookkeeping onto the wire document. */
  private recoveryView(info: ChildRecovery): {
    restartCount: number
    nextRetryAt?: number
    exhausted?: boolean
  } {
    return {
      restartCount: info.restartCount,
      ...(info.nextRetryAt === undefined ? {} : { nextRetryAt: info.nextRetryAt }),
      ...(info.exhausted ? { exhausted: true } : {}),
    }
  }

  /** Problems reported after auto-restart stopped retrying. */
  private recoveryProblems(): Diagnostic[] {
    const problems: Diagnostic[] = []
    if (this.hostRecovery.exhausted) {
      problems.push({
        code: 'remote-host-restart-exhausted',
        message: '远程宿主连续异常退出，已停止自动重启；请检查运行器配置或手动重新启用。',
      })
    }
    if (this.tunnelRecovery.exhausted) {
      problems.push({
        code: 'frpc-restart-exhausted',
        message: 'frpc 隧道子进程连续异常退出，已停止自动重启；请检查隧道配置后手动启动。',
      })
    }
    return problems
  }

  /** Project the persisted configuration onto the wire document, dropping the access key. */
  private view(config: DeviceInterconnectConfig): DeviceInterconnectView {
    const tunnel: TunnelSettingsView = {
      provider: config.tunnel.provider,
      frpcPath: config.tunnel.frpcPath,
      tunnelIds: config.tunnel.tunnelIds,
      publicAddress: config.tunnel.publicAddress,
      iniPath: config.tunnel.iniPath,
      extraArgs: config.tunnel.extraArgs,
      tokenConfigured: config.tunnel.token !== '',
      autoProvision: config.tunnel.autoProvision,
      frpcAutoDownload: config.tunnel.frpcAutoDownload,
      nodeId: config.tunnel.nodeId,
      tunnelName: config.tunnel.tunnelName,
      tunnelId: config.tunnel.tunnelId,
    }
    return { enabled: config.enabled, runner: config.runner, host: config.host, pairing: config.pairing, tunnel }
  }

  /** Project the tunnel child and its derived facts into the page view. */
  private tunnelState(config: DeviceInterconnectConfig): TunnelState {
    const readiness = this.configTunnelReadiness(config)
    const frpc = this.frpcInfo(config.tunnel)
    const node = this.provisionNode
      ?? (config.tunnel.nodeId !== null && config.tunnel.nodeId > 0 ? { id: config.tunnel.nodeId } : undefined)
    const tunnelInfo = this.provisionTunnelInfo
      ?? (config.tunnel.tunnelId !== null && config.tunnel.tunnelId > 0
        ? {
          id: config.tunnel.tunnelId,
          name: config.tunnel.tunnelName,
          ...remoteOfAddress(config.tunnel.publicAddress),
        }
        : undefined)
    const provision = this.provisionSteps.length === 0
      ? undefined
      : {
        lastSteps: this.provisionSteps,
        ...(this.provisionError === undefined ? {} : { lastError: this.provisionError }),
        ...(this.provisionWarning === undefined ? {} : { warning: this.provisionWarning }),
      }
    return {
      ...this.tunnelSupervisor.status(),
      provider: config.tunnel.provider,
      ready: readiness.ready,
      problems: readiness.problems,
      derivedPublicOrigin: derivePublicOrigin(config.tunnel),
      ...(this.provisionAccount === undefined ? {} : { account: this.provisionAccount }),
      ...(provision === undefined ? {} : { provision }),
      ...(node === undefined ? {} : { node }),
      ...(tunnelInfo === undefined ? {} : { tunnel: tunnelInfo }),
      ...(frpc === undefined ? {} : { frpc }),
    }
  }

  /** Resolve the frpc executable the launch and readiness checks use. */
  private frpcPathFor(tunnel: TunnelSettings): string {
    if (tunnel.frpcPath !== '') return tunnel.frpcPath
    // Only the automatic provision may run the plugin-downloaded binary.
    if (!tunnel.autoProvision) return ''
    const managed = frpcInstallPath(this.dataDir, this.platform)
    return this.exists(managed) ? managed : ''
  }

  /** Project the resolved frpc executable facts onto the page view. */
  private frpcInfo(tunnel: TunnelSettings): TunnelFrpcInfo | undefined {
    const path = this.frpcPathFor(tunnel)
    if (path === '') return undefined
    const managed = frpcInstallPath(this.dataDir, this.platform)
    const cached = this.provisionFrpc?.path === path ? this.provisionFrpc : undefined
    const downloaded = path === managed || cached?.downloaded === true
    const version = cached?.version
    return { path, downloaded, ...(version === undefined ? {} : { version }) }
  }

  /** Whether the current configuration asks for and can start the tunnel. */
  private tunnelWanted(config: DeviceInterconnectConfig): boolean {
    return config.enabled && config.tunnel.provider === 'sakurafrp' && this.configTunnelReadiness(config).ready
  }

  /** Build the tunnel readiness of one configuration. */
  private configTunnelReadiness(config: DeviceInterconnectConfig): TunnelReadiness {
    return tunnelReadiness(config.tunnel, this.exists, this.frpcPathFor(config.tunnel))
  }

  /** Project the control-plane window into the page view. */
  private pairingView(config: DeviceInterconnectConfig, state: ControlPlaneState | undefined): PairingView {
    const longTerm = config.pairing.longTerm
    const window = state?.pairing
    if (window?.open !== true || window.expiresAt === undefined || window.pairUrl === undefined) {
      return { open: false, longTerm }
    }
    return {
      open: true,
      expiresAt: window.expiresAt,
      pairUrl: window.pairUrl,
      ...(window.usbPairUrl === undefined ? {} : { usbPairUrl: window.usbPairUrl }),
      longTerm,
      qrSvgUrl: `${QR_ROUTE}?v=${String(window.expiresAt)}`,
    }
  }

  /** Read the control plane, reusing a read younger than the cache lifetime. */
  private async readControlPlane(config: DeviceInterconnectConfig): Promise<ControlPlaneRead> {
    const cached = this.cachedRead
    if (cached !== undefined && this.now() - cached.at < this.stateCacheMs) return cached.read
    let read: ControlPlaneRead
    if (!config.host.pagesEnabled) {
      read = { ok: false, error: { code: 'pages-disabled', message: '本机配对页已关闭，配对信息不可用；重新开启后可用。' } }
    } else {
      try {
        read = { ok: true, state: await this.controlPlaneFor(config).state() }
      } catch (error) {
        read = { ok: false, error: diagnosticOf(error) }
      }
    }
    this.cachedRead = { at: this.now(), read }
    return read
  }

  /** Build the control client of the configured page port. */
  private controlPlaneFor(config: DeviceInterconnectConfig): ControlPlane {
    return this.controlPlane(`http://127.0.0.1:${String(config.host.pagesPort)}`)
  }

  /**
   * Start the tunnel after the remote host is ready, when the configuration
   * still asks for it. Runs in the background so page actions and activation
   * never wait for the remote host's boot.
   */
  private deferTunnelStart(): void {
    if (this.disposed) return
    const config = this.store.current()
    if (!this.tunnelWanted(config) || !this.supervisor.status().running) return
    const { task } = this.startTunnelStartup(signal => this.startTunnelWhenReady(signal))
    void task.catch((error: unknown) => {
      this.logger.warn('device-interconnect: deferred frpc tunnel start failed: %s', describeError(error))
    })
  }

  /**
   * One background tunnel start: wait for the host, then spawn frpc unless the
   * configuration changed or the page stopped the tunnel meanwhile.
   * @param signal - aborted by disposal or a newer start/stop action.
   */
  private async startTunnelWhenReady(signal: AbortSignal): Promise<void> {
    const config = this.store.current()
    const ready = await this.waitForHostReady(config, signal)
    if (this.disposed || signal.aborted) return
    if (!ready) {
      this.logger.warn('device-interconnect: frpc tunnel not started because the remote host did not become ready')
      return
    }
    const current = this.store.current()
    if (!this.tunnelWanted(current) || this.tunnelSupervisor.status().running) return
    this.tunnelSupervisor.start(tunnelLaunchCommand(current.tunnel, this.dataDir, this.env, this.frpcPathFor(current.tunnel)))
    this.tunnelDesired = this.tunnelSupervisor.status().running
    if (this.tunnelDesired) this.scheduleHealthyReset('tunnel')
    this.logger.info('device-interconnect: frpc tunnel child started')
  }

  /**
   * One explicit tunnel start: refuse a configuration that cannot start, apply
   * the derived origin to the running remote host, then spawn frpc.
   * @param signal - aborted by disposal or a newer start/stop action.
   * @throws {TunnelError} when the tunnel cannot start.
   */
  private async startTunnelNow(signal: AbortSignal): Promise<void> {
    const config = this.store.current()
    if (config.tunnel.provider !== 'sakurafrp') {
      throw new TunnelError('tunnel-provider-off', 400, '未启用 SakuraFrp 隧道：请先在内网穿透设置里选择 SakuraFrp 并保存。')
    }
    const readiness = this.configTunnelReadiness(config)
    if (!readiness.ready) {
      throw new TunnelError(
        'tunnel-not-ready',
        400,
        `内网穿透设置不完整：${readiness.problems.map(problem => problem.message).join('；')}`,
      )
    }
    if (!config.enabled) throw new TunnelError('tunnel-host-not-running', 409, '远程宿主开关未开启，请先启用远程宿主。')
    if (!this.supervisor.status().running) {
      throw new TunnelError('tunnel-host-not-running', 409, '远程宿主未运行，请先启用远程宿主后再启动隧道。')
    }
    await this.syncHostOrigin(config)
    const ready = await this.waitForHostReady(config, signal)
    if (this.disposed || signal.aborted) return
    if (!ready) throw new TunnelError('tunnel-host-not-ready', 409, '远程宿主尚未就绪（监听端口未确认），请稍后重试。')
    if (this.tunnelSupervisor.status().running) return
    this.tunnelSupervisor.start(tunnelLaunchCommand(config.tunnel, this.dataDir, this.env, this.frpcPathFor(config.tunnel)))
    this.tunnelDesired = this.tunnelSupervisor.status().running
    if (this.tunnelDesired) this.scheduleHealthyReset('tunnel')
    this.logger.info('device-interconnect: frpc tunnel child started')
  }

  /** Restart the remote host when the announced origin differs from the overlay it runs. */
  private async syncHostOrigin(config: DeviceInterconnectConfig): Promise<void> {
    if (!this.supervisor.status().running) return
    const effective = withTunnelOrigin(config)
    if (this.appliedPublicOrigin === effective.host.publicOrigin) return
    await this.applyOverlay(config)
    this.hostDesired = true
    await this.restartHostChild(this.launchCommand(config))
    if (this.supervisor.status().running) this.scheduleHealthyReset('host')
    this.logger.info('device-interconnect: remote host restarted to apply the tunnel public origin')
  }

  /**
   * Wait until the remote host reports its listener before starting the tunnel.
   * @param config - configuration in force.
   * @param signal - aborted when the caller no longer needs the start.
   * @returns whether the host became ready within the configured ceiling.
   */
  private async waitForHostReady(config: DeviceInterconnectConfig, signal: AbortSignal): Promise<boolean> {
    const attempts = Math.max(1, Math.ceil(this.readinessTimeoutMs / this.readinessPollMs))
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      if (signal.aborted) return false
      if (await this.probeHostReady(config)) return true
      if (attempt + 1 < attempts) await delay(this.readinessPollMs, signal)
    }
    return false
  }

  /**
   * Ask the remote host's control plane whether its `wss` listener is up.
   * @param config - configuration in force.
   * @returns whether the host is ready to accept a tunnel mapping.
   */
  private async probeHostReady(config: DeviceInterconnectConfig): Promise<boolean> {
    if (!this.supervisor.status().running) return false
    // Without the local pairing page there is no control plane to ask; the
    // running child is the strongest fact available.
    if (!config.host.pagesEnabled) return true
    try {
      const state = await this.controlPlaneFor(config).state()
      return state.host?.listening === true
    } catch {
      // A control plane that has not finished starting refuses the read; the caller retries.
      return false
    }
  }

  /** Begin one tunnel startup, aborting the previous one. */
  private startTunnelStartup(run: (signal: AbortSignal) => Promise<void>): { readonly task: Promise<void> } {
    this.cancelTunnelStartup()
    const controller = new AbortController()
    this.tunnelStartup = controller
    const task = run(controller.signal)
    const settled: Promise<void> = task.then(() => undefined, () => undefined)
    this.tunnelStartupTask = settled
    void settled.finally(() => {
      if (this.tunnelStartupTask === settled) this.tunnelStartupTask = undefined
      if (this.tunnelStartup === controller) this.tunnelStartup = undefined
    })
    return { task }
  }

  /** Abort the startup in flight, if any. */
  private cancelTunnelStartup(): void {
    const controller = this.tunnelStartup
    if (controller === undefined) return
    this.tunnelStartup = undefined
    controller.abort()
  }

  /** Build the child launch command from the runner configuration. */
  private launchCommand(config: DeviceInterconnectConfig): LaunchCommand {
    const { runner } = config
    const args = [
      runner.pnpmPath,
      'dsh',
      '--profile',
      runner.profile,
      '--patch',
      overlayPath(this.dataDir),
      '--no-open',
    ]
    if (runner.patchPath !== '') args.push('--patch', runner.patchPath)
    const env: NodeJS.ProcessEnv = { ...this.env }
    if (runner.dshHome !== '') env['DSH_HOME'] = runner.dshHome
    const nodeDirectory = dirname(runner.nodePath)
    const pathKey = Object.keys(env).find(key => key.toUpperCase() === 'PATH') ?? 'PATH'
    const pathValue = env[pathKey]
    env[pathKey] = pathValue === undefined ? nodeDirectory : `${nodeDirectory}${nodePathSeparator()}${pathValue}`
    return { file: runner.nodePath, args, cwd: runner.repoDir, env }
  }

  /** Whether the configured runner can launch, and what is missing. */
  private runnerReadiness(config: DeviceInterconnectConfig): RuntimeState['runner'] {
    const { runner } = config
    const problems: Diagnostic[] = []
    if (runner.nodePath === '') {
      problems.push({ code: 'runner-node-missing', message: '未配置 Node.js 可执行文件路径（运行器 → nodePath）。' })
    } else if (!this.exists(runner.nodePath)) {
      problems.push({ code: 'runner-node-missing', message: `Node.js 可执行文件不存在：${runner.nodePath}` })
    }
    if (runner.pnpmPath === '') {
      problems.push({ code: 'runner-pnpm-missing', message: '未配置 pnpm.mjs 路径（运行器 → pnpmPath）。' })
    } else if (!this.exists(runner.pnpmPath)) {
      problems.push({ code: 'runner-pnpm-missing', message: `pnpm.mjs 不存在：${runner.pnpmPath}` })
    }
    if (runner.repoDir === '') {
      problems.push({ code: 'runner-repo-missing', message: '未配置本仓库目录（运行器 → repoDir）。' })
    } else if (!this.exists(runner.repoDir)) {
      problems.push({ code: 'runner-repo-missing', message: `仓库目录不存在：${runner.repoDir}` })
    }
    if (runner.patchPath !== '' && !this.exists(runner.patchPath)) {
      problems.push({ code: 'runner-patch-missing', message: `附加补丁文件不存在：${runner.patchPath}` })
    }
    return { ready: problems.length === 0, problems }
  }
}

/** Platform path-list separator for the child's `PATH`. */
function nodePathSeparator(): string {
  return process.platform === 'win32' ? ';' : ':'
}

/**
 * Read one provision request body; every field is optional and type-checked.
 * @param candidate - parsed JSON body, or undefined for an empty body.
 * @returns the validated request.
 * @throws {ConfigValidationError} when a field has the wrong type.
 */
function readProvisionRequest(candidate: unknown): ProvisionRequest {
  if (candidate === undefined) return {}
  if (!isRecord(candidate)) throw new ConfigValidationError(['请求体必须是一个 JSON 对象。'])
  const request: { -readonly [K in keyof ProvisionRequest]: ProvisionRequest[K] } = {}
  const token = candidate['token']
  if (token !== undefined) {
    if (token === null) request.token = null
    else if (typeof token === 'string') request.token = token.trim()
    else throw new ConfigValidationError(['token 必须是字符串或 null。'])
  }
  const frpcPath = candidate['frpcPath']
  if (frpcPath !== undefined) {
    if (typeof frpcPath !== 'string') throw new ConfigValidationError(['frpcPath 必须是字符串。'])
    request.frpcPath = frpcPath
  }
  const frpcAutoDownload = candidate['frpcAutoDownload']
  if (frpcAutoDownload !== undefined) {
    if (typeof frpcAutoDownload !== 'boolean') throw new ConfigValidationError(['frpcAutoDownload 必须是 true 或 false。'])
    request.frpcAutoDownload = frpcAutoDownload
  }
  const nodeId = candidate['nodeId']
  if (nodeId !== undefined) {
    if (nodeId === null) request.nodeId = null
    else if (typeof nodeId === 'number' && Number.isSafeInteger(nodeId) && nodeId >= 0) {
      request.nodeId = nodeId === 0 ? null : nodeId
    } else {
      throw new ConfigValidationError(['nodeId 必须是 0 或正整数，或 null（自动选择）。'])
    }
  }
  const tunnelName = candidate['tunnelName']
  if (tunnelName !== undefined) {
    if (typeof tunnelName !== 'string') throw new ConfigValidationError(['tunnelName 必须是字符串。'])
    request.tunnelName = tunnelName
  }
  const reuseExisting = candidate['reuseExisting']
  if (reuseExisting !== undefined) {
    if (typeof reuseExisting !== 'boolean') throw new ConfigValidationError(['reuseExisting 必须是 true 或 false。'])
    request.reuseExisting = reuseExisting
  }
  return request
}

/** The provider-side remote value of one public address, when it has one. */
function remoteOfAddress(publicAddress: string): { readonly remote?: string } {
  const index = publicAddress.lastIndexOf(':')
  if (index < 0) return {}
  const remote = publicAddress.slice(index + 1)
  return remote === '' ? {} : { remote }
}

/** Whether one unknown value is a JSON object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Convert one caught control-plane or transport failure into a diagnostic. */
function diagnosticOf(error: unknown): Diagnostic {
  if (error instanceof ControlPlaneError) return { code: error.code, message: error.message }
  return { code: 'control-error', message: `读取本机配对控制面失败：${describeError(error)}` }
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Wait one poll interval, resolving immediately when the caller aborts.
 * @param ms - milliseconds to wait.
 * @param signal - abort signal shared with the caller.
 * @returns completion once the timer elapsed or the signal aborted.
 */
function delay(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise<void>((resolve) => {
    const timer = setTimeout(finish, ms)
    function finish(): void {
      clearTimeout(timer)
      signal.removeEventListener('abort', finish)
      resolve()
    }
    signal.addEventListener('abort', finish, { once: true })
  })
}
