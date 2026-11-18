/**
 * Download of the SakuraFrp frpc build into the bundle data directory, with the
 * `frpc -V` check that proves the downloaded binary is the SakuraFrp fork
 * before it is ever spawned. The download runs only when the user starts the
 * one-click provision; nothing here executes during plugin activation.
 * @module @deepseek-ai/dsh-device-interconnect/host/frpc-download
 */

import { spawn } from 'node:child_process'
import { access, chmod, mkdir, rename, rm, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { TunnelProvisionError, frpcInstallPath } from './tunnel.ts'

/** Base URL of the SakuraFrp binary download service. */
export const DEFAULT_FRPC_DOWNLOAD_BASE = 'https://getfr.sh/d'

/**
 * Nyatwork CDN that mirrors the same frpc builds per version. The download
 * service can be unreachable from networks that block its hostname, so the
 * installer falls back to this versioned mirror.
 */
export const SAKURA_FRPC_CDN_BASE = 'https://nya.globalslb.net/natfrp/client/frpc'

/** Version used when the CDN version listing itself cannot be read. */
export const FRPC_CDN_FALLBACK_VERSION = '0.51.0-sakura-15.1'

/** Largest accepted download, in bytes. */
export const MAXIMUM_FRPC_BYTES = 64 * 1024 * 1024

/** Deadline of the `frpc -V` version check. */
export const FRPC_VERSION_TIMEOUT_MS = 10_000

/** Default request deadline of the frpc download. */
export const FRPC_DOWNLOAD_TIMEOUT_MS = 120_000

/** Options of one frpc download. */
export interface FrpcDownloadOptions {
  /** Bundle data directory the binary is installed under. */
  readonly dataDir: string
  /** Target platform; defaults to `process.platform`. */
  readonly platform?: NodeJS.Platform
  /** Target CPU architecture; defaults to `process.arch`. */
  readonly arch?: string
  /** Fetch implementation; defaults to the global one. */
  readonly fetch?: typeof fetch
  /** Download base URL; defaults to {@link DEFAULT_FRPC_DOWNLOAD_BASE}. */
  readonly downloadBaseUrl?: string
  /** Versioned CDN mirror base; defaults to {@link SAKURA_FRPC_CDN_BASE}. */
  readonly cdnBaseUrl?: string
  /** Version-check seam; defaults to running `frpc -V`. */
  readonly versionCheck?: (path: string) => Promise<string>
  /** Download deadline; defaults to {@link FRPC_DOWNLOAD_TIMEOUT_MS}. */
  readonly timeoutMs?: number
}

/** One installed frpc binary. */
export interface FrpcDownloadResult {
  /** Absolute path of the installed binary. */
  readonly path: string
  /** Version text reported by `frpc -V`. */
  readonly version: string
}

/**
 * Artifact file name of the SakuraFrp frpc build for one platform.
 * @param platform - target platform.
 * @param arch - target CPU architecture.
 * @returns the artifact name, or undefined for a platform this build has no artifact for.
 */
export function frpcArtifactName(platform: NodeJS.Platform, arch: string): string | undefined {
  if (platform === 'win32' || platform === 'linux') {
    if (arch === 'x64') return `frpc_${platform === 'win32' ? 'windows' : 'linux'}_amd64`
    if (arch === 'arm64') return `frpc_${platform === 'win32' ? 'windows' : 'linux'}_arm64`
  } else if (platform === 'darwin') {
    if (arch === 'x64') return 'frpc_darwin_amd64'
    if (arch === 'arm64') return 'frpc_darwin_arm64'
  }
  return undefined
}

/**
 * Download URL of the SakuraFrp frpc build for one platform.
 * @param platform - target platform.
 * @param arch - target CPU architecture.
 * @param baseUrl - download base URL.
 * @returns the URL, or undefined for a platform this build has no artifact for.
 */
export function frpcDownloadUrl(
  platform: NodeJS.Platform,
  arch: string,
  baseUrl: string = DEFAULT_FRPC_DOWNLOAD_BASE,
): string | undefined {
  const name = frpcArtifactName(platform, arch)
  if (name === undefined) return undefined
  const suffix = platform === 'win32' ? '.exe' : ''
  return `${baseUrl.replace(/\/+$/u, '')}/${name}${suffix}`
}

/**
 * CDN URL of one versioned frpc artifact.
 * @param baseUrl - CDN base URL.
 * @param version - version directory, for example `0.51.0-sakura-15.1`.
 * @param artifact - artifact name without the platform suffix.
 * @param platform - target platform; Windows artifacts carry `.exe`.
 * @returns the CDN artifact URL.
 */
export function frpcCdnUrl(
  baseUrl: string,
  version: string,
  artifact: string,
  platform: NodeJS.Platform,
): string {
  const suffix = platform === 'win32' ? '.exe' : ''
  return `${baseUrl.replace(/\/+$/u, '')}/${version}/${artifact}${suffix}`
}

/** Structural version parts used to order the CDN version directories. */
function versionParts(version: string): readonly number[] {
  return [...version.matchAll(/\d+/gu)].map(match => Number(match[0]))
}

/** Order two SakuraFrp frpc version strings, newest first. */
function compareVersions(left: string, right: string): number {
  const a = versionParts(left)
  const b = versionParts(right)
  const length = Math.max(a.length, b.length)
  for (let index = 0; index < length; index += 1) {
    const delta = (b[index] ?? 0) - (a[index] ?? 0)
    if (delta !== 0) return delta
  }
  return 0
}

/**
 * Read the version directories from the CDN listing, newest first.
 * @param fetchImplementation - fetch seam.
 * @param baseUrl - CDN base URL.
 * @param timeoutMs - listing deadline.
 * @returns the parsed versions, or an empty list when the listing is unavailable.
 */
async function listCdnVersions(
  fetchImplementation: typeof fetch,
  baseUrl: string,
  timeoutMs: number,
): Promise<readonly string[]> {
  try {
    const response = await fetchImplementation(`${baseUrl.replace(/\/+$/u, '')}/`, {
      headers: { 'user-agent': 'dsh-device-interconnect' },
      signal: AbortSignal.timeout(timeoutMs),
    })
    if (!response.ok) return []
    const html = await response.text()
    const versions = [...html.matchAll(/href="([^"?]+)\/"/gu)]
      .map(match => match[1] ?? '')
      .filter(version => /^\d+\.\d+\.\d+-sakura-/u.test(version))
    return [...new Set(versions)].sort(compareVersions)
  } catch {
    // The version listing is an optimization; the caller still tries the pinned mirror.
    return []
  }
}

/**
 * Install the SakuraFrp frpc build, reusing an already installed executable
 * when it still reports itself as the SakuraFrp build, and falling back to the
 * versioned Nyatwork CDN when the primary download service is unreachable.
 * @param options - target directory, platform, download, and version-check seams.
 * @returns the installed executable and its version.
 * @throws {TunnelProvisionError} when the platform is unsupported, the download
 * fails, or the binary does not report itself as the SakuraFrp build.
 */
export async function downloadFrpc(options: FrpcDownloadOptions): Promise<FrpcDownloadResult> {
  const platform = options.platform ?? process.platform
  const arch = options.arch ?? process.arch
  const artifact = frpcArtifactName(platform, arch)
  if (artifact === undefined) {
    throw new TunnelProvisionError(
      'frpc-unsupported-platform',
      `暂不支持在当前平台（${platform}/${arch}）自动下载 frpc，请手动填写可执行文件路径。`,
      [],
    )
  }
  const target = frpcInstallPath(options.dataDir, platform)
  const versionCheck = options.versionCheck ?? ((path: string) => readFrpcVersion(path))
  const installed = await access(target).then(() => versionCheck(target)).catch(() => undefined)
  if (installed !== undefined && /sakura/iu.test(installed)) {
    return { path: target, version: firstLine(installed) }
  }
  const timeoutMs = options.timeoutMs ?? FRPC_DOWNLOAD_TIMEOUT_MS
  const urls: string[] = []
  const primary = frpcDownloadUrl(platform, arch, options.downloadBaseUrl)
  if (primary !== undefined) urls.push(primary)
  const cdnBase = options.cdnBaseUrl ?? SAKURA_FRPC_CDN_BASE
  const versions = await listCdnVersions(options.fetch ?? ((input, init) => fetch(input, init)), cdnBase, timeoutMs)
  for (const version of versions.length === 0 ? [FRPC_CDN_FALLBACK_VERSION] : versions) {
    urls.push(frpcCdnUrl(cdnBase, version, artifact, platform))
  }
  const fetchImplementation = options.fetch ?? ((input, init) => fetch(input, init))
  const failures: string[] = []
  let versionMismatch: string | undefined
  for (const url of urls) {
    let bytes: Uint8Array
    try {
      const response = await fetchImplementation(url, {
        headers: { 'user-agent': 'dsh-device-interconnect' },
        signal: AbortSignal.timeout(timeoutMs),
      })
      if (!response.ok) {
        failures.push(`${url} → HTTP ${String(response.status)}`)
        continue
      }
      bytes = new Uint8Array(await response.arrayBuffer())
      if (bytes.byteLength === 0) {
        failures.push(`${url} → 空文件`)
        continue
      }
      if (bytes.byteLength > MAXIMUM_FRPC_BYTES) {
        failures.push(`${url} → 超过大小上限`)
        continue
      }
      const temporary = `${target}.${String(process.pid)}.download`
      await mkdir(dirname(target), { recursive: true })
      await writeFile(temporary, bytes)
      if (platform !== 'win32') await chmod(temporary, 0o755)
      await rename(temporary, target)
    } catch (error) {
      await rm(`${target}.${String(process.pid)}.download`, { force: true }).catch(() => {
        // A leftover temporary file is harmless; the failure below is the report.
      })
      failures.push(`${url} → ${describeError(error)}`)
      continue
    }
    // A version-check failure is a real executable problem, not a network
    // failure: surface it instead of silently trying another mirror.
    const version = await versionCheck(target)
    if (!/sakura/iu.test(version)) {
      await rm(target, { force: true }).catch(() => {
        // A non-SakuraFrp binary must not be kept for a later start attempt.
      })
      versionMismatch = version
      failures.push(`${url} → 不是 SakuraFrp 版本（${version.slice(0, 120)}）`)
      continue
    }
    return { path: target, version: firstLine(version) }
  }
  if (versionMismatch !== undefined) {
    throw new TunnelProvisionError(
      'frpc-version-invalid',
      `下载的 frpc 不是 SakuraFrp 版本（frpc -V 输出：${versionMismatch.slice(0, 200)}），请手动填写可执行文件路径。`,
      [],
    )
  }
  throw new TunnelProvisionError(
    'frpc-download-failed',
    `下载 frpc 失败（已尝试 ${String(urls.length)} 个来源）：${failures.slice(-3).join('；')}`,
    [],
  )
}

/**
 * Run `frpc -V` and collect its combined output.
 * @param path - frpc executable.
 * @param timeoutMs - deadline of the check.
 * @returns the combined stdout and stderr.
 * @throws {TunnelProvisionError} when the executable cannot run, fails, or times out.
 */
export function readFrpcVersion(path: string, timeoutMs: number = FRPC_VERSION_TIMEOUT_MS): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const child = spawn(path, ['-V'], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
    let output = ''
    let settled = false
    const end = (action: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      action()
    }
    const timer = setTimeout(() => {
      child.kill()
      end(() => { reject(new TunnelProvisionError('frpc-version-failed', '校验 frpc 版本超时。', [])) })
    }, timeoutMs)
    child.stdout?.on('data', (chunk: Buffer | string) => { output += typeof chunk === 'string' ? chunk : chunk.toString('utf8') })
    child.stderr?.on('data', (chunk: Buffer | string) => { output += typeof chunk === 'string' ? chunk : chunk.toString('utf8') })
    child.on('error', (error) => {
      end(() => { reject(new TunnelProvisionError('frpc-version-failed', `无法执行 frpc -V：${error.message}`, [])) })
    })
    child.on('exit', (code) => {
      end(() => {
        if (code === 0) resolve(output.trim())
        else reject(new TunnelProvisionError('frpc-version-failed', `frpc -V 退出码 ${String(code)}：${output.trim().slice(0, 200)}`, []))
      })
    })
  })
}

/** First non-empty line of one command output. */
function firstLine(value: string): string {
  for (const line of value.split(/\r?\n/u)) {
    if (line.trim() !== '') return line.trim()
  }
  return value.trim()
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
