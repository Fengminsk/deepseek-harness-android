/**
 * Wire types shared by the Device Interconnect bundle's two faces: the Host
 * plugin writes them into its HTTP bridge, and the browser page reads them from
 * it. They also mirror the remote host's loopback pairing-control JSON, which
 * the Host plugin validates at that process boundary.
 * @module @deepseek-ai/dsh-device-interconnect/types
 */

/** How the supervised remote host child process is launched. */
export interface RunnerConfig {
  /** Node.js executable that runs the launcher. */
  readonly nodePath: string
  /** `pnpm.mjs` executed by that Node.js executable. */
  readonly pnpmPath: string
  /** Repository checkout the child runs from; its root `dsh` script starts the host. */
  readonly repoDir: string
  /** DSH profile the child launches. */
  readonly profile: string
  /** Additional `--patch` overlay passed after the generated one; empty for none. */
  readonly patchPath: string
  /** `DSH_HOME` given to the child; empty inherits this Host process's value. */
  readonly dshHome: string
}

/** Remote host listener settings written into the generated overlay. */
export interface RemoteHostSettings {
  /** `wss` listen port of the remote host. */
  readonly port: number
  /** Listen address of the remote host. */
  readonly host: string
  /** Host name or IPv4 address advertised in pairing links; empty auto-selects. */
  readonly publicHost: string
  /** Externally announced pairing origin (`wss://host[:port]`); empty auto-generates. */
  readonly publicOrigin: string
  /** Whether UDP LAN discovery answers phones. */
  readonly discoveryEnabled: boolean
  /** UDP discovery port. */
  readonly discoveryPort: number
  /** Whether the loopback pairing page (and its HTTP control API) is served. */
  readonly pagesEnabled: boolean
  /** Loopback HTTP port of the pairing page and its control API. */
  readonly pagesPort: number
}

/** Long-term pairing settings written into the generated overlay. */
export interface PairingSettings {
  /** Keep a fresh pairing window open after each successful pairing. */
  readonly longTerm: boolean
  /** How long one pairing window stays valid, in milliseconds. */
  readonly pairingTtlMs: number
}

/** Tunnel providers a managed NAT-traversal child can use. */
export type TunnelProvider = 'none' | 'sakurafrp'

/**
 * SakuraFrp TCP tunnel settings.
 *
 * The remote host terminates TLS itself with a fixed CA, so only a TCP tunnel
 * works: an HTTP or HTTPS tunnel would terminate TLS at the provider and every
 * pinned-certificate connection would fail.
 *
 * With `autoProvision` the plugin uses the SakuraFrp API to validate the
 * account, pick a node, create or reuse the tunnel, and fill in `tunnelId`,
 * `nodeId`, `publicAddress`, and `tunnelIds`; without it every value stays
 * manual and `autoProvision=false` keeps the historical behavior.
 */
export interface TunnelSettings {
  /** Which tunnel provider to manage; `none` keeps the frpc child stopped. */
  readonly provider: TunnelProvider
  /** Local frpc executable; empty means not configured. The plugin never downloads it. */
  readonly frpcPath: string
  /** SakuraFrp access key; write-only, so the bridge never serves it back. */
  readonly token: string
  /** SakuraFrp tunnel ids, comma separated: `114514` or `114514,114516`. */
  readonly tunnelIds: string
  /** Public `<node-domain>:<remote-port>` of the TCP tunnel, as the panel shows it. */
  readonly publicAddress: string
  /** Custom `frpc.ini`; when set it replaces the access-key command. */
  readonly iniPath: string
  /** Additional whitespace-separated frpc arguments; empty for none. */
  readonly extraArgs: string
  /** Use the SakuraFrp API to validate the account and create or reuse the tunnel. */
  readonly autoProvision: boolean
  /** Allow downloading frpc when provisioning needs it and `frpcPath` is empty. */
  readonly frpcAutoDownload: boolean
  /** Node the automatic provision uses; `null` picks one automatically. */
  readonly nodeId: number | null
  /** Tunnel name the automatic provision reuses or creates. */
  readonly tunnelName: string
  /** Tunnel the automatic provision created or reused; `null` until it ran. */
  readonly tunnelId: number | null
}

