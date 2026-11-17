/**
 * Managed NAT-traversal tunnel: the frpc launch command, the checks that keep a
 * broken configuration from spawning it, and the public origin derived from the
 * provider's TCP tunnel address.
 *
 * The remote host serves TLS itself with a fixed CA, so only an SakuraFrp TCP
 * tunnel preserves end-to-end TLS. An HTTP or HTTPS tunnel terminates TLS at
 * the provider, and the pinned-certificate App could never connect through it.
 * @module @deepseek-ai/dsh-device-interconnect/host/tunnel
 */

import { join } from 'node:path'
import type {
  DeviceInterconnectConfig, Diagnostic, ProvisionStep, TunnelReadiness, TunnelSettings,
} from '../types.ts'
import type { LaunchCommand } from './supervisor.ts'

/** Highest accepted public TCP port. */
const MAXIMUM_PORT = 65_535

/** Longest accepted DNS name in the tunnel's public address. */
const MAXIMUM_HOST_LENGTH = 253

/** Longest accepted DNS label. */
const MAXIMUM_LABEL_LENGTH = 63

/**
 * `node-domain:port` of one SakuraFrp TCP tunnel. The address never carries a
 * scheme: a pasted `https://…` URL is rejected with a message about TLS
 * termination, because that tunnel type cannot serve the fixed CA.
 */
