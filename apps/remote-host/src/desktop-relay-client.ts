/**
 * Client for the desktop Plan-B relay (`<DSH_HOME>/device-interconnect/relay.json`).
 *
 * The remote-host child reads the descriptor on demand; a missing descriptor,
 * a stopped desktop process, a bad token, or a timeout all degrade to
 * {@link DesktopRelayUnavailableError}. Callers then keep their existing child
 * behaviour, so the relay is an additive path only.
 *
 * The token is never logged. Bodies are bounded in `desktop-relay.ts`; this
 * client only sends validated text sends.
 * @module @deepseek-ai/dsh-remote-host/desktop-relay-client
 */

import { readFile } from 'node:fs/promises'

/** Default request timeout for one relay call. */
export const DESKTOP_RELAY_TIMEOUT_MS = 4_000

/**
 * Default timeout for the read-only status calls. They run on the request path of
 * `sessions.list` / `tasks.session`, so a slow desktop must never delay the list
 * response by the full action timeout.
 */
export const DESKTOP_RELAY_STATUS_TIMEOUT_MS = 800

/** Descriptor published by the desktop plugin. */
export interface DesktopRelayDescriptor {
  /** Loopback base URL, e.g. `http://127.0.0.1:53421`. */
  readonly url: string
  /** Shared secret sent in `x-dsh-desktop-relay`. */
  readonly token: string
  /** Desktop relay process id (diagnostics only). */
  readonly pid?: number
  /** Descriptor creation time (diagnostics only). */
  readonly createdAt?: number
}

/** Text send accepted by `POST /relay/session/send`. */
export interface DesktopRelaySendRequest {
  /** Target desktop session. */
  readonly sessionId: string
  /** App request id. */
  readonly requestId?: string
  /** Message text. */
  readonly text: string
  /** Optional model provider selected by the App. */
  readonly provider?: string
  /** Optional model name selected by the App. */
  readonly model?: string
  /** Whether the App asked to switch models before sending. */
  readonly selectModel?: boolean
}

/** One relay session status. */
export interface DesktopRelaySessionStatus {
  /** Coarse execution state. */
  readonly status: 'running' | 'waiting' | 'queued' | 'idle' | 'unknown'
  /** Running tool name when available. */
  readonly toolName?: string
  /** Queued inbox messages. */
  readonly queued?: number
}

/** The relay is not available; callers fall back to their child behaviour. */
export class DesktopRelayUnavailableError extends Error {
  /** Stable reason for diagnostics. */
  readonly code: string

  /**
   * @param code - stable failure code (`no-descriptor`, `timeout`, `unauthorized`, ...).
   * @param message - readable reason without token/content.
   */
  constructor(code: string, message: string) {
    super(message)
    this.name = 'DesktopRelayUnavailableError'
    this.code = code
  }
}

/** Options of one relay client. */
export interface DesktopRelayClientOptions {
  /** Descriptor file path from remote-host Config (`desktopRelayFile`). */
  readonly file: string
  /** Per-request timeout; defaults to {@link DESKTOP_RELAY_TIMEOUT_MS}. */
  readonly timeoutMs?: number
  /** Status-read timeout; defaults to {@link DESKTOP_RELAY_STATUS_TIMEOUT_MS}. */
  readonly statusTimeoutMs?: number
  /** Fetch implementation; defaults to the global one (tests inject a local server). */
  readonly fetch?: typeof fetch
}

/** JSON envelope returned by the relay. */
interface RelayEnvelope {
  readonly ok?: boolean
  readonly result?: unknown
  readonly error?: { readonly code?: unknown; readonly message?: unknown }
  readonly status?: unknown
  readonly toolName?: unknown
  readonly queued?: unknown
  readonly sessions?: unknown
}

/** Bounded text send + optional model switch, relayed to the desktop process. */
export class DesktopRelayClient {
  private readonly options: DesktopRelayClientOptions

  /** @param options - descriptor path and transport seams. */
  constructor(options: DesktopRelayClientOptions) {
    this.options = options
  }

  /** @returns whether a descriptor file currently exists and parses. */
  async available(): Promise<boolean> {
    try {
      await this.descriptor()
      return true
    } catch {
      return false
    }
  }

  /**
   * Relay one text send to the desktop process.
   * @param request - validated text send.
   * @returns the desktop facade's `session.send` result.
   * @throws {DesktopRelayUnavailableError} when the relay cannot execute it.
   */
  async send(request: DesktopRelaySendRequest): Promise<unknown> {
    const envelope = await this.post('/relay/session/send', request)
    if (envelope.ok === true) return envelope.result
    throw new DesktopRelayUnavailableError(
      typeof envelope.error?.code === 'string' ? envelope.error.code : 'relay/error',
      typeof envelope.error?.message === 'string' ? envelope.error.message : '桌面中继没有执行这次发送。',
    )
  }