/** Everything the Host plugin persists in `<DSH_HOME>/device-interconnect/config.json`. */
export interface DeviceInterconnectConfig {
  /** Whether the supervised remote host child should be running. */
  readonly enabled: boolean
  /** Child-process launch settings. */
  readonly runner: RunnerConfig
  /** Remote host listener settings. */
  readonly host: RemoteHostSettings
  /** Long-term pairing settings. */
  readonly pairing: PairingSettings
  /** Managed NAT-traversal tunnel settings. */
  readonly tunnel: TunnelSettings
}

/** The tunnel settings the Settings page sees: the access key is reduced to a presence flag. */
export interface TunnelSettingsView {
  /** Which tunnel provider is configured. */
  readonly provider: TunnelProvider
  /** Local frpc executable. */
  readonly frpcPath: string
  /** SakuraFrp tunnel ids. */
  readonly tunnelIds: string
  /** Public `<node-domain>:<remote-port>`. */
  readonly publicAddress: string
  /** Custom `frpc.ini`, or empty. */
  readonly iniPath: string
  /** Additional whitespace-separated frpc arguments. */
  readonly extraArgs: string
  /** Whether an access key is stored; the key itself is never served. */
  readonly tokenConfigured: boolean
  /** Whether the automatic provision mode is on. */
  readonly autoProvision: boolean
  /** Whether frpc may be downloaded when provisioning needs it. */
  readonly frpcAutoDownload: boolean
  /** Pinned node id, or null for automatic selection. */
  readonly nodeId: number | null
  /** Tunnel name the automatic provision reuses or creates. */
  readonly tunnelName: string
  /** Tunnel the automatic provision created or reused, or null. */
  readonly tunnelId: number | null
}

/** The configuration as the Settings page sees it, with the write-only access key removed. */
export interface DeviceInterconnectView {
  /** Whether the supervised remote host child should be running. */
  readonly enabled: boolean
  /** Child-process launch settings. */
  readonly runner: RunnerConfig
  /** Remote host listener settings. */
  readonly host: RemoteHostSettings
  /** Long-term pairing settings. */
  readonly pairing: PairingSettings
  /** Tunnel settings without the access key. */
  readonly tunnel: TunnelSettingsView
}

/**
 * One tunnel block submitted by the Settings page.
 *
 * The access key is write-only: an absent or empty `token` keeps the stored
 * key, `null` clears it, and `clearToken: true` clears it without a value.
 */
export interface TunnelSettingsInput {
  /** Which tunnel provider the page selected; absent keeps the stored value. */
  readonly provider?: TunnelProvider
  /** Local frpc executable path. */
  readonly frpcPath?: string
  /** Replacement access key; absent or empty keeps the stored one, `null` clears it. */
  readonly token?: string | null
  /** Clear the stored access key instead of replacing it. */
  readonly clearToken?: boolean
  /** SakuraFrp tunnel ids. */
  readonly tunnelIds?: string
  /** Public `<node-domain>:<remote-port>`. */
  readonly publicAddress?: string
  /** Custom `frpc.ini`. */
  readonly iniPath?: string
  /** Additional whitespace-separated frpc arguments. */
  readonly extraArgs?: string
  /** Turn the automatic provision mode on or off. */
  readonly autoProvision?: boolean
  /** Allow downloading frpc when provisioning needs it. */
  readonly frpcAutoDownload?: boolean
  /** Pinned node id; null or 0 selects one automatically. */
  readonly nodeId?: number | null
  /** Tunnel name the automatic provision reuses or creates. */
  readonly tunnelName?: string
  /** Tunnel the automatic provision created or reused. */
  readonly tunnelId?: number | null
}

