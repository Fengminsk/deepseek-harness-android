/**
 * 远程 DSH 的 PC 宿主网络层：`wss://<host>:<port>/app` 的升级准入、连接对象、握手门禁，
 * 以及 WebSocket 与 Node 流之间的最小适配器。
 *
 * 一条已接受升级的连接恰好持有一条 `JsonRpcLineTransport`：入站帧由它解析并分派，出站帧由它按单行 JSON-RPC 2.0 写出。
 * 本模块只负责传输、升级准入、握手、心跳、关闭，以及配对用的 HTTP 端点，不解释任何业务方法名；
 * 业务方法由 {@link RemoteConnection.onRequest} 安装的处理器应答。
 *
 * 与协议文档（`apps/android/docs/remote-dsh/protocol.md`）的对应关系：
 * - §1.1 端点：只接受 `/app`，其它路径、带查询串或片段的升级请求一律 404；
 * - §1.5 保活：每 20 s 发一次 ws Ping，连续两个周期没有任何活动即关闭 `1001`；
 * - §2.1/§2.2 鉴权：`Origin` 精确匹配否则 403，`Authorization` 形态不符合则 401，令牌内容校验放在升级之后，
 *   好让手机拿到 `4000` / `4001` 关闭码与 `-32001` / `-32002` 错误帧里的可展示原因；
 * - §2 配对：`GET /ca.cer` 回 CA 证书，`POST /pair` 用一次性令牌换设备令牌；
 * - §3.1–§3.3 握手：连接先进入 `awaiting-hello`，首帧必须是 `protocol.hello`，否则以 `4002` 关闭；
 * - §8.4 撤销：先落盘删除，再向该设备已 `ready` 的连接推 `remote.deviceRevoked`，最后以 `4001` 关闭。
 *
 * @module @deepseek-ai/dsh-remote-host/server
 */

import { randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { createServer, type Server as HttpsServer } from 'node:https'
import type { Duplex } from 'node:stream'
import { Readable, Transform, Writable } from 'node:stream'
import { StringDecoder } from 'node:string_decoder'
import type { TLSSocket } from 'node:tls'
import { JsonRpcLineTransport } from '@deepseek-ai/dsh-sdk-protocol'
import WebSocket, { WebSocketServer, type RawData } from 'ws'

/** 协议唯一允许的 WebSocket 路径（协议 §1.1）。 */
export const REMOTE_APP_PATH = '/app'

/** 配对用的 CA 证书端点（协议 §2 的配对流程第二步）。 */
export const REMOTE_CA_PATH = '/ca.cer'

/** 配对用的令牌兑换端点（协议 §2 的配对流程第三步）。 */
export const REMOTE_PAIR_PATH = '/pair'

/** 升级请求必须逐字节匹配的 `Origin`（协议 §2.1）。 */
export const REMOTE_ORIGIN = 'https://pocket-harness.local'

/** 本模块实现的协议版本（协议 §3.3：v1 恒为 1）。 */
export const REMOTE_PROTOCOL_VERSION = 1

/** 握手专用方法名（协议 §3.1）。 */
export const REMOTE_HELLO_METHOD = 'protocol.hello'

/** 单条上行帧上限：1 MiB（协议 §1.3）。超过上限的帧由 ws 直接以 1009 关闭连接。 */
const MAX_CLIENT_FRAME_BYTES = 1024 * 1024

/** ws Ping 间隔，同时也是「一个心跳周期」（协议 §1.5，App 侧同为 20 s）。 */
const HEARTBEAT_INTERVAL_MS = 20_000

/** 连续两个心跳周期没有任何活动即判定连接已死（协议 §1.5）。 */
const MAX_MISSED_HEARTBEATS = 2

/** 升级完成后等待 `protocol.hello` 的上限（协议 §3.3：10 s）。 */
const DEFAULT_HANDSHAKE_TIMEOUT_MS = 10_000

/** 关闭帧发出后等待对端完成关闭握手的宽限；超时直接断开，避免连接对象悬挂。 */
const CLOSE_GRACE_MS = 5_000

/** `Authorization` 头的严格形态：`Bearer ` + 43 字符 base64url（协议 §2.1）。 */
const DEVICE_TOKEN_PATTERN = /^Bearer ([A-Za-z0-9_-]{43})$/

/** 配对令牌的线上形态：43 字符 base64url（`./pairing.ts`）。 */
const PAIRING_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u

/** `/pair` 请求体上限；与 App 侧 `remotePairingMaxResponseBytes` 同为 64 KiB。 */
const MAX_PAIR_REQUEST_BYTES = 64 * 1024

/** 设备显示名上限，与协议 §3.1 的 `deviceLabel` 一致。 */
const DEVICE_LABEL_MAX_LENGTH = 120

/** App 构建号上限（协议 §3.1 只要求是字符串；这里与 App 侧校验一致）。 */
const APP_VERSION_MAX_LENGTH = 64

/** WebSocket 关闭原因的字节上限（WS 规范：123 字节）。 */
const MAX_CLOSE_REASON_BYTES = 123

/** 认证失败时给手机看的中文句子（协议 §9.4 的标准文案）。 */
const AUTH_FAILED_MESSAGE = '连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。'

/** 设备已撤销时给手机看的中文句子（协议 §9.4 的标准文案）。 */
const AUTH_REVOKED_MESSAGE = '这台手机已被电脑撤销授权。请在电脑上重新配对。'

/** 握手未完成时的可展示句子（协议 §3.3 的 `handshake-required`）。 */
const HANDSHAKE_REQUIRED_MESSAGE = '连接还没有完成 protocol.hello 握手，电脑不接受这个方法。请重新连接。'

/** 重复握手时的可展示句子（协议 §3.3 的 `duplicate-hello`）。 */
const DUPLICATE_HELLO_MESSAGE = '这条连接已经完成握手，不能再发送 protocol.hello。'

/** 配对接口的 `Content-Type` 校验：`application/json` 及带参数的变体。 */
const JSON_CONTENT_TYPE = /^application\/(?:[a-z0-9.+-]*\+)?json\b/iu

/** 握手门禁在 `ready` 之前只解析真正关心的帧，`ready` 之后也只对含该标记的帧做二次解析。 */
const HELLO_MARKER = `"${REMOTE_HELLO_METHOD}"`

/** 宿主能主动使用的关闭码（协议 §1.4）。 */
export type RemoteCloseCode = 1000 | 1001 | 1002 | 1009 | 4000 | 4001 | 4002 | 4003

/** 一条连接的生命周期状态（协议附录 B）。 */
export type RemoteConnectionState = 'awaiting-hello' | 'ready' | 'closing' | 'closed'

/** 结构化日志级别。 */
export type RemoteLogLevel = 'debug' | 'info' | 'warn' | 'error'

/** 一条结构化日志。`event` 供过滤，`message` 是可以直接展示的中文描述。 */
export interface RemoteLogRecord {
  readonly level: RemoteLogLevel
  readonly event: string
  readonly message: string
  readonly fields?: Readonly<Record<string, unknown>>
}

/** 结构化日志接收器。宿主把日志交给谁由装配方决定，默认写 stderr。 */
export type RemoteLogger = (record: RemoteLogRecord) => void

/** 服务端 TLS 材料，由 `./tls.ts` 的自签 CA 与叶子证书提供。 */
export interface RemoteTlsMaterial {
  readonly certPem: string
  readonly keyPem: string
}

/** 设备令牌校验结果；失败原因决定关闭码是 4000 还是 4001。 */
export type RemoteAuthOutcome =
  | { readonly ok: true; readonly deviceId: string }
  | { readonly ok: false; readonly code: 'auth-failed' | 'auth-revoked' }

/** 设备令牌校验器，由 `./devices.ts` 的设备表实现。 */
export type RemoteAuthenticator = (token: string) => Promise<RemoteAuthOutcome>

/**
 * 宿主本地应答者：协议 §5.2 里「由宿主拦截」的那批 `native.*` 方法。
 *
 * 必须在转发给上层 dispatch 之前询问它，否则手机的 `-32601` 会盖掉 PC 本来能满足的请求（附录 B 约束 3）。
 */
export interface RemoteNativeProvider {
  /**
   * @param method - 入站方法名。
   * @returns 是否由宿主本地就地应答。
   */
  handles(method: string): boolean

  /**
   * @param method - 已由 {@link handles} 命中的方法名。
   * @param params - 帧里的 `params` 对象（省略时为空对象）。
   * @returns 即 JSON-RPC 的 `result`；抛错由传输层转成 `-32603`。
   */
  request(method: string, params: Record<string, unknown>): unknown
}

/** App → 宿主的业务方法处理器。返回值即 JSON-RPC 的 `result`。 */
export type RemoteRequestHandler = (
  method: string,
  params: Record<string, unknown>,
) => unknown

/** App → 宿主的通知处理器。通知没有响应可回，未安装时一律丢弃。 */
export type RemoteNotificationHandler = (method: string, params: Record<string, unknown>) => void

/** 鉴权是异步的，握手后的首帧不能在这段窗口里丢掉，因此先按到达顺序暂存。 */
export interface RemoteIncomingFrame {
  readonly data: RawData
  readonly binary: boolean
}

/** 一条连接对外的关闭结果。 */
export interface RemoteCloseOutcome {
  /** 实际使用的关闭码（协议 §1.4）。 */
  readonly code: RemoteCloseCode
  /** 关闭原因，已按 123 字节上限截断。 */
  readonly reason: string
  /** 是否由对端先发起关闭。 */
  readonly byPeer: boolean
}

/**
 * 握手响应里属于宿主的那一半（协议 §3.2）。
 *
 * `methods` / `unsupported` 必须来自门面的分发表（协议 §10.1：`methods` 是宿主可应答
 * 方法的完整清单，不是增量），`capabilities` 是宿主支持的能力（v1 只有 `window-ack`）。
 */
export interface RemoteHandshake {
  /** 宿主显示名，进入 `host.name`（≤ 120 字符）。 */
  readonly hostName: string
  /** DSH 主目录绝对路径，进入 `host.home`，只用于展示与排障。 */
  readonly hostHome: string
  /** 宿主可应答的方法清单，条目是精确名或 `.*` 结尾的前缀。 */
  readonly methods: readonly string[]
  /** 宿主明确不支持的方法清单；优先级高于 `methods`。 */
  readonly unsupported: readonly string[]
  /** 宿主能力声明；v1 只定义 `window-ack`。 */
  readonly capabilities: readonly string[]
  /** 握手窗口毫秒数；省略时 10 s（协议 §3.3）。 */
  readonly timeoutMs?: number
}

/** 一次 `POST /pair` 的请求内容（字段名即线上字段名）。 */
export interface RemotePairRequest {
  /** 一次性配对令牌（43 字符 base64url）。 */
  readonly token: string
  /** 设备显示名；1–120 个非控制字符。 */
  readonly deviceLabel: string
  /** App 构建号，仅用于排障与记录。 */
  readonly appVersion: string
  /** 对端标识（源地址），用于按对端限速。 */
  readonly peer: string
}

/**
 * 一次 `POST /pair` 的结论。
 *
 * 失败时的 `status` 决定 App 的提示分支：`401` 令牌无效，`403` 配对窗口已关闭或过期，
 * `429` 尝试过于频繁；`400` / `415` / `500` 落在 App 的兜底文案里。
 */
export type RemotePairOutcome =
  | {
    readonly ok: true
    /** 设备 id（32 位小写十六进制）。 */
    readonly deviceId: string
    /** 设备令牌（43 字符 base64url），只在此响应里出现一次。 */
    readonly deviceToken: string
    /** 设备令牌到期时间（Unix 毫秒）。 */
    readonly expiresAt: number
  }
  | {
    readonly ok: false
    /** 要回的 HTTP 状态码。 */
    readonly status: 400 | 401 | 403 | 415 | 429 | 500
    /** 可直接展示的中文说明；不得包含令牌或私钥。 */
    readonly message: string
  }

/** 配对 HTTP 面：`GET /ca.cer` 与 `POST /pair` 的宿主侧实现（协议 §2）。 */
export interface RemotePairingSurface {
  /** CA 证书 DER；`GET /ca.cer` 原样返回，App 用它的 SHA-256 核对 instanceId。 */
  readonly caCertificateDer: Buffer
  /**
   * 用一次性令牌换设备令牌。
   * @param request - 请求体字段与对端标识。
   * @returns 成功时的设备凭证，或带 HTTP 状态码的失败。
   */
  redeem(request: RemotePairRequest): Promise<RemotePairOutcome>
}

/** 撤销设备时用到的设备表表面；只声明本模块用到的两个方法。 */
export interface RemoteDeviceRevoker {
  /**
   * 落盘撤销一台设备。
   * @param deviceId - 设备 id。
   * @returns 本次是否撤销了一台此前有效的设备。
   */
  revoke(deviceId: string): Promise<boolean>

  /** @returns 设备摘要列表；用于取显示名与撤销时间。 */
  list(): readonly { readonly id: string; readonly label: string; readonly revokedAt?: number }[]
}

/** 一次设备撤销的结果。 */
export interface RemoteDeviceRevokeResult {
  /** 设备此前是否有效、本次是否落盘撤销成功。 */
  readonly revoked: boolean
  /** 被关闭的在线连接数。 */
  readonly closed: number
}

/** {@link RemoteConnection} 的构造依赖。 */
export interface RemoteConnectionOptions {
  /** 进程内唯一的连接 id。 */
  readonly id: string
  /** 鉴权阶段确定的设备 id。 */
  readonly deviceId: string
  /** 对端地址，仅用于日志。 */
  readonly remoteAddress: string
  /** 已接受升级的 WebSocket。 */
  readonly socket: WebSocket
  /** `native.*` 的本地应答者。 */
  readonly nativeProvider: RemoteNativeProvider
  /** 握手响应里属于宿主的那一半（协议 §3.2）。 */
  readonly handshake: RemoteHandshake
  /** 结构化日志接收器。 */
  readonly log: RemoteLogger
  /** 鉴权窗口里暂存的入站帧，先于 socket 的后续帧交给传输层。 */
  readonly initialFrames: readonly RemoteIncomingFrame[]
  /** 连接关闭（且资源已释放）后的回调。 */
  readonly onClosed: (connection: RemoteConnection, outcome: RemoteCloseOutcome) => void
}

/** {@link RemoteHostServer} 的构造参数。 */
export interface RemoteHostServerOptions {
  /** 监听端口；0 表示由系统分配。 */
  readonly port: number
  /** 监听地址。 */
  readonly host: string
  /** TLS 材料；本协议只提供 `wss://`，不开明文 ws。 */
  readonly tls: RemoteTlsMaterial
  /** 设备令牌校验器。 */
  readonly authenticate: RemoteAuthenticator
  /** 一条连接通过鉴权后交给装配方：在这里安装 dispatch 处理器。 */
  readonly onConnection: (connection: RemoteConnection) => void
  /** 一条连接关闭并释放资源后的回调，用于记账与日志。 */
  readonly onClose?: (connection: RemoteConnection, outcome: RemoteCloseOutcome) => void
  /** `native.*` 的本地应答者。 */
  readonly nativeProvider: RemoteNativeProvider
  /** 握手响应里属于宿主的那一半（协议 §3.2）。 */
  readonly handshake: RemoteHandshake
  /** 配对 HTTP 面；省略时不提供 `/ca.cer` 与 `/pair`（两个路径回 404）。 */
  readonly pairing?: RemotePairingSurface
  /** 结构化日志接收器；省略时写 stderr。 */
  readonly log?: RemoteLogger
}

/**
 * 把一条日志写到 stderr。宿主进程没有注入 logger 时使用它。
 * @param record - 结构化日志记录。
 * @returns 无返回值。
 */
export function writeRemoteLog(record: RemoteLogRecord): void {
  const fields = record.fields === undefined ? '' : ` ${JSON.stringify(record.fields)}`
  process.stderr.write(`[remote-host] ${record.level} ${record.event}: ${record.message}${fields}\n`)
}

/**
 * 把任意抛出值收敛成一行可记录的描述。
 * @param error - 任意抛出值。
 * @returns `name: message` 形式的一行文本；非 Error 直接字符串化。
 */
export function describeRemoteError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`
  return String(error)
}

/** 连接已经关闭或正在关闭，却还尝试收发。 */
export class RemoteConnectionClosedError extends Error {
  /** @param detail - 具体是哪个动作被拒绝，写进 message 供排障。 */
  constructor(detail: string) {
    super(`远程连接已关闭：${detail}`)
    this.name = 'RemoteConnectionClosedError'
  }
}

/** 入站方法既不是宿主的 `native.*` 拦截项，也没有安装 dispatch 处理器。 */
export class RemoteUnsupportedMethodError extends Error {
  /** 方法名，便于上层按协议 §10.1 生成 `unsupported-method`。 */
  readonly method: string

  /** @param method - 入站方法名。 */
  constructor(method: string) {
    super(`当前连接的电脑不支持「${method}」。`)
    this.name = 'RemoteUnsupportedMethodError'
    this.method = method
  }
}

/** 入站帧违反协议（例如发来二进制帧）。它让连接以 1002 关闭。 */
class RemoteFrameViolation extends Error {
  constructor(detail: string) {
    super(`违反帧格式：${detail}`)
    this.name = 'RemoteFrameViolation'
  }
}

/**
 * 把 ws 的 `RawData` 归一成连续字节。
 * @param data - 文本帧载荷，可能是单片 Buffer、分片数组或 ArrayBuffer。
 * @returns 完整的帧字节。
 */
function frameBytes(data: RawData): Buffer {
  if (Buffer.isBuffer(data)) return data
  if (Array.isArray(data)) return Buffer.concat(data)
  return Buffer.from(data)
}

/**
 * 把关闭原因截断到 WS 允许的 123 字节内，且不切断多字节字符。
 * @param reason - 原始原因文本。
 * @returns 可直接交给 `socket.close()` 的字符串。
 */
function truncateCloseReason(reason: string): string {
  const bytes = Buffer.from(reason, 'utf8')
  if (bytes.byteLength <= MAX_CLOSE_REASON_BYTES) return reason
  return bytes.subarray(0, MAX_CLOSE_REASON_BYTES).toString('utf8').replace(/\uFFFD+$/u, '')
}

/**
 * 把对端关闭码收敛到协议认识的集合，表外一律按 1001（协议 §1.4）。
 * @param code - ws 给的关闭码。
 * @returns 协议内的关闭码。
 */
function peerCloseCode(code: number): RemoteCloseCode {
  switch (code) {
    case 1000:
    case 1001:
    case 1002:
    case 1009:
    case 4000:
    case 4001:
    case 4002:
    case 4003:
      return code
    default:
      return 1001
  }
}

/**
 * 校验升级请求的路径：必须精确等于 `/app`，且不带查询串或片段。
 * @param url - 原始请求行里的 URL。
 * @returns 是否为协议端点。
 */
function isAppEndpoint(url: string): boolean {
  return url === REMOTE_APP_PATH
}

/**
 * 从 `Authorization` 头里取出设备令牌。
 * @param header - 请求头原值；缺失时为 undefined。
 * @returns 43 字符 base64url 令牌；形态不符合时 undefined（不回显原值，协议 §2.2）。
 */
function bearerToken(header: string | undefined): string | undefined {
  if (header === undefined) return undefined
  const matched = DEVICE_TOKEN_PATTERN.exec(header)
  return matched?.[1]
}

/**
 * 在升级之前拒掉一个请求：写一行 HTTP 响应再断开。
 * @param socket - 尚未交给 WebSocket 的原始连接。
 * @param status - HTTP 状态码（404/401/403）。
 * @param reasonPhrase - HTTP 原因短语，用 ASCII，仅作协议用途。
 * @returns 无返回值。
 */
function rejectUpgrade(socket: Duplex, status: number, reasonPhrase: string): void {
  // 拒绝响应写不出去说明对端已经断开，此时无需再做什么；必须挂监听，否则 socket 上的
  // 'error' 事件没有接收者会让进程崩掉。
  socket.once('error', () => {})
  socket.end(`HTTP/1.1 ${status} ${reasonPhrase}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`)
}

/** `/pair` 请求体超过上限。只用于把「太大」与真正的 IO 错误分开。 */
class PairBodyTooLargeError extends Error {
  constructor(limit: number) {
    super(`配对请求体超过 ${limit} 字节上限`)
    this.name = 'PairBodyTooLargeError'
  }
}

/**
 * 读完一个 HTTP 请求体，超过上限立即中止。
 * @param request - 入站请求。
 * @param limit - 允许的最大字节数。
 * @returns UTF-8 文本形式的请求体。
 * @throws {@link PairBodyTooLargeError} 超过上限时；流自身的错误原样抛出。
 */
async function readBoundedBody(request: IncomingMessage, limit: number): Promise<string> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk), 'utf8')
    total += buffer.byteLength
    if (total > limit) throw new PairBodyTooLargeError(limit)
    chunks.push(buffer)
  }
  return Buffer.concat(chunks).toString('utf8')
}

/**
 * 写一条 `/pair` 失败响应：一句话说明，绝不回显请求里的令牌。
 * @param response - 待写的响应。
 * @param status - HTTP 状态码。
 * @param message - 可直接展示的中文说明。
 * @returns 无返回值。
 */
function writePairFailure(response: ServerResponse, status: number, message: string): void {
  if (response.headersSent) return
  const payload = JSON.stringify({ error: message })
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload, 'utf8'),
    'cache-control': 'no-store',
  })
  response.end(payload)
}

/** `/pair` 请求体的解析结果。 */
type ParsedPairBody =
  | { readonly ok: true; readonly token: string; readonly deviceLabel: string; readonly appVersion: string }
  | { readonly ok: false; readonly message: string }

/**
 * 校验 `POST /pair` 的请求体：`{token, deviceLabel, appVersion}`（字段名即线上字段名）。
 *
 * 只做协议层能判定的校验；设备显示名仍交给设备表做最终收敛，这里先挡住明显不合法的输入，
 * 免得白白消耗一次性配对窗口。
 * @param body - 请求体文本。
 * @returns 解析结果；失败时 `message` 是可直接展示的中文说明。
 */
function parsePairRequestBody(body: string): ParsedPairBody {
  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  } catch {
    return { ok: false, message: '配对请求不是合法 JSON。' }
  }
  const record = asRecord(parsed)
  if (record === undefined) return { ok: false, message: '配对请求必须是 JSON 对象。' }
  const token = record.token
  if (typeof token !== 'string' || !PAIRING_TOKEN_PATTERN.test(token)) {
    return { ok: false, message: '配对请求缺少合法的 token（43 字符 base64url）。' }
  }
  const deviceLabel = record.deviceLabel
  if (typeof deviceLabel !== 'string' || deviceLabel.trim().length === 0
    || Array.from(deviceLabel.trim()).length > DEVICE_LABEL_MAX_LENGTH
    || /[\u0000-\u001f\u007f]/u.test(deviceLabel)) {
    return { ok: false, message: `配对请求的设备名必须是 1–${DEVICE_LABEL_MAX_LENGTH} 个非控制字符。` }
  }
  const appVersion = record.appVersion
  if (typeof appVersion !== 'string' || appVersion.trim().length === 0
    || Array.from(appVersion.trim()).length > APP_VERSION_MAX_LENGTH) {
    return { ok: false, message: `配对请求的 appVersion 必须是 1–${APP_VERSION_MAX_LENGTH} 个字符。` }
  }
  return { ok: true, token, deviceLabel: deviceLabel.trim(), appVersion: appVersion.trim() }
}

/**
 * 把 WebSocket 的 `message` / `close` / `error` 事件变成字节流，供 `JsonRpcLineTransport` 读取。
 *
 * 只做搬运：帧内容由传输层解析。二进制帧违反协议 §1.1，直接以错误销毁流，由连接以 1002 关闭。
 */
class WebSocketSource extends Readable {
  private readonly socket: WebSocket

  constructor(socket: WebSocket, initialFrames: readonly RemoteIncomingFrame[]) {
    super()
    this.socket = socket
    for (const frame of initialFrames) this.accept(frame)
    socket.on('message', this.onMessage)
    socket.on('close', this.onClose)
    socket.on('error', this.onSocketError)
  }

  override _read(): void {
    // 数据由 socket 事件推入，没有需要主动拉取的东西。
  }

  override _destroy(error: Error | null, callback: (error: Error | null) => void): void {
    this.socket.off('message', this.onMessage)
    this.socket.off('close', this.onClose)
    this.socket.off('error', this.onSocketError)
    callback(error)
  }

  private accept(frame: RemoteIncomingFrame): void {
    if (frame.binary) {
      this.destroy(new RemoteFrameViolation('远程 DSH 只接受文本帧'))
      return
    }
    this.push(frameBytes(frame.data))
  }

  private readonly onMessage = (data: RawData, binary: boolean): void => {
    this.accept({ data, binary })
  }

  private readonly onClose = (): void => {
    this.push(null)
  }

  private readonly onSocketError = (error: Error): void => {
    this.destroy(error)
  }
}

/**
 * 把 `JsonRpcLineTransport` 写出的字节变成 WebSocket 文本帧。
 *
 * 发送完成回调直接当作写入完成回调，因此下游背压就是 socket 的真实背压。
 */
class WebSocketSink extends Writable {
  private readonly socket: WebSocket

  constructor(socket: WebSocket) {
    super()
    this.socket = socket
  }

  override _write(
    chunk: Buffer,
    _encoding: BufferEncoding,
    callback: (error?: Error | null) => void,
  ): void {
    const text = chunk.toString('utf8')
    // transport.flush() 的空写只用作屏障，不产生任何帧。
    if (text.length === 0) {
      callback()
      return
    }
    if (this.socket.readyState !== WebSocket.OPEN) {
      callback(new RemoteConnectionClosedError('帧未发送'))
      return
    }
    this.socket.send(text, (error?: Error) => {
      callback(error)
    })
  }

  override _destroy(error: Error | null, callback: (error: Error | null) => void): void {
    callback(error)
  }
}

/**
 * 握手门禁的接线：门禁自己写出握手应答与协议错误帧，连接对象只负责关连接。
 */
interface RemoteHandshakeGateOptions {
  /** 握手响应里属于宿主的那一半。 */
  readonly handshake: RemoteHandshake
  /**
   * 写出一帧（已按单行 JSON 编码的字符串）；兑现表示已交给 socket。
   * @param frame - 完整的 JSON-RPC 帧对象。
   * @returns 写入完成即兑现。
   */
  readonly writeFrame: (frame: Record<string, unknown>) => Promise<void>
  /**
   * 握手成功：连接从 `awaiting-hello` 进入 `ready`。
   * @param deviceLabel - 已收敛到 1–120 个非控制字符的设备显示名。
   * @param capabilities - 客户端声明且宿主支持的能力（交集）。
   */
  readonly onHello: (deviceLabel: string, capabilities: string[]) => void
  /**
   * 握手被拒：错误帧已写出，连接必须按协议 §3.3 关闭 `4002`。
   * @param reason - 关闭原因，同时是错误帧里的 `data.detail`。
   */
  readonly onViolation: (reason: string) => void
}

/**
 * 握手门禁：在 `JsonRpcLineTransport` 之前拦住连接上的第一帧（协议 §3.1–§3.3）。
 *
 * - 第一帧必须是 `protocol.hello`，否则回 `-32000 / protocol-mismatch`（`detail` 为
 *   `handshake-required`）并让连接关闭 `4002`；
 * - 同一连接第二次 `protocol.hello` → `detail` 为 `duplicate-hello`，同样关闭 `4002`；
 * - 握手前的通知帧丢弃、不关闭（协议 §3.3）；
 * - 握手成功后所有帧（除重复握手）原样交给传输层，不再二次解析。
 *
 * 门禁必须在传输层之前，因为传输层只能回 `-32603` 且不携带 `data`；而 `-32000` 与
 * `detail` 是 App 区分「版本不匹配 / 未握手 / 重复握手」的唯一依据。
 */
class RemoteHandshakeGate extends Transform {
  private readonly options: RemoteHandshakeGateOptions
  private readonly decoder = new StringDecoder('utf8')
  private buffered = ''
  private state: 'awaiting-hello' | 'ready' | 'closed' = 'awaiting-hello'

  /** @param options - 握手材料与三个回调。 */
  constructor(options: RemoteHandshakeGateOptions) {
    super()
    this.options = options
  }

  /** @returns 门禁是否仍在等首帧。 */
  get awaitingHello(): boolean {
    return this.state === 'awaiting-hello'
  }

  override _transform(
    chunk: Buffer,
    _encoding: BufferEncoding,
    callback: (error?: Error | null) => void,
  ): void {
    const text = this.decoder.write(chunk)
    // 握手之后：除非这一批里可能出现重复握手，否则完全按字节转发，不做任何额外解析。
    if (this.state === 'ready' && !this.buffered.includes(HELLO_MARKER) && !text.includes(HELLO_MARKER)) {
      this.push(Buffer.from(text, 'utf8'))
      callback()
      return
    }
    this.buffered += text
    let forward = ''
    for (;;) {
      const newline = this.buffered.indexOf('\n')
      if (newline < 0) break
      const line = this.buffered.slice(0, newline).trim()
      this.buffered = this.buffered.slice(newline + 1)
      if (line.length === 0) continue
      const decision = this.state === 'ready' ? this.inspectAfterHello(line) : this.inspectBeforeHello(line)
      if (decision === 'deliver') forward += `${line}\n`
      if (this.state === 'closed') {
        this.buffered = ''
        break
      }
    }
    if (this.state === 'ready') {
      // 握手刚在这批里完成：剩下的字节（可能含半行）原样交给传输层。
      forward += this.buffered
      this.buffered = ''
    }
    if (forward.length > 0) this.push(Buffer.from(forward, 'utf8'))
    callback()
  }

  override _flush(callback: (error?: Error | null) => void): void {
    const remaining = this.buffered + this.decoder.end()
    this.buffered = ''
    if (remaining.length > 0 && this.state !== 'closed') this.push(Buffer.from(remaining, 'utf8'))
    callback()
  }

  /**
   * 判定 `ready` 之后的一行：只有重复握手会被拦下。
   * @param line - 已去掉首尾空白的一行。
   * @returns `deliver` 表示继续交给传输层。
   */
  private inspectAfterHello(line: string): 'deliver' | 'handled' {
    if (!line.includes(HELLO_MARKER)) return 'deliver'
    const frame = parseFrameObject(line)
    if (frame === undefined || frame.method !== REMOTE_HELLO_METHOD) return 'deliver'
    const id = requestIdOf(frame)
    if (id === undefined) return 'handled'
    this.reject(id, REMOTE_HELLO_METHOD, 'duplicate-hello', DUPLICATE_HELLO_MESSAGE)
    return 'handled'
  }

  /**
   * 判定 `awaiting-hello` 时的一行（协议 §3.3）。
   * @param line - 已去掉首尾空白的一行。
   * @returns `deliver` 表示继续交给传输层（握手前只有无法识别成分的帧会走到这里）。
   */
  private inspectBeforeHello(line: string): 'deliver' | 'handled' {
    const frame = parseFrameObject(line)
    // 连 JSON 对象都不是的帧交给传输层：它按既有行为忽略，不在这里改变语义。
    if (frame === undefined) return 'deliver'
    if (typeof frame.method !== 'string') return 'deliver'
    const id = requestIdOf(frame)
    if (frame.method !== REMOTE_HELLO_METHOD) {
      // 握手前的通知丢弃、不关闭（协议 §3.3）。
      if (id === undefined) return 'handled'
      this.reject(id, frame.method, 'handshake-required', HANDSHAKE_REQUIRED_MESSAGE)
      return 'handled'
    }
    if (id === undefined) return 'handled'
    this.acceptHello(id, frame.params)
    return 'handled'
  }

  /**
   * 校验并应答一次握手（协议 §3.2、§3.3）。
   * @param id - 请求 id，原样回填。
   * @param params - 握手参数。
   */
  private acceptHello(id: string | number, params: unknown): void {
    const request = asRecord(params)
    const clientVersion = request?.protocolVersion
    if (clientVersion !== REMOTE_PROTOCOL_VERSION) {
      this.writeAndClose({
        jsonrpc: '2.0',
        id,
        error: {
          code: -32000,
          message: `协议版本不匹配：电脑为 v${REMOTE_PROTOCOL_VERSION}，手机为 v${describeVersion(clientVersion)}。请把两端升级到同一版本。`,
          data: {
            code: 'protocol-mismatch',
            hostVersion: REMOTE_PROTOCOL_VERSION,
            appVersion: typeof clientVersion === 'number' ? clientVersion : null,
            detail: 'version-mismatch',
          },
        },
      }, 'version-mismatch')
      return
    }
    const label = normalizeDeviceLabel(request?.deviceLabel)
    const capabilities = negotiateCapabilities(request?.capabilities, this.options.handshake.capabilities)
    this.state = 'ready'
    const result = {
      protocolVersion: REMOTE_PROTOCOL_VERSION,
      host: {
        name: this.options.handshake.hostName,
        platform: process.platform,
        home: this.options.handshake.hostHome,
      },
      methods: [...this.options.handshake.methods],
      unsupported: [...this.options.handshake.unsupported],
      capabilities: [...this.options.handshake.capabilities],
    }
    // 先切状态再写帧：手机可能把 hello 和业务请求放在同一批里，状态不切会让后续帧被判成未握手。
    this.options.onHello(label, capabilities)
    void this.options.writeFrame({ jsonrpc: '2.0', id, result }).catch(() => {
      // 写失败由连接的 sink 错误处理记录；连接随后会随 socket 关闭收敛。
    })
  }

  /**
   * 回一条 `-32000` 并让连接关闭 `4002`（协议 §3.3、§9.1）。
   * @param id - 触发错误的请求 id。
   * @param method - 触发错误的方法名，写进 `data.method`。
   * @param detail - `handshake-required` 或 `duplicate-hello`。
   * @param message - 可直接展示的中文说明。
   */
  private reject(id: string | number, method: string, detail: string, message: string): void {
    this.writeAndClose({
      jsonrpc: '2.0',
      id,
      error: {
        code: -32000,
        message,
        data: { code: 'protocol-mismatch', detail, method, hostVersion: REMOTE_PROTOCOL_VERSION },
      },
    }, detail)
  }

  /**
   * 写出一帧，写出（或写失败）之后让连接以 `4002` 关闭，保证错误帧先于关闭帧。
   * @param frame - 要写出的错误帧。
   * @param reason - 关闭原因。
   */
  private writeAndClose(frame: Record<string, unknown>, reason: string): void {
    this.state = 'closed'
    void this.options.writeFrame(frame).catch(() => {}).then(() => {
      this.options.onViolation(reason)
    })
  }
}

/**
 * 把一行文本解析成 JSON-RPC 帧对象。
 * @param line - 单行帧文本。
 * @returns 对象形态的帧；不是 JSON 对象时 undefined。
 */
function parseFrameObject(line: string): Record<string, unknown> | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    return undefined
  }
  return asRecord(parsed)
}

/**
 * 把任意值收窄成普通对象。
 * @param value - 待收窄的值。
 * @returns 非数组的普通对象；其它值 undefined。
 */
function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  return value as Record<string, unknown>
}

/**
 * 取出请求 id。
 * @param frame - 已解析的帧。
 * @returns 字符串或数字 id；通知帧与 `id: null` 时 undefined。
 */
function requestIdOf(frame: Record<string, unknown>): string | number | undefined {
  const id = frame.id
  return typeof id === 'string' || typeof id === 'number' ? id : undefined
}

/**
 * 把握手里的协议版本渲染成可展示文本。
 * @param version - 客户端声明的版本。
 * @returns 整数的十进制文本，其余为 `未知`。
 */
function describeVersion(version: unknown): string {
  return typeof version === 'number' && Number.isSafeInteger(version) ? String(version) : '未知'
}

/**
 * 收敛握手里的设备显示名（协议 §3.1：1–120 字符）。
 *
 * 显示名只用于设备表与排障，不值得因为它让整条连接握手失败，因此这里清洗而不是拒绝：
 * 去掉控制字符与首尾空白、按码点截断；清洗后为空时用一个固定的占位名。
 * @param raw - 握手里的 `deviceLabel`。
 * @returns 1–120 个非控制字符的显示名。
 */
function normalizeDeviceLabel(raw: unknown): string {
  if (typeof raw !== 'string') return '未命名的 Android 设备'
  const cleaned = raw.normalize('NFC').replace(/[\u0000-\u001f\u007f]/gu, ' ').replace(/\s+/gu, ' ').trim()
  if (cleaned.length === 0) return '未命名的 Android 设备'
  return Array.from(cleaned).slice(0, DEVICE_LABEL_MAX_LENGTH).join('')
}

/**
 * 计算客户端与宿主的能力交集（协议 §6.4、附录 B：连接的能力是「客户端声明且服务端支持」）。
 * @param declared - 握手里的 `capabilities`。
 * @param supported - 宿主支持的能力。
 * @returns 交集，保持宿主声明顺序。
 */
function negotiateCapabilities(declared: unknown, supported: readonly string[]): string[] {
  if (!Array.isArray(declared)) return []
  const client = new Set(declared.filter((entry): entry is string => typeof entry === 'string'))
  return supported.filter(entry => client.has(entry))
}

/**
 * 一条已接受升级的远程连接（协议附录 B 的 Node 侧实现）。
 *
 * 对外只暴露协议列出的字段与方法；内部持有一条 `JsonRpcLineTransport` 和一对 ws↔流适配器。
 *
 * 连接建立后先停在 `awaiting-hello`：只有收到合法的 `protocol.hello` 才进入 `ready`
 * （协议 §3.1–§3.3），10 s 内没有握手即关闭 `4002`。`methods` / `unsupported` 来自
 * {@link RemoteHandshake}，即装配方从门面分发表生成的那一份。
 */
export class RemoteConnection {
  /** 连接 id，进程内唯一。 */
  readonly id: string
  /** 设备 id；由鉴权阶段确定。 */
  readonly deviceId: string
  /** 对端地址，仅用于日志。 */
  readonly remoteAddress: string
  /** 已协商版本，v1 恒为 1。 */
  readonly protocolVersion = 1 as const
  /** 设备显示名；握手前为空串，`protocol.hello` 之后填入。 */
  deviceLabel = ''
  /** 客户端声明且服务端支持的能力，例如 `['window-ack']`；握手前为空。 */
  capabilities: string[] = []
  /** 本连接可应答的方法清单（协议 §10.1 语法）。 */
  readonly methods: readonly string[]
  /** 本连接明确不支持的方法清单（协议 §10.1 语法）。 */
  readonly unsupported: readonly string[]
  /** 生命周期状态。 */
  state: RemoteConnectionState = 'awaiting-hello'

  private readonly socket: WebSocket
  private readonly transport: JsonRpcLineTransport
  private readonly gate: RemoteHandshakeGate
  private readonly sink: WebSocketSink
  private readonly log: RemoteLogger
  private readonly nativeProvider: RemoteNativeProvider
  private readonly onClosed: (connection: RemoteConnection, outcome: RemoteCloseOutcome) => void

  private requestHandler: RemoteRequestHandler | undefined
  private notification: RemoteNotificationHandler | undefined
  private heartbeatTimer: NodeJS.Timeout | undefined
  private handshakeTimer: NodeJS.Timeout | undefined
  private closing: Promise<void> | undefined
  private missedHeartbeats = 0

  /** @param options - 连接 id、设备 id、socket、握手材料、native 应答者、日志与关闭回调。 */
  constructor(options: RemoteConnectionOptions) {
    this.id = options.id
    this.deviceId = options.deviceId
    this.remoteAddress = options.remoteAddress
    this.socket = options.socket
    this.log = options.log
    this.nativeProvider = options.nativeProvider
    this.onClosed = options.onClosed
    this.methods = options.handshake.methods
    this.unsupported = options.handshake.unsupported

    this.socket.on('pong', this.markActive)
    this.socket.on('message', this.markActive)
    this.socket.on('close', this.handleSocketClose)

    const source = new WebSocketSource(this.socket, options.initialFrames)
    this.sink = new WebSocketSink(this.socket)
    this.sink.on('error', this.handleSinkError)
    source.on('error', this.handleSourceError)
    this.gate = new RemoteHandshakeGate({
      handshake: options.handshake,
      writeFrame: (frame: Record<string, unknown>) => this.writeFrame(frame),
      onHello: (deviceLabel: string, capabilities: string[]) => {
        this.handleHello(deviceLabel, capabilities)
      },
      onViolation: (reason: string) => {
        this.log({
          level: 'warn',
          event: 'handshake-rejected',
          message: '连接没有通过握手门禁，已按协议关闭。',
          fields: { connectionId: this.id, deviceId: this.deviceId, reason },
        })
        void this.close(4002, reason).catch((error: unknown) => {
          this.handleSinkError(error instanceof Error ? error : new Error(String(error)))
        })
      },
    })

    // 协议 §1.2：宿主发起的反向请求 id 必须是 `h-` + uuidv4，与 App 的 `a-` 前缀分向。
    this.transport = new JsonRpcLineTransport(this.gate, this.sink, { requestIdPrefix: 'h-' })
    this.transport.onRequest(this.handleRequest)
    this.transport.onNotification(this.handleNotification)
    this.transport.start()
    // 关闭时 gate 会被销毁，残余写入会以错误事件浮上来；这里接住它，避免变成未捕获异常。
    this.gate.on('error', this.handleGateError)
    source.pipe(this.gate)

    this.startHeartbeat()
    this.startHandshakeTimer(options.handshake.timeoutMs ?? DEFAULT_HANDSHAKE_TIMEOUT_MS)
  }

  /**
   * 宿主 → App 的请求。
   * @param method - 方法名，例如 `native.documents.roots`。
   * @param params - 请求参数，缺省为 `{}`。
   * @param signal - 中止信号；中止只丢弃在途记录，不发送任何帧。
   * @returns 结果；失败为传输层抛出的错误。
   */
  async request(method: string, params: object = {}, signal?: AbortSignal): Promise<unknown> {
    this.assertOpen('发送请求')
    return this.transport.request(method, params, signal)
  }

  /**
   * 宿主 → App 的通知。
   * @param method - 例如 `remote.taskCompleted`。
   * @param params - 通知参数；省略时不写 `params` 成员。
   * @returns 无返回值；连接不可写时抛 {@link RemoteConnectionClosedError}。
   */
  notify(method: string, params?: object): void {
    this.assertOpen('发送通知')
    this.transport.notify(method, params)
  }

  /**
   * 安装 App → 宿主的请求处理器。已安装的处理器被替换。
   * @param handler - 返回值为 JSON-RPC `result`；抛错由传输层转成 `-32603`。
   * @returns 无返回值。
   */
  onRequest(handler: RemoteRequestHandler): void {
    this.requestHandler = handler
  }

  /**
   * 安装 App → 宿主的通知处理器。已安装的处理器被替换。
   *
   * 握手完成前到达的通知按协议 §3.3 丢弃（不关闭连接）。
   * @param handler - 每条通知调用一次；通知没有响应可回。
   * @returns 无返回值。
   */
  onNotification(handler: RemoteNotificationHandler): void {
    this.notification = handler
  }

  /**
   * 关闭连接：先让传输层拒绝在途反向请求，再按协议关闭码关闭 WS。
   * 幂等，重复调用共享同一次完成。
   * @param code - 协议 §1.4 的关闭码之一。
   * @param reason - 简短原因，超过 123 字节按字节截断。
   * @returns 连接真正关闭且资源释放后兑现。
   */
  close(code: RemoteCloseCode, reason: string): Promise<void> {
    if (this.closing !== undefined) return this.closing
    this.state = 'closing'
    this.closing = this.finalize(code, reason, false)
    return this.closing
  }

  private assertOpen(action: string): void {
    if (this.state === 'closed' || this.state === 'closing') {
      throw new RemoteConnectionClosedError(action)
    }
  }

  private readonly markActive = (): void => {
    this.missedHeartbeats = 0
  }

  private readonly handleSinkError = (error: Error): void => {
    this.log({
      level: 'error',
      event: 'frame-write-failed',
      message: '向手机写一帧失败。',
      fields: { connectionId: this.id, deviceId: this.deviceId, error: describeRemoteError(error) },
    })
  }

  private readonly handleSourceError = (error: Error): void => {
    this.log({
      level: 'error',
      event: 'frame-read-failed',
      message: '从手机读帧失败，连接即将关闭。',
      fields: { connectionId: this.id, deviceId: this.deviceId, error: describeRemoteError(error) },
    })
    if (error instanceof RemoteFrameViolation) void this.close(1002, 'protocol-error')
  }

  /**
   * 握手门禁的流水线错误。连接已经在收尾时忽略（销毁 gate 后的残余写入属正常现象），
   * 其余情况按协议错误以 `1002` 关闭，而不是让异常浮成未捕获错误。
   * @param error - 门禁流上报的错误。
   */
  private readonly handleGateError = (error: Error): void => {
    if (this.state === 'closing' || this.state === 'closed') return
    this.log({
      level: 'error',
      event: 'frame-pipeline-failed',
      message: '握手门禁的帧流水线出错，连接即将关闭。',
      fields: { connectionId: this.id, deviceId: this.deviceId, error: describeRemoteError(error) },
    })
    void this.close(1002, 'protocol-error').catch((closeError: unknown) => {
      this.handleSinkError(closeError instanceof Error ? closeError : new Error(String(closeError)))
    })
  }

  private readonly handleRequest = async (
    method: string,
    params: Record<string, unknown>,
  ): Promise<unknown> => {
    // 本地拦截必须优先于转发（协议附录 B 约束 3）。
    if (this.nativeProvider.handles(method)) return await this.nativeProvider.request(method, params)
    const handler = this.requestHandler
    if (handler === undefined) throw new RemoteUnsupportedMethodError(method)
    return await handler(method, params)
  }

  private readonly handleNotification = (method: string, params: Record<string, unknown>): void => {
    // 协议 §3.3：握手前收到通知帧丢弃、不关闭。
    if (this.state !== 'ready') return
    this.notification?.(method, params)
  }

  /**
   * 把一帧交给 socket。门禁写握手应答与协议错误帧时用它，与传输层的出站帧共用同一个 sink，
   * 因此帧顺序与写入顺序一致。
   * @param frame - 完整的 JSON-RPC 帧对象。
   * @returns 写入完成即兑现；连接不可写时以 {@link RemoteConnectionClosedError} 拒绝。
   */
  private writeFrame(frame: Record<string, unknown>): Promise<void> {
    const text = `${JSON.stringify(frame)}\n`
    return new Promise<void>((resolve, reject) => {
      this.sink.write(text, (error?: Error | null) => {
        if (error === undefined || error === null) resolve()
        else reject(error)
      })
    })
  }

  /**
   * 握手成功：记录设备显示名与协商能力，进入 `ready`，并结束握手计时。
   * @param deviceLabel - 已收敛的显示名。
   * @param capabilities - 客户端声明且宿主支持的能力。
   */
  private handleHello(deviceLabel: string, capabilities: string[]): void {
    this.deviceLabel = deviceLabel
    this.capabilities = capabilities
    this.state = 'ready'
    this.stopHandshakeTimer()
    this.log({
      level: 'info',
      event: 'handshake-complete',
      message: '远程连接已完成 protocol.hello 握手。',
      fields: {
        connectionId: this.id,
        deviceId: this.deviceId,
        deviceLabel,
        capabilities,
        methods: this.methods.length,
        unsupported: this.unsupported.length,
      },
    })
  }

  private startHandshakeTimer(timeoutMs: number): void {
    this.handshakeTimer = setTimeout(() => {
      this.handshakeTimer = undefined
      if (this.state !== 'awaiting-hello') return
      this.log({
        level: 'warn',
        event: 'handshake-timeout',
        message: '连接在握手窗口内没有收到 protocol.hello，已关闭。',
        fields: { connectionId: this.id, deviceId: this.deviceId, timeoutMs },
      })
      void this.close(4002, 'handshake-timeout').catch((error: unknown) => {
        this.handleSinkError(error instanceof Error ? error : new Error(String(error)))
      })
    }, timeoutMs)
    this.handshakeTimer.unref()
  }

  private stopHandshakeTimer(): void {
    if (this.handshakeTimer === undefined) return
    clearTimeout(this.handshakeTimer)
    this.handshakeTimer = undefined
  }

  private startHeartbeat(): void {
    this.heartbeatTimer = setInterval(this.beat, HEARTBEAT_INTERVAL_MS)
    this.heartbeatTimer.unref()
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer === undefined) return
    clearInterval(this.heartbeatTimer)
    this.heartbeatTimer = undefined
  }

  private readonly beat = (): void => {
    // 握手窗口里也要发 ping：连接可能一直不发 hello，那属于握手超时的分支，不是心跳的。
    if (this.state !== 'ready' && this.state !== 'awaiting-hello') return
    if (this.missedHeartbeats >= MAX_MISSED_HEARTBEATS) {
      this.log({
        level: 'warn',
        event: 'heartbeat-timeout',
        message: '连接连续两个心跳周期没有任何活动，已按协议关闭。',
        fields: { connectionId: this.id, deviceId: this.deviceId, remoteAddress: this.remoteAddress },
      })
      // 协议 §1.4、§7 缺陷清单第 3 条：心跳超时必须走 1001 关闭帧，不能直接掐断（对端会看到 1006）。
      void this.close(1001, 'heartbeat-timeout').catch((error: unknown) => {
        this.handleSinkError(error instanceof Error ? error : new Error(String(error)))
      })
      return
    }
    this.missedHeartbeats += 1
    if (this.socket.readyState === WebSocket.OPEN) this.socket.ping()
  }

  private readonly handleSocketClose = (code: number, reason: Buffer): void => {
    if (this.closing !== undefined) return
    this.state = 'closing'
    this.closing = this.finalize(peerCloseCode(code), reason.toString('utf8'), true)
  }

  private async finalize(code: RemoteCloseCode, reason: string, byPeer: boolean): Promise<void> {
    this.state = 'closing'
    this.stopHeartbeat()
    this.stopHandshakeTimer()
    const safeReason = truncateCloseReason(reason)
    // 先停掉入站流水线，再终结传输层：在途反向请求在这里被拒绝，之后才动 socket。
    this.gate.destroy()
    // 先终结传输层：在途反向请求在这里被拒绝，之后才动 socket。
    this.transport.close()
    await this.closeSocket(code, safeReason)
    this.state = 'closed'
    this.onClosed(this, { code, reason: safeReason, byPeer })
  }

  private closeSocket(code: RemoteCloseCode, reason: string): Promise<void> {
    if (this.socket.readyState === WebSocket.CLOSED) return Promise.resolve()
    const closed = Promise.withResolvers<void>()
    const grace = setTimeout(() => {
      // 对端不回应关闭握手：直接断开，避免连接对象一直挂着。
      this.socket.terminate()
    }, CLOSE_GRACE_MS)
    grace.unref()
    this.socket.once('close', () => {
      clearTimeout(grace)
      closed.resolve()
    })
    if (this.socket.readyState === WebSocket.OPEN) this.socket.close(code, reason)
    else if (this.socket.readyState === WebSocket.CONNECTING) this.socket.terminate()
    // CLOSING：对端已经发过关闭帧，等它收尾，超时由上面的宽限计时器兜底。
    return closed.promise
  }
}

/**
 * 远程宿主服务器：自建 https server + `noServer` 的 WebSocketServer，只服务 `/app`。
 *
 * 构造只准备监听器，真正开始监听由 {@link start} 完成，因此装配方可以先把 TLS 材料、设备表准备好，
 * 并在失败时干净退出。
 */
export class RemoteHostServer {
  private readonly options: RemoteHostServerOptions
  private readonly log: RemoteLogger
  private readonly httpServer: HttpsServer
  private readonly webSockets: WebSocketServer
  private readonly connections = new Map<string, RemoteConnection>()
  private bound: { readonly port: number; readonly host: string } | undefined
  private stopping: Promise<void> | undefined

  /** @param options - 端口、地址、TLS 材料、鉴权器、连接回调与 native 应答者。 */
  constructor(options: RemoteHostServerOptions) {
    this.options = options
    this.log = options.log ?? writeRemoteLog
    this.httpServer = createServer({ cert: options.tls.certPem, key: options.tls.keyPem }, this.handleHttpRequest)
    this.webSockets = new WebSocketServer({
      noServer: true,
      // 协议 §1.1：v1 不启用 permessage-deflate，也不协商子协议。
      perMessageDeflate: false,
      maxPayload: MAX_CLIENT_FRAME_BYTES,
    })
    this.httpServer.on('upgrade', this.handleUpgrade)
    this.httpServer.on('tlsClientError', this.handleTlsClientError)
  }

  /**
   * 开始监听。
   * @returns 实际绑定的端口与地址；端口配置为 0 时这里给出系统分配的端口。
   * @throws 已经停止过的服务器再次监听时抛出；端口占用等 listen 错误原样抛出。
   */
  async start(): Promise<{ readonly port: number; readonly host: string }> {
    if (this.bound !== undefined) return this.bound
    if (this.stopping !== undefined) throw new Error('远程宿主服务器已经停止，不能再监听。')
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error): void => {
        this.httpServer.off('listening', onListening)
        reject(error)
      }
      const onListening = (): void => {
        this.httpServer.off('error', onError)
        resolve()
      }
      this.httpServer.once('error', onError)
      this.httpServer.once('listening', onListening)
      this.httpServer.listen(this.options.port, this.options.host)
    })
    const address = this.httpServer.address()
    const port = typeof address === 'object' && address !== null ? address.port : this.options.port
    this.bound = { port, host: this.options.host }
    return this.bound
  }

  /**
   * 停止监听：先按 1001 关掉全部连接，再关 WebSocketServer 与 https server。幂等。
   * @returns 全部连接与监听都收尾后兑现。
   */
  stop(): Promise<void> {
    if (this.stopping !== undefined) return this.stopping
    this.stopping = this.finishStop()
    return this.stopping
  }

  private async finishStop(): Promise<void> {
    const closing = [...this.connections.values()].map(async (connection) => {
      try {
        await connection.close(1001, 'server-stop')
      } catch (error) {
        this.log({
          level: 'error',
          event: 'connection-close-failed',
          message: '停止监听时关闭一条连接失败。',
          fields: { connectionId: connection.id, error: describeRemoteError(error) },
        })
      }
    })
    await Promise.all(closing)
    await new Promise<void>((resolve) => {
      this.webSockets.close(() => {
        resolve()
      })
    })
    await new Promise<void>((resolve) => {
      this.httpServer.close((error?: Error) => {
        if (error !== undefined) {
          this.log({
            level: 'warn',
            event: 'server-close-failed',
            message: '关闭 https 监听时报告了错误，监听已经不可用。',
            fields: { error: describeRemoteError(error) },
          })
        }
        resolve()
      })
    })
    this.bound = undefined
  }

  private readonly handleHttpRequest = (request: IncomingMessage, response: ServerResponse): void => {
    const url = request.url ?? ''
    const pairing = this.options.pairing
    if (pairing !== undefined && url === REMOTE_CA_PATH) {
      this.handleCaRequest(request, response, pairing)
      return
    }
    if (pairing !== undefined && url === REMOTE_PAIR_PATH) {
      void this.handlePairRequest(request, response, pairing).catch((error: unknown) => {
        this.log({
          level: 'error',
          event: 'pair-request-failed',
          message: '处理 /pair 请求时出现未预期的错误，已回 500。',
          fields: { error: describeRemoteError(error) },
        })
        writePairFailure(response, 500, '电脑处理配对请求时出错，请重试。')
      })
      return
    }
    // 协议 §1.1：wss 只在 /app；配对端点之外的 HTTP 路径一律 404。
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(pairing === undefined
      ? '未找到资源：远程 DSH 只在 /app 提供 wss 端点。\n'
      : '未找到资源：配对接口只有 /ca.cer 与 /pair。\n')
  }

  /**
   * `GET /ca.cer`：原样回 CA 证书 DER（协议 §2 的配对流程第二步）。
   *
   * App 用响应体 DER 的 SHA-256 与自己记下的 instanceId 比对，一致才固定这张 CA；
   * 因此这里不能做任何编码转换，也不能回叶子证书。
   * @param request - 入站 HTTP 请求。
   * @param response - 待写的响应。
   * @param pairing - 配对 HTTP 面的宿主实现。
   */
  private handleCaRequest(
    request: IncomingMessage,
    response: ServerResponse,
    pairing: RemotePairingSurface,
  ): void {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.writeHead(405, { allow: 'GET, HEAD', 'content-type': 'text/plain; charset=utf-8' })
      response.end('CA 证书只支持 GET。\n')
      return
    }
    const body = pairing.caCertificateDer
    response.writeHead(200, {
      'content-type': 'application/x-x509-ca-cert',
      'content-length': body.byteLength,
      // 证书内容由 instanceId 决定；不允许中间层缓存成另一份。
      'cache-control': 'no-store',
    })
    response.end(request.method === 'HEAD' ? undefined : body)
  }

  /**
   * `POST /pair`：用一次性配对令牌换设备令牌（协议 §2）。
   *
   * 失败状态码与 App 的 `remote_pairing.dart` 映射一一对应：401 令牌无效、403 配对窗口
   * 已关闭或过期、429 尝试过于频繁；响应体只给一句话，不回显任何令牌。
   * @param request - 入站 HTTP 请求。
   * @param response - 待写的响应。
   * @param pairing - 配对 HTTP 面的宿主实现。
   * @returns 响应写完后兑现。
   */
  private async handlePairRequest(
    request: IncomingMessage,
    response: ServerResponse,
    pairing: RemotePairingSurface,
  ): Promise<void> {
    if (request.method !== 'POST') {
      response.writeHead(405, { allow: 'POST', 'content-type': 'text/plain; charset=utf-8' })
      response.end('配对只支持 POST。\n')
      return
    }
    const contentType = request.headers['content-type']
    if (typeof contentType !== 'string' || !JSON_CONTENT_TYPE.test(contentType)) {
      writePairFailure(response, 415, '配对请求必须是 application/json。')
      return
    }
    let body: string
    try {
      body = await readBoundedBody(request, MAX_PAIR_REQUEST_BYTES)
    } catch (error) {
      if (!(error instanceof PairBodyTooLargeError)) throw error
      writePairFailure(response, 400, `配对请求体超过 ${MAX_PAIR_REQUEST_BYTES} 字节上限。`)
      return
    }
    const parsed = parsePairRequestBody(body)
    if (!parsed.ok) {
      writePairFailure(response, 400, parsed.message)
      return
    }
    const outcome = await pairing.redeem({
      token: parsed.token,
      deviceLabel: parsed.deviceLabel,
      appVersion: parsed.appVersion,
      peer: request.socket.remoteAddress ?? 'unknown',
    })
    if (!outcome.ok) {
      this.log({
        level: 'warn',
        event: 'pair-rejected',
        message: '一次配对请求被拒绝。',
        fields: {
          peer: request.socket.remoteAddress ?? 'unknown',
          status: outcome.status,
          appVersion: parsed.appVersion,
        },
      })
      writePairFailure(response, outcome.status, outcome.message)
      return
    }
    this.log({
      level: 'info',
      event: 'pair-issued',
      message: '一台新设备完成配对。',
      fields: {
        peer: request.socket.remoteAddress ?? 'unknown',
        deviceId: outcome.deviceId,
        deviceLabel: parsed.deviceLabel,
        appVersion: parsed.appVersion,
        expiresAt: outcome.expiresAt,
      },
    })
    const payload = JSON.stringify({
      deviceId: outcome.deviceId,
      deviceToken: outcome.deviceToken,
      expiresAt: outcome.expiresAt,
    })
    response.writeHead(200, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(payload, 'utf8'),
      // 设备令牌只出现这一次，任何中间层都不许缓存。
      'cache-control': 'no-store',
    })
    response.end(payload)
  }

  /**
   * 撤销一台设备（协议 §2.2、§8.4）。
   *
   * 顺序固定：先落盘删除（设备表的 `revoke` 成功返回才继续），再向该设备已进入 `ready`
   * 的连接推 `remote.deviceRevoked`，最后以 `4001` 关闭这些连接。通知先于关闭帧发出，
   * 与 §8.4「App 收到后忽略随后到达的连接关闭原因」一致。
   * @param store - 设备表；撤销结果以它落盘后的状态为准。
   * @param deviceId - 设备 id。
   * @param reason - `user-revoked` 或 `expired`。
   * @returns 撤销是否生效，以及被关闭的连接数。
   */
  async revokeDevice(
    store: RemoteDeviceRevoker,
    deviceId: string,
    reason: 'user-revoked' | 'expired' = 'user-revoked',
  ): Promise<RemoteDeviceRevokeResult> {
    const revoked = await store.revoke(deviceId)
    if (!revoked) return { revoked: false, closed: 0 }
    const record = store.list().find(candidate => candidate.id === deviceId)
    const revokedAt = record?.revokedAt ?? Date.now()
    const targets = [...this.connections.values()].filter(connection => connection.deviceId === deviceId)
    let closed = 0
    for (const connection of targets) {
      if (connection.state === 'ready') {
        try {
          connection.notify('remote.deviceRevoked', {
            deviceId,
            ...(record === undefined ? {} : { deviceLabel: record.label }),
            reason,
            revokedAt,
          })
        } catch (error) {
          this.log({
            level: 'warn',
            event: 'device-revoked-notify-failed',
            message: '撤销通知没有写出去，连接仍会按 4001 关闭。',
            fields: { connectionId: connection.id, deviceId, error: describeRemoteError(error) },
          })
        }
      }
      try {
        await connection.close(4001, 'auth-revoked')
        closed += 1
      } catch (error) {
        this.log({
          level: 'error',
          event: 'device-revoked-close-failed',
          message: '撤销设备时关闭一条连接失败。',
          fields: { connectionId: connection.id, deviceId, error: describeRemoteError(error) },
        })
      }
    }
    this.log({
      level: 'info',
      event: 'device-revoked',
      message: '已撤销一台设备并关闭它的在线连接。',
      fields: { deviceId, reason, closed },
    })
    return { revoked: true, closed }
  }

  private readonly handleTlsClientError = (error: Error, socket: TLSSocket): void => {
    this.log({
      level: 'warn',
      event: 'tls-client-error',
      message: '一次 TLS 握手失败，连接已断开。',
      fields: { remoteAddress: socket.remoteAddress ?? 'unknown', error: describeRemoteError(error) },
    })
    socket.destroy()
  }

  private readonly handleUpgrade = (request: IncomingMessage, socket: Duplex, head: Buffer): void => {
    const remoteAddress = request.socket.remoteAddress ?? 'unknown'
    const url = request.url ?? ''
    if (!isAppEndpoint(url)) {
      this.log({
        level: 'warn',
        event: 'upgrade-rejected',
        message: '升级请求的路径不是 /app，已按 404 拒绝。',
        fields: { remoteAddress, url },
      })
      rejectUpgrade(socket, 404, 'Not Found')
      return
    }
    if (request.headers.origin !== REMOTE_ORIGIN) {
      this.log({
        level: 'warn',
        event: 'upgrade-rejected',
        message: '升级请求的 Origin 不匹配，已按 403 拒绝。',
        fields: { remoteAddress, origin: request.headers.origin ?? null },
      })
      rejectUpgrade(socket, 403, 'Forbidden')
      return
    }
    const token = bearerToken(request.headers.authorization)
    if (token === undefined) {
      this.log({
        level: 'warn',
        event: 'upgrade-rejected',
        message: '升级请求缺少合法的 Authorization 头，已按 401 拒绝。',
        fields: { remoteAddress },
      })
      rejectUpgrade(socket, 401, 'Unauthorized')
      return
    }
    this.webSockets.handleUpgrade(request, socket, head, (webSocket) => {
      // 令牌校验是异步的，而手机可能在鉴权返回前就发出 protocol.hello。
      // 先把期间的帧收下来，交给连接对象按到达顺序补进传输层，避免丢首帧。
      const buffered: RemoteIncomingFrame[] = []
      const collect = (data: RawData, binary: boolean): void => {
        buffered.push({ data, binary })
      }
      webSocket.on('message', collect)
      webSocket.on('error', (error: Error) => {
        this.log({
          level: 'warn',
          event: 'socket-error',
          message: '连接上报了 socket 错误。',
          fields: { remoteAddress, error: describeRemoteError(error) },
        })
      })
      void this.admit(webSocket, token, remoteAddress, buffered, () => {
        webSocket.off('message', collect)
      })
    })
  }

  private async admit(
    webSocket: WebSocket,
    token: string,
    remoteAddress: string,
    buffered: RemoteIncomingFrame[],
    stopCollecting: () => void,
  ): Promise<void> {
    const id = `c-${randomUUID().replaceAll('-', '')}`
    let outcome: RemoteAuthOutcome
    try {
      outcome = await this.options.authenticate(token)
    } catch (error) {
      this.log({
        level: 'error',
        event: 'authenticate-failed',
        message: '设备令牌校验本身出错，连接已断开。',
        fields: { connectionId: id, remoteAddress, error: describeRemoteError(error) },
      })
      webSocket.terminate()
      return
    }
    if (webSocket.readyState !== WebSocket.OPEN) {
      this.log({
        level: 'info',
        event: 'connection-abandoned',
        message: '鉴权期间手机已经断开，连接不再建立。',
        fields: { connectionId: id, remoteAddress },
      })
      return
    }
    if (!outcome.ok) {
      this.rejectAuthentication(webSocket, id, remoteAddress, outcome.code)
      return
    }
    stopCollecting()
    const connection = new RemoteConnection({
      id,
      deviceId: outcome.deviceId,
      remoteAddress,
      socket: webSocket,
      nativeProvider: this.options.nativeProvider,
      handshake: this.options.handshake,
      log: this.log,
      initialFrames: buffered,
      onClosed: (closedConnection, closeOutcome) => {
        this.connections.delete(closedConnection.id)
        this.options.onClose?.(closedConnection, closeOutcome)
      },
    })
    this.connections.set(id, connection)
    this.log({
      level: 'info',
      event: 'connection-opened',
      message: '手机已通过鉴权并建立远程连接。',
      fields: { connectionId: id, deviceId: connection.deviceId, remoteAddress },
    })
    this.options.onConnection(connection)
  }

  /**
   * 令牌内容不匹配或设备已撤销：升级已经通过，用带 `id: null` 的错误帧说明原因再关闭。
   * @param webSocket - 已升级的连接。
   * @param id - 连接 id，仅用于日志。
   * @param remoteAddress - 对端地址，仅用于日志。
   * @param code - `auth-failed` 或 `auth-revoked`。
   * @returns 无返回值。
   */
  private rejectAuthentication(
    webSocket: WebSocket,
    id: string,
    remoteAddress: string,
    code: 'auth-failed' | 'auth-revoked',
  ): void {
    const closeCode: RemoteCloseCode = code === 'auth-failed' ? 4000 : 4001
    const frame = {
      jsonrpc: '2.0',
      id: null,
      error: {
        code: code === 'auth-failed' ? -32001 : -32002,
        message: code === 'auth-failed' ? AUTH_FAILED_MESSAGE : AUTH_REVOKED_MESSAGE,
        data: { code },
      },
    }
    this.log({
      level: 'warn',
      event: 'upgrade-rejected',
      message: code === 'auth-failed' ? '设备令牌无效，连接已拒绝。' : '设备已被撤销，连接已拒绝。',
      fields: { connectionId: id, remoteAddress, closeCode },
    })
    if (webSocket.readyState !== WebSocket.OPEN) {
      webSocket.terminate()
      return
    }
    webSocket.send(`${JSON.stringify(frame)}\n`, () => {
      webSocket.close(closeCode, code)
    })
  }
}

