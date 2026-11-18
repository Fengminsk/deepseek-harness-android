/**
 * The Settings page's HTTP surface inside the running DSH Host.
 *
 * Threat model: the page is served same-origin by this Host, and every route
 * here is a local control surface — it can start and stop a process and reveal
 * a pairing token. The bridge therefore accepts only loopback `Host` heads, an
 * absent or same-origin `Origin`, and a custom header for every read and write;
 * it answers no CORS header. A cross-site page cannot read a response, and a
 * cross-site request that sets the custom header needs a preflight this server
 * never approves. The one exception is the QR image, which an `<img>` element
 * loads without custom headers; it carries no secret beyond the pairing link
 * the page itself already displays. The SakuraFrp access key is write-only: no
 * route here returns it.
 * @module @deepseek-ai/dsh-device-interconnect/host/routes
 */

import type { IncomingMessage, ServerResponse } from 'node:http'
import {
  API_PREFIX, BRIDGE_HEADER, BRIDGE_HEADER_VALUE, CONFIG_ROUTE, DELETE_ROUTE, ENABLED_ROUTE, LOGS_ROUTE,
  PAIR_ROUTE, PROVISION_ROUTE, QR_ROUTE, REVOKE_ROUTE, STATE_ROUTE, TUNNEL_LOGS_ROUTE, TUNNEL_ROUTE,
} from '../api.ts'
import type { ErrorBody, RuntimeState } from '../types.ts'
import { ConfigValidationError } from './config.ts'
import { ControlPlaneError } from './control-plane.ts'
import { TunnelError } from './tunnel.ts'

/** Largest accepted JSON request body; the complete configuration fits far below it. */
export const MAXIMUM_BODY_BYTES = 64 * 1_024

/** The bridge actions the HTTP surface calls; {@link Bridge} is the production implementation. */
export interface BridgeApi {
  /** @returns the current runtime snapshot. */
  state(): Promise<RuntimeState>
  /** Switch the supervised child on or off. */
  setEnabled(enabled: unknown): Promise<RuntimeState>
  /** Start or stop the managed NAT-traversal tunnel. */
  setTunnelEnabled(enabled: unknown): Promise<RuntimeState>
  /** Validate the access key and create or reuse the SakuraFrp tunnel. */
  provisionTunnel(candidate: unknown): Promise<RuntimeState>
  /** Validate and persist one configuration. */
  saveConfig(candidate: unknown): Promise<RuntimeState>
  /** Reopen the pairing window. */
  pair(): Promise<RuntimeState>
  /** Revoke one paired device. */
  revoke(deviceId: unknown): Promise<RuntimeState>
  /** Permanently delete one paired device record. */
  deleteDevice(deviceId: unknown): Promise<RuntimeState>
  /** @returns the child's output tail. */
  logs(): string
  /** @returns the tunnel child's output tail. */
  tunnelLogs(): string
  /** @returns the proxied QR SVG. */
  qrSvg(): Promise<string>
}

/** Log sink for rejected requests and internal failures. */
export interface RouteLogger {
  /** A request the guard rejected or a handler that failed. */
  warn(message: string, ...rest: unknown[]): void
  /** An unexpected failure. */
  error(message: string, ...rest: unknown[]): void
}

/** A request body that could not be read. */
class BodyError extends Error {
  /** HTTP status the bridge answers with. */
  readonly status: number
  /** Stable machine-readable code. */
  readonly code: string

  /**
   * @param status - response status.
   * @param code - machine-readable code.
   * @param message - Chinese message.
   */
  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'BodyError'
    this.status = status
    this.code = code
  }
}

/**
 * Build the handler the Host web server registers under {@link API_PREFIX}.
 * @param bridge - the composed bridge.
 * @param logger - log sink for rejections and failures.
 * @returns the Node HTTP handler.
 */