/** One complete configuration document submitted by the Settings page. */
export interface DeviceInterconnectConfigInput {
  /** Whether the supervised remote host child should be running. */
  readonly enabled?: boolean
  /** Child-process launch settings. */
  readonly runner?: RunnerConfig
  /** Remote host listener settings. */
  readonly host?: RemoteHostSettings
  /** Long-term pairing settings. */
  readonly pairing?: PairingSettings
  /** Tunnel settings, whose access key is write-only. */
  readonly tunnel?: TunnelSettingsInput
}

/** One paired device as the remote host reports it, without any token material. */
export interface RemoteDevice {
  /** Device id: 32 lowercase hexadecimal characters. */
  readonly id: string
  /** Device display name. */
  readonly label: string
  /** Pairing time (Unix milliseconds). */
  readonly createdAt: number
  /** Last authenticated connection time (Unix milliseconds). */
  readonly lastSeenAt: number
  /** Device token expiry (Unix milliseconds). */
  readonly expiresAt: number
  /** Revocation time (Unix milliseconds); present when the device is revoked. */
  readonly revokedAt?: number
}

/** The remote host's own identity and listener facts. */
export interface RemoteHostFacts {
  /** Host display name from the handshake. */
  readonly name: string
  /** 64 lowercase hexadecimal instance id (certificate fingerprint). */
  readonly instanceId: string
  /** Announced `wss://host[:port]` origin. */
  readonly origin: string
  /** `wss` listen port. */
  readonly port: number
  /** LAN discovery state. */
  readonly discovery: {
    /** Whether discovery answers phones. */
    readonly enabled: boolean
    /** UDP port discovery listens on. */
    readonly port: number
  }
  /** Whether the remote host is listening. */
  readonly listening: boolean
}

/** One pairing window, present while the remote host has an unused window open. */
export interface PairingWindow {
  /** Whether a usable window exists. */
  readonly open: boolean
  /** Window expiry (Unix milliseconds); absent when closed. */
  readonly expiresAt?: number
  /** Pairing link to display and encode; absent when closed. */
  readonly pairUrl?: string
  /** Loopback pairing link for `adb reverse` USB connections; absent when closed. */
  readonly usbPairUrl?: string
}

/** The remote host's loopback `/api/state` JSON, restricted to the fields this bundle reads. */
export interface ControlPlaneState {
  /** Host identity and listener facts. */
  readonly host?: RemoteHostFacts
  /** The current pairing window. */
  readonly pairing: PairingWindow
  /** Paired device summaries. */
  readonly devices: readonly RemoteDevice[]
}

/** Child-process state as the supervisor reports it. */
export interface ChildState {
  /** Whether a child process is running. */
  readonly running: boolean
  /** Child process id while running. */
  readonly pid?: number
  /** Spawn time (Unix milliseconds) while running. */
  readonly startedAt?: number
  /** Exit code once the child exited. */
  readonly exitCode?: number
  /** Exit time (Unix milliseconds) once the child exited. */
  readonly exitedAt?: number
  /** Last spawn or runtime error message, kept until the next start. */
  readonly error?: string
  /** Tail of the child's combined stdout and stderr, at most 64 KiB. */
  readonly logsTail: string
}

/** A user-presentable problem: a stable code plus a Chinese, directly displayable message. */
export interface Diagnostic {
  /** Stable machine-readable code the Client maps onto its locale dictionary. */
  readonly code: string
  /** Chinese message usable as-is when the Client has no mapping. */
  readonly message: string
}

/** Whether the saved tunnel can launch its frpc child, and what is missing if it cannot. */
export interface TunnelReadiness {
  /** Every required setting is present and its executable path exists. */
  readonly ready: boolean
  /** Missing or invalid tunnel facts, in display order. */
  readonly problems: readonly Diagnostic[]
}

/** The SakuraFrp account facts shown next to the one-click action. */
export interface TunnelAccount {
  /** Account name. */
  readonly name?: string
  /** Account id. */
  readonly uid?: number
  /** Bandwidth limit in Mbit/s. */
  readonly speed?: number
  /** Maximum number of tunnels the account may own. */
  readonly tunnelLimit?: number
  /** Tunnels the account owns now. */
  readonly tunnelCount?: number
  /** Remaining traffic in the provider's unit. */
  readonly trafficRemaining?: number
}

