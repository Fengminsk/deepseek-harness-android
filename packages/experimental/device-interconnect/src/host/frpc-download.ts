/**
 * Download of the SakuraFrp frpc build into the bundle data directory, with the
 * `frpc -V` check that proves the downloaded binary is the SakuraFrp fork
 * before it is ever spawned. The download runs only when the user starts the
 * one-click provision; nothing here executes during plugin activation.
 * @module @deepseek-ai/dsh-device-interconnect/host/frpc-download
 */

import { spawn } from 'node:child_process'
import { chmod, mkdir, rename, rm, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { TunnelProvisionError, frpcInstallPath } from './tunnel.ts'

/** Base URL of the SakuraFrp binary download service. */
export const DEFAULT_FRPC_DOWNLOAD_BASE = 'https://getfr.sh/d'

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
  const suffix = platform === 'win32' ? '.exe' : ''
  let name: string | undefined
  if (platform === 'win32' || platform === 'linux') {
    if (arch === 'x64') name = `frpc_${platform === 'win32' ? 'windows' : 'linux'}_amd64`
    else if (arch === 'arm64') name = `frpc_${platform === 'win32' ? 'windows' : 'linux'}_arm64`
  } else if (platform === 'darwin') {
    if (arch === 'x64') name = 'frpc_darwin_amd64'
    else if (arch === 'arm64') name = 'frpc_darwin_arm64'
  }
  if (name === undefined) return undefined
  return `${baseUrl.replace(/\/+$/u, '')}/${name}${suffix}`
}

/**
 * Download, install, and version-check the SakuraFrp frpc build.
 * @param options - target directory, platform, download, and version-check seams.
 * @returns the installed executable and its version.
 * @throws {TunnelProvisionError} when the platform is unsupported, the download
 * fails, or the binary does not report itself as the SakuraFrp build.
 */
export async function downloadFrpc(options: FrpcDownloadOptions): Promise<FrpcDownloadResult> {
  const platform = options.platform ?? process.platform
  const arch = options.arch ?? process.arch
  const url = frpcDownloadUrl(platform, arch, options.downloadBaseUrl)
  if (url === undefined) {
    throw new TunnelProvisionError(
      'frpc-unsupported-platform',
      `暂不支持在当前平台（${platform}/${arch}）自动下载 frpc，请手动填写可执行文件路径。`,
      [],
    )
  }
  const target = frpcInstallPath(options.dataDir, platform)
  const fetchImplementation = options.fetch ?? ((input, init) => fetch(input, init))
  let bytes: Uint8Array
  try {
    const response = await fetchImplementation(url, { signal: AbortSignal.timeout(options.timeoutMs ?? FRPC_DOWNLOAD_TIMEOUT_MS) })
    if (!response.ok) {
      throw new TunnelProvisionError('frpc-download-failed', `下载 frpc 失败：HTTP ${String(response.status)}。`, [])
    }
    bytes = new Uint8Array(await response.arrayBuffer())
  } catch (error) {
    if (error instanceof TunnelProvisionError) throw error
    throw new TunnelProvisionError('frpc-download-failed', `下载 frpc 失败：${describeError(error)}`, [])
  }
  if (bytes.byteLength === 0) {
    throw new TunnelProvisionError('frpc-download-failed', '下载的 frpc 文件为空。', [])
  }
  if (bytes.byteLength > MAXIMUM_FRPC_BYTES) {
    throw new TunnelProvisionError('frpc-download-too-large', '下载的 frpc 文件超过大小上限，已放弃使用。', [])
  }
  const temporary = `${target}.${String(process.pid)}.download`
  try {
    await mkdir(dirname(target), { recursive: true })
    await writeFile(temporary, bytes)
    if (platform !== 'win32') await chmod(temporary, 0o755)
    await rename(temporary, target)
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => {
      // A leftover temporary file is harmless; the write failure below is the report.
    })
    throw new TunnelProvisionError('frpc-download-failed', `写入 frpc 失败：${describeError(error)}`, [])
  }
  const version = await (options.versionCheck ?? (path => readFrpcVersion(path)))(target)
  if (!/sakura/iu.test(version)) {
    throw new TunnelProvisionError(
      'frpc-version-invalid',
      `下载的 frpc 不是 SakuraFrp 版本（frpc -V 输出：${version.slice(0, 200)}），请手动填写可执行文件路径。`,
      [],
    )
  }
  return { path: target, version: firstLine(version) }
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