export function createApiHandler(
  bridge: BridgeApi,
  logger: RouteLogger = console,
): (request: IncomingMessage, response: ServerResponse) => Promise<void> {
  return async (request, response) => {
    try {
      await route(bridge, logger, request, response)
    } catch (error) {
      if (response.headersSent) {
        logger.error('device-interconnect: bridge request failed after headers were sent: %s', describeError(error))
        response.destroy()
        return
      }
      const classified = classifyBridgeError(error)
      if (classified !== undefined) {
        sendJson(response, classified.status, classified.body)
        return
      }
      logger.error('device-interconnect: bridge request failed: %s', describeError(error))
      sendJson(response, 500, { error: { code: 'internal', message: '设备互联处理请求失败，详情见宿主日志。' } })
    }
  }
}

/** Dispatch one request after the guard checks. */
async function route(
  bridge: BridgeApi,
  logger: RouteLogger,
  request: IncomingMessage,
  response: ServerResponse,
): Promise<void> {
  const method = request.method ?? ''
  const pathname = pathnameOf(request.url)
  if (pathname === undefined || (pathname !== API_PREFIX && !pathname.startsWith(`${API_PREFIX}/`))) {
    sendJson(response, 404, { error: { code: 'not-found', message: '没有这个设备互联接口。' } })
    return
  }
  if (!isLoopbackHostHeader(request.headers.host)) {
    logger.warn('device-interconnect: rejected non-loopback Host header %s', String(request.headers.host))
    sendJson(response, 403, { error: { code: 'host-not-allowed', message: '只接受本机回环地址的请求。' } })
    return
  }
  if (!isSameOrigin(request.headers.origin, request.headers.host)) {
    logger.warn('device-interconnect: rejected cross-origin request from %s', String(request.headers.origin))
    sendJson(response, 403, { error: { code: 'origin-not-allowed', message: '不允许跨站访问设备互联接口。' } })
    return
  }
  if (pathname === QR_ROUTE) {
    await answerQr(bridge, request, response)
    return
  }
  if (!hasBridgeHeader(request)) {
    logger.warn('device-interconnect: rejected request without the bridge header: %s %s', method, pathname)
    sendJson(response, 403, { error: { code: 'header-required', message: '缺少设备互联请求标记，请求已被拒绝。' } })
    return
  }
  switch (pathname) {
    case STATE_ROUTE:
      if (!requireMethod(method, 'GET', response)) return
      sendJson(response, 200, await bridge.state())
      return
    case LOGS_ROUTE:
      if (!requireMethod(method, 'GET', response)) return
      sendJson(response, 200, { logsTail: bridge.logs() })
      return
    case TUNNEL_LOGS_ROUTE:
      if (!requireMethod(method, 'GET', response)) return
      sendJson(response, 200, { logsTail: bridge.tunnelLogs() })
      return
    case ENABLED_ROUTE: {
      if (!requireMethod(method, 'POST', response)) return
      const body = await readJsonBody(request, response)
      if (body === undefined) return
      if (typeof body !== 'object' || body === null || Array.isArray(body)) {
        sendJson(response, 400, { error: { code: 'invalid-body', message: '请求体必须是一个 JSON 对象。' } })
        return
      }
      sendJson(response, 200, await bridge.setEnabled((body as { readonly enabled?: unknown }).enabled))
      return
    }
    case TUNNEL_ROUTE: {
      if (!requireMethod(method, 'POST', response)) return
      const body = await readJsonBody(request, response)
      if (body === undefined) return
      if (typeof body !== 'object' || body === null || Array.isArray(body)) {
        sendJson(response, 400, { error: { code: 'invalid-body', message: '请求体必须是一个 JSON 对象。' } })
        return
      }
      sendJson(response, 200, await bridge.setTunnelEnabled((body as { readonly enabled?: unknown }).enabled))
      return
    }
    case PROVISION_ROUTE: {
      if (!requireMethod(method, 'POST', response)) return
      const body = await readJsonBody(request, response)
      if (body === undefined) return
      sendJson(response, 200, await bridge.provisionTunnel(body))
      return
    }
    case CONFIG_ROUTE: {
      if (!requireMethod(method, 'POST', response)) return
      const body = await readJsonBody(request, response)
      if (body === undefined) return
      const candidate = typeof body === 'object' && body !== null && !Array.isArray(body)
        ? (body as { readonly config?: unknown }).config
        : undefined
      sendJson(response, 200, await bridge.saveConfig(candidate))
      return
    }
    case PAIR_ROUTE:
      if (!requireMethod(method, 'POST', response)) return
      drain(request)
      sendJson(response, 200, await bridge.pair())
      return
    case REVOKE_ROUTE: {
      if (!requireMethod(method, 'POST', response)) return
      const body = await readJsonBody(request, response)
      if (body === undefined) return
      const deviceId = typeof body === 'object' && body !== null && !Array.isArray(body)
        ? (body as { readonly deviceId?: unknown }).deviceId
        : undefined
      sendJson(response, 200, await bridge.revoke(deviceId))
      return
    }
    case DELETE_ROUTE: {
      if (!requireMethod(method, 'POST', response)) return
      const body = await readJsonBody(request, response)
      if (body === undefined) return
      const deviceId = typeof body === 'object' && body !== null && !Array.isArray(body)
        ? (body as { readonly deviceId?: unknown }).deviceId
        : undefined
      sendJson(response, 200, await bridge.deleteDevice(deviceId))
      return
    }
    default:
      sendJson(response, 404, { error: { code: 'not-found', message: '没有这个设备互联接口。' } })
  }
}

