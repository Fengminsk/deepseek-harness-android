/**
 * 本机配对设置页：宿主内嵌的、只监听 127.0.0.1 的 HTTP 面。
 *
 * 解决的问题：配对链接里有 107 个必须原样保留的字符，终端日志与二维码之外，用户还需要
 * 一个能看窗口倒计时、放大二维码、管理已配对设备的地方。页面由宿主自己提供，不启用完整
 * Web 组合（不碰 `dsh-web-app`/`webStartup`），也不引任何新依赖。
 *
 * 安全边界（每一条都在实现里成立）：
 * - 只绑 {@link PAGE_BIND_ADDRESS}（127.0.0.1），不提供任何非回环入口；
 * - 所有请求校验 `Host` 头只能是 `127.0.0.1:<port>` / `localhost:<port>`，挡住 DNS rebinding；
 * - 带 `Origin` 的请求必须是同源，否则 403；不返回任何 CORS 头；
 * - POST 必须带本进程随机生成的 CSRF token（隐藏表单字段），缺失或不符一律 403；
 * - 控制 API（`POST /api/pair`、`POST /api/devices/revoke`）是给本机插件用的 JSON 端点：
 *   除 Host/Origin 外还必须带固定控制头 {@link CONTROL_HEADER}: `1`，缺失或不符一律 403。
 *   它挡的是「浏览器里其它网页发起的 CSRF」——跨站表单不能加自定义头，跨站 fetch 加自定义头
 *   会先发预检，而本页不实现 OPTIONS、也不返回 CORS 头，预检必然失败。控制头不是鉴权：
 *   同机其它进程本来就能模拟它（见下方已接受的威胁）；
 * - `GET /qr.svg` 与 `GET /api/state` 是只读端点，不做控制头校验（浏览器 `<img>` 不能带自定义
 *   头，而跨站读取被同源策略与「无 CORS 头」挡住）；
 * - 页面与 JSON 只展示设备摘要（`DeviceSummary` 不含令牌摘要），配对令牌只在窗口打开时出现；
 * - `X-Content-Type-Options: nosniff`、`Cache-Control: no-store`、CSP 与 `frame-ancestors 'none'`
 *   阻止嗅探、缓存、外链资源与点击劫持；
 * - 结构化日志不记录令牌：动作日志只有事件名、方法与结果。
 *
 * 已接受的威胁：同一台电脑上的其它进程本来就能读 `$DSH_HOME/remote-host/devices.json` 与宿主
 * 日志，回环页带来的增量风险有限；本页只防「浏览器里其它网页发起的 CSRF / DNS rebinding」。
 * `<img src="/qr.svg">` 这类跨源嵌入只能显示、不能读像素，也就不构成令牌外泄通道。
 *
 * 失败语义：页面是增强能力。端口被占用或没有权限时只写一条 warn、返回 `listening:false`，
 * 宿主照常启动，配对链接仍在日志里（与 `./discovery.ts` 的降级一致）。
 *
 * 窗口语义：页面与控制 API 不发明「重开」之外的任何入口。窗口是单次有效的，被消耗或过期后
 * {@link PairingPageSource.currentPairing} 返回 undefined，页面如实显示「没有打开的窗口」。
 * 长期配对（`Config.pairingLongTerm`）由宿主在配对成功后自动重开下一个窗口，本模块只反映
 * 宿主的当前事实，不自己延长有效期。
 * @module remote-host/pairing-page
 */

import { randomBytes, timingSafeEqual } from 'node:crypto'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import type { DeviceSummary } from './devices.ts'
import { encodeQrMatrix, type QrMatrix } from './pairing-qr.ts'
import {
  describeRemoteError,
  writeRemoteLog,
  type RemoteDeviceRevokeResult,
  type RemoteLogger,
} from './server.ts'

/** 页面唯一的绑定地址：任何非回环地址都不应看到设备列表与配对令牌。 */
const PAGE_BIND_ADDRESS = '127.0.0.1'

/** `Config.pagesPort` 的默认值；0 表示交给系统分配（只用于测试与本地调试）。 */
export const DEFAULT_PAIRING_PAGE_PORT = 4780

/** `Host` 头允许的主机名：只接受回环别名。 */
const ALLOWED_HOST_NAMES: readonly string[] = ['127.0.0.1', 'localhost']

/** POST 表单体的字节上限；页面只有两个隐藏字段，永远不该接近它。 */
const MAXIMUM_FORM_BYTES = 4 * 1024

/** 控制 API JSON 请求体的字节上限；`/api/devices/revoke` 只有一个设备 id。 */
const MAXIMUM_CONTROL_BODY_BYTES = 4 * 1024

/** 控制 API 的自定义请求头；本机插件用它标记「这是控制面客户端，不是浏览器表单」。 */
const CONTROL_HEADER = 'x-dsh-pairing-control'

/** {@link CONTROL_HEADER} 唯一允许的值。 */
const CONTROL_HEADER_VALUE = '1'

/** CSRF token 的隐藏字段名。 */
const CSRF_FIELD = 'csrf'

/** 设备 id 形态（与 `./devices.ts` 落盘时的约束一致）。 */
const DEVICE_ID_PATTERN = /^[0-9a-f]{32}$/u

/** HTML 响应类型。 */
const HTML_CONTENT_TYPE = 'text/html; charset=utf-8'

/** 纯文本响应类型（错误说明）。 */
const TEXT_CONTENT_TYPE = 'text/plain; charset=utf-8'

/** JSON 响应类型。 */
const JSON_CONTENT_TYPE = 'application/json; charset=utf-8'

/** SVG 响应类型（二维码端点）。 */
const SVG_CONTENT_TYPE = 'image/svg+xml; charset=utf-8'

/**
 * 页面把窗口显示成「长期有效」而不显示秒级倒计时的阈值（1 小时）。
 *
 * 长期配对部署的窗口常在数天到 90 天之间，逐秒倒计时既没有信息量，也让用户误以为
 * 又回到了「单次短窗口」；此时只展示真实的过期时间，倒计时留给短窗口。
 */
const LONG_LIVED_WINDOW_SECONDS = 60 * 60

/**
 * 所有响应统一带的防护头。
 *
 * `default-src 'none'` 要求页面不得引用任何外部资源；`connect-src 'self'` 是页面轮询
 * `/api/state` 需要的唯一网络权限；不写 `Access-Control-Allow-*`，因此没有跨站读取。
 */
const SECURITY_HEADERS: Readonly<Record<string, string>> = Object.freeze({
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
})

/** 一次打开着的配对窗口；`remoteHost.pair()` 与配对页共用同一份事实。 */
export interface PairingPageTicket {
  /** 可直接展示/编码成二维码的配对链接（局域网或反代 origin）。 */
  readonly pairUrl: string
  /** 回环地址（`wss://127.0.0.1:<port>`）的同一张配对票据，供 `adb reverse` USB 连接使用。 */
  readonly usbPairUrl: string
  /** 窗口关闭时间（Unix 毫秒）。 */
  readonly expiresAt: number
}

