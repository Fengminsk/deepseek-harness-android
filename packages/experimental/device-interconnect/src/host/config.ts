/**
 * The Device Interconnect configuration file: defaults, first-run runner
 * inference, strict validation for the settings page's writes, and an atomic
 * JSON file under `<DSH_HOME>/device-interconnect/config.json`.
 *
 * The file is the single source of truth once it exists; the bundle row's
 * `config` only seeds the first run. Validation happens at this file and HTTP
 * boundary rather than between typed same-process callers.
 * @module @deepseek-ai/dsh-device-interconnect/host/config
 */

import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { mkdir, rename, rm, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import type {
  DeviceInterconnectConfig, PairingSettings, RemoteHostSettings, RunnerConfig, TunnelProvider, TunnelSettings,
} from '../types.ts'
import { isSafeTunnelExtraArgs, isTunnelPublicAddress } from './tunnel.ts'

/** Directory under `DSH_HOME` holding this bundle's configuration and generated overlay. */
export const DATA_DIRECTORY_NAME = 'device-interconnect'

/** Configuration file name inside {@link DATA_DIRECTORY_NAME}. */
export const CONFIG_FILE_NAME = 'config.json'

/** Generated remote-host overlay file name inside {@link DATA_DIRECTORY_NAME}. */
export const OVERLAY_FILE_NAME = 'remote-host.overlay.yml'

/** Default long-term pairing window: 30 days, inside the remote host's 90-day ceiling. */
export const DEFAULT_PAIRING_TTL_MS = 2_592_000_000

/** Pairing window floor accepted by the remote host. */
export const MINIMUM_PAIRING_TTL_MS = 1_000

/** Pairing window ceiling accepted by the remote host (90 days). */
export const MAXIMUM_PAIRING_TTL_MS = 7_776_000_000

/** Default `wss` listen port of the remote host. */
export const DEFAULT_HOST_PORT = 4_777

/** Default UDP LAN discovery port of the remote host. */
export const DEFAULT_DISCOVERY_PORT = 4_778

/** Default loopback pairing-page and control-API port. */
export const DEFAULT_PAGES_PORT = 4_780

/** Default remote host profile launched by the supervised child. */
export const DEFAULT_PROFILE = 'remote-host'

/** Default name of the tunnel the automatic provision reuses or creates. */
export const DEFAULT_TUNNEL_NAME = 'DSH 设备互联'

/** Longest accepted tunnel name, in characters. */
const MAXIMUM_TUNNEL_NAME_LENGTH = 64

/** Longest accepted access key, in characters. */
const MAXIMUM_TUNNEL_TOKEN_LENGTH = 512

/** SakuraFrp tunnel ids: one or more decimal ids separated by commas. */
const TUNNEL_IDS_PATTERN = /^\d+(,\d+)*$/u

/** An address carrying a URL scheme, which a tunnel public address never has. */
const SCHEME_PATTERN = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//u

/** Whitespace and control characters a single-line setting value may not contain. */
const SINGLE_LINE_VIOLATION = /[\u0000-\u001f\u007f]/u

/** Whitespace or control characters inside an access key. */
const TOKEN_VIOLATION = /\s|[\u0000-\u001f\u007f]/u

/** Largest accepted device id length (32 hexadecimal characters). */
const DEVICE_ID_PATTERN = /^[0-9a-f]{32}$/u

/** Profile names the launcher accepts: no separators and no relative segments. */
const PROFILE_PATTERN = /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/u

/** Highest accepted TCP/UDP port. */
const MAXIMUM_PORT = 65_535

/** The environment facts runner inference reads; injectable so tests need no real machine layout. */
export interface InferenceEnvironment {
  /** Process environment, including the optional `DSH_DEVICE_INTERCONNECT_*` overrides. */
  readonly env: NodeJS.ProcessEnv
  /** Node platform, choosing `node.exe` over `node`. */
  readonly platform: NodeJS.Platform
  /** This Host process's executable. */
  readonly execPath: string
  /** Whether this Host runs inside Electron, whose executable is not a Node.js runtime. */
  readonly isElectron: boolean
  /** User home directory containing the DSH installation. */
  readonly homeDir: string
  /** Whether one path exists. */
  readonly exists: (path: string) => boolean
  /** Directory entries, sorted stable; an unreadable directory reads as empty. */
  readonly readDirectory: (path: string) => readonly string[]
}

/**
 * The inference facts of the running Host process.
 * @returns environment, platform, executable, Electron flag, home, and filesystem probes.
 */
export function processInferenceEnvironment(): InferenceEnvironment {
  return {
    env: process.env,
    platform: process.platform,
    execPath: process.execPath,
    isElectron: process.versions.electron !== undefined,
    homeDir: userHome(process.env),
    exists: path => existsSync(path),
    readDirectory: (path) => {
      try {
        return readdirSync(path).sort()
      } catch (error) {
        // A missing DSH runtimes directory is the ordinary fresh-install state.
        if (isMissingPath(error)) return []
        throw error
      }
    },
  }
}

/**
 * DSH home directory of this Host process.
 * @param env - process environment.
 * @returns `DSH_HOME` when set, otherwise `~/.dsh`.
 */
export function defaultDshHome(env: NodeJS.ProcessEnv): string {
  const configured = env['DSH_HOME']
  return configured !== undefined && configured !== '' ? configured : join(userHome(env), '.dsh')
}

/**
 * This bundle's data directory.
 * @param env - process environment.
 * @returns `<DSH_HOME>/device-interconnect`.
 */
export function dataDirectory(env: NodeJS.ProcessEnv): string {
  return join(defaultDshHome(env), DATA_DIRECTORY_NAME)
}

/**
 * The first-run configuration: inferred runner, product listener defaults, and
 * long-term pairing on.
 * @param environment - inference facts of this Host process.
 * @returns the defaults a fresh installation starts from.
 */
export function defaultConfig(environment: InferenceEnvironment = processInferenceEnvironment()): DeviceInterconnectConfig {
  return {
    enabled: false,
    runner: inferRunner(environment),
    host: {
      port: DEFAULT_HOST_PORT,
      host: '0.0.0.0',
      publicHost: '',
      publicOrigin: '',
      discoveryEnabled: true,
      discoveryPort: DEFAULT_DISCOVERY_PORT,
      pagesEnabled: true,
      pagesPort: DEFAULT_PAGES_PORT,
    },
    pairing: { longTerm: true, pairingTtlMs: DEFAULT_PAIRING_TTL_MS },
    tunnel: {
      provider: 'none',
      frpcPath: '',
      token: '',
      tunnelIds: '',
      publicAddress: '',
      iniPath: '',
      extraArgs: '',
      autoProvision: false,
      frpcAutoDownload: true,
      nodeId: null,
      tunnelName: DEFAULT_TUNNEL_NAME,
      tunnelId: null,
    },
  }
}

/**
 * Infer the child-process runner from the managed DSH runtime and environment
 * overrides. An executable or checkout this inference cannot find stays empty,
 * and the Settings page reports the missing fact instead of guessing a path.
 * @param environment - inference facts of this Host process.
 * @returns the inferred runner; paths it could not find are empty strings.
 */
export function inferRunner(environment: InferenceEnvironment): RunnerConfig {
  const hostDshHome = defaultDshHome(environment.env)
  const runtimeDependencies = join(hostDshHome, 'dsh-runtimes')
  const nodeRelative = environment.platform === 'win32'
    ? ['dependencies', 'node', 'bin', 'node.exe']
    : ['dependencies', 'node', 'bin', 'node']
  const pnpmRelative = ['dependencies', 'pnpm', 'bin', 'pnpm.mjs']
  const runtimeNode = firstRuntimeFile(environment, runtimeDependencies, nodeRelative)
  const inferredNode = environment.env['DSH_DEVICE_INTERCONNECT_NODE']
    ?? runtimeNode
    ?? (environment.isElectron ? '' : environment.execPath)
  return {
    nodePath: inferredNode,
    pnpmPath: environment.env['DSH_DEVICE_INTERCONNECT_PNPM']
      ?? firstRuntimeFile(environment, runtimeDependencies, pnpmRelative)
      ?? '',
    repoDir: environment.env['DSH_DEVICE_INTERCONNECT_REPO'] ?? '',
    profile: DEFAULT_PROFILE,
    patchPath: '',
    dshHome: '',
  }
}

/** One validated configuration read. */
export type ConfigRead =
  | { readonly ok: true; readonly config: DeviceInterconnectConfig }
  | { readonly ok: false; readonly problems: readonly string[] }

/** Thrown by the settings-page writes when the submitted configuration is unusable. */
export class ConfigValidationError extends Error {
  /** Every problem with the submitted value, in display order. */
  readonly problems: readonly string[]

  /**
   * @param problems - every problem with the submitted value.
   */
  constructor(problems: readonly string[]) {
    super(`配置无效：${problems.join('；')}`)
    this.name = 'ConfigValidationError'
    this.problems = problems
  }
}

/**
 * Validate one configuration value, filling absent fields from a fallback.
 *
 * Every field present in the candidate is validated; a missing field inherits
 * the fallback, which lets the bundle row seed only `enabled`.
 * @param candidate - the value read from the file or submitted by the page.
 * @param fallback - complete configuration supplying absent fields.
 * @returns the complete validated configuration, or every problem found.
 */
export function normalizeConfig(candidate: unknown, fallback: DeviceInterconnectConfig): ConfigRead {
  const problems: string[] = []
  if (!isRecord(candidate)) return { ok: false, problems: ['配置必须是一个 JSON 对象。'] }
  const enabled = readBoolean(candidate['enabled'], 'enabled', fallback.enabled, problems)
  const runner = readRunner(candidate['runner'], fallback.runner, problems)
  const host = readHost(candidate['host'], fallback.host, problems)
  const pairing = readPairing(candidate['pairing'], fallback.pairing, problems)
  const tunnel = readTunnel(candidate['tunnel'], fallback.tunnel, problems)
  if (problems.length > 0) return { ok: false, problems }
  return { ok: true, config: { enabled, runner, host, pairing, tunnel } }
}

/**
 * Read the configuration file if it exists.
 * @param file - absolute configuration file path.
 * @param fallback - configuration used for a missing file and for absent fields.
 * @returns the validated configuration, or the read problems.
 */
export function readConfigFile(file: string, fallback: DeviceInterconnectConfig): ConfigRead {
  let text: string
  try {
    text = readFileSync(file, 'utf8')
  } catch (error) {
    if (isMissingPath(error)) return { ok: true, config: fallback }
    return { ok: false, problems: [`读取 ${file} 失败：${describeError(error)}`] }
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    return { ok: false, problems: [`${file} 不是合法 JSON：${describeError(error)}`] }
  }
  return normalizeConfig(parsed, fallback)
}

/**
 * Write the configuration file atomically: a temporary sibling renamed over the
 * target, so a crash leaves either the old or the new document.
 * @param file - absolute configuration file path.
 * @param config - complete configuration to persist.
 * @returns completion once the rename finished.
 */
export async function writeConfigFile(file: string, config: DeviceInterconnectConfig): Promise<void> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${String(process.pid)}.${Math.random().toString(16).slice(2)}.tmp`
  try {
    await writeFile(temporary, `${JSON.stringify(config, undefined, 2)}\n`, 'utf8')
    await rename(temporary, file)
  } catch (error) {
    await removeQuietly(temporary)
    throw error
  }
}

/**
 * The configuration file store: one document read at activation, rewritten only
 * by validated settings-page writes.
 */
export class ConfigStore {
  /** Absolute path of the file this store owns. */
  readonly file: string
  private config: DeviceInterconnectConfig
  private readonly loadProblems: readonly string[]
  private readonly logger: { warn(message: string, ...rest: unknown[]): void }

  /**
   * @param options.file - absolute configuration file path.
   * @param options.fallback - first-run configuration.
   * @param options.logger - warning sink for an unreadable file.
   */
  constructor(options: {
    readonly file: string
    readonly fallback: DeviceInterconnectConfig
    readonly logger?: { warn(message: string, ...rest: unknown[]): void }
  }) {
    this.file = options.file
    this.logger = options.logger ?? console
    const read = readConfigFile(options.file, options.fallback)
    if (read.ok) {
      this.config = read.config
      this.loadProblems = []
    } else {
      // A corrupt file must not stop the Host from serving the page that repairs it.
      this.config = options.fallback
      this.loadProblems = read.problems
      this.logger.warn('device-interconnect: configuration file is unusable and was ignored: %s', read.problems.join('; '))
    }
  }

  /**
   * The configuration currently in force.
   * @returns the last validated configuration.
   */
  current(): DeviceInterconnectConfig {
    return this.config
  }

  /**
   * Problems found while reading the file at activation.
   * @returns readable diagnostics; empty when the file was usable.
   */
  problems(): readonly string[] {
    return this.loadProblems
  }

  /**
   * Validate and persist one submitted configuration, making it current only
   * after the write succeeded.
   * @param candidate - the submitted configuration.
   * @returns the accepted configuration.
   * @throws {ConfigValidationError} when the candidate is unusable.
   */
  async save(candidate: unknown): Promise<DeviceInterconnectConfig> {
    const normalized = normalizeConfig(candidate, this.config)
    if (!normalized.ok) throw new ConfigValidationError(normalized.problems)
    await writeConfigFile(this.file, normalized.config)
    this.config = normalized.config
    return this.config
  }
}

/** Read the first existing `<runtime>/<relative...>` file under the DSH runtimes directory. */
function firstRuntimeFile(
  environment: InferenceEnvironment,
  runtimesDirectory: string,
  relative: readonly string[],
): string | undefined {
  for (const runtime of environment.readDirectory(runtimesDirectory)) {
    const candidate = join(runtimesDirectory, runtime, ...relative)
    if (environment.exists(candidate)) return candidate
  }
  return undefined
}

/** User home directory of one environment. */
function userHome(env: NodeJS.ProcessEnv): string {
  return env['USERPROFILE'] ?? env['HOME'] ?? homedir()
}

/** Whether a caught filesystem error means the path is absent. */
function isMissingPath(error: unknown): boolean {
  return typeof error === 'object' && error !== null && ('code' in error)
    && (error as { readonly code?: unknown }).code === 'ENOENT'
}

/** Delete a temporary file, ignoring its absence. */
async function removeQuietly(file: string): Promise<void> {
  try {
    await rm(file, { force: true })
  } catch (error) {
    // A leftover temporary file is harmless; the error that triggered cleanup is rethrown.
    if (!isMissingPath(error)) return
  }
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Whether one unknown value is a JSON object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Read a boolean field, or the fallback when absent. */
function readBoolean(value: unknown, path: string, fallback: boolean, problems: string[]): boolean {
  if (value === undefined) return fallback
  if (typeof value !== 'boolean') {
    problems.push(`${path} 必须是 true 或 false。`)
    return fallback
  }
  return value
}

/** Read an integer field within a closed range, or the fallback when absent. */
function readInteger(value: unknown, path: string, minimum: number, maximum: number, fallback: number, problems: string[]): number {
  if (value === undefined) return fallback
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    problems.push(`${path} 必须是 ${String(minimum)}–${String(maximum)} 的整数。`)
    return fallback
  }
  return value
}

/** Read a string field, or the fallback when absent. */
function readString(value: unknown, path: string, fallback: string, problems: string[], maximumLength = 4_096): string {
  if (value === undefined) return fallback
  if (typeof value !== 'string' || value.length > maximumLength) {
    problems.push(`${path} 必须是不超过 ${String(maximumLength)} 个字符的字符串。`)
    return fallback
  }
  return value
}

/** Read the runner section. */
function readRunner(value: unknown, fallback: RunnerConfig, problems: string[]): RunnerConfig {
  if (value === undefined) return fallback
  if (!isRecord(value)) {
    problems.push('runner 必须是一个 JSON 对象。')
    return fallback
  }
  const profile = readString(value['profile'], 'runner.profile', fallback.profile, problems, 128)
  if (profile !== '' && !PROFILE_PATTERN.test(profile)) {
    problems.push('runner.profile 只能包含字母、数字、点、下划线和连字符。')
  }
  return {
    nodePath: readString(value['nodePath'], 'runner.nodePath', fallback.nodePath, problems),
    pnpmPath: readString(value['pnpmPath'], 'runner.pnpmPath', fallback.pnpmPath, problems),
    repoDir: readString(value['repoDir'], 'runner.repoDir', fallback.repoDir, problems),
    profile,
    patchPath: readString(value['patchPath'], 'runner.patchPath', fallback.patchPath, problems),
    dshHome: readString(value['dshHome'], 'runner.dshHome', fallback.dshHome, problems),
  }
}

/** Read the remote host listener section. */
function readHost(value: unknown, fallback: RemoteHostSettings, problems: string[]): RemoteHostSettings {
  if (value === undefined) return fallback
  if (!isRecord(value)) {
    problems.push('host 必须是一个 JSON 对象。')
    return fallback
  }
  const listenHost = readString(value['host'], 'host.host', fallback.host, problems, 255)
  if (listenHost.trim() !== listenHost || listenHost === '') {
    problems.push('host.host 必须是一个非空、不含首尾空白的地址。')
  }
  const publicOrigin = readString(value['publicOrigin'], 'host.publicOrigin', fallback.publicOrigin, problems)
  if (publicOrigin !== '' && !isPairingOrigin(publicOrigin)) {
    problems.push('host.publicOrigin 必须是 wss://主机名[:端口] 形式的地址，可留空。')
  }
  return {
    port: readInteger(value['port'], 'host.port', 1, MAXIMUM_PORT, fallback.port, problems),
    host: listenHost,
    publicHost: readString(value['publicHost'], 'host.publicHost', fallback.publicHost, problems, 255),
    publicOrigin,
    discoveryEnabled: readBoolean(value['discoveryEnabled'], 'host.discoveryEnabled', fallback.discoveryEnabled, problems),
    discoveryPort: readInteger(value['discoveryPort'], 'host.discoveryPort', 1, MAXIMUM_PORT, fallback.discoveryPort, problems),
    pagesEnabled: readBoolean(value['pagesEnabled'], 'host.pagesEnabled', fallback.pagesEnabled, problems),
    pagesPort: readInteger(value['pagesPort'], 'host.pagesPort', 1, MAXIMUM_PORT, fallback.pagesPort, problems),
  }
}

/** Read the long-term pairing section. */
function readPairing(value: unknown, fallback: PairingSettings, problems: string[]): PairingSettings {
  if (value === undefined) return fallback
  if (!isRecord(value)) {
    problems.push('pairing 必须是一个 JSON 对象。')
    return fallback
  }
  return {
    longTerm: readBoolean(value['longTerm'], 'pairing.longTerm', fallback.longTerm, problems),
    pairingTtlMs: readInteger(
      value['pairingTtlMs'],
      'pairing.pairingTtlMs',
      MINIMUM_PAIRING_TTL_MS,
      MAXIMUM_PAIRING_TTL_MS,
      fallback.pairingTtlMs,
      problems,
    ),
  }
}

/**
 * Read the managed-tunnel section.
 *
 * Required-for-launch facts (executable, access key, tunnel ids, public
 * address) may stay empty so the page can persist partial work; the tunnel
 * readiness check reports them before any spawn. Formats are validated here,
 * strictly, because a wrong value would only fail once frpc runs.
 */
function readTunnel(value: unknown, fallback: TunnelSettings, problems: string[]): TunnelSettings {
  if (value === undefined) return fallback
  if (!isRecord(value)) {
    problems.push('tunnel 必须是一个 JSON 对象。')
    return fallback
  }
  const provider = readTunnelProvider(value['provider'], fallback.provider, problems)
  const frpcPath = readString(value['frpcPath'], 'tunnel.frpcPath', fallback.frpcPath, problems)
  if (SINGLE_LINE_VIOLATION.test(frpcPath)) problems.push('tunnel.frpcPath 不能包含换行或控制字符。')
  const token = readTunnelToken(value['token'], value['clearToken'], fallback.token, problems)
  const tunnelIds = readString(value['tunnelIds'], 'tunnel.tunnelIds', fallback.tunnelIds, problems, 512)
  if (tunnelIds !== '' && !TUNNEL_IDS_PATTERN.test(tunnelIds)) {
    problems.push('tunnel.tunnelIds 必须是数字隧道 ID，用英文逗号分隔（如 114514 或 114514,114516）。')
  }
  const publicAddress = readString(value['publicAddress'], 'tunnel.publicAddress', fallback.publicAddress, problems, 255)
  if (publicAddress !== '') {
    if (SCHEME_PATTERN.test(publicAddress)) {
      problems.push('tunnel.publicAddress 只填写「节点域名:远程端口」。HTTPS 隧道会在服务端终止 TLS，无法配合远程宿主的固定证书，必须使用 TCP 隧道。')
    } else if (!isTunnelPublicAddress(publicAddress)) {
      problems.push('tunnel.publicAddress 必须是 节点域名:远程端口 形式（如 cn-xx.natfrp.cloud:12345）。')
    }
  }
  const iniPath = readString(value['iniPath'], 'tunnel.iniPath', fallback.iniPath, problems)
  if (SINGLE_LINE_VIOLATION.test(iniPath)) problems.push('tunnel.iniPath 不能包含换行或控制字符。')
  const extraArgs = readString(value['extraArgs'], 'tunnel.extraArgs', fallback.extraArgs, problems)
  if (extraArgs !== '' && !isSafeTunnelExtraArgs(extraArgs)) {
    problems.push('tunnel.extraArgs 只能包含空白分隔的 frpc 参数，不能包含 shell 元字符或换行。')
  }
  const autoProvision = readBoolean(value['autoProvision'], 'tunnel.autoProvision', fallback.autoProvision, problems)
  const frpcAutoDownload = readBoolean(value['frpcAutoDownload'], 'tunnel.frpcAutoDownload', fallback.frpcAutoDownload, problems)
  const nodeId = readNullableId(value['nodeId'], 'tunnel.nodeId', fallback.nodeId, problems)
  const tunnelName = readString(value['tunnelName'], 'tunnel.tunnelName', fallback.tunnelName, problems, MAXIMUM_TUNNEL_NAME_LENGTH)
  if (SINGLE_LINE_VIOLATION.test(tunnelName)) problems.push('tunnel.tunnelName 不能包含换行或控制字符。')
  if (tunnelName.trim() === '') problems.push('tunnel.tunnelName 不能为空。')
  const tunnelId = readNullableId(value['tunnelId'], 'tunnel.tunnelId', fallback.tunnelId, problems)
  return {
    provider,
    frpcPath,
    token,
    tunnelIds,
    publicAddress,
    iniPath,
    extraArgs,
    autoProvision,
    frpcAutoDownload,
    nodeId,
    tunnelName,
    tunnelId,
  }
}

/**
 * Read an optional provider id: absent keeps the fallback, `null` clears it, and
 * a non-negative safe integer sets it. Zero means "let the plugin choose".
 */
function readNullableId(value: unknown, path: string, fallback: number | null, problems: string[]): number | null {
  if (value === undefined) return fallback
  if (value === null) return null
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    problems.push(`${path} 必须是 0 或正整数，或 null（自动选择）。`)
    return fallback
  }
  return value
}

/** Read the tunnel provider, or the fallback when absent. */
function readTunnelProvider(value: unknown, fallback: TunnelProvider, problems: string[]): TunnelProvider {
  if (value === undefined) return fallback
  if (value !== 'none' && value !== 'sakurafrp') {
    problems.push('tunnel.provider 必须是 none 或 sakurafrp。')
    return fallback
  }
  return value
}

/**
 * Read the write-only access key: absent or empty keeps the stored key, `null`
 * or `clearToken: true` clears it, and any other value replaces it.
 */
function readTunnelToken(value: unknown, clearFlag: unknown, fallback: string, problems: string[]): string {
  const clear = readBoolean(clearFlag, 'tunnel.clearToken', false, problems)
  if (clear) return ''
  if (value === undefined || value === '') return fallback
  if (value === null) return ''
  if (typeof value !== 'string' || value.length > MAXIMUM_TUNNEL_TOKEN_LENGTH) {
    problems.push(`tunnel.token 必须是不超过 ${String(MAXIMUM_TUNNEL_TOKEN_LENGTH)} 个字符的字符串或 null。`)
    return fallback
  }
  if (TOKEN_VIOLATION.test(value)) {
    problems.push('tunnel.token（访问密钥）不能包含空白或控制字符。')
    return fallback
  }
  return value
}

/**
 * Whether one value is a pairing origin the remote host accepts: `wss://`
 * authority only, with no path, query, fragment, or account information.
 * @param value - candidate text.
 * @returns true for an accepted origin.
 */
export function isPairingOrigin(value: string): boolean {
  let url: URL
  try {
    url = new URL(value)
  } catch (error) {
    // An unparsable origin is exactly what this check reports.
    if (error instanceof TypeError) return false
    throw error
  }
  return url.protocol === 'wss:'
    && url.username === ''
    && url.password === ''
    && url.pathname === '/'
    && url.search === ''
    && url.hash === ''
    && url.hostname !== ''
}

/**
 * Whether one value is a device id the remote host serves.
 * @param value - candidate device id.
 * @returns true for 32 lowercase hexadecimal characters.
 */
export function isDeviceId(value: unknown): value is string {
  return typeof value === 'string' && DEVICE_ID_PATTERN.test(value)
}
