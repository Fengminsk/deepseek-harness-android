/**
 * Loopback desktop relay (Plan B): a tiny HTTP server inside the desktop DSH
 * process that the remote-host child can call when it cannot act itself.
 *
 * The server binds 127.0.0.1 only, authenticates every request with a random
 * token, and publishes `{url, token, pid, createdAt}` in
 * `<DSH_HOME>/device-interconnect/relay.json` so the child discovers it without
 * any profile change. Handlers never throw: every failure becomes a JSON error
 * response, so a remote-host retry cannot crash the desktop client.
 *
 * The relay delegates the actual desktop work through a {@link DesktopRelayExecutor}
 * seam. The production executor uses only already-loaded desktop services
 * (`typertGateway`, `connection`, `agents`); no App runtime or remote-host plugin
 * is loaded into the desktop process.
 * @module @deepseek-ai/dsh-device-interconnect/host/desktop-relay
 */

import { randomBytes, timingSafeEqual } from 'node:crypto'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { mkdir, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'

/** Descriptor file name inside the bundle data directory. */
export const RELAY_FILE_NAME = 'relay.json'

/** Request header carrying the relay token. */
export const RELAY_HEADER = 'x-dsh-desktop-relay'

/** Largest accepted JSON body, in bytes; a text send plus metadata fits easily. */
export const MAXIMUM_RELAY_BODY_BYTES = 64 * 1024

/** Largest accepted session text, in characters. */
export const MAXIMUM_RELAY_TEXT_LENGTH = 32_768

/** One relay session status. */
export interface DesktopRelaySessionStatus {
  /** Coarse execution state of one desktop session. */
  readonly status: 'running' | 'waiting' | 'queued' | 'idle' | 'unknown'
  /** Currently running tool name when the desktop services expose one. */
  readonly toolName?: string
  /** Queued messages in the agent inbox. */
  readonly queued?: number
}

/** Request body of `POST /relay/session/send`. */
export interface DesktopRelaySendRequest {
  /** Session the phone is writing to. */
  readonly sessionId: string
  /** App request id used for dedupe/route confirmation. */
  readonly requestId?: string
  /** Message text. */
  readonly text: string
  /** Optional model route selected by the App. */
  readonly provider?: string
  /** Optional model name selected by the App. */
  readonly model?: string
  /** Whether the App explicitly asked to switch to provider/model first. */
  readonly selectModel?: boolean
  /** Attachment ids; the first relay phase rejects any non-empty list. */
  readonly attachmentIds?: readonly string[]
}

/** Desktop-side work the relay can perform. */
export interface DesktopRelayExecutor {
  /**
   * Send one text message into a desktop-owned session.
   * @param request - validated send request.
   * @returns the same result shape as the facade `session.send`.
   */
  send(request: DesktopRelaySendRequest): Promise<unknown>

  /**
   * Read one session's coarse status.
   * @param sessionId - session id.
   * @returns status facts; unknown when the desktop cannot tell.
   */
  status(sessionId: string): Promise<DesktopRelaySessionStatus>

  /**
   * Read every desktop session's coarse status.
   * @returns session id to status map.
   */
  sessions(): Promise<Readonly<Record<string, DesktopRelaySessionStatus>>>
}

/** A structured relay failure returned as JSON, never thrown to the HTTP layer. */
export class DesktopRelayError extends Error {
  /** Stable code shown to the child/App mapping. */
  readonly code: string

  /**
   * @param code - stable failure code.
   * @param message - readable reason.
   */
  constructor(code: string, message: string) {
    super(message)
    this.name = 'DesktopRelayError'
    this.code = code
  }
}

/** Relay availability as the Settings page shows it. */
export interface DesktopRelayStatus {
  /** Whether the loopback server is listening. */
  readonly available: boolean
  /** Loopback base URL; absent when unavailable. */
  readonly url?: string
  /** Readable failure reason; absent when available. */
  readonly error?: string
}

/** Options of one relay server. */
export interface DesktopRelayOptions {
  /** Bundle data directory holding the descriptor file. */
  readonly dataDir: string
  /** Desktop-side executor. */
  readonly executor: DesktopRelayExecutor
  /** Lifecycle log sink. */
  readonly logger: {
    info(message: string, ...rest: unknown[]): void
    warn(message: string, ...rest: unknown[]): void
  }
  /** Clock used in the descriptor; defaults to `Date.now`. */
  readonly now?: () => number
}

/** One JSON response. */
interface RelayResponse {
  readonly status: number
  readonly body: unknown
}

/** Relay server: starts lazily, stops idempotently, deletes the descriptor. */
export class DesktopRelay {
  private readonly options: DesktopRelayOptions
  private readonly token = randomBytes(32).toString('hex')
  private server: Server | undefined
  private url: string | undefined
  private error: string | undefined
  private stopped = false

  /** @param options - data directory, executor, and logging. */
  constructor(options: DesktopRelayOptions) {
    this.options = options
  }

  /** Current availability for the bridge state; never exposes the token. */
  status(): DesktopRelayStatus {
    return {
      available: this.server !== undefined && this.url !== undefined,
      ...(this.url === undefined ? {} : { url: this.url }),
      ...(this.error === undefined ? {} : { error: this.error }),
    }
  }

  /**
   * Start the loopback server and write the descriptor. A failure is recorded
   * and returned, never thrown into plugin activation.
   * @returns the status after the attempt.
   */
  async start(): Promise<DesktopRelayStatus> {
    if (this.server !== undefined) return this.status()
    try {
      const server = createServer((request, response) => {
        void this.handle(request, response)
      })
      this.server = server
      await new Promise<void>((resolve, reject) => {
        server.once('error', reject)
        server.listen(0, '127.0.0.1', () => {
          server.off('error', reject)
          resolve()
        })
      })
      const address = server.address()
      if (address === null || typeof address === 'string') throw new Error('relay did not expose a TCP port')
      this.url = `http://127.0.0.1:${String(address.port)}`
      await this.writeDescriptor()
      this.error = undefined
      this.options.logger.info('device-interconnect: desktop relay listening on %s', this.url)
    } catch (error) {
      this.error = error instanceof Error ? error.message : String(error)
      this.options.logger.warn('device-interconnect: desktop relay unavailable: %s', this.error)
      await this.stop()
    }
    return this.status()
  }

  /** Stop the server and delete the descriptor. Idempotent. */
  async stop(): Promise<void> {
    if (this.stopped && this.server === undefined) return
    this.stopped = true
    const server = this.server
    this.server = undefined
    this.url = undefined
    if (server !== undefined) {
      await new Promise<void>((resolve) => { server.close(() => resolve()) })
    }
    try {
      await rm(this.descriptorPath(), { force: true })
    } catch {
      // A descriptor that cannot be removed only means the child fails closed.
    }
  }

  /** Absolute descriptor path inside the bundle data directory. */
  descriptorPath(): string {
    return join(this.options.dataDir, RELAY_FILE_NAME)
  }

  /** Write the descriptor atomically; the child reads it on demand. */
  private async writeDescriptor(): Promise<void> {
    const file = this.descriptorPath()
    await mkdir(dirname(file), { recursive: true })
    const temporary = `${file}.${String(process.pid)}.tmp`
    const document = JSON.stringify({
      url: this.url,
      token: this.token,
      pid: process.pid,
      createdAt: (this.options.now ?? Date.now)(),
    })
    try {
      await writeFile(temporary, document, { encoding: 'utf8', mode: 0o600 })
      await rename(temporary, file)
    } catch (error) {
      await rm(temporary, { force: true })
      throw error
    }
  }

  /** Route one request through authentication, size limits, and the executor. */
  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      if (!isLoopback(request.socket.remoteAddress)) {
        this.write(response, 403, { ok: false, error: { code: 'relay/forbidden', message: '只接受本机回环请求。' } })
        return
      }
      if (!this.tokenMatches(request.headers[RELAY_HEADER])) {
        this.write(response, 403, { ok: false, error: { code: 'relay/unauthorized', message: '桌面中继令牌无效。' } })
        return
      }
      const url = new URL(request.url ?? '/', 'http://127.0.0.1')
      const result = await this.route(request, url)
      this.write(response, result.status, result.body)
    } catch (error) {
      this.options.logger.warn('device-interconnect: desktop relay handler failed: %s', error instanceof Error ? error.message : String(error))
      this.write(response, 500, { ok: false, error: { code: 'relay/internal', message: '桌面中继处理失败。' } })
    }
  }

  /** Dispatch one authenticated request. */
  private async route(request: IncomingMessage, url: URL): Promise<RelayResponse> {
    if (request.method === 'GET' && url.pathname === '/relay/health') {
      return { status: 200, body: { ok: true } }
    }
    if (request.method === 'POST' && url.pathname === '/relay/session/send') {
      const body = await this.readJson(request)
      if (body === undefined) return relayError('relay/bad-request', '请求体必须是合法 JSON 对象。', 400)
      const parsed = parseSendRequest(body)
      if ('error' in parsed) return relayError(parsed.error.code, parsed.error.message, 400)
      try {
        const result = await this.options.executor.send(parsed.value)
        return { status: 200, body: { ok: true, result } }
      } catch (error) {
        return relayError(
          error instanceof DesktopRelayError ? error.code : 'relay/internal',
          error instanceof Error ? error.message : '桌面发送失败。',
          500,
        )
      }
    }
    if (request.method === 'GET' && url.pathname === '/relay/session/status') {
      const sessionId = url.searchParams.get('sessionId') ?? ''
      if (sessionId === '' || sessionId.length > 512) {
        return relayError('relay/bad-request', 'sessionId 缺失或过长。', 400)
      }
      try {
        return { status: 200, body: { ok: true, ...(await this.options.executor.status(sessionId)) } }
      } catch {
        return { status: 200, body: { ok: true, status: 'unknown' } }
      }
    }
    if (request.method === 'GET' && url.pathname === '/relay/sessions/status') {
      try {
        return { status: 200, body: { ok: true, sessions: await this.options.executor.sessions() } }
      } catch {
        return { status: 200, body: { ok: true, sessions: {} } }
      }
    }
    return relayError('relay/not-found', '未知的桌面中继端点。', 404)
  }

  /** Read a bounded JSON object body. */
  private async readJson(request: IncomingMessage): Promise<Record<string, unknown> | undefined> {
    const chunks: Buffer[] = []
    let size = 0
    for await (const chunk of request) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
      size += buffer.length
      if (size > MAXIMUM_RELAY_BODY_BYTES) return undefined
      chunks.push(buffer)
    }
    if (chunks.length === 0) return undefined
    try {
      const value = JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown
      return isRecord(value) ? value : undefined
    } catch {
      return undefined
    }
  }

  /** Constant-time token comparison (length differences are rejected first). */
  private tokenMatches(header: string | string[] | undefined): boolean {
    const value = Array.isArray(header) ? header[0] : header
    if (value === undefined) return false
    const expected = Buffer.from(this.token, 'utf8')
    const actual = Buffer.from(value, 'utf8')
    return actual.length === expected.length && timingSafeEqual(actual, expected)
  }

  /** Write one JSON response. */
  private write(response: ServerResponse, status: number, body: unknown): void {
    if (response.headersSent) return
    response.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    })
    response.end(JSON.stringify(body))
  }
}