  /**
   * Read one desktop session's status.
   * @param sessionId - session id.
   * @returns coarse status; `unknown` when the relay is unavailable.
   */
  async sessionStatus(sessionId: string): Promise<DesktopRelaySessionStatus> {
    try {
      const envelope = await this.get(
        `/relay/session/status?sessionId=${encodeURIComponent(sessionId)}`,
        this.options.statusTimeoutMs ?? DESKTOP_RELAY_STATUS_TIMEOUT_MS,
      )
      return statusOf(envelope)
    } catch {
      return { status: 'unknown' }
    }
  }

  /**
   * Read every desktop session status.
   * @returns session id to status map; `{}` when the relay is unavailable.
   */
  async sessionsStatus(): Promise<Readonly<Record<string, DesktopRelaySessionStatus>>> {
    try {
      const envelope = await this.get(
        '/relay/sessions/status',
        this.options.statusTimeoutMs ?? DESKTOP_RELAY_STATUS_TIMEOUT_MS,
      )
      const sessions = envelope.sessions
      if (typeof sessions !== 'object' || sessions === null || Array.isArray(sessions)) return {}
      const result: Record<string, DesktopRelaySessionStatus> = {}
      for (const [id, value] of Object.entries(sessions)) {
        if (typeof value !== 'object' || value === null) continue
        result[id] = statusOf(value as RelayEnvelope)
      }
      return result
    } catch {
      return {}
    }
  }

  /** Read and validate the descriptor. */
  private async descriptor(): Promise<DesktopRelayDescriptor> {
    let raw: string
    try {
      raw = await readFile(this.options.file, 'utf8')
    } catch {
      throw new DesktopRelayUnavailableError('no-descriptor', '桌面中继描述文件不存在。')
    }
    let value: unknown
    try {
      value = JSON.parse(raw)
    } catch {
      throw new DesktopRelayUnavailableError('bad-descriptor', '桌面中继描述文件不是合法 JSON。')
    }
    if (typeof value !== 'object' || value === null) {
      throw new DesktopRelayUnavailableError('bad-descriptor', '桌面中继描述文件结构无效。')
    }
    const record = value as Record<string, unknown>
    const url = record['url']
    const token = record['token']
    if (typeof url !== 'string' || !/^http:\/\/127\.0\.0\.1:\d+$/u.test(url)) {
      throw new DesktopRelayUnavailableError('bad-descriptor', '桌面中继 URL 不是本机回环地址。')
    }
    if (typeof token !== 'string' || token.length < 32) {
      throw new DesktopRelayUnavailableError('bad-descriptor', '桌面中继令牌无效。')
    }
    return { url, token, ...(typeof record['pid'] === 'number' ? { pid: record['pid'] } : {}) }
  }

  /** Send one authenticated JSON request. */
  private async post(path: string, body: unknown): Promise<RelayEnvelope> {
    return this.request(path, { method: 'POST', body: JSON.stringify(body) })
  }

  /** Send one authenticated GET request. */
  private async get(path: string, timeoutMs?: number): Promise<RelayEnvelope> {
    return this.request(path, { method: 'GET' }, timeoutMs)
  }

  /** Perform one authenticated request with a bounded timeout. */
  private async request(path: string, init: { method: string; body?: string }, timeoutMs?: number): Promise<RelayEnvelope> {
    const descriptor = await this.descriptor()
    const doFetch = this.options.fetch ?? fetch
    let response: Response
    try {
      response = await doFetch(`${descriptor.url}${path}`, {
        method: init.method,
        headers: {
          'x-dsh-desktop-relay': descriptor.token,
          ...(init.body === undefined ? {} : { 'content-type': 'application/json' }),
        },
        ...(init.body === undefined ? {} : { body: init.body }),
        signal: AbortSignal.timeout(timeoutMs ?? this.options.timeoutMs ?? DESKTOP_RELAY_TIMEOUT_MS),
      })
    } catch (error) {
      const timeout = error instanceof Error && error.name === 'TimeoutError'
      throw new DesktopRelayUnavailableError(
        timeout ? 'timeout' : 'unreachable',
        timeout ? '桌面中继请求超时。' : '无法连接桌面中继。',
      )
    }
    if (response.status === 403) throw new DesktopRelayUnavailableError('unauthorized', '桌面中继鉴权失败。')
    let value: unknown
    try {
      value = await response.json()
    } catch {
      throw new DesktopRelayUnavailableError('bad-response', '桌面中继返回了非 JSON 响应。')
    }
    if (typeof value !== 'object' || value === null) {
      throw new DesktopRelayUnavailableError('bad-response', '桌面中继响应结构无效。')
    }
    return value as RelayEnvelope
  }
}

/** Read one status envelope; invalid fields degrade to `unknown`. */
function statusOf(envelope: RelayEnvelope): DesktopRelaySessionStatus {
  const status = envelope.status
  if (status !== 'running' && status !== 'waiting' && status !== 'queued' && status !== 'idle') {
    return { status: 'unknown' }
  }
  return {
    status,
    ...(typeof envelope.toolName === 'string' && envelope.toolName !== '' ? { toolName: envelope.toolName } : {}),
    ...(typeof envelope.queued === 'number' && envelope.queued >= 0 ? { queued: envelope.queued } : {}),
  }
}