/** Answer the proxied QR SVG, or a status that renders a missing image. */
async function answerQr(bridge: BridgeApi, request: IncomingMessage, response: ServerResponse): Promise<void> {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    requireMethod(request.method ?? '', 'GET', response)
    return
  }
  try {
    const svg = await bridge.qrSvg()
    send(response, 200, 'image/svg+xml; charset=utf-8', svg)
  } catch (error) {
    const status = error instanceof ControlPlaneError && error.code === 'qr-unavailable' ? 404 : 502
    send(response, status, 'text/plain; charset=utf-8', describeError(error))
  }
}

/** Answer 405 with the allowed method for this route. */
function requireMethod(method: string, allowed: 'GET' | 'POST', response: ServerResponse): boolean {
  if (method === allowed) return true
  sendJson(response, 405, { error: { code: 'method-not-allowed', message: `只允许 ${allowed}。` } }, { Allow: allowed })
  return false
}

/** Read one JSON body under the size and content-type rules. */
async function readJsonBody(request: IncomingMessage, response: ServerResponse): Promise<unknown | undefined> {
  if (!isJsonContentType(request.headers['content-type'])) {
    sendJson(response, 415, { error: { code: 'content-type-required', message: '只接受 application/json 请求体。' } })
    return undefined
  }
  try {
    const text = await readBody(request)
    if (text === '') return undefined
    return JSON.parse(text)
  } catch (error) {
    if (error instanceof BodyError) {
      sendJson(response, error.status, { error: { code: error.code, message: error.message } })
      return undefined
    }
    if (error instanceof SyntaxError) {
      sendJson(response, 400, { error: { code: 'invalid-json', message: '请求体不是合法 JSON。' } })
      return undefined
    }
    throw error
  }
}

/** Read a request body up to {@link MAXIMUM_BODY_BYTES}. */
function readBody(request: IncomingMessage): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    request.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > MAXIMUM_BODY_BYTES) {
        reject(new BodyError(413, 'body-too-large', `请求体超过 ${String(MAXIMUM_BODY_BYTES)} 字节上限。`))
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => { resolve(Buffer.concat(chunks).toString('utf8')) })
    request.on('error', (error) => { reject(new BodyError(400, 'body-read-failed', `读取请求体失败：${error.message}`)) })
  })
}