/** Parse `POST /relay/session/send`; attachment sends are explicitly rejected. */
export function parseSendRequest(body: Record<string, unknown>):
  | { readonly value: DesktopRelaySendRequest }
  | { readonly error: { readonly code: string; readonly message: string } } {
  const sessionId = body['sessionId']
  const text = body['text']
  if (typeof sessionId !== 'string' || sessionId.trim() === '' || sessionId.length > 512) {
    return { error: { code: 'relay/bad-request', message: 'sessionId 必须是非空字符串。' } }
  }
  if (typeof text !== 'string' || text.trim() === '') {
    return { error: { code: 'relay/bad-request', message: 'text 必须是非空字符串。' } }
  }
  if (text.length > MAXIMUM_RELAY_TEXT_LENGTH) {
    return { error: { code: 'relay/too-large', message: '消息过长，桌面中继上限为 32 KiB。' } }
  }
  const attachments = body['attachmentIds']
  if (attachments !== undefined && (!Array.isArray(attachments) || attachments.length > 0)) {
    return { error: { code: 'relay/attachments-unsupported', message: '内嵌中继暂不支持附件，请在电脑上直接发送带附件的消息。' } }
  }
  const optional = (key: string): string | undefined => {
    const value = body[key]
    return typeof value === 'string' && value !== '' ? value : undefined
  }
  const requestId = optional('requestId')
  const provider = optional('provider')
  const model = optional('model')
  return {
    value: {
      sessionId,
      text,
      ...(requestId === undefined ? {} : { requestId }),
      ...(provider === undefined ? {} : { provider }),
      ...(model === undefined ? {} : { model }),
      ...(body['selectModel'] === true ? { selectModel: true } : {}),
    },
  }
}