/** 配对页头部展示的宿主身份与监听信息；`/api/state` 的 `host` 字段原样复用它。 */
export interface PairingPageHost {
  /** 宿主显示名（握手里的 `host.name`）。 */
  readonly name: string
  /** 64 位小写十六进制 instanceId（CA 证书指纹），页面只展示前 8 位。 */
  readonly instanceId: string
  /** 对外宣告的 `wss://host[:port]` origin。 */
  readonly origin: string
  /** wss 监听端口；USB 段落里的 `adb reverse` 与回环配对链接都用它。 */
  readonly port: number
  /** UDP 局域网发现状态（只是展示，页面不控制它）。 */
  readonly discovery: { readonly enabled: boolean; readonly port: number }
  /**
   * wss 监听是否在服务。
   *
   * 控制面在页面被请求时已经起来，因此宿主装配方在页面生命周期内恒传 `true`；单独给字段
   * 是为了让本机插件能明确读到「宿主在监听」，而不是从端口号是否大于 0 去猜。
   */
  readonly listening: boolean
}

/**
 * 配对页的数据源：由装配方（`./index.ts`）注入。
 *
 * 页面不自己判断窗口状态、不读设备表、不关连接——它只把宿主给出的这些事实画出来，
 * 并把「重开窗口 / 撤销设备」转成宿主已有的动作，避免两套配对语义漂移。
 */
export interface PairingPageSource {
  /**
   * 当前打开的配对窗口。
   * @returns 打开中的票据；没有打开过、已被消费或已过期时为 undefined。
   */
  currentPairing(): PairingPageTicket | undefined

  /**
   * 打开新的配对窗口（复用宿主 `pair()` 的既有逻辑：旧窗口立即失效并写日志）。
   * @returns 新窗口的票据。
   */
  pair(): PairingPageTicket

  /** @returns 已配对设备摘要（含已撤销与已过期），不含令牌摘要。 */
  devices(): readonly DeviceSummary[]

  /**
   * 撤销一台设备（宿主先落盘删除 → 关闭连接 → 推 `remote.deviceRevoked`）。
   * @param deviceId - 32 位小写十六进制设备 id。
   * @returns 撤销是否生效与被关闭的连接数。
   */
  revokeDevice(deviceId: string): Promise<RemoteDeviceRevokeResult>

  /** @returns 宿主身份、origin 与监听信息。 */
  host(): PairingPageHost
}

/** {@link PairingPageServer} 的构造参数。 */
export interface PairingPageOptions {
  /** HTTP 端口；0 表示交给系统分配（只用于测试与本地调试）。 */
  readonly port: number
  /** 宿主侧事实与动作。 */
  readonly source: PairingPageSource
  /** 结构化日志接收器；省略时写 stderr。 */
  readonly log?: RemoteLogger
  /** 时钟来源，默认 `Date.now`；自检可替换。 */
  readonly now?: () => number
}

/** 一次启动的结论；`listening:false` 表示页面没起来，宿主照常运行。 */
export type PairingPageStart =
  | { readonly listening: true; readonly port: number; readonly url: string }
  | { readonly listening: false }

/**
 * `/api/state` 里当前窗口的 JSON 投影。
 *
 * 四个字段在两种状态下都出现（关闭时是 `null`），本机控制面客户端因此不需要处理
 * 缺失字段；`usbPairUrl` 与顶层同名字段是同一份事实，顶层那个是兼容旧消费者的副本。
 */
export type PairingPagePairingState =
  | {
    readonly open: false
    readonly expiresAt: null
    readonly pairUrl: null
    readonly usbPairUrl: null
  }
  | {
    readonly open: true
    readonly expiresAt: number
    readonly pairUrl: string
    readonly usbPairUrl: string
  }

/** `/api/state` 的 JSON 内容；不包含设备令牌或令牌摘要。 */
export interface PairingPageState {
  /** 宿主身份、wss 监听端口、对外 origin 与发现状态（供本机控制面客户端使用）。 */
  readonly host: PairingPageHost
  /** 当前配对窗口；`open: false` 表示没有可用窗口（未打开/已过期/已被消费）。 */
  readonly pairing: PairingPagePairingState
  /** USB 回环配对链接（`pairing.usbPairUrl` 的顶层兼容副本）；窗口未打开时为 null。 */
  readonly usbPairUrl: string | null
  /** 已配对设备摘要。 */
  readonly devices: readonly DeviceSummary[]
}

/** 渲染页面时现取的全部事实。 */
interface PageSnapshot {
  /** 宿主身份与监听信息。 */
  readonly host: PairingPageHost
  /** 打开的窗口；没有时为 undefined。 */
  readonly pairing: PairingPageTicket | undefined
  /** 设备摘要列表。 */
  readonly devices: readonly DeviceSummary[]
  /** 当前时间（Unix 毫秒）。 */
  readonly now: number
}

/**
 * 请求体读取的结论。
 *
 * `too-large` 与 `read-failed` 分开：前者回 413、后者回 400，两者都不再读请求体。
 */
type BodyRead =
  | { readonly ok: true; readonly text: string }
  | { readonly ok: false; readonly reason: 'too-large' | 'read-failed' }

/** 页面表单 POST 的动作名（日志 `pairing-page-action.fields.action`）。 */
type FormAction = 'pair-reopen' | 'device-revoke'

/** 控制 API 的动作名（日志 `pairing-page-action.fields.action`）。 */
type ControlAction = 'api-pair' | 'api-device-revoke'

/**
 * 本机配对设置页服务。
 *
 * 生命周期与宿主一致：`start()` 绑定 `127.0.0.1` 并开始服务，`stop()` 关闭监听并断开
 * 现存连接（含浏览器 keep-alive）。启动失败不抛出，写 warn 后返回 `listening:false`。
 */
export class PairingPageServer {
  /** 本进程唯一的 CSRF token；只出现在本页 HTML 的表单隐藏字段里。 */
  private readonly csrfToken = randomBytes(32).toString('base64url')
  private readonly requestedPort: number
  private readonly source: PairingPageSource
  private readonly log: RemoteLogger
  private readonly now: () => number
  private server: Server | undefined
  private boundPort: number | undefined

  /**
   * @param options - 端口、数据源与日志出口。
   * @throws 端口不是 0–65535 的整数时抛出：这是装配错误，不做静默兜底。
   */
  constructor(options: PairingPageOptions) {
    if (!Number.isSafeInteger(options.port) || options.port < 0 || options.port > 65_535) {
      throw new Error(`配对页端口必须是 0–65535 的整数（收到 ${String(options.port)}）。`)
    }
    this.requestedPort = options.port
    this.source = options.source
    this.log = options.log ?? writeRemoteLog
    this.now = options.now ?? Date.now
  }

  /** @returns 已绑定的 HTTP 端口；没有在监听时为 undefined。 */
  get port(): number | undefined {
    return this.boundPort
  }

  /** @returns 浏览器打开用的完整 URL；没有在监听时为 undefined。 */
  get url(): string | undefined {
    return this.boundPort === undefined ? undefined : pageUrl(this.boundPort)
  }