/** One status of the automatic provision flow. */
export type ProvisionStepStatus = 'pending' | 'done' | 'failed' | 'skipped'

/** One step of the automatic provision flow. */
export interface ProvisionStep {
  /** Stable step id: `verify-token`, `select-node`, `ensure-tunnel`, `resolve-address`, `prepare-frpc`, `start-tunnel`. */
  readonly id: string
  /** Step outcome. */
  readonly status: ProvisionStepStatus
  /** Chinese, directly displayable outcome text. */
  readonly message: string
}

/** The last automatic provision attempt. */
export interface TunnelProvisionState {
  /** Steps of the last attempt, in execution order. */
  readonly lastSteps: readonly ProvisionStep[]
  /** Why the last attempt failed, when it did. */
  readonly lastError?: Diagnostic
  /** Provider warning the API asked the caller to surface to the user. */
  readonly warning?: string
}

/** The node the automatic provision selected. */
export interface TunnelNodeInfo {
  /** Node id. */
  readonly id: number
  /** Node display name. */
  readonly name?: string
  /** Node host the public address uses. */
  readonly host?: string
  /** Measured TCP latency of the node, in milliseconds. */
  readonly latencyMs?: number
}

/** The tunnel the automatic provision created or reused. */
export interface TunnelInfo {
  /** Tunnel id. */
  readonly id: number
  /** Tunnel name. */
  readonly name?: string
  /** Provider-side remote port or address assigned to the tunnel. */
  readonly remote?: string
}

/** The frpc executable the plugin resolved. */
export interface TunnelFrpcInfo {
  /** Absolute executable path. */
  readonly path?: string
  /** Whether the plugin downloaded this executable. */
  readonly downloaded?: boolean
  /** Version reported by `frpc -V`. */
  readonly version?: string
}

/** The tunnel child state plus the facts the page derives from its settings. */
export interface TunnelState extends ChildState {
  /** Configured provider. */
  readonly provider: TunnelProvider
  /** Whether the saved tunnel settings can launch. */
  readonly ready: boolean
  /** Missing or invalid tunnel facts, in display order. */
  readonly problems: readonly Diagnostic[]
  /** Origin derived from the public address (`wss://…`); empty when none applies. */
  readonly derivedPublicOrigin: string
  /** SakuraFrp account from the last provision, when known. */
  readonly account?: TunnelAccount
  /** The last automatic provision attempt. */
  readonly provision?: TunnelProvisionState
  /** Node selected by the last provision or pinned in the configuration. */
  readonly node?: TunnelNodeInfo
  /** Tunnel created or reused by the last provision, or the persisted id. */
  readonly tunnel?: TunnelInfo
  /** frpc executable facts. */
  readonly frpc?: TunnelFrpcInfo
}

/** Whether the saved runner can launch, and what is missing if it cannot. */
export interface RunnerReadiness {
  /** Every executable path and the repository directory exists. */
  readonly ready: boolean
  /** Missing or invalid runner facts, in display order. */
  readonly problems: readonly Diagnostic[]
}

/** The pairing facts the page renders, including the same-origin QR image URL. */
export interface PairingView extends PairingWindow {
  /** Whether long-term pairing is configured, which the page shows instead of a countdown. */
  readonly longTerm: boolean
  /** Same-origin Host route serving the QR SVG, versioned by the window expiry. */
  readonly qrSvgUrl?: string
}

/** Desktop Plan-B relay availability shown on the Settings page (never the token). */
export interface DesktopRelayState {
  /** Whether the loopback relay is listening. */
  readonly available: boolean
  /** Loopback base URL when available. */
  readonly url?: string
  /** Readable failure reason when unavailable. */
  readonly error?: string
}

