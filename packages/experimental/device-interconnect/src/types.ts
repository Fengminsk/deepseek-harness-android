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

/** The complete snapshot the Host bridge serves to the Settings page. */
export interface RuntimeState {
  /** The persisted configuration in force. */
  readonly config: DeviceInterconnectConfig
  /** Supervised child state and its log tail. */
  readonly child: ChildState
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
  /** Activation-time problems the page reports above the cards. */
  readonly problems: readonly Diagnostic[]
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

/** `POST /device-interconnect/api/config` body. */
export interface ConfigRequest {
  /** The complete edited configuration. */
  readonly config: DeviceInterconnectConfig
}

/** `POST /device-interconnect/api/devices/revoke` body. */
export interface RevokeRequest {
  /** Device id to revoke. */
  readonly deviceId: string
}

/** `GET /device-interconnect/api/logs` body. */
export interface LogsResponse {
  /** Tail of the child's combined output. */
  readonly logsTail: string
}
