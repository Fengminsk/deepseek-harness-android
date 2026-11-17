/**
 * The Settings page's server bridge: it composes the persisted configuration,
 * the supervised child, and the remote host's loopback control API into one
 * snapshot, and turns each page action into the corresponding effect.
 *
 * Reads are cached for one second so several open pages polling at 2 s cannot
 * multiply loopback requests; actions invalidate the cache.
 * @module @deepseek-ai/dsh-device-interconnect/host/bridge
 */

import { existsSync } from 'node:fs'
import { dirname } from 'node:path'
import type {
  ControlPlaneState, DeviceInterconnectConfig, Diagnostic, PairingView, RuntimeState,
} from '../types.ts'
import { QR_ROUTE } from '../api.ts'
import { ConfigStore, ConfigValidationError, isDeviceId } from './config.ts'
import { ControlPlaneError, type ControlPlane } from './control-plane.ts'
import { overlayPath, writeOverlay } from './overlay.ts'
import type { LaunchCommand, SupervisorApi } from './supervisor.ts'

/** Options of one bridge. */
export interface BridgeOptions {
  /** Bundle data directory holding the configuration and the generated overlay. */
  readonly dataDir: string
  /** Persisted configuration. */
  readonly store: ConfigStore
  /** Child-process supervisor. */
  readonly supervisor: SupervisorApi
  /** Builds the control client for one loopback pairing page. */
  readonly controlPlane: (baseUrl: string) => ControlPlane
  /** Environment inherited by the child; defaults to this process's. */
  readonly env?: NodeJS.ProcessEnv
  /** Clock; defaults to `Date.now`. */
  readonly now?: () => number
  /** Control-plane read cache lifetime; defaults to 1000 ms. */
  readonly stateCacheMs?: number
  /** Existence probe for runner readiness; defaults to `existsSync`. */
  readonly exists?: (path: string) => boolean
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
  private readonly controlPlane: (baseUrl: string) => ControlPlane
  private readonly env: NodeJS.ProcessEnv
  private readonly now: () => number
  private readonly stateCacheMs: number
  private readonly exists: (path: string) => boolean
  private readonly logger: NonNullable<BridgeOptions['logger']>
  private readonly activationProblems: Diagnostic[]
  private cachedRead: { readonly at: number; readonly read: ControlPlaneRead } | undefined

  /** @param options - the composed services and seams. */
  constructor(options: BridgeOptions) {
    this.dataDir = options.dataDir
    this.store = options.store
    this.supervisor = options.supervisor
    this.controlPlane = options.controlPlane
    this.env = options.env ?? process.env
    this.now = options.now ?? Date.now
    this.stateCacheMs = options.stateCacheMs ?? 1_000
    this.exists = options.exists ?? existsSync
    this.logger = options.logger ?? console
    this.activationProblems = this.store.problems().map(message => ({ code: 'config-unreadable', message }))
  }

  /**
   * Apply the persisted configuration at activation: start the child when the
   * switch is on. A start failure is reported by {@link state}, never thrown
   * into the plugin activation.
   * @returns completion once the start was attempted.
   */
  async initialize(): Promise<void> {
    try {
      await this.apply(false)
    } catch (error) {
      const problem: Diagnostic = { code: 'config-apply-failed', message: `应用设备互联配置失败：${describeError(error)}` }
      this.activationProblems.push(problem)
      this.logger.error('device-interconnect: %s', problem.message)
    }
  }

  /**
   * Build the runtime snapshot the page renders.
   * @returns configuration, child state, control-plane facts, pairing view, devices, and problems.
   */
  async state(): Promise<RuntimeState> {
    const config = this.store.current()
    const read = await this.readControlPlane(config)
    return this.snapshot(config, read)
  }

  /**
   * Switch the supervised remote host on or off.
   * @param enabled - the requested switch position.
   * @returns the snapshot after the change.
   * @throws {ConfigValidationError} when the body is not a boolean.
   */
  async setEnabled(enabled: unknown): Promise<RuntimeState> {
    if (typeof enabled !== 'boolean') throw new ConfigValidationError(['enabled 必须是 true 或 false。'])
    const candidate = { ...this.store.current(), enabled }
    await this.store.save(candidate)
    await this.apply(false)
    this.cachedRead = undefined
    return this.state()
  }

  /**
   * Validate and persist a complete configuration, applying it to a running child.
   * @param candidate - submitted configuration document.
   * @returns the snapshot after the change.
   * @throws {ConfigValidationError} when the document is unusable.
   */
  async saveConfig(candidate: unknown): Promise<RuntimeState> {
    const saved = await this.store.save(candidate)
    await this.apply(saved.enabled)
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
   * The child's combined output tail, for the page's log disclosure.
   * @returns the retained output text.
   */
  logs(): string {
    return this.supervisor.status().logsTail
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
   * Stop the supervised child.
   * @returns completion once the child is gone.
   */
  async dispose(): Promise<void> {
    await this.supervisor.dispose()
  }

  /** Start, stop, or restart the child so the current configuration is in force. */
  private async apply(restart: boolean): Promise<void> {
    const config = this.store.current()
    if (!config.enabled) {
      await this.supervisor.stop()
      return
    }
    const readiness = this.runnerReadiness(config)
    if (!readiness.ready) return
    await writeOverlay(overlayPath(this.dataDir), config)
    const command = this.launchCommand(config)
    if (restart) {
      await this.supervisor.restart(command)
      return
    }
    if (!this.supervisor.status().running) this.supervisor.start(command)
  }

  /** Assemble the snapshot from one configuration and control-plane read. */
  private snapshot(config: DeviceInterconnectConfig, read: ControlPlaneRead): RuntimeState {
    const cpState = read.ok ? read.state : undefined
    const controlPlane: RuntimeState['controlPlane'] = read.ok
      ? { reachable: true, ...(cpState?.host === undefined ? {} : { host: cpState.host }) }
      : { reachable: false, error: read.error }
    return {
      config,
      child: this.supervisor.status(),
      controlPlane,
      pairing: this.pairingView(config, cpState),
      devices: cpState?.devices ?? [],
      runner: this.runnerReadiness(config),
      problems: [...this.activationProblems],
    }
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