/** Consume and discard a request body a route does not read. */
function drain(request: IncomingMessage): void {
  request.resume()
}

/** Write one JSON response with the bridge's fixed headers and no CORS header. */
function sendJson(
  response: ServerResponse,
  status: number,
  value: unknown,
  extra: Readonly<Record<string, string>> = {},
): void {
  send(response, status, 'application/json; charset=utf-8', JSON.stringify(value), extra)
}

/** Write one response with the bridge's fixed headers and no CORS header. */
function send(
  response: ServerResponse,
  status: number,
  contentType: string,
  body: string,
  extra: Readonly<Record<string, string>> = {},
): void {
  if (response.headersSent) return
  const payload = Buffer.from(body, 'utf8')
  response.writeHead(status, {
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Type': contentType,
    'Content-Length': String(payload.length),
    ...extra,
  })
  response.end(payload)
}

/**
 * Whether a `Host` head names a loopback endpoint. DNS rebinding attacks carry
 * an attacker-controlled host name, which this rejects before any handler runs.
 * @param header - the request's `Host` head.
 * @returns true for `127.0.0.1`, `localhost`, or `[::1]`, with any port.
 */
export function isLoopbackHostHeader(header: string | undefined): boolean {
  if (header === undefined) return false
  const value = header.trim().toLowerCase()
  return /^(?:127\.0\.0\.1|localhost|\[::1\])(?::\d{1,5})?$/u.test(value)
}

/**
 * Whether an `Origin` head is same-origin with the `Host` head. An absent
 * `Origin` is a non-browser request (the page's own fetch always sends one).
 * @param origin - the request's `Origin` head.
 * @param host - the request's `Host` head.
 * @returns true when the request is same-origin or carries no origin.
 */
export function isSameOrigin(origin: string | undefined, host: string | undefined): boolean {
  if (origin === undefined) return true
  if (host === undefined) return false
  let parsed: URL
  try {
    parsed = new URL(origin)
  } catch (error) {
    // An unparsable Origin is a request this bridge refuses.
    if (error instanceof TypeError) return false
    throw error
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false
  return isLoopbackHostHeader(parsed.host) && parsed.host.toLowerCase() === host.trim().toLowerCase()
}

/**
 * Whether a request carries the bridge's custom header.
 * @param request - the request's header container.
 * @returns true when the header is exactly the accepted value.
 */
export function hasBridgeHeader(request: { readonly headers: NodeJS.Dict<string | string[]> }): boolean {
  const value = request.headers[BRIDGE_HEADER]
  return typeof value === 'string' && value === BRIDGE_HEADER_VALUE
}

/** Parse a request target's pathname. */
function pathnameOf(target: string | undefined): string | undefined {
  try {
    return new URL(target ?? '/', 'http://127.0.0.1').pathname
  } catch (error) {
    // A malformed request target is refused as not-found.
    if (error instanceof TypeError) return undefined
    throw error
  }
}

/** Whether one header value is a JSON content type. */
function isJsonContentType(value: string | undefined): boolean {
  if (value === undefined) return false
  const [mediaType] = value.split(';')
  return mediaType?.trim().toLowerCase() === 'application/json'
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Map a bridge failure onto the HTTP status and JSON error body it answers.
 * @param error - a failure thrown by one bridge action.
 * @returns the status and body, or undefined for an unexpected failure.
 */
export function classifyBridgeError(error: unknown): { readonly status: number; readonly body: ErrorBody } | undefined {
  if (error instanceof ConfigValidationError) {
    return { status: 400, body: { error: { code: 'invalid-config', message: error.problems.join('；') } } }
  }
  if (error instanceof TunnelError) {
    return { status: error.status, body: { error: { code: error.code, message: error.message } } }
  }
  if (error instanceof ControlPlaneError) {
    const reported = error.status
    const status = reported !== undefined && reported >= 400 && reported < 500 ? reported : 502
    return { status, body: { error: { code: error.code, message: error.message } } }
  }
  return undefined
}