  /**
   * 绑定回环端口并开始服务。
   *
   * 幂等：已经在监听时直接返回同一个结论。绑定失败只写一条 warn 日志并返回
   * `{listening:false}`，不抛错、不影响宿主启动。
   * @returns 监听状态、实际端口与页面 URL。
   */
  start(): Promise<PairingPageStart> {
    const existing = this.server
    if (existing !== undefined) {
      const port = this.boundPort ?? this.requestedPort
      return Promise.resolve({ listening: true, port, url: pageUrl(port) })
    }
    const server = createServer((request, response) => {
      void this.respond(request, response)
    })
    this.server = server
    return new Promise<PairingPageStart>((resolve) => {
      const settle = settleOnce(resolve)
      const fail = (error: unknown, phase: string): void => {
        this.server = undefined
        this.boundPort = undefined
        closeServer(server, this.log)
        this.log({
          level: 'warn',
          event: 'pairing-page-failed',
          message: '本机配对页没有起来（回环 HTTP 端口绑定失败），宿主照常启动；配对链接仍会写进日志。',
          fields: { port: this.requestedPort, address: PAGE_BIND_ADDRESS, phase, error: describeRemoteError(error) },
        })
        settle({ listening: false })
      }
      server.on('error', (error: Error) => {
        // 已经停止或已经判定失败的服务器（含关闭过程中的迟到错误）不再处理。
        if (this.server !== server) return
        // 绑定阶段失败才是「页面没起来」；监听期间的套接字错误只降级记录，不拆掉宿主。
        if (this.boundPort === undefined) {
          fail(error, 'bind')
          return
        }
        this.log({
          level: 'warn',
          event: 'pairing-page-failed',
          message: '本机配对页的 HTTP 监听出错，页面可能已不可用；远程连接不受影响。',
          fields: { port: this.boundPort, phase: 'runtime', error: describeRemoteError(error) },
        })
      })
      try {
        server.listen(this.requestedPort, PAGE_BIND_ADDRESS, () => {
          const address: AddressInfo | string | null = server.address()
          const port = typeof address === 'object' && address !== null ? address.port : this.requestedPort
          this.boundPort = port
          // 页面是增强能力：不能因为一个 HTTP 监听把宿主进程留在事件循环里。
          server.unref()
          const url = pageUrl(port)
          this.log({
            level: 'info',
            event: 'pairing-page-ready',
            message: `本机配对页已就绪：在电脑浏览器打开 ${url}（只监听 ${PAGE_BIND_ADDRESS}）。`,
            fields: { url, port, address: PAGE_BIND_ADDRESS },
          })
          settle({ listening: true, port, url })
        })
      } catch (error) {
        // 部分平台对非法绑定参数是同步抛出：与异步 bind 失败同一种处理。
        fail(error, 'bind-sync')
      }
    })
  }

  /**
   * 停止服务并断开全部连接（含浏览器 keep-alive），幂等。
   * @returns 关闭完成后兑现。
   */
  stop(): Promise<void> {
    const server = this.server
    this.server = undefined
    this.boundPort = undefined
    if (server === undefined) return Promise.resolve()
    return new Promise<void>((resolve) => {
      let settled = false
      const settle = (): void => {
        if (settled) return
        settled = true
        resolve()
      }
      try {
        server.close(() => {
          settle()
        })
        // 插件卸载时不等浏览器主动断开 keep-alive 连接。
        server.closeAllConnections()
      } catch (error) {
        this.log({
          level: 'warn',
          event: 'pairing-page-failed',
          message: '关闭本机配对页失败，回环端口可能仍被占用。',
          fields: { error: describeRemoteError(error) },
        })
        settle()
      }
    })
  }