/** The complete snapshot the Host bridge serves to the Settings page. */
export interface RuntimeState {
  /** The persisted configuration in force, with the write-only access key removed. */
  readonly config: DeviceInterconnectView
  /** Supervised child state and its log tail. */
  readonly child: ChildState
  /** The managed tunnel child state and the origin derived from its settings. */
  readonly tunnel: TunnelState
  /** Whether the loopback control API answered, plus host facts when it did. */
  readonly controlPlane: {
    /** Whether the last control-plane read succeeded. */
    readonly reachable: boolean
    /** Remote host facts from the last successful read. */
    readonly host?: RemoteHostFacts
    /** Why the last read failed, when it did. */
    readonly error?: Diagnostic
  }
  /** The pairing window as the page should render it. */
  readonly pairing: PairingView
  /** Paired devices, newest first as the remote host reports them. */
  readonly devices: readonly RemoteDevice[]
  /** Whether the runner can start. */
  readonly runner: RunnerReadiness
  /** Automatic-restart bookkeeping for the two supervised children. */
  readonly recovery?: RuntimeRecovery
  /** Desktop Plan-B relay availability. */
  readonly relay?: DesktopRelayState
  /** Activation-time problems the page reports above the cards. */
  readonly problems: readonly Diagnostic[]
}

/** Auto-restart facts of one supervised child. */
export interface RecoveryState {
  /** How many automatic restarts have been started since the bridge began. */
  readonly restartCount: number
  /** Unix time of the next scheduled auto-restart; absent when none is pending. */
  readonly nextRetryAt?: number
  /** True when restarts stopped after repeated crashes. */
  readonly exhausted?: boolean
}

/** Auto-restart facts for the remote host and the frpc tunnel. */
export interface RuntimeRecovery {
  /** Remote-host child recovery. */
  readonly host: RecoveryState
  /** Tunnel child recovery. */
  readonly tunnel: RecoveryState
}

/** One JSON error body every Host bridge route returns on failure. */
export interface ErrorBody {
  /** The failure. */
  readonly error: Diagnostic
}

/** `POST /device-interconnect/api/enabled` body. */
export interface EnabledRequest {
  /** The new switch position. */
  readonly enabled: boolean
}

/** `POST /device-interconnect/api/tunnel` body. */
export interface TunnelRequest {
  /** Whether the tunnel child should run. */
  readonly enabled: boolean
}

/** `POST /device-interconnect/api/tunnel/provision` body. */
export interface ProvisionRequest {
  /** Replacement access key; absent or empty keeps the stored one, `null` clears it. */
  readonly token?: string | null
  /** Local frpc executable path; absent keeps the stored one. */
  readonly frpcPath?: string
  /** Allow downloading frpc when needed; absent keeps the stored value. */
  readonly frpcAutoDownload?: boolean
  /** Pinned node id; `null` or `0` selects one automatically. */
  readonly nodeId?: number | null
  /** Tunnel name to reuse or create; absent keeps the stored value. */
  readonly tunnelName?: string
  /** Reuse an existing tunnel instead of creating one; defaults to true. */
  readonly reuseExisting?: boolean
}

/** `POST /device-interconnect/api/config` body. */
export interface ConfigRequest {
  /** The complete edited configuration, including the write-only access key rules. */
  readonly config: DeviceInterconnectConfigInput
}

/** `POST /device-interconnect/api/devices/revoke` body. */
export interface RevokeRequest {
  /** Device id to revoke. */
  readonly deviceId: string
}

/** `POST /device-interconnect/api/devices/delete` body. */
export interface DeleteRequest {
  /** Device id whose record is removed permanently. */
  readonly deviceId: string
}

/** `GET /device-interconnect/api/logs` body. */
export interface LogsResponse {
  /** Tail of the child's combined output. */
  readonly logsTail: string
}

/** `GET /device-interconnect/api/tunnel/logs` body. */
export interface TunnelLogsResponse {
  /** Tail of the frpc child's combined output. */
  readonly logsTail: string
}