/** Build a JSON relay error response. */
function relayError(code: string, message: string, status: number): RelayResponse {
  return { status, body: { ok: false, error: { code, message } } }
}

/** Only 127.0.0.1/::1 shapes count as loopback peers. */
export function isLoopback(address: string | undefined): boolean {
  if (address === undefined) return false
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
}

/** Record guard for wire values. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Build the production executor from the desktop services the plugin can read
 * with `ctx.get`. Missing services disable the affected operation; the rest of
 * the plugin keeps loading.
 * @param ctx - plugin context in the desktop Host process.
 * @returns the executor used by {@link DesktopRelay}.
 */
export function createDesktopRelayExecutor(ctx: Context): DesktopRelayExecutor {
  const get = <T>(name: string): T | undefined => {
    try {
      return ctx.get(name, false) as T | undefined
    } catch {
      return undefined
    }
  }
  interface PeerFactory {
    createPeer(input: { readonly principal: { readonly kind: 'owner' }; readonly interactions: 'none' }): unknown
  }
  interface Gateway {
    invoke(input: {
      readonly namespace: string
      readonly method: string
      readonly args: Record<string, unknown>
      readonly peer: unknown
      readonly signal?: AbortSignal
    }): Promise<unknown>
  }
  interface AgentRow {
    readonly id: unknown
    readonly status?: string
    readonly inbox?: { readonly nextTurn?: readonly unknown[]; readonly nextStep?: readonly unknown[] }
  }
  interface AgentList {
    list(): readonly AgentRow[]
    get(id: unknown): AgentRow | undefined
  }
  let peer: unknown
  const invoke = (namespace: string, method: string, request: Record<string, unknown>): Promise<unknown> => {
    const gateway = get<Gateway>('typertGateway')
    if (gateway === undefined) throw new DesktopRelayError('relay/service-unavailable', '桌面 DSH 的 typertGateway 服务不可用。')
    const connection = get<PeerFactory>('connection')
    if (connection === undefined) throw new DesktopRelayError('relay/service-unavailable', '桌面 DSH 的 connection 服务不可用。')
    peer ??= connection.createPeer({ principal: { kind: 'owner' }, interactions: 'none' })
    return gateway.invoke({ namespace, method, args: { request }, peer })
  }
  const agents = (): AgentList | undefined => get<AgentList>('agents')
  const statusOf = (agent: AgentRow | undefined): DesktopRelaySessionStatus => {
    if (agent === undefined) return { status: 'unknown' }
    const nextTurn = agent.inbox?.nextTurn?.length ?? 0
    const nextStep = agent.inbox?.nextStep?.length ?? 0
    if (agent.status === 'running') return { status: 'running', ...(nextTurn + nextStep > 0 ? { queued: nextTurn + nextStep } : {}) }
    if (nextTurn + nextStep > 0) return { status: 'queued', queued: nextTurn + nextStep }
    if (agent.status === 'idle') return { status: 'idle' }
    return { status: 'unknown' }
  }
  return {
    async send(request) {
      if (request.selectModel === true && request.provider !== undefined && request.model !== undefined) {
        await invoke('session', 'selectModel', {
          sessionId: request.sessionId,
          provider: request.provider,
          model: request.model,
        })
      }
      return invoke('session', 'prompt', {
        sessionId: request.sessionId,
        ...(request.requestId === undefined ? {} : { requestId: request.requestId }),
        mode: 'queue',
        content: [{ type: 'text', text: request.text }],
      })
    },
    async status(sessionId) {
      return statusOf(agents()?.get(sessionId))
    },
    async sessions() {
      const list = agents()?.list() ?? []
      const result: Record<string, DesktopRelaySessionStatus> = {}
      for (const agent of list) {
        const id = typeof agent.id === 'string' ? agent.id : String(agent.id)
        result[id] = statusOf(agent)
      }
      return result
    },
  }
}
