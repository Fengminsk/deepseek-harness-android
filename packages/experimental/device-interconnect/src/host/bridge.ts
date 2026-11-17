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
  ControlPlaneState, DeviceInterconnectConfig, DeviceInterconnectView, Diagnostic, PairingView, RuntimeState,
  TunnelReadiness, TunnelSettingsView, TunnelState,
} from '../types.ts'
import { QR_ROUTE } from '../api.ts'
import { ConfigStore, ConfigValidationError, isDeviceId } from './config.ts'
import { ControlPlaneError, type ControlPlane } from './control-plane.ts'
import { overlayPath, writeOverlay } from './overlay.ts'
import type { LaunchCommand, SupervisorApi } from './supervisor.ts'
import {
  TunnelError, derivePublicOrigin, tunnelLaunchCommand, tunnelReadiness, withTunnelOrigin,
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
  private readonly activationProblems: Diagnostic[]
  private cachedRead: { readonly at: number; readonly read: ControlPlaneRead } | undefined
  private appliedPublicOrigin: string | undefined
  private disposed = false
  private tunnelStartup: AbortController | undefined
  private tunnelStartupTask: Promise<void> | undefined

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
    this.activationProblems = this.store.problems().map(message => ({ code: 'config-unreadable', message }))
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
      this.cancelTunnelStartup()
      await this.tunnelSupervisor.stop()
      return this.state()
    }
    const { task } = this.startTunnelStartup(signal => this.startTunnelNow(signal))
    await task
    return this.state()
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
    this.cancelTunnelStartup()
    const pending = this.tunnelStartupTask
    if (pending !== undefined) await pending
    await this.tunnelSupervisor.dispose()
    await this.supervisor.dispose()
  }

  /** Start, stop, or restart both children so the current configuration is in force. */
  private async apply(restart: boolean): Promise<void> {
    const config = this.store.current()
    // A restarted or disabled remote host invalidates the tunnel mapping, so the
    // tunnel always stops first; the callers start it again once the host is ready.
    if (restart || !this.tunnelWanted(config)) {
      this.cancelTunnelStartup()
      await this.tunnelSupervisor.stop()
    }
    if (!config.enabled) {
      await this.supervisor.stop()
      return
    }
    const readiness = this.runnerReadiness(config)
    if (!readiness.ready) return
    await this.applyOverlay(config)
    const command = this.launchCommand(config)
    if (restart) {
      await this.supervisor.restart(command)
      return
    }
    if (!this.supervisor.status().running) this.supervisor.start(command)
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
      problems: [...this.activationProblems],
    }
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
    }
    return { enabled: config.enabled, runner: config.runner, host: config.host, pairing: config.pairing, tunnel }
  }

  /** Project the tunnel child and its derived facts into the page view. */
  private tunnelState(config: DeviceInterconnectConfig): TunnelState {
    const readiness = this.configTunnelReadiness(config)
    return {
      ...this.tunnelSupervisor.status(),
      provider: config.tunnel.provider,
      ready: readiness.ready,
      problems: readiness.problems,
      derivedPublicOrigin: derivePublicOrigin(config.tunnel),
    }
  }

  /** Whether the current configuration asks for and can start the tunnel. */
  private tunnelWanted(config: DeviceInterconnectConfig): boolean {
    return config.enabled && config.tunnel.provider === 'sakurafrp' && this.configTunnelReadiness(config).ready
  }

  /** Build the tunnel readiness of one configuration. */
  private configTunnelReadiness(config: DeviceInterconnectConfig): TunnelReadiness {
    return tunnelReadiness(config.tunnel, this.exists)
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
    this.tunnelSupervisor.start(tunnelLaunchCommand(current.tunnel, this.dataDir, this.env))
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
    this.tunnelSupervisor.start(tunnelLaunchCommand(config.tunnel, this.dataDir, this.env))
    this.logger.info('device-interconnect: frpc tunnel child started')
  }

  /** Restart the remote host when the announced origin differs from the overlay it runs. */
  private async syncHostOrigin(config: DeviceInterconnectConfig): Promise<void> {
    if (!this.supervisor.status().running) return
    const effective = withTunnelOrigin(config)
    if (this.appliedPublicOrigin === effective.host.publicOrigin) return
    await this.applyOverlay(config)
    await this.supervisor.restart(this.launchCommand(config))
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
