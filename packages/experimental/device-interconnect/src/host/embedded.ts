/**
 * Experimental embedded remote host: load the repository's remote-host and
 * Android-runtime function plugins into this DSH Host process instead of
 * spawning a child profile.
 *
 * The loader is a seam: production code binds it to a Cordis context, while the
 * Bridge tests inject a fake so no desktop service or production port is used.
 * Any import or activation failure rejects `start`; the bridge then falls back
 * to the supervised child, so a DSH upgrade that changes these plugin
 * interfaces can never disable the desktop client.
 * @module @deepseek-ai/dsh-device-interconnect/host/embedded
 */

import { existsSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import type { Context, Plugin } from '@deepseek-ai/cordis'
import type { PairingSettings, RemoteHostSettings } from '../types.ts'

/** The embedded runtime's attachment ceiling: 2 GiB, matching the child overlay. */
export const EMBEDDED_ATTACHMENT_FILE_MAX_BYTES = 2_147_483_648

/** How long to wait for the runtime/remote-host services after activating a plugin. */
const SERVICE_WAIT_TIMEOUT_MS = 15_000

/** Poll interval while waiting for a provided service. */
const SERVICE_WAIT_POLL_MS = 50

/** One embedded host attempt's inputs, derived from the persisted configuration. */
export interface EmbeddedHostOptions {
  /** Repository checkout containing `apps/android/runtime` and `apps/remote-host`. */
  readonly repoDir: string
  /** Remote host listener settings (already includes the derived tunnel origin). */
  readonly host: RemoteHostSettings
  /** Long-term pairing settings. */
  readonly pairing: PairingSettings
}

/** Load state of the embedded host. */
export interface EmbeddedHostStatus {
  /** Whether both plugins are loaded and their services are visible. */
  readonly loaded: boolean
  /** Readable failure reason; present only after a failed attempt. */
  readonly reason?: string
}

/** A started embedded host. */
export interface EmbeddedHostHandle {
  /** Current load state. */
  readonly status: EmbeddedHostStatus
  /** Dispose both plugins and release their listeners. Idempotent. */
  stop(): Promise<void>
}

/** Loads and activates the embedded host plugins. */
export interface EmbeddedHostLoader {
  /**
   * Load both plugins for one configuration.
   * @param options - repository and listener settings.
   * @returns the started host handle.
   * @throws {EmbeddedHostError} when paths are missing or activation fails.
   */
  start(options: EmbeddedHostOptions): Promise<EmbeddedHostHandle>
}

/** A structured embedded-load failure; the bridge turns it into a fallback problem. */
export class EmbeddedHostError extends Error {
  /** Stable code for diagnostics and tests. */
  readonly code: string

  /**
   * @param code - stable failure code.
   * @param message - readable Chinese reason.
   */
  constructor(code: string, message: string) {
    super(message)
    this.name = 'EmbeddedHostError'
    this.code = code
  }
}

/** Shape of a dynamically imported Cordis plugin module namespace. */
interface PluginModule {
  readonly apply?: unknown
}

/** One disposable plugin activation. */
interface FiberHandle {
  dispose(): unknown
  readonly state?: unknown
}

/** Runtime plugin config: desktop platform and the 2 GiB attachment ceiling. */
function runtimeConfig(): Record<string, unknown> {
  return { platform: 'desktop', attachmentFileMaxBytes: EMBEDDED_ATTACHMENT_FILE_MAX_BYTES }
}

/** Remote-host plugin config built from the bridge's listener/pairing settings. */
function remoteHostConfig(options: EmbeddedHostOptions): Record<string, unknown> {
  return {
    enabled: true,
    port: options.host.port,
    host: options.host.host,
    publicHost: options.host.publicHost,
    publicOrigin: options.host.publicOrigin,
    discoveryEnabled: options.host.discoveryEnabled,
    discoveryPort: options.host.discoveryPort,
    pagesEnabled: options.host.pagesEnabled,
    pagesPort: options.host.pagesPort,
    pairingTtlMs: options.pairing.pairingTtlMs,
    pairingLongTerm: options.pairing.longTerm,
  }
}

/** Resolve one repository entry, refusing paths outside the checkout. */
function repositoryPath(repoDir: string, relative: readonly string[]): string {
  if (!isAbsolute(repoDir)) {
    throw new EmbeddedHostError('embedded-repo-invalid', '内嵌模式需要运行器配置里的仓库目录为绝对路径。')
  }
  const path = join(repoDir, ...relative)
  if (!existsSync(path)) {
    throw new EmbeddedHostError(
      'embedded-entry-missing',
      `内嵌宿主入口不存在：${path}。请确认运行器仓库目录包含已构建的 remote-host 与 Android 运行时。`,
    )
  }
  return path
}

/** Runtime plugin services the embedded runtime depends on. */
const RUNTIME_REQUIRED_SERVICES = [
  'agents',
  'sessions',
  'workingDirectory',
  'settings',
  'tools',
  'appReady',
  'sessionPersistence',
] as const

/** Services the runtime facade waits for before it provides `appRuntimeFacade`. */
const FACADE_REQUIRED_SERVICES = [
  'sessionController',
  'typertGateway',
  'connection',
  'fileUploads',
  'pluginManager',
  'jobs',
  'sessionProjections',
  'subagents',
  'workspaceRegistry',
] as const

/** Return the services this desktop Host does not currently provide. */
function missingServices(ctx: Context, names: readonly string[]): string[] {
  return names.filter((name) => {
    try {
      return ctx.get(name) === undefined
    } catch {
      return true
    }
  })
}

/** Poll the plugin context for one provided service. */
async function waitForService(ctx: Context, name: string): Promise<void> {
  const deadline = Date.now() + SERVICE_WAIT_TIMEOUT_MS
  while (Date.now() < deadline) {
    try {
      if (ctx.get(name) !== undefined) return
    } catch {
      // The strict lookup throws before the service exists; keep waiting.
    }
    await new Promise<void>((resolve) => { setTimeout(resolve, SERVICE_WAIT_POLL_MS) })
  }
  throw new EmbeddedHostError('embedded-service-timeout', `内嵌宿主在 ${SERVICE_WAIT_TIMEOUT_MS}ms 内没有提供 ${name} 服务。`)
}

/** Bind the embedded loader to one Cordis context; unload leaves top-level services untouched. */
class ContextEmbeddedHost implements EmbeddedHostHandle {
  private loaded = false
  private reason: string | undefined
  private readonly fibers: FiberHandle[] = []

  constructor(private readonly ctx: Context) {}

  get status(): EmbeddedHostStatus {
    return {
      loaded: this.loaded,
      ...(this.reason === undefined ? {} : { reason: this.reason }),
    }
  }

  async start(options: EmbeddedHostOptions): Promise<void> {
    if (this.loaded) return
    // The official desktop Host exposes a different Agent service surface than
    // the App carrier this runtime targets (for example `agents.roots` is
    // unavailable). Loading it in-process crashed the desktop Host during
    // development, so embedded mode stays behind an explicit development flag
    // until the runtime is adapted and verified against the desktop surface.
    if (process.env.DSH_DEVICE_INTERCONNECT_EMBEDDED !== '1') {
      throw new EmbeddedHostError(
        'embedded-disabled',
        '内嵌远程宿主当前为开发者实验模式，官方桌面 DSH 的 Agent 服务接口尚未完全适配，已自动回退独立子进程（不影响电脑端使用）。',
      )
    }
    const captured: string[] = []
    const previousDiagnostic = process.env.DSH_EMBEDDED_DIAGNOSTIC
    process.env.DSH_EMBEDDED_DIAGNOSTIC = '1'
    const globalHost = globalThis as { __dshEmbeddedFacadeError?: string }
    delete globalHost.__dshEmbeddedFacadeError
    const originalError = console.error
    const originalWarn = console.warn
    const capture = (...args: unknown[]): void => {
      captured.push(args.map(value => value instanceof Error ? value.message : String(value)).join(' '))
      if (captured.length > 20) captured.shift()
    }
    console.error = capture
    console.warn = capture
    try {
      const missingRuntime = missingServices(this.ctx, RUNTIME_REQUIRED_SERVICES)
      if (missingRuntime.length > 0) {
        throw new EmbeddedHostError(
          'embedded-desktop-services-missing',
          `desktop 进程缺少内嵌运行时需要的服务：${missingRuntime.join('、')}。已回退独立子进程；如需内嵌模式，请检查 DSH 版本与服务组合。`,
        )
      }
      const missingFacade = missingServices(this.ctx, FACADE_REQUIRED_SERVICES)
      if (missingFacade.length > 0) {
        throw new EmbeddedHostError(
          'embedded-desktop-services-missing',
          `desktop 进程缺少远程门面需要的服务：${missingFacade.join('、')}。已回退独立子进程；如需内嵌模式，请检查 DSH 版本与服务组合。`,
        )
      }
      const runtimePath = repositoryPath(options.repoDir, ['apps', 'android', 'runtime', 'index.mjs'])
      const remoteHostPath = repositoryPath(options.repoDir, ['apps', 'remote-host', 'lib', 'index.js'])
      const runtimeModule = await import(`${pathToFileURL(runtimePath).href}?embedded=${String(Date.now())}`) as PluginModule
      const runtimeFiber = this.ctx.plugin(runtimeModule as Plugin, runtimeConfig())
      this.fibers.push(runtimeFiber)
      await runtimeFiber.await()
      await waitForService(this.ctx, 'appRuntimeFacade')

      const remoteHostModule = await import(`${pathToFileURL(remoteHostPath).href}?embedded=${String(Date.now())}`) as PluginModule
      const remoteHostFiber = this.ctx.plugin(remoteHostModule as Plugin, remoteHostConfig(options))
      this.fibers.push(remoteHostFiber)
      await remoteHostFiber.await()
      await waitForService(this.ctx, 'remoteHost')
      this.loaded = true
      this.reason = undefined
    } catch (error) {
      this.reason = error instanceof Error ? error.message : String(error)
      const states = this.fibers.map(fiber => String(fiber.state)).join(',')
      this.reason = `${this.reason}（fiber 状态：${states || '无'}）`
      const progress = (globalThis as { __dshEmbeddedProgress?: string[] }).__dshEmbeddedProgress
      if (progress !== undefined && progress.length > 0) {
        this.reason = `${this.reason}（内嵌进度：${progress.slice(-5).join(' → ')}）`
      }
      delete (globalThis as { __dshEmbeddedProgress?: string[] }).__dshEmbeddedProgress
      const missingNow = [
        ...missingServices(this.ctx, RUNTIME_REQUIRED_SERVICES),
        ...missingServices(this.ctx, FACADE_REQUIRED_SERVICES),
      ]
      if (missingNow.length > 0) this.reason = `${this.reason}（当前缺少服务：${missingNow.join('、')}）`
      if (captured.length > 0) this.reason = `${this.reason}（宿主日志：${captured.slice(-3).join('；')}）`
      await this.stop()
      if (error instanceof EmbeddedHostError) throw new EmbeddedHostError(error.code, this.reason)
      throw new EmbeddedHostError('embedded-load-failed', `内嵌远程宿主加载失败：${this.reason}`)
    } finally {
      console.error = originalError
      console.warn = originalWarn
      const diagnostic = globalHost.__dshEmbeddedFacadeError
      delete globalHost.__dshEmbeddedFacadeError
      if (process.env.DSH_EMBEDDED_DIAGNOSTIC === '1' && diagnostic !== undefined) captured.push(diagnostic)
      if (previousDiagnostic === undefined) delete process.env.DSH_EMBEDDED_DIAGNOSTIC
      else process.env.DSH_EMBEDDED_DIAGNOSTIC = previousDiagnostic
    }
  }

  async stop(): Promise<void> {
    this.loaded = false
    const fibers = this.fibers.splice(0).reverse()
    for (const fiber of fibers) {
      try {
        await fiber.dispose()
      } catch {
        // Disposal failures must never escape into the desktop Host.
      }
    }
  }
}

/**
 * Create the production embedded loader bound to this plugin's context.
 * @param ctx - the bridge plugin context; loaded plugins stay inside it.
 * @returns a loader whose start/stop never modify profiles or configuration files.
 */
export function createContextEmbeddedLoader(ctx: Context): EmbeddedHostLoader {
  return {
    async start(options: EmbeddedHostOptions): Promise<EmbeddedHostHandle> {
      const host = new ContextEmbeddedHost(ctx)
      await host.start(options)
      return host
    },
  }
}