  /**
   * 处理一个请求；任何内部失败都收敛成 500，不让异常逃到 HTTP 服务器的回调里。
   * @param request - 入站请求。
   * @param response - 待写响应。
   */
  private async respond(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      await this.route(request, response)
    } catch (error) {
      this.log({
        level: 'error',
        event: 'pairing-page-failed',
        message: '本机配对页处理请求失败。',
        fields: { phase: 'request', error: describeRemoteError(error) },
      })
      if (response.headersSent) response.destroy()
      else this.send(response, 500, TEXT_CONTENT_TYPE, '本机配对页内部错误，详情见宿主日志。')
    }
  }

  /**
   * 路由一个请求。
   *
   * 校验顺序固定：Host → Origin → 路径 → 方法 → 表单/CSRF。Host 与 Origin 不读请求体，
   * 所以被拒绝的跨站请求不会消耗内存。
   * @param request - 入站请求。
   * @param response - 待写响应。
   */
  private async route(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const boundPort = this.boundPort
    if (boundPort === undefined) {
      this.send(response, 503, TEXT_CONTENT_TYPE, '本机配对页还没有就绪。')
      return
    }
    const method = request.method ?? ''
    if (!allowedHostHeader(request.headers.host, boundPort)) {
      this.logRejected(method, 'request', 'host')
      this.send(
        response,
        403,
        TEXT_CONTENT_TYPE,
        'Host 头不在允许范围：本页只接受 127.0.0.1:<端口> 或 localhost:<端口>。',
      )
      return
    }
    if (!allowedOriginHeader(request.headers.origin, boundPort)) {
      this.logRejected(method, 'request', 'origin')
      this.send(response, 403, TEXT_CONTENT_TYPE, '请求来源不在允许范围：本页不提供跨站访问。')
      return
    }
    let pathname: string
    try {
      pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname
    } catch {
      this.send(response, 400, TEXT_CONTENT_TYPE, '请求路径不合法。')
      return
    }
    switch (pathname) {
      case '/':
        if (method !== 'GET') {
          this.methodNotAllowed(response, 'GET')
          return
        }
        this.send(response, 200, HTML_CONTENT_TYPE, this.renderHome(this.snapshot()))
        return
      case '/api/state':
        if (method !== 'GET') {
          this.methodNotAllowed(response, 'GET')
          return
        }
        this.sendJson(response, 200, this.buildState(this.snapshot()))
        return
      case '/api/pair':
        if (method !== 'POST') {
          this.methodNotAllowed(response, 'POST')
          return
        }
        if (!this.allowedControlHeader(request, response, method, 'api-pair')) return
        await this.handleApiPair(request, response)
        return
      case '/api/devices/revoke':
        if (method !== 'POST') {
          this.methodNotAllowed(response, 'POST')
          return
        }
        if (!this.allowedControlHeader(request, response, method, 'api-device-revoke')) return
        await this.handleApiRevoke(request, response)
        return
      case '/qr.svg':
        if (method !== 'GET') {
          this.methodNotAllowed(response, 'GET')
          return
        }
        this.handleQrSvg(response)
        return
      case '/pair/reopen':
        if (method !== 'POST') {
          this.methodNotAllowed(response, 'POST')
          return
        }
        await this.handleFormPost(request, response, 'pair-reopen')
        return
      case '/devices/revoke':
        if (method !== 'POST') {
          this.methodNotAllowed(response, 'POST')
          return
        }
        await this.handleFormPost(request, response, 'device-revoke')
        return
      default:
        this.send(response, 404, TEXT_CONTENT_TYPE, '没有这个页面。')
    }
  }

  /**
   * 校验控制 API 的自定义头。
   *
   * 只对 `POST /api/pair` 与 `POST /api/devices/revoke` 生效：跨站表单无法设置自定义头，
   * 跨站 fetch 设置它会先发本页不实现的 CORS 预检，两条路都到不了这里。这不是鉴权——
   * 同机进程可以照抄这个头，威胁模型见模块注释。
   * @param request - 入站请求。
   * @param response - 待写响应。
   * @param method - 请求方法（用于日志）。
   * @param action - 动作名（用于日志）。
   * @returns 通过时为 true；已写 403 响应时为 false。
   */
  private allowedControlHeader(
    request: IncomingMessage,
    response: ServerResponse,
    method: string,
    action: ControlAction,
  ): boolean {
    const value = request.headers[CONTROL_HEADER]
    if (value === CONTROL_HEADER_VALUE) return true
    this.logRejected(method, action, 'control-header')
    this.sendJsonError(
      response,
      403,
      'control-header-required',
      `控制 API 需要请求头 ${CONTROL_HEADER}: ${CONTROL_HEADER_VALUE}。`,
    )
    return false
  }

  /**
   * `POST /api/pair`：打开/重开配对窗口并回最新 state（本机插件用，等价页面表单 `/pair/reopen`）。
   * @param request - 入站请求。
   * @param response - 待写响应。
   * @returns 响应写完后兑现。
   */
  private async handleApiPair(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = await this.readControlBody(request, response, 'api-pair')
    if (body === undefined) return
    try {
      this.source.pair()
    } catch (error) {
      this.log({
        level: 'error',
        event: 'pairing-page-action',
        message: '控制 API 打开配对窗口失败。',
        fields: { action: 'api-pair', method: 'POST', result: 'failed', error: describeRemoteError(error) },
      })
      this.sendJsonError(response, 500, 'pair-failed', '打开配对窗口失败，详情见宿主日志。')
      return
    }
    this.log({
      level: 'info',
      event: 'pairing-page-action',
      message: '控制 API 重新打开了配对窗口（配对令牌不写进日志）。',
      fields: { action: 'api-pair', method: 'POST', result: 'ok' },
    })
    this.sendJson(response, 200, this.buildState(this.snapshot()))
  }

  /**
   * `POST /api/devices/revoke`：撤销设备并回最新 state（本机插件用）。
   *
   * 与页面表单的差别只在响应体：表单 303 回页面，这里 200 回 state，并区分
   * 「记录不存在」（404）与「已经撤销」（409），让插件能展示准确原因。
   * @param request - 入站请求。
   * @param response - 待写响应。
   * @returns 响应写完后兑现。
   */
  private async handleApiRevoke(request: IncomingMessage, response: ServerResponse): Promise<void> {
    if (!isJsonContentType(request.headers['content-type'])) {
      this.logRejected('POST', 'api-device-revoke', 'content-type')
      this.sendJsonError(response, 415, 'unsupported-media-type', '只接受 application/json 请求体。')
      return
    }
    const json = await this.readControlBody(request, response, 'api-device-revoke')
    if (json === undefined) return
    const deviceId = deviceIdFromJson(json)
    if (deviceId === undefined) {
      this.logRejected('POST', 'api-device-revoke', 'device-id')
      this.sendJsonError(response, 400, 'invalid-request', 'deviceId 必须是 32 位小写十六进制。')
      return
    }
    const existing = this.source.devices().find(device => device.id === deviceId)
    if (existing !== undefined && existing.revokedAt !== undefined) {
      this.logRejected('POST', 'api-device-revoke', 'already-revoked')
      this.sendJsonError(response, 409, 'device-already-revoked', '这台设备已经撤销过了。')
      return
    }
    let result: RemoteDeviceRevokeResult
    try {
      result = await this.source.revokeDevice(deviceId)
    } catch (error) {
      this.log({
        level: 'error',
        event: 'pairing-page-action',
        message: '控制 API 撤销设备失败。',
        fields: {
          action: 'api-device-revoke',
          method: 'POST',
          result: 'failed',
          deviceId,
          error: describeRemoteError(error),
        },
      })
      this.sendJsonError(response, 500, 'revoke-failed', '撤销设备失败，详情见宿主日志。')
      return
    }
    if (!result.revoked) {
      this.logRejected('POST', 'api-device-revoke', 'not-found')
      this.sendJsonError(response, 404, 'device-not-found', '没有找到这台设备。')
      return
    }
    this.log({
      level: 'info',
      event: 'pairing-page-action',
      message: '控制 API 撤销了一台设备，已通知它的在线连接。',
      fields: {
        action: 'api-device-revoke',
        method: 'POST',
        result: 'revoked',
        deviceId,
        closedConnections: result.closed,
      },
    })
    this.sendJson(response, 200, this.buildState(this.snapshot()))
  }

  /**
   * 读取并校验控制 API 的请求体（空体视为 `{}`；非空必须是 JSON 对象）。
   * @param request - 入站请求。
   * @param response - 待写响应。
   * @param action - 动作名（用于日志）。
   * @returns 解析后的 JSON 对象；已经写过错误响应时为 undefined。
   */
  private async readControlBody(
    request: IncomingMessage,
    response: ServerResponse,
    action: ControlAction,
  ): Promise<Record<string, unknown> | undefined> {
    const body = await readBody(request, MAXIMUM_CONTROL_BODY_BYTES)
    if (!body.ok) {
      const tooLarge = body.reason === 'too-large'
      this.logRejected('POST', action, body.reason)
      this.sendJsonError(
        response,
        tooLarge ? 413 : 400,
        tooLarge ? 'body-too-large' : 'invalid-request',
        tooLarge ? `请求体超过 ${MAXIMUM_CONTROL_BODY_BYTES} 字节上限。` : '请求体读取失败。',
      )
      return undefined
    }
    const text = body.text.trim()
    if (text === '') return {}
    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch {
      this.logRejected('POST', action, 'json')
      this.sendJsonError(response, 400, 'invalid-request', '请求体必须是 JSON 对象。')
      return undefined
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      this.logRejected('POST', action, 'json')
      this.sendJsonError(response, 400, 'invalid-request', '请求体必须是 JSON 对象。')
      return undefined
    }
    return parsed as Record<string, unknown>
  }

  /**
   * `GET /qr.svg`：当前打开窗口 pairUrl 的二维码 SVG。
   *
   * 供本机插件的设置页用 `<img src>` 直接展示（跨源 `<img>` 不需要 CORS，也不能带自定义头）；
   * 只依赖 Host 校验，不要求控制头。窗口未打开时 404，页面本身与 /api/state 仍是权威来源。
   * @param response - 待写响应。
   */
  private handleQrSvg(response: ServerResponse): void {
    const pairing = this.source.currentPairing()
    if (pairing === undefined) {
      this.send(response, 404, TEXT_CONTENT_TYPE, '当前没有打开的配对窗口：请先在电脑上打开配对窗口。')
      return
    }
    let svg: string
    try {
      svg = renderPairingQrSvg(pairing.pairUrl)
    } catch (error) {
      this.log({
        level: 'warn',
        event: 'pairing-page-failed',
        message: '二维码端点没有生成二维码：配对链接超出内置编码器的容量。',
        fields: { phase: 'qr', error: describeRemoteError(error) },
      })
      this.send(response, 500, TEXT_CONTENT_TYPE, '二维码没有生成：配对链接太长，请直接使用配对链接。')
      return
    }
    this.send(response, 200, SVG_CONTENT_TYPE, svg)
  }

  /**
   * 处理两个 POST 动作的公共前置：表单类型 → 体积 → CSRF。
   * @param request - 入站请求。
   * @param response - 待写响应。
   * @param action - 要执行的动作。
   */
  private async handleFormPost(
    request: IncomingMessage,
    response: ServerResponse,
    action: FormAction,
  ): Promise<void> {
    if (!isFormContentType(request.headers['content-type'])) {
      this.logRejected('POST', action, 'content-type')
      this.send(response, 415, TEXT_CONTENT_TYPE, '只接受 application/x-www-form-urlencoded 表单提交。')
      return
    }
    const body = await readBody(request, MAXIMUM_FORM_BYTES)
    if (!body.ok) {
      const tooLarge = body.reason === 'too-large'
      this.logRejected('POST', action, body.reason)
      this.send(
        response,
        tooLarge ? 413 : 400,
        TEXT_CONTENT_TYPE,
        tooLarge ? `表单内容超过 ${MAXIMUM_FORM_BYTES} 字节上限。` : '表单内容读取失败。',
      )
      return
    }
    const params = new URLSearchParams(body.text)
    if (!this.verifyCsrf(singleField(params, CSRF_FIELD))) {
      this.logRejected('POST', action, 'csrf')
      this.send(response, 403, TEXT_CONTENT_TYPE, '缺少或不匹配的 CSRF token，请求已被拒绝。')
      return
    }
    if (action === 'pair-reopen') {
      this.reopenPairing(response)
      return
    }
    const deviceId = singleField(params, 'id')
    if (deviceId === undefined || !DEVICE_ID_PATTERN.test(deviceId)) {
      this.logRejected('POST', action, 'device-id')
      this.send(response, 400, TEXT_CONTENT_TYPE, '设备 id 不合法。')
      return
    }
    await this.revokeDevice(response, deviceId)
  }

  /**
   * 重开配对窗口并回 303；失败回 500，错误只进日志。
   * @param response - 待写响应。
   */
  private reopenPairing(response: ServerResponse): void {
    try {
      this.source.pair()
    } catch (error) {
      this.log({
        level: 'error',
        event: 'pairing-page-action',
        message: '本机配对页重开配对窗口失败。',
        fields: { action: 'pair-reopen', method: 'POST', result: 'failed', error: describeRemoteError(error) },
      })
      this.send(response, 500, TEXT_CONTENT_TYPE, '打开配对窗口失败，详情见宿主日志。')
      return
    }
    this.log({
      level: 'info',
      event: 'pairing-page-action',
      message: '本机配对页重新打开了配对窗口（配对令牌不写进日志）。',
      fields: { action: 'pair-reopen', method: 'POST', result: 'ok' },
    })
    this.redirect(response)
  }

  /**
   * 撤销设备并回 303；宿主负责落盘、关连接与推送 `remote.deviceRevoked`。
   * @param response - 待写响应。
   * @param deviceId - 已通过形态校验的设备 id。
   */
  private async revokeDevice(response: ServerResponse, deviceId: string): Promise<void> {
    let result: RemoteDeviceRevokeResult
    try {
      result = await this.source.revokeDevice(deviceId)
    } catch (error) {
      this.log({
        level: 'error',
        event: 'pairing-page-action',
        message: '本机配对页撤销设备失败。',
        fields: {
          action: 'device-revoke',
          method: 'POST',
          result: 'failed',
          deviceId,
          error: describeRemoteError(error),
        },
      })
      this.send(response, 500, TEXT_CONTENT_TYPE, '撤销设备失败，详情见宿主日志。')
      return
    }
    this.log({
      level: 'info',
      event: 'pairing-page-action',
      message: result.revoked
        ? '本机配对页撤销了一台设备，已通知它的在线连接。'
        : '本机配对页尝试撤销设备，但该设备已不在有效列表中。',
      fields: { action: 'device-revoke', method: 'POST', result: result.revoked ? 'revoked' : 'not-revoked', deviceId, closedConnections: result.closed },
    })
    this.redirect(response)
  }

  /**
   * 记一条「请求被拒绝」的动作日志；不记录 token 本身。
   * @param method - 请求方法。
   * @param action - 命中的动作或 `request`。
   * @param reason - 拒绝原因。
   */
  private logRejected(method: string, action: string, reason: string): void {
    this.log({
      level: 'warn',
      event: 'pairing-page-action',
      message: `本机配对页拒绝了一次请求：${reason}。`,
      fields: { action, method, result: 'rejected', reason },
    })
  }

  /**
   * 回 405 并给出允许的方法；不带 CORS 头。
   * @param response - 待写响应。
   * @param allowed - 该路径允许的方法。
   */
  private methodNotAllowed(response: ServerResponse, allowed: string): void {
    this.send(response, 405, TEXT_CONTENT_TYPE, `只允许 ${allowed}。`, { Allow: allowed })
  }

  /**
   * 写一个带统一防护头的响应。
   * @param response - 待写响应。
   * @param status - HTTP 状态码。
   * @param contentType - `Content-Type` 值。
   * @param body - UTF-8 响应体。
   * @param extra - 额外的响应头（例如 `Allow`、`Location`）。
   */
  private send(
    response: ServerResponse,
    status: number,
    contentType: string,
    body: string,
    extra: Readonly<Record<string, string>> = {},
  ): void {
    const payload = Buffer.from(body, 'utf8')
    response.writeHead(status, {
      ...SECURITY_HEADERS,
      'Content-Type': contentType,
      'Content-Length': String(payload.length),
      ...extra,
    })
    response.end(payload)
  }

  /**
   * 写 JSON 响应。
   * @param response - 待写响应。
   * @param status - HTTP 状态码。
   * @param value - 要序列化的值。
   */
  private sendJson(response: ServerResponse, status: number, value: unknown): void {
    this.send(response, status, JSON_CONTENT_TYPE, JSON.stringify(value))
  }

  /**
   * 写控制 API 的统一错误体 `{"error":{"code","message"}}`。
   * @param response - 待写响应。
   * @param status - HTTP 状态码。
   * @param code - 稳定的机器可读错误码。
   * @param message - 可直接展示的中文说明。
   */
  private sendJsonError(response: ServerResponse, status: number, code: string, message: string): void {
    this.sendJson(response, status, { error: { code, message } })
  }

  /**
   * 303 重定向回 `/`（POST → GET，刷新后看到新的窗口与设备状态）。
   * @param response - 待写响应。
   */
  private redirect(response: ServerResponse): void {
    response.writeHead(303, { ...SECURITY_HEADERS, Location: '/', 'Content-Length': '0' })
    response.end()
  }

  /**
   * 校验 POST 表单里的 CSRF token。
   * @param token - 表单里的 `csrf` 字段；缺失为 undefined。
   * @returns 长度与内容都匹配时为 true。
   */
  private verifyCsrf(token: string | undefined): boolean {
    if (token === undefined) return false
    const expected = Buffer.from(this.csrfToken, 'utf8')
    const actual = Buffer.from(token, 'utf8')
    if (actual.length !== expected.length) return false
    return timingSafeEqual(actual, expected)
  }

  /** @returns 渲染与 JSON 共用的当前事实。 */
  private snapshot(): PageSnapshot {
    return {
      host: this.source.host(),
      pairing: this.source.currentPairing(),
      devices: this.source.devices(),
      now: this.now(),
    }
  }

  /**
   * 把快照投影成 `/api/state` 的 JSON。
   * @param snapshot - 当前事实。
   * @returns 不含令牌摘要的页面状态。
   */
  private buildState(snapshot: PageSnapshot): PairingPageState {
    const { host, pairing, devices } = snapshot
    if (pairing === undefined) {
      return {
        host,
        pairing: { open: false, expiresAt: null, pairUrl: null, usbPairUrl: null },
        usbPairUrl: null,
        devices,
      }
    }
    return {
      host,
      pairing: {
        open: true,
        expiresAt: pairing.expiresAt,
        pairUrl: pairing.pairUrl,
        usbPairUrl: pairing.usbPairUrl,
      },
      usbPairUrl: pairing.usbPairUrl,
      devices,
    }
  }

  /**
   * 服务端渲染整页 HTML。
   * @param snapshot - 当前事实。
   * @returns 完整 HTML 文档。
   */
  private renderHome(snapshot: PageSnapshot): string {
    const { host, pairing, devices, now } = snapshot
    const csrf = escapeHtml(this.csrfToken)
    const deviceCount = devices.length
    const deviceList = deviceCount === 0
      ? '<p class="muted">还没有配对过的设备。</p>'
      : this.renderDeviceTable(devices, csrf, now)
    const pairingBody = pairing === undefined
      ? '<p class="muted">二维码会在打开配对窗口后显示。</p>'
      : renderPairingOpenBody(host, pairing, now, this.renderPairingQr(pairing.pairUrl))
    const initialState = JSON.stringify(
      pairing === undefined
        ? { open: false, deviceCount }
        : { open: true, deviceCount, expiresAt: pairing.expiresAt },
    ).replace(/</gu, '\\u003c')
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>远程 DSH · 本机配对页</title>
<style>
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { margin: 0; padding: 32px 16px 64px; font: 14px/1.7 system-ui, -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif; background: #f4f5f7; color: #1d1f23; }
main { max-width: 760px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 16px; margin: 0 0 12px; }
h3 { font-size: 14px; margin: 20px 0 8px; }
p { margin: 8px 0; }
.muted { color: #6b7280; }
.warn { color: #b45309; }
code, textarea { font-family: ui-monospace, "Cascadia Mono", Consolas, monospace; }
code { background: #eceef1; border-radius: 4px; padding: 1px 5px; word-break: break-all; }
.card { background: #fff; border: 1px solid #e2e4e8; border-radius: 12px; padding: 20px; margin: 16px 0; }
.status strong { font-weight: 600; }
.qr { margin: 16px 0; }
.qr svg { width: 100%; max-width: 320px; height: auto; display: block; border: 1px solid #e2e4e8; border-radius: 8px; padding: 8px; background: #fff; }
textarea { width: 100%; resize: vertical; border: 1px solid #d3d6db; border-radius: 8px; padding: 8px; font-size: 12px; line-height: 1.5; background: #fbfbfc; color: inherit; }
button { font: inherit; border: 1px solid #d3d6db; border-radius: 8px; background: #fff; color: inherit; padding: 6px 14px; cursor: pointer; }
button:hover { background: #f0f1f3; }
button.primary { background: #1d4ed8; border-color: #1d4ed8; color: #fff; }
button.primary:hover { background: #1e40af; }
button.danger { color: #b91c1c; border-color: #f0b4b4; }
button.danger:hover { background: #fef2f2; }
form.inline { display: inline; margin: 0; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid #eceef1; vertical-align: middle; }
th { color: #6b7280; font-weight: 600; white-space: nowrap; }
td.ok { color: #047857; }
td.muted, td.expired { color: #6b7280; }
footer { margin-top: 24px; font-size: 12px; color: #6b7280; }
[hidden] { display: none !important; }
@media (prefers-color-scheme: dark) {
  body { background: #17181b; color: #e6e8eb; }
  .card { background: #1f2125; border-color: #33363c; }
  code { background: #2a2d32; }
  textarea { background: #17181b; border-color: #3a3d44; }
  button { background: #26292e; border-color: #3a3d44; }
  button:hover { background: #2f3339; }
  button.primary { background: #2563eb; border-color: #2563eb; }
  button.danger { color: #f87171; border-color: #7f1d1d; }
  th, td { border-bottom-color: #2f3339; }
}
</style>
</head>
<body>
<main>
  <header>
    <h1>远程 DSH · 本机配对页</h1>
    <p class="muted">宿主 <strong>${escapeHtml(host.name)}</strong> · 实例 <code>${escapeHtml(host.instanceId.slice(0, 8))}</code> · 监听 <code>${escapeHtml(host.origin)}</code></p>
    <p class="muted">局域网发现：${host.discovery.enabled ? `已开启（UDP ${host.discovery.port}）` : '已关闭'} · 本页只监听 <code>${PAGE_BIND_ADDRESS}</code>，只在本机浏览器打开。</p>
  </header>

  <section class="card">
    <h2>配对窗口</h2>
    <div id="pairing-open"${pairing === undefined ? ' hidden' : ''}>${pairingBody}</div>
    <div id="pairing-closed"${pairing === undefined ? '' : ' hidden'}>
      <p class="status">当前没有打开的配对窗口（已过期或已被使用）。</p>
      <p class="muted">点下面的「重新打开配对窗口」生成新的二维码与链接。配对窗口是单次有效的：配好一台手机后需要重新打开，才能配下一台。</p>
    </div>
    <form method="post" action="/pair/reopen">
      <input type="hidden" name="${CSRF_FIELD}" value="${csrf}">
      <button type="submit" class="primary">重新打开配对窗口</button>
    </form>
  </section>

  <section class="card">
    <h2>已配对设备（${deviceCount}）</h2>
    ${deviceList}
  </section>

  <footer>
    <p>安全说明：本页只监听回环地址 127.0.0.1，不建立也不改变任何信任关系；撤销设备后那台手机需要重新配对。</p>
    <p>同一台电脑上的其它进程仍可能读取本页与宿主日志中的配对信息，这属于已接受的本地威胁模型；不要通过端口转发或反向代理把本页暴露给其它机器。</p>
  </footer>
</main>
<script>
(function () {
  var initialState = ${initialState};
  var current = initialState;
  var openBlock = document.getElementById('pairing-open');
  var closedBlock = document.getElementById('pairing-closed');
  var remainingEl = document.getElementById('remaining');

  function applyVisibility(isOpen) {
    if (openBlock) openBlock.hidden = !isOpen;
    if (closedBlock) closedBlock.hidden = isOpen;
  }

  function renderCountdown() {
    if (!current.open) { applyVisibility(false); return; }
    var left = current.expiresAt - Date.now();
    if (left <= 0) { current.open = false; applyVisibility(false); return; }
    if (remainingEl) remainingEl.textContent = String(Math.ceil(left / 1000));
    applyVisibility(true);
  }

  function poll() {
    fetch('/api/state', { cache: 'no-store', credentials: 'same-origin' })
      .then(function (response) { return response.ok ? response.json() : null; })
      .then(function (state) {
        if (!state || !state.pairing) return;
        if (state.devices && state.devices.length !== current.deviceCount) { window.location.reload(); return; }
        var wasOpen = current.open;
        current.open = state.pairing.open === true;
        current.expiresAt = state.pairing.expiresAt;
        if (!wasOpen && current.open) { window.location.reload(); return; }
        if (state.pairing.open !== true) { applyVisibility(false); }
      })
      .catch(function () { /* 轮询失败不影响倒计时；页面保留上次状态 */ });
  }

  function bindCopy(buttonId, fieldId) {
    var button = document.getElementById(buttonId);
    var field = document.getElementById(fieldId);
    if (!button || !field) return;
    button.addEventListener('click', function () {
      var label = button.textContent;
      function flash() {
        button.textContent = '已复制';
        window.setTimeout(function () { button.textContent = label; }, 1500);
      }
      function fallback() {
        field.focus();
        field.select();
        try { if (document.execCommand('copy')) flash(); } catch (error) { /* 用户手动复制 */ }
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(field.value).then(flash, fallback);
      } else {
        fallback();
      }
    });
  }

  bindCopy('copy-pair-link', 'pair-link');
  bindCopy('copy-usb-link', 'usb-link');
  window.setInterval(renderCountdown, 1000);
  window.setInterval(poll, 2000);
  renderCountdown();
})();
</script>
</body>
</html>
`
  }

  /**
   * 生成配对链接二维码；链接超出内置编码器容量时降级成一句提示而不是让整页失败。
   * @param pairUrl - 这次窗口的配对链接。
   * @returns 内联 SVG 或降级说明。
   */
  private renderPairingQr(pairUrl: string): string {
    try {
      return renderPairingQrSvg(pairUrl)
    } catch (error) {
      this.log({
        level: 'warn',
        event: 'pairing-page-failed',
        message: '本机配对页绘制二维码失败：配对链接超出内置编码器的容量，页面仍可复制链接。',
        fields: { phase: 'qr', error: describeRemoteError(error) },
      })
      return '<p class="warn">二维码没有生成：配对链接太长，请直接复制下面的链接到 App。</p>'
    }
  }

  /**
   * 渲染一张设备表。
   * @param devices - 设备摘要。
   * @param csrf - 已转义的 CSRF token。
   * @param now - 当前时间（Unix 毫秒）。
   * @returns 表格 HTML。
   */
  private renderDeviceTable(devices: readonly DeviceSummary[], csrf: string, now: number): string {
    const rows = devices.map(device => renderDeviceRow(device, csrf, now)).join('')
    return `<table>
<thead><tr><th>设备名</th><th>设备 id</th><th>配对时间</th><th>最近连接</th><th>状态</th><th>操作</th></tr></thead>
<tbody>${rows}</tbody>
</table>`
  }
}

/**
 * 拼页面的完整 URL。
 * @param port - 已绑定的回环端口。
 * @returns `http://127.0.0.1:<port>/`。
 */
function pageUrl(port: number): string {
  return `http://${PAGE_BIND_ADDRESS}:${port}/`
}

/**
 * 校验 `Host` 头：只接受回环主机名加本页端口（防 DNS rebinding）。
 * @param hostHeader - 请求的 `Host` 头。
 * @param port - 本页实际绑定的端口。
 * @returns 允许时为 true。
 */
function allowedHostHeader(hostHeader: string | undefined, port: number): boolean {
  if (hostHeader === undefined) return false
  const match = /^(127\.0\.0\.1|localhost)(?::(\d{1,5}))?$/u.exec(hostHeader.trim().toLowerCase())
  if (match === null) return false
  const names = ALLOWED_HOST_NAMES
  const name = match[1]
  if (name === undefined || !names.includes(name)) return false
  const rawPort = match[2]
  if (rawPort === undefined) return port === 80
  return Number(rawPort) === port
}

/**
 * 校验 `Origin` 头：省略视为本机直接访问，出现则必须与本页同源。
 * @param originHeader - 请求的 `Origin` 头。
 * @param port - 本页实际绑定的端口。
 * @returns 允许时为 true。
 */
function allowedOriginHeader(originHeader: string | undefined, port: number): boolean {
  if (originHeader === undefined) return true
  const value = originHeader.trim().toLowerCase()
  const allowed = [`http://127.0.0.1:${port}`, `http://localhost:${port}`]
  if (port === 80) allowed.push('http://127.0.0.1', 'http://localhost')
  return allowed.includes(value)
}

/**
 * 判断请求体是不是表单编码。
 * @param contentType - 请求的 `Content-Type` 头。
 * @returns 以 `application/x-www-form-urlencoded` 开头时为 true。
 */
function isFormContentType(contentType: string | undefined): boolean {
  if (contentType === undefined) return false
  const [mediaType] = contentType.split(';')
  return mediaType?.trim().toLowerCase() === 'application/x-www-form-urlencoded'
}

/**
 * 判断请求体是不是 JSON。
 * @param contentType - 请求的 `Content-Type` 头。
 * @returns 以 `application/json` 开头时为 true。
 */
function isJsonContentType(contentType: string | undefined): boolean {
  if (contentType === undefined) return false
  const [mediaType] = contentType.split(';')
  return mediaType?.trim().toLowerCase() === 'application/json'
}

/**
 * 从已解析的 JSON 里取设备 id。
 * @param value - `JSON.parse` 的结果。
 * @returns 32 位小写十六进制设备 id；不是对象或字段形态不对时为 undefined。
 */
function deviceIdFromJson(value: unknown): string | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  const deviceId = (value as Record<string, unknown>).deviceId
  return typeof deviceId === 'string' && DEVICE_ID_PATTERN.test(deviceId) ? deviceId : undefined
}

/**
 * 读取请求体，超过 `limit` 或读取失败时提前结束。
 * @param request - 入站请求。
 * @param limit - 字节上限。
 * @returns 读取结论。
 */
function readBody(request: IncomingMessage, limit: number): Promise<BodyRead> {
  return new Promise<BodyRead>((resolve) => {
    const chunks: Buffer[] = []
    let size = 0
    let tooLarge = false
    const settle = settleOnce(resolve)
    request.on('data', (chunk: Buffer) => {
      // 超限后仍把剩余数据读完（丢弃不再累积），让 413 响应能正常写回。
      if (tooLarge) return
      size += chunk.length
      if (size > limit) {
        tooLarge = true
        settle({ ok: false, reason: 'too-large' })
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => {
      settle({ ok: true, text: Buffer.concat(chunks).toString('utf8') })
    })
    request.on('error', () => {
      settle({ ok: false, reason: 'read-failed' })
    })
  })
}

/**
 * 取唯一一个表单字段；缺失或重复出现都算无效。
 * @param params - 解析后的表单。
 * @param name - 字段名。
 * @returns 唯一的值；没有或不止一个时为 undefined。
 */
function singleField(params: URLSearchParams, name: string): string | undefined {
  const values = params.getAll(name)
  return values.length === 1 ? values[0] : undefined
}

/**
 * 生成只生效一次的回调：重复调用直接丢弃（Promise 只兑现一次）。
 * @param resolve - 等待中的 Promise 的 resolve。
 * @returns 首次调用兑现、之后无副作用的回调。
 */
function settleOnce<T>(resolve: (value: T) => void): (value: T) => void {
  let settled = false
  return (value: T): void => {
    if (settled) return
    settled = true
    resolve(value)
  }
}

/**
 * 关闭一个 HTTP 服务器；失败只记录。
 * @param server - 待关闭的服务器。
 * @param log - 日志出口。
 */
function closeServer(server: Server, log: RemoteLogger): void {
  try {
    server.close()
    server.closeAllConnections()
  } catch (error) {
    log({
      level: 'warn',
      event: 'pairing-page-failed',
      message: '关闭本机配对页的监听失败，回环端口可能仍被短暂占用。',
      fields: { error: describeRemoteError(error) },
    })
  }
}

/**
 * HTML 转义：动态值（设备名、链接、时间）一律转义后再拼进文档。
 * @param value - 原始文本。
 * @returns 转义后的文本。
 */
function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/gu, (character) => {
    switch (character) {
      case '&': return '&amp;'
      case '<': return '&lt;'
      case '>': return '&gt;'
      case '"': return '&quot;'
      default: return '&#39;'
    }
  })
}

/**
 * 把 Unix 毫秒格式化成页面可读的本机时间。
 * @param value - Unix 毫秒。
 * @returns `YYYY-MM-DD HH:mm:ss`；非法时间返回 `—`。
 */
function formatTimestamp(value: number): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '—'
  const pad = (part: number): string => String(part).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} `
    + `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
}

/**
 * 把配对链接编码成二维码并渲染成内联 SVG。
 *
 * 页面内联二维码、`GET /qr.svg` 与宿主包根导出的同名函数都走这一条路径，避免三处各写
 * 一遍编码 + 渲染；纯函数，无 I/O。
 * @param pairUrl - 完整的配对链接（`wss://…#instance=…&token=…`）。
 * @returns 内联 SVG 文本。
 * @throws 链接超出内置编码器容量时抛出（由调用方决定降级方式）。
 */
export function renderPairingQrSvg(pairUrl: string): string {
  return renderQrSvg(encodeQrMatrix(pairUrl))
}

/**
 * 把二维码模块矩阵渲染成内联 SVG。
 *
 * 只依赖矩阵本身：白色安静区 4 个模块，每行连续深色模块合并成一条 path，
 * 浏览器直接按 `viewBox` 缩放，页面不需要任何外部资源。
 * @param matrix - `encodeQrMatrix` 给出的模块矩阵。
 * @returns 内联 SVG 文本。
 * @throws 矩阵行数与边长不一致时抛出。
 */
export function renderQrSvg(matrix: QrMatrix): string {
  const quiet = 4
  const side = matrix.size + quiet * 2
  const commands: string[] = []
  for (let row = 0; row < matrix.size; row += 1) {
    const modules = matrix.modules[row]
    if (modules === undefined || modules.length !== matrix.size) {
      throw new Error(`二维码矩阵第 ${row} 行不完整。`)
    }
    let column = 0
    while (column < matrix.size) {
      if (!modules[column]) {
        column += 1
        continue
      }
      let run = 1
      while (column + run < matrix.size && modules[column + run]) run += 1
      commands.push(`M${column + quiet} ${row + quiet}h${run}v1h-${run}z`)
      column += run
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${side} ${side}" width="320" height="320" shape-rendering="crispEdges" role="img" aria-label="配对二维码"><rect width="${side}" height="${side}" fill="#fff"/><path d="${commands.join('')}" fill="#000"/></svg>`
}

/**
 * 渲染「窗口打开中」的主体：倒计时、二维码、链接、USB 段落。
 *
 * 窗口剩余时间超过 {@link LONG_LIVED_WINDOW_SECONDS} 时不再显示秒级倒计时，只展示真实
 * 过期时间与「长期有效」——长期配对部署的窗口是数天到 90 天，逐秒倒计时没有信息量。
 * @param host - 宿主监听信息（USB 端口取自它）。
 * @param pairing - 打开中的窗口。
 * @param now - 当前时间（Unix 毫秒）。
 * @param qr - 已渲染好的二维码（SVG 或降级说明）。
 * @returns 配对卡片的主体 HTML。
 */
function renderPairingOpenBody(host: PairingPageHost, pairing: PairingPageTicket, now: number, qr: string): string {
  const remaining = Math.max(0, Math.ceil((pairing.expiresAt - now) / 1000))
  const status = remaining > LONG_LIVED_WINDOW_SECONDS
    ? `<p class="status">状态：<strong>打开中</strong> · <strong>长期有效</strong> · 过期时间 <code>${formatTimestamp(pairing.expiresAt)}</code>（本机时间）</p>
<p class="muted">长期窗口等于长期可配对入口：链接发给谁，谁就能配对这台电脑。只适合个人可信网络；不用时关闭宿主或撤销不再使用的设备。</p>`
    : `<p class="status">状态：<strong>打开中</strong> · 剩余 <strong id="remaining">${remaining}</strong> 秒 · 过期时间 <code>${formatTimestamp(pairing.expiresAt)}</code>（本机时间）</p>`
  const adbCommand = `adb reverse tcp:${host.port} tcp:${host.port}`
  return `${status}
<p>手机 App →「添加连接」→「扫码配对」，扫描下面的二维码；或复制链接粘贴到 App 的配对页。</p>
<div class="qr">${qr}</div>
<textarea id="pair-link" readonly rows="3">${escapeHtml(pairing.pairUrl)}</textarea>
<p><button type="button" id="copy-pair-link">复制配对链接</button></p>
<h3>USB 连接（手机与电脑不在同一网段）</h3>
<p>在电脑上执行 <code>${adbCommand}</code>，让手机的 <code>127.0.0.1:${host.port}</code> 转发到本机；然后在 App 配对页粘贴下面这一行（回环地址的同一张配对票据）：</p>
<textarea id="usb-link" readonly rows="3">${escapeHtml(pairing.usbPairUrl)}</textarea>
<p><button type="button" id="copy-usb-link">复制 USB 配对链接</button></p>`
}

/**
 * 渲染设备表的一行；只有仍有效的设备给撤销按钮。
 * @param device - 设备摘要。
 * @param csrf - 已转义的 CSRF token。
 * @param now - 当前时间（Unix 毫秒）。
 * @returns 表格行 HTML。
 */
function renderDeviceRow(device: DeviceSummary, csrf: string, now: number): string {
  const active = device.revokedAt === undefined && device.expiresAt > now
  const status = device.revokedAt !== undefined ? '已撤销' : active ? '有效' : '已过期'
  const statusClass = device.revokedAt !== undefined ? 'muted' : active ? 'ok' : 'expired'
  const action = active
    ? `<form class="inline" method="post" action="/devices/revoke" onsubmit="return confirm('撤销后这台手机需要重新配对才能连接，确定撤销吗？')">
<input type="hidden" name="${CSRF_FIELD}" value="${csrf}">
<input type="hidden" name="id" value="${escapeHtml(device.id)}">
<button type="submit" class="danger">撤销</button>
</form>`
    : '—'
  return `<tr><td>${escapeHtml(device.label)}</td><td><code title="${escapeHtml(device.id)}">${escapeHtml(device.id.slice(0, 8))}</code></td><td>${formatTimestamp(device.createdAt)}</td><td>${formatTimestamp(device.lastSeenAt)}</td><td class="${statusClass}">${status}</td><td>${action}</td></tr>`
}