const PUBLIC_ADDRESS_PATTERN = /^(?<host>[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):(?<port>\d{1,5})$/u

/** Shell metacharacters and C0/C1 control characters an extra argument may not contain. */
const UNSAFE_EXTRA_ARGUMENT = /[\u0000-\u001f\u007f&|;<>()$`"'*?[\]{}!^%~]/u

/** A tunnel action the bridge refused before spawning frpc. */
export class TunnelError extends Error {
  /** Stable machine-readable code the Client maps onto its locale dictionary. */
  readonly code: string
  /** HTTP status the bridge answers with. */
  readonly status: number

  /**
   * @param code - stable failure code.
   * @param status - HTTP status the bridge answers with.
   * @param message - Chinese message usable as-is as a fallback.
   */
  constructor(code: string, status: number, message: string) {
    super(message)
    this.name = 'TunnelError'
    this.code = code
    this.status = status
  }
}

/** A failure of the automatic SakuraFrp provision, carrying the steps it reached. */
export class TunnelProvisionError extends Error {
  /** Stable machine-readable code the Client maps onto its locale dictionary. */
  readonly code: string
  /** Steps of the attempt up to the failure, followed by pending steps. */
  readonly steps: readonly ProvisionStep[]

  /**
   * @param code - stable failure code.
   * @param message - Chinese message usable as-is.
   * @param steps - steps up to the failure.
   */
  constructor(code: string, message: string, steps: readonly ProvisionStep[]) {
    super(message)
    this.name = 'TunnelProvisionError'
    this.code = code
    this.steps = steps
  }
}

/**
 * Whether one value is a SakuraFrp TCP tunnel public address: `node-domain:port`
 * with a DNS name or IPv4 literal and a port in 1–65535.
 * @param value - candidate address.
 * @returns true for an accepted address.
 */
export function isTunnelPublicAddress(value: string): boolean {
  const match = PUBLIC_ADDRESS_PATTERN.exec(value)
  if (match === null) return false
  const host = match.groups?.['host'] ?? ''
  const port = Number(match.groups?.['port'] ?? '')
  if (!Number.isSafeInteger(port) || port < 1 || port > MAXIMUM_PORT) return false
  if (host.length > MAXIMUM_HOST_LENGTH || host.includes('..')) return false
  return host.split('.').every(label => label !== '' && label.length <= MAXIMUM_LABEL_LENGTH)
}

/**
 * Whether one extra-arguments string has no shell metacharacter or control
 * character. frpc is spawned without a shell, so this keeps a pasted shell
 * fragment from being silently misread as frpc arguments.
 * @param value - candidate arguments.
 * @returns true when the arguments are acceptable.
 */
export function isSafeTunnelExtraArgs(value: string): boolean {
  return !UNSAFE_EXTRA_ARGUMENT.test(value)
}

/**
 * The remote host origin a SakuraFrp TCP tunnel makes public, including an
 * explicit `:443`; empty when the provider is off or the address is not one.
 * @param tunnel - tunnel settings.
 * @returns `wss://<node-domain>:<port>`, or an empty string.
 */
export function derivePublicOrigin(tunnel: TunnelSettings): string {
  if (tunnel.provider !== 'sakurafrp') return ''
  if (tunnel.publicAddress === '' || !isTunnelPublicAddress(tunnel.publicAddress)) return ''
  return `wss://${tunnel.publicAddress}`
}

/**
 * Apply the tunnel-derived origin over the manually configured one. The
 * derivation wins because the pairing link must name the address a phone can
 * actually reach; the Settings page still shows the manual field for the case
 * without a managed tunnel.
 * @param config - configuration in force.
 * @returns the configuration whose remote host origin reflects the tunnel.
 */
export function withTunnelOrigin(config: DeviceInterconnectConfig): DeviceInterconnectConfig {
  const derived = derivePublicOrigin(config.tunnel)
  if (derived === '') return config
  return { ...config, host: { ...config.host, publicOrigin: derived } }
}

/**
 * Absolute path of the frpc executable the plugin downloads when the
 * automatic provision needs one.
 * @param dataDir - bundle data directory.
 * @param platform - host platform; Windows uses the `.exe` suffix.
 * @returns the install path inside the bundle data directory.
 */
export function frpcInstallPath(dataDir: string, platform: NodeJS.Platform): string {
  return join(dataDir, 'bin', platform === 'win32' ? 'frpc.exe' : 'frpc')
}

/**
 * Whether the saved tunnel can launch frpc, and what is missing if it cannot.
 * Structural problems are rejected at save; this also covers a hand-edited
 * configuration file, an executable removed after saving, and the state before
 * the automatic provision created its tunnel.
 * @param tunnel - tunnel settings.
 * @param exists - whether one path exists.
 * @param frpcPath - resolved executable, defaulting to the configured path.
 * @returns readiness with one problem per missing fact.
 */
export function tunnelReadiness(
  tunnel: TunnelSettings,
  exists: (path: string) => boolean,
  frpcPath: string = tunnel.frpcPath,
): TunnelReadiness {
  if (tunnel.provider !== 'sakurafrp') return { ready: false, problems: [] }
  const problems: Diagnostic[] = []
  if (frpcPath === '') {
    problems.push({
      code: 'tunnel-frpc-missing',
      message: tunnel.autoProvision
        ? '未找到 frpc 可执行文件：请填写路径，或点击一键创建并在允许时自动下载。'
        : '未配置 frpc 可执行文件路径（内网穿透 → frpc 路径）。',
    })
  } else if (!exists(frpcPath)) {
    problems.push({ code: 'tunnel-frpc-missing', message: `frpc 可执行文件不存在：${frpcPath}` })
  }
  if (tunnel.iniPath !== '') {
    if (!exists(tunnel.iniPath)) {
      problems.push({ code: 'tunnel-ini-missing', message: `自定义 frpc.ini 不存在：${tunnel.iniPath}` })
    }
  }
  if (tunnel.autoProvision) {
    if (tunnel.token === '') {
      problems.push({ code: 'tunnel-token-missing', message: '未配置 SakuraFrp 访问密钥（一键创建需要）。' })
    }
    if (tunnel.tunnelId === null || tunnel.tunnelId <= 0) {
      problems.push({ code: 'tunnel-not-provisioned', message: '尚未自动创建隧道：点击「保存并自动创建隧道」。' })
    }
  } else if (tunnel.iniPath === '') {
    if (tunnel.token === '') {
      problems.push({ code: 'tunnel-token-missing', message: '未配置 SakuraFrp 访问密钥。' })
    }
    if (tunnel.tunnelIds === '') {
      problems.push({ code: 'tunnel-ids-missing', message: '未配置 SakuraFrp 隧道 ID。' })
    }
  } else {
    // A custom frpc.ini replaces the access key and tunnel ids.
  }
  if (tunnel.autoProvision) {
    if (tunnel.publicAddress === '') {
      problems.push({ code: 'tunnel-public-address-missing', message: '隧道公网地址尚未生成，请重新执行一键创建。' })
    } else if (!isTunnelPublicAddress(tunnel.publicAddress)) {
      problems.push({
        code: 'tunnel-public-address-invalid',
        message: `隧道公网地址必须是 节点域名:远程端口 形式（如 cn-xx.natfrp.cloud:12345）：${tunnel.publicAddress}`,
      })
    }
  } else if (tunnel.publicAddress === '') {
    problems.push({ code: 'tunnel-public-address-missing', message: '未填写隧道公网地址（节点域名:远程端口）。' })
  } else if (!isTunnelPublicAddress(tunnel.publicAddress)) {
    problems.push({
      code: 'tunnel-public-address-invalid',
      message: `隧道公网地址必须是 节点域名:远程端口 形式（如 cn-xx.natfrp.cloud:12345）：${tunnel.publicAddress}`,
    })
  }
  return { ready: problems.length === 0, problems }
}

/**
 * Split one extra-arguments string into frpc arguments.
 * @param value - whitespace-separated arguments.
 * @returns the arguments, or an empty list.
 */
export function splitExtraArgs(value: string): readonly string[] {
  const trimmed = value.trim()
  return trimmed === '' ? [] : trimmed.split(/\s+/u)
}

/**
 * Build the launch command of the managed frpc child.
 *
 * Without a custom `frpc.ini` the command pulls the tunnel configuration from
 * the access key: `frpc -f <key>:<tunnelIds> -n --disable_log_color`. With one
 * it runs `frpc -c <ini> -n` instead; either way the extra arguments are
 * appended verbatim.
 * @param tunnel - tunnel settings.
 * @param dataDir - bundle data directory the child runs in.
 * @param env - complete environment of the child.
 * @param frpcPath - resolved executable, defaulting to the configured path.
 * @returns the frpc launch command.
 */
export function tunnelLaunchCommand(
  tunnel: TunnelSettings,
  dataDir: string,
  env: NodeJS.ProcessEnv,
  frpcPath: string = tunnel.frpcPath,
): LaunchCommand {
  const args = tunnel.iniPath === ''
    ? ['-f', `${tunnel.token}:${tunnel.tunnelIds}`, '-n', '--disable_log_color']
    : ['-c', tunnel.iniPath, '-n']
  args.push(...splitExtraArgs(tunnel.extraArgs))
  return { file: frpcPath, args, cwd: dataDir, env }
}
