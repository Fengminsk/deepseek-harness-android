/**
 * 本机配对页自检：证明 `../src/pairing-page.ts` 的 HTML/JSON 契约、回环防护与控制 API 成立。
 *
 * 运行：`node --import tsx/esm apps/remote-host/scripts/pairing-page-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本只监听 127.0.0.1 的临时端口，不写文件、
 * 不占固定端口、不需要 DSH_HOME 或 TLS 材料（数据源是内存里的假实现）。
 *
 * 覆盖：
 * 1. 启动绑定回环临时端口并记录 `pairing-page-ready`（URL 含完整端口，不含令牌）；
 * 2. `GET /` 单页 HTML：配对状态/倒计时/过期时间、内联二维码 SVG、明文链接、USB
 *    `adb reverse` 段落、设备列表（label / id 前缀 / 时间）、CSRF 隐藏字段；设备名按 HTML 转义；
 *    长窗口（> 1 小时）显示「长期有效」而不是秒级倒计时；
 * 3. `GET /api/state` 的字段集合（`host` / `pairing` / 顶层 `usbPairUrl` / `devices`）、
 *    窗口打开/关闭两种形态、`host` 的监听事实、不出现令牌摘要；
 * 4. 响应头：nosniff / no-store / CSP / 无 CORS（页面、JSON 与 `/qr.svg`）；
 * 5. 窗口过期后页面、JSON 与 `/qr.svg` 都不再带配对链接；
 * 6. `POST /pair/reopen` 303 后窗口换新令牌；`POST /devices/revoke` 303 后调用撤销并
 *    模拟推送 `remote.deviceRevoked`，页面与 JSON 反映已撤销；
 * 7. 控制 API：`GET /qr.svg` 返回与 `renderPairingQrSvg` 一致的内联 SVG（无需控制头、query 忽略）；
 *    `POST /api/pair` 带 `x-dsh-pairing-control: 1` → 200 + 最新 state；缺头/错头 → 403 且无副作用；
 *    `POST /api/devices/revoke` JSON → 200 + 最新 state，并区分 415/400/404/409；
 * 8. 防护：伪造 `Host`（含缺 Host）/ 跨站 `Origin` / 缺或错 CSRF / 非表单内容 /
 *    超大表单体 / 方法错误 / 未知路径，全部 4xx，且被拒绝的动作不产生副作用；
 * 9. 动作失败回 500 且日志 `result=failed`；日志与两台实例的 CSRF token 都不外泄；
 * 10. 生命周期：stop 释放端口、重复 start 复用同一进程级 CSRF token；端口被占用时
 *    `start()` 返回 `listening:false` 且只记 warn，不抛错、不影响进程。
 *
 * 为什么用假数据源：本文件验证的是页面本身的路由、防护与渲染；宿主侧的窗口记账、长期配对
 * 自动续开与撤销语义由 `pairing-longterm-selfcheck.ts` 与 `smoke-remote-host.ts` 覆盖，
 * 这里不重复造栈。
 * @module @deepseek-ai/dsh-remote-host/scripts/pairing-page-selfcheck
 */

import {
  createServer as createHttpServer,
  request as createRequest,
  type IncomingHttpHeaders,
  type Server,
} from 'node:http'
import { connect as connectTcp } from 'node:net'
import type { DeviceSummary } from '../src/devices.ts'
import { encodeQrMatrix } from '../src/pairing-qr.ts'
import { PairingPageServer, renderPairingQrSvg, type PairingPageHost, type PairingPageSource, type PairingPageTicket } from '../src/pairing-page.ts'
import type { RemoteDeviceDeleteResult, RemoteDeviceRevokeResult, RemoteLogRecord } from '../src/server.ts'

/** 自检用的宿主显示名。 */
const SAMPLE_HOST_NAME = 'DESKTOP-SELFCHECK'

/** 自检用的 instanceId（64 位小写十六进制）。 */
const SAMPLE_INSTANCE_ID = 'e'.repeat(64)

/** 自检用的对外 origin。 */
const SAMPLE_ORIGIN = 'wss://192.168.5.21:4777'

/** 自检用的 wss 监听端口（配对链接与 adb reverse 段落里的端口）。 */
const SAMPLE_WSS_PORT = 4777

/** 自检用的配对窗口有效期（毫秒）。 */
const PAIRING_TTL_MS = 120_000

/** 自检用的长期配对窗口有效期（30 天，远大于「长期有效」展示阈值）。 */
const LONG_PAIRING_TTL_MS = 30 * 24 * 60 * 60 * 1000

/** 控制 API 的自定义头（与 `../src/pairing-page.ts` 的常量一致）。 */
const CONTROL_HEADER = 'x-dsh-pairing-control'

/** 自检的起始时钟（Unix 毫秒）。 */
const START_TIME = 1_700_000_000_000

/** 一次 HTTP 等待上限。 */
const REQUEST_TIMEOUT_MS = 5_000

/** 一条断言失败。 */
class SelfCheckFailure extends Error {}

/**
 * 断言为真；调用点之后的类型收窄继续生效。
 * @param condition - 断言条件，任意真值表达式。
 * @param message - 失败时写进输出的中文说明。
 * @throws 条件不成立时抛出。
 */
function check(condition: unknown, message: string): asserts condition {
  if (condition) return
  throw new SelfCheckFailure(message)
}

/**
 * 把任意抛出值收敛成一行描述。
 * @param error - 任意抛出值。
 * @returns `name: message`；非 Error 直接字符串化。
 */
function describeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`
  return String(error)
}

/**
 * 把 JSON 值按对象键递归排序后序列化，避免键顺序造成假失败。
 * @param value - 任意 JSON 值。
 * @returns 键序稳定的 JSON 文本。
 */
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(entry => canonical(entry)).join(',')}]`
  if (typeof value === 'object' && value !== null) {
    const record = value as Record<string, unknown>
    const entries = Object.keys(record).sort().map(key => `${JSON.stringify(key)}:${canonical(record[key])}`)
    return `{${entries.join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

/**
 * 断言两段 JSON 值相等。
 * @param actual - 实际值。
 * @param expected - 期望值。
 * @param label - 失败说明里的字段名。
 */
function checkJsonEqual(actual: unknown, expected: unknown, label: string): void {
  check(canonical(actual) === canonical(expected), `${label} 不符：期望 ${canonical(expected)}，实际 ${canonical(actual)}`)
}

/**
 * 把未知值收窄成 JSON 对象。
 * @param value - 待收窄的值。
 * @param label - 失败说明里的位置。
 * @returns 该对象。
 * @throws 不是 JSON 对象时抛出。
 */
function asRecord(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new SelfCheckFailure(`${label} 不是 JSON 对象`)
  }
  return value as Record<string, unknown>
}

/**
 * 把未知值收窄成 JSON 数组。
 * @param value - 待收窄的值。
 * @param label - 失败说明里的位置。
 * @returns 该数组。
 * @throws 不是 JSON 数组时抛出。
 */
function asJsonArray(value: unknown, label: string): readonly unknown[] {
  if (!Array.isArray(value)) throw new SelfCheckFailure(`${label} 不是 JSON 数组`)
  return value
}

/**
 * 解析 JSON 响应体为对象。
 * @param text - 响应体文本。
 * @param label - 失败说明里的接口名。
 * @returns 解析后的对象。
 * @throws 不是合法 JSON 对象时抛出。
 */
function parseJsonObject(text: string, label: string): Record<string, unknown> {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    throw new SelfCheckFailure(`${label} 不是合法 JSON：${describeError(error)}；原文 ${text.slice(0, 120)}`)
  }
  return asRecord(parsed, label)
}

/** 一条 HTTP 响应。 */
interface TestResponse {
  /** 状态码。 */
  readonly status: number
  /** 响应头。 */
  readonly headers: IncomingHttpHeaders
  /** 解码后的响应体。 */
  readonly body: string
}

/** 一次测试请求的参数。 */
interface RequestOptions {
  /** HTTP 方法，默认 GET。 */
  readonly method?: string
  /** 请求路径，默认 `/`。 */
  readonly path?: string
  /** 额外请求头。 */
  readonly headers?: Readonly<Record<string, string>>
  /** 请求体文本。 */
  readonly body?: string
}

/**
 * 发一次回环 HTTP 请求（每次新连接，避免 keep-alive 干扰清理断言）。
 * @param port - 目标端口。
 * @param options - 方法、路径、请求头与请求体。
 * @returns 状态码、响应头与响应体。
 */
function httpRequest(port: number, options: RequestOptions = {}): Promise<TestResponse> {
  return new Promise<TestResponse>((resolve, reject) => {
    const request = createRequest({
      host: '127.0.0.1',
      port,
      method: options.method ?? 'GET',
      path: options.path ?? '/',
      agent: false,
      ...(options.headers === undefined ? {} : { headers: options.headers }),
    }, (response) => {
      const chunks: Buffer[] = []
      response.on('data', (chunk: Buffer) => {
        chunks.push(chunk)
      })
      response.on('end', () => {
        resolve({
          status: response.statusCode ?? 0,
          headers: response.headers,
          body: Buffer.concat(chunks).toString('utf8'),
        })
      })
    })
    request.setTimeout(REQUEST_TIMEOUT_MS, () => {
      request.destroy(new SelfCheckFailure(`请求 ${options.path ?? '/'} 超时`))
    })
    request.on('error', reject)
    if (options.body !== undefined) request.write(options.body)
    request.end()
  })
}

/**
 * 取响应头文本。
 * @param response - 测试响应。
 * @param name - 头名（Node 已小写）。
 * @returns 头值；缺失时为空串。
 */
function headerValue(response: TestResponse, name: string): string {
  const value = response.headers[name]
  if (Array.isArray(value)) return value.join(', ')
  return value ?? ''
}

/**
 * 发一个表单 POST。
 * @param port - 目标端口。
 * @param path - 请求路径。
 * @param fields - 表单字段。
 * @param headers - 额外请求头（例如 `Origin`、`Host`）。
 * @returns 测试响应。
 */
function postForm(
  port: number,
  path: string,
  fields: Readonly<Record<string, string>>,
  headers: Readonly<Record<string, string>> = {},
): Promise<TestResponse> {
  const body = new URLSearchParams(fields).toString()
  return httpRequest(port, {
    method: 'POST',
    path,
    body,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', ...headers },
  })
}

/**
 * 发一个控制 API 的 JSON POST。
 * @param port - 目标端口。
 * @param path - 请求路径。
 * @param body - 请求体（对象会序列化成 JSON；`undefined` 表示空体）。
 * @param headers - 额外请求头（默认已带控制头与 JSON 内容类型）。
 * @returns 测试响应。
 */
function postControlJson(
  port: number,
  path: string,
  body: unknown = undefined,
  headers: Readonly<Record<string, string>> = {},
): Promise<TestResponse> {
  return httpRequest(port, {
    method: 'POST',
    path,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    headers: {
      [CONTROL_HEADER]: '1',
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...headers,
    },
  })
}

/**
 * 断言响应是统一 JSON 错误体。
 * @param response - 测试响应。
 * @param status - 期望状态码。
 * @param code - 期望错误码。
 * @param label - 失败说明里的接口名。
 * @returns 错误体的 message。
 * @throws 状态码或错误体不符合时抛出。
 */
function checkJsonError(response: TestResponse, status: number, code: string, label: string): string {
  check(response.status === status, `${label} 状态码期望 ${status}，实际 ${response.status}：${response.body.slice(0, 120)}`)
  check(headerValue(response, 'content-type').startsWith('application/json'), `${label} 的 Content-Type 不是 JSON`)
  const body = parseJsonObject(response.body, label)
  const error = asRecord(body.error, `${label}.error`)
  check(error.code === code, `${label} 的 error.code 期望 ${code}，实际 ${String(error.code)}`)
  check(typeof error.message === 'string' && error.message.length > 0, `${label} 的 error.message 不是非空字符串`)
  return error.message
}

/**
 * 用原始 TCP 发一帧 HTTP：覆盖「没有 Host 头」这种 http 客户端无法构造的请求。
 * @param port - 目标端口。
 * @param payload - 原始请求文本。
 * @returns 原始响应文本。
 */
function rawExchange(port: number, payload: string): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    let settled = false
    const socket = connectTcp(port, '127.0.0.1')
    const chunks: Buffer[] = []
    const settle = (error: Error | undefined, text: string): void => {
      if (settled) return
      settled = true
      socket.destroy()
      if (error === undefined) resolve(text)
      else reject(error)
    }
    socket.setTimeout(REQUEST_TIMEOUT_MS, () => {
      settle(new SelfCheckFailure('原始 HTTP 请求超时'), '')
    })
    socket.on('connect', () => {
      socket.write(payload)
    })
    socket.on('data', (chunk: Buffer) => {
      chunks.push(chunk)
    })
    socket.on('end', () => {
      settle(undefined, Buffer.concat(chunks).toString('utf8'))
    })
    socket.on('error', (error: Error) => {
      settle(error, '')
    })
  })
}

/**
 * 探测 TCP 端口现在是否可连接。
 * @param port - 目标端口。
 * @returns 能建立连接时为 true。
 */
function canConnect(port: number): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    let settled = false
    const socket = connectTcp(port, '127.0.0.1')
    const settle = (value: boolean): void => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(value)
    }
    socket.setTimeout(1_000, () => {
      settle(false)
    })
    socket.once('connect', () => {
      settle(true)
    })
    socket.once('error', () => {
      settle(false)
    })
  })
}

/**
 * 从页面 HTML 里取出 CSRF 隐藏字段的值。
 * @param html - `GET /` 的响应体。
 * @returns 43 个 base64url 字符的 token。
 * @throws 找不到隐藏字段时抛出。
 */
function extractCsrf(html: string): string {
  const match = /name="csrf" value="([A-Za-z0-9_-]{43})"/u.exec(html)
  if (match === null) throw new SelfCheckFailure('页面里没有 43 字符的 CSRF 隐藏字段')
  const token = match[1]
  if (token === undefined) throw new SelfCheckFailure('CSRF 隐藏字段的值是空的')
  return token
}

/**
 * 取一对配对链接里的令牌（用于断言日志不外泄令牌）。
 * @param ticket - 配对票据。
 * @returns `#instance=…&token=…` 里的 token。
 * @throws 链接里没有 token 时抛出。
 */
function tokenOf(ticket: PairingPageTicket): string {
  const marker = '&token='
  const index = ticket.pairUrl.indexOf(marker)
  if (index < 0) throw new SelfCheckFailure('配对链接里没有 token 字段')
  return ticket.pairUrl.slice(index + marker.length)
}

/**
 * 按页面 `formatTimestamp` 的规则格式化 Unix 毫秒（本地时间 `YYYY-MM-DD HH:mm:ss`）。
 * @param value - Unix 毫秒。
 * @returns 与页面一致的本地时间文本。
 */
function formatPageTimestamp(value: number): string {
  const date = new Date(value)
  const pad = (part: number): string => String(part).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} `
    + `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
}

/** 页面里展示的宿主信息。 */
const SAMPLE_HOST: PairingPageHost = {
  name: SAMPLE_HOST_NAME,
  instanceId: SAMPLE_INSTANCE_ID,
  origin: SAMPLE_ORIGIN,
  port: SAMPLE_WSS_PORT,
  discovery: { enabled: true, port: 4778 },
  listening: true,
}

/** 初始设备列表：有效两台、已撤销一台、已过期一台。 */
function initialDevices(): DeviceSummary[] {
  return [
    {
      id: 'a'.repeat(32),
      label: 'OnePlus6',
      createdAt: START_TIME - 3_600_000,
      lastSeenAt: START_TIME - 60_000,
      expiresAt: START_TIME + 90 * 24 * 3_600_000,
    },
    {
      // 设备名来自配对方上报，页面必须按 HTML 转义后再展示。
      id: 'b'.repeat(32),
      label: '<img src=x onerror=alert(1)>',
      createdAt: START_TIME - 7_200_000,
      lastSeenAt: START_TIME - 7_200_000,
      expiresAt: START_TIME + 90 * 24 * 3_600_000,
    },
    {
      id: 'c'.repeat(32),
      label: '旧手机',
      createdAt: START_TIME - 90 * 24 * 3_600_000,
      lastSeenAt: START_TIME - 80 * 24 * 3_600_000,
      expiresAt: START_TIME - 10 * 24 * 3_600_000,
      revokedAt: START_TIME - 5 * 24 * 3_600_000,
    },
    {
      id: 'd'.repeat(32),
      label: '过期的手机',
      createdAt: START_TIME - 200 * 24 * 3_600_000,
      lastSeenAt: START_TIME - 190 * 24 * 3_600_000,
      expiresAt: START_TIME - 100 * 24 * 3_600_000,
    },
  ]
}

/**
 * 假数据源：维护窗口与设备状态，记录页面调用的动作。
 *
 * 语义与 `./index.ts` 注入的真实数据源保持一致：过期窗口 `currentPairing()` 返回
 * undefined；撤销成功模拟宿主推送 `remote.deviceRevoked`。
 */
class FakePairingSource implements PairingPageSource {
  /** 页面触发的重开窗口次数。 */
  pairCalls = 0
  /** 下一次 `pair()` 是否抛错（验证失败路径）。 */
  failPairOnce = false
  /** 页面触发的撤销设备 id 顺序。 */
  readonly revokeCalls: string[] = []
  /** 页面触发的永久删除设备 id 顺序。 */
  readonly deleteCalls: string[] = []
  /** 模拟宿主推给在线连接的 `remote.deviceRevoked`。 */
  readonly deviceRevokedEvents: string[] = []
  /** 已签发过的全部配对令牌（用于断言日志不外泄）。 */
  readonly issuedTokens: string[] = []
  /** 下一次 `pair()` 打开窗口用的有效期；默认 {@link PAIRING_TTL_MS}。 */
  pairingTtlMs = PAIRING_TTL_MS
  private readonly clock: () => number
  private deviceRecords: DeviceSummary[]
  private ticket: PairingPageTicket | undefined
  private ticketSerial = 0

  /**
   * @param clock - 与页面共享的假时钟。
   * @param devices - 初始设备列表。
   */
  constructor(clock: () => number, devices: readonly DeviceSummary[]) {
    this.clock = clock
    this.deviceRecords = [...devices]
    this.ticket = this.issueTicket()
  }

  /** @returns 仍可用的窗口；过期或没有窗口时为 undefined。 */
  currentPairing(): PairingPageTicket | undefined {
    const ticket = this.ticket
    if (ticket === undefined || ticket.expiresAt <= this.clock()) return undefined
    return ticket
  }

  /** @returns 新窗口的票据。 */
  pair(): PairingPageTicket {
    this.pairCalls += 1
    if (this.failPairOnce) {
      this.failPairOnce = false
      throw new Error('自检注入的重开失败')
    }
    const ticket = this.issueTicket()
    this.ticket = ticket
    return ticket
  }

  /** @returns 设备摘要列表。 */
  devices(): readonly DeviceSummary[] {
    return this.deviceRecords
  }

  /**
   * 撤销设备并模拟推送 `remote.deviceRevoked`。
   * @param deviceId - 设备 id。
   * @returns 撤销结果。
   */
  async revokeDevice(deviceId: string): Promise<RemoteDeviceRevokeResult> {
    this.revokeCalls.push(deviceId)
    const index = this.deviceRecords.findIndex(device => device.id === deviceId && device.revokedAt === undefined)
    const target = this.deviceRecords[index]
    if (index < 0 || target === undefined) return { revoked: false, closed: 0 }
    this.deviceRecords = this.deviceRecords.map((device, position) => (
      position === index ? { ...device, revokedAt: this.clock() } : device
    ))
    this.deviceRevokedEvents.push(deviceId)
    return { revoked: true, closed: 1 }
  }

  /**
   * 永久删除设备记录；有效设备模拟先走撤销路径（断连 + 通知）再删除。
   * @param deviceId - 设备 id。
   * @returns 删除结果。
   */
  async deleteDevice(deviceId: string): Promise<RemoteDeviceDeleteResult> {
    this.deleteCalls.push(deviceId)
    const index = this.deviceRecords.findIndex(device => device.id === deviceId)
    const target = this.deviceRecords[index]
    if (index < 0 || target === undefined) return { deleted: false, wasActive: false, closedConnections: 0 }
    const wasActive = target.revokedAt === undefined && target.expiresAt > this.clock()
    let closedConnections = 0
    if (wasActive) {
      const revoked = await this.revokeDevice(deviceId)
      closedConnections = revoked.closed
    }
    this.deviceRecords = this.deviceRecords.filter(device => device.id !== deviceId)
    return { deleted: true, wasActive, closedConnections }
  }

  /** @returns 页面头部展示的宿主信息。 */
  host(): PairingPageHost {
    return SAMPLE_HOST
  }

  /**
   * 替换设备列表（验证空态）。
   * @param devices - 新设备列表。
   */
  setDevices(devices: readonly DeviceSummary[]): void {
    this.deviceRecords = [...devices]
  }

  /** @returns 新签发的票据（令牌按序号变化）。 */
  private issueTicket(): PairingPageTicket {
    this.ticketSerial += 1
    const token = `t${String(this.ticketSerial).padStart(42, '0')}`
    this.issuedTokens.push(token)
    return {
      pairUrl: `${SAMPLE_ORIGIN}#instance=${SAMPLE_INSTANCE_ID}&token=${token}`,
      usbPairUrl: `wss://127.0.0.1:${SAMPLE_WSS_PORT}#instance=${SAMPLE_INSTANCE_ID}&token=${token}`,
      expiresAt: this.clock() + this.pairingTtlMs,
    }
  }
}

/** 逐项结果统计。 */
let passed = 0
let total = 0
const failures: string[] = []

/**
 * 跑一项断言并打印结果。失败不中断后续项，但会计入退出码。
 * @param label - 中文说明。
 * @param run - 断言本体，返回通过时展示的细节。
 */
async function step(label: string, run: () => Promise<string>): Promise<void> {
  total += 1
  try {
    const detail = await run()
    passed += 1
    console.log(`PASS  ${total}. ${label}：${detail}`)
  } catch (error) {
    const detail = describeError(error)
    failures.push(`${label}：${detail}`)
    console.log(`FAIL  ${total}. ${label}：${detail}`)
  }
}

/**
 * 自检主体：启动 → 页面/JSON 契约 → 防护 → 动作 → 生命周期。
 * @returns 进程退出码：全部通过为 0。
 */
async function main(): Promise<number> {
  const logRecords: RemoteLogRecord[] = []
  const log = (record: RemoteLogRecord): void => {
    logRecords.push(record)
  }
  let fakeNow = START_TIME
  const clock = (): number => fakeNow
  const source = new FakePairingSource(clock, initialDevices())
  const server = new PairingPageServer({ port: 0, source, log, now: clock })
  let port = 0
  let csrf = ''

  try {
    await step('启动绑定回环临时端口并记录 pairing-page-ready', async () => {
      const started = await server.start()
      check(started.listening, '页面没有进入监听状态')
      check(started.port > 0, `临时端口无效：${started.port}`)
      check(started.url === `http://127.0.0.1:${started.port}/`, `启动结果 URL 不符：${started.url}`)
      check(server.port === started.port, 'port getter 与启动结果不一致')
      check(server.url === started.url, 'url getter 与启动结果不一致')
      const ready = logRecords.filter(record => record.event === 'pairing-page-ready')
      check(ready.length === 1, `pairing-page-ready 应为 1 条，实际 ${ready.length} 条`)
      const record = ready[0]
      check(record !== undefined, '没有找到 pairing-page-ready 日志')
      check(record.level === 'info', 'pairing-page-ready 应当是 info 级别')
      check(record.fields?.url === started.url, 'pairing-page-ready 的 fields.url 与实际 URL 不一致')
      check(record.fields?.port === started.port, 'pairing-page-ready 的 fields.port 与实际端口不一致')
      check(record.fields?.address === '127.0.0.1', 'pairing-page-ready 的绑定地址不是 127.0.0.1')
      port = started.port
      return `HTTP 127.0.0.1:${port}，日志含 pairing-page-ready`
    })

    await step('GET / 单页 HTML 含二维码/倒计时/链接/USB 段落/设备列表/CSRF', async () => {
      const ticket = source.currentPairing()
      check(ticket !== undefined, '自检数据源没有打开中的窗口')
      const response = await httpRequest(port, { path: '/' })
      check(response.status === 200, `状态码期望 200，实际 ${response.status}`)
      check(headerValue(response, 'content-type').startsWith('text/html; charset=utf-8'), 'Content-Type 不是 HTML')
      const html = response.body
      check(html.includes('<!DOCTYPE html>'), '不是完整 HTML 文档')
      check(/id="remaining">(?:119|120)</u.test(html), '页面没有窗口剩余秒数')
      check(/<svg[^>]*viewBox="0 0 \d+ \d+"/u.test(html), '页面没有内联二维码 SVG')
      check(html.includes('shape-rendering="crispEdges"'), '二维码 SVG 缺少 crispEdges')
      // SVG 必须由同一份矩阵渲染：viewBox 边长 = 矩阵边长 + 左右各 4 个安静区模块。
      const matrix = encodeQrMatrix(ticket.pairUrl)
      const expectedSide = matrix.size + 8
      check(html.includes(`viewBox="0 0 ${expectedSide} ${expectedSide}"`), `二维码 SVG 的 viewBox 不是 ${expectedSide}`)
      check(html.includes('M4 4h'), '二维码 SVG 没有从安静区后的第一个（左上角）深色模块开始绘制')
      check(html.includes(ticket.pairUrl.replace(/&/gu, '&amp;')), '页面没有转义后的配对链接')
      check(html.includes(ticket.usbPairUrl.replace(/&/gu, '&amp;')), '页面没有转义后的 USB 配对链接')
      check(html.includes(`adb reverse tcp:${SAMPLE_WSS_PORT} tcp:${SAMPLE_WSS_PORT}`), '页面没有 adb reverse 提示')
      check(html.includes(SAMPLE_HOST_NAME), '页面没有宿主显示名')
      check(html.includes(SAMPLE_INSTANCE_ID.slice(0, 8)), '页面没有 instanceId 前缀')
      check(html.includes(SAMPLE_ORIGIN), '页面没有 origin')
      check(html.includes('重新打开配对窗口'), '页面没有重开按钮')
      csrf = extractCsrf(html)
      return `二维码 SVG + 剩余 ${PAIRING_TTL_MS / 1000} 秒 + CSRF ${csrf.length} 字符 + USB 段落`
    })

    await step('设备列表展示 label / id 前缀 / 时间，设备名按 HTML 转义', async () => {
      const html = (await httpRequest(port, { path: '/' })).body
      check(html.includes('OnePlus6'), '页面没有设备名')
      check(html.includes('a'.repeat(8)), '页面没有设备 id 前缀')
      check(/<td>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}<\/td>/u.test(html), '页面没有格式化后的设备时间')
      check(html.includes('已撤销'), '页面没有已撤销状态')
      check(html.includes('已过期'), '页面没有已过期状态')
      check(!html.includes('<img src=x onerror=alert(1)>'), '设备名没有转义，存在 XSS 注入')
      check(html.includes('&lt;img src=x onerror=alert(1)&gt;'), '设备名转义结果不符')
      const activeForms = html.split('action="/devices/revoke"').length - 1
      check(activeForms === 2, `有效设备的撤销表单应为 2 个，实际 ${activeForms} 个`)
      return '4 台设备（2 有效 / 1 已撤销 / 1 已过期），设备名完成 HTML 转义'
    })

    await step('GET /api/state 字段集合、host 监听事实与窗口打开形态，不含令牌摘要', async () => {
      const ticket = source.currentPairing()
      check(ticket !== undefined, '自检数据源没有打开中的窗口')
      const response = await httpRequest(port, { path: '/api/state' })
      check(response.status === 200, `状态码期望 200，实际 ${response.status}`)
      check(headerValue(response, 'content-type').startsWith('application/json'), 'Content-Type 不是 JSON')
      const state = parseJsonObject(response.body, '/api/state')
      checkJsonEqual(Object.keys(state).sort(), ['devices', 'host', 'pairing', 'usbPairUrl'], '/api/state 字段集合')
      const host = asRecord(state.host, 'host')
      checkJsonEqual(
        Object.keys(host).sort(),
        ['discovery', 'instanceId', 'listening', 'name', 'origin', 'port'],
        'host 字段集合',
      )
      check(host.name === SAMPLE_HOST_NAME, 'host.name 不符')
      check(host.instanceId === SAMPLE_INSTANCE_ID, 'host.instanceId 不符')
      check(host.origin === SAMPLE_ORIGIN, 'host.origin 不符')
      check(host.port === SAMPLE_WSS_PORT, 'host.port 不是 wss 监听端口')
      check(host.listening === true, 'host.listening 不是 true')
      checkJsonEqual(host.discovery, { enabled: true, port: 4778 }, 'host.discovery')
      const pairing = asRecord(state.pairing, 'pairing')
      checkJsonEqual(Object.keys(pairing).sort(), ['expiresAt', 'open', 'pairUrl', 'usbPairUrl'], 'pairing 字段集合')
      check(pairing.open === true, 'pairing.open 不是 true')
      check(pairing.expiresAt === ticket.expiresAt, 'pairing.expiresAt 与票据不一致')
      check(pairing.pairUrl === ticket.pairUrl, 'pairing.pairUrl 与票据不一致')
      check(pairing.usbPairUrl === ticket.usbPairUrl, 'pairing.usbPairUrl 与票据不一致')
      check(state.usbPairUrl === ticket.usbPairUrl, '顶层 usbPairUrl（兼容字段）与票据不一致')
      const devices = asJsonArray(state.devices, 'devices')
      check(devices.length === 4, `设备数期望 4，实际 ${devices.length}`)
      const first = asRecord(devices[0], 'devices[0]')
      checkJsonEqual(Object.keys(first).sort(), ['createdAt', 'expiresAt', 'id', 'label', 'lastSeenAt'], 'devices[0] 字段集合')
      check(first.id === 'a'.repeat(32), 'devices[0].id 不符')
      check(first.label === 'OnePlus6', 'devices[0].label 不符')
      const serialized = JSON.stringify(state)
      check(!serialized.includes('tokenDigest'), '/api/state 泄漏了令牌摘要字段')
      // 窗口打开时三处带 token 的链接：pairing.pairUrl / pairing.usbPairUrl / 顶层 usbPairUrl。
      const tokenOccurrences = serialized.split('&token=').length - 1
      check(tokenOccurrences === 3, `窗口打开时 /api/state 应恰好含 3 条带令牌的链接，实际 ${tokenOccurrences} 条`)
      return `${devices.length} 台设备 + host(listening) + pairing.open=true，无令牌摘要`
    })

    await step('响应头：nosniff / no-store / CSP / frame 拒绝 / 没有 CORS', async () => {
      for (const path of ['/', '/api/state', '/qr.svg']) {
        const response = await httpRequest(port, { path })
        check(headerValue(response, 'x-content-type-options') === 'nosniff', `${path} 缺少 nosniff`)
        check(headerValue(response, 'cache-control') === 'no-store', `${path} 缺少 no-store`)
        check(headerValue(response, 'x-frame-options') === 'DENY', `${path} 缺少 X-Frame-Options: DENY`)
        const csp = headerValue(response, 'content-security-policy')
        check(csp.includes("default-src 'none'"), `${path} 的 CSP 缺少 default-src 'none'`)
        check(csp.includes("frame-ancestors 'none'"), `${path} 的 CSP 缺少 frame-ancestors 'none'`)
        check(csp.includes("connect-src 'self'"), `${path} 的 CSP 缺少 connect-src 'self'（页面轮询需要）`)
        check(headerValue(response, 'access-control-allow-origin') === '', `${path} 返回了 CORS 头`)
      }
      return '页面 / JSON / QR SVG 都带 nosniff/no-store/CSP，且没有任何 Access-Control-* 头'
    })

    await step('没有设备时展示空态', async () => {
      source.setDevices([])
      const html = (await httpRequest(port, { path: '/' })).body
      check(html.includes('还没有配对过的设备'), '空设备列表没有空态文案')
      check(!html.includes('action="/devices/revoke"'), '空设备列表仍有撤销表单')
      source.setDevices(initialDevices())
      return '空列表显示空态文案，无撤销表单'
    })

    await step('窗口过期后页面、JSON 与 /qr.svg 都不再带配对链接', async () => {
      const expiredTicket = source.currentPairing()
      check(expiredTicket !== undefined, '过期前数据源没有窗口')
      const expiredToken = tokenOf(expiredTicket)
      fakeNow += PAIRING_TTL_MS + 1_000
      const response = await httpRequest(port, { path: '/api/state' })
      const state = parseJsonObject(response.body, '/api/state')
      checkJsonEqual(
        state.pairing,
        { open: false, expiresAt: null, pairUrl: null, usbPairUrl: null },
        '过期后的 pairing',
      )
      check(state.usbPairUrl === null, '过期后 usbPairUrl 不是 null')
      const html = (await httpRequest(port, { path: '/' })).body
      check(/id="pairing-open" hidden/u.test(html), '过期后未隐藏二维码区块')
      check(html.includes('当前没有打开的配对窗口'), '过期后没有已关闭文案')
      check(!html.includes(expiredToken), '过期后的页面仍出现旧配对令牌')
      check(!html.includes('#instance='), '过期后的页面仍出现配对链接')
      check(!html.includes(`adb reverse tcp:${SAMPLE_WSS_PORT}`), '过期后的页面仍展示 USB 配对链接')
      const qr = await httpRequest(port, { path: '/qr.svg' })
      check(qr.status === 404, `窗口关闭后 /qr.svg 期望 404，实际 ${qr.status}`)
      check(!qr.body.includes('<svg'), '窗口关闭后 /qr.svg 仍返回了二维码')
      check(!qr.body.includes('#instance='), '/qr.svg 的 404 响应泄漏了配对链接')
      return '窗口过期 → pairing 四字段全 null、usbPairUrl=null，页面隐藏二维码，/qr.svg 404'
    })

    await step('POST /pair/reopen 带 CSRF → 303，窗口换新令牌与过期时间', async () => {
      const before = source.currentPairing()
      const response = await postForm(port, '/pair/reopen', { csrf })
      check(response.status === 303, `状态码期望 303，实际 ${response.status}`)
      check(headerValue(response, 'location') === '/', '303 的 Location 不是 /')
      check(source.pairCalls === 1, `source.pair 调用次数期望 1，实际 ${source.pairCalls}`)
      const after = source.currentPairing()
      check(after !== undefined, '重开后数据源仍没有窗口')
      check(before === undefined || tokenOf(after) !== tokenOf(before), '重开后令牌没有变化')
      check(after.expiresAt === fakeNow + PAIRING_TTL_MS, '重开后的过期时间没有按当前时钟更新')
      const state = parseJsonObject((await httpRequest(port, { path: '/api/state' })).body, '/api/state')
      const pairing = asRecord(state.pairing, 'pairing')
      check(pairing.open === true, '重开后 pairing.open 不是 true')
      check(pairing.pairUrl === after.pairUrl, '重开后 /api/state 的 pairUrl 不是新链接')
      const html = (await httpRequest(port, { path: '/' })).body
      check(html.includes(after.pairUrl.replace(/&/gu, '&amp;')), '重开后页面没有新配对链接')
      csrf = extractCsrf(html)
      return `303 → /，新令牌 ${tokenOf(after).slice(0, 4)}…，expiresAt=${after.expiresAt}`
    })

    await step('GET /qr.svg 返回当前窗口二维码 SVG，无需控制头，query 忽略', async () => {
      const ticket = source.currentPairing()
      check(ticket !== undefined, '自检数据源没有打开中的窗口')
      const response = await httpRequest(port, { path: '/qr.svg' })
      check(response.status === 200, `状态码期望 200，实际 ${response.status}`)
      check(
        headerValue(response, 'content-type').startsWith('image/svg+xml'),
        `Content-Type 不是 image/svg+xml：${headerValue(response, 'content-type')}`,
      )
      check(headerValue(response, 'cache-control') === 'no-store', '/qr.svg 缺少 no-store')
      check(response.body.startsWith('<svg '), '/qr.svg 响应体不是内联 SVG')
      check(
        response.body === renderPairingQrSvg(ticket.pairUrl),
        '/qr.svg 与导出的 renderPairingQrSvg(pairUrl) 不是同一份渲染结果',
      )
      const withQuery = await httpRequest(port, { path: '/qr.svg?v=123' })
      check(withQuery.status === 200, `/qr.svg?v=123 期望 200，实际 ${withQuery.status}`)
      check(withQuery.body === response.body, '/qr.svg 的 query 串影响了响应内容（应被忽略）')
      const matrix = encodeQrMatrix(ticket.pairUrl)
      check(response.body.includes(`viewBox="0 0 ${matrix.size + 8} ${matrix.size + 8}"`), 'QR SVG 的 viewBox 与矩阵不符')
      return `image/svg+xml ${response.body.length} 字节，与 renderPairingQrSvg 完全一致，query 忽略`
    })

    await step('POST /api/pair 带控制头 → 200 + 最新 state，窗口换新令牌', async () => {
      const before = source.currentPairing()
      const pairCallsBefore = source.pairCalls
      const response = await postControlJson(port, '/api/pair')
      check(response.status === 200, `状态码期望 200，实际 ${response.status}: ${response.body.slice(0, 120)}`)
      check(headerValue(response, 'content-type').startsWith('application/json'), 'Content-Type 不是 JSON')
      const state = parseJsonObject(response.body, '/api/pair')
      checkJsonEqual(Object.keys(state).sort(), ['devices', 'host', 'pairing', 'usbPairUrl'], '/api/pair 应返回完整 state')
      check(source.pairCalls === pairCallsBefore + 1, `source.pair 调用次数期望 +1，实际 ${source.pairCalls - pairCallsBefore}`)
      const after = source.currentPairing()
      check(after !== undefined, '控制 API 重开后数据源仍没有窗口')
      check(before === undefined || tokenOf(after) !== tokenOf(before), '控制 API 重开后令牌没有变化')
      const pairing = asRecord(state.pairing, 'pairing')
      check(pairing.open === true, '控制 API 重开后 pairing.open 不是 true')
      check(pairing.pairUrl === after.pairUrl, '响应里的 pairing.pairUrl 不是新链接')
      check(pairing.expiresAt === after.expiresAt, '响应里的 pairing.expiresAt 不是新窗口')
      // 与随后 GET /api/state 的完整 state 完全一致：客户端可以直接用响应刷新 UI。
      const fetched = parseJsonObject((await httpRequest(port, { path: '/api/state' })).body, '/api/state')
      checkJsonEqual(state, fetched, 'POST /api/pair 的响应与随后 /api/state')
      const action = logRecords.find(record => record.event === 'pairing-page-action'
        && record.fields?.action === 'api-pair'
        && record.fields?.result === 'ok')
      check(action !== undefined, '控制 API 重开窗口缺少 result=ok 的动作日志')
      return `200 + state，新令牌 ${tokenOf(after).slice(0, 4)}…，日志 result=ok`
    })

    await step('POST /api/pair 缺/错控制头 → 403 且无副作用', async () => {
      const pairCallsBefore = source.pairCalls
      const missing = await httpRequest(port, {
        method: 'POST',
        path: '/api/pair',
        body: '{}',
        headers: { 'Content-Type': 'application/json' },
      })
      checkJsonError(missing, 403, 'control-header-required', 'POST /api/pair 缺控制头')
      const wrong = await httpRequest(port, {
        method: 'POST',
        path: '/api/pair',
        body: '{}',
        headers: { 'Content-Type': 'application/json', [CONTROL_HEADER]: 'yes' },
      })
      checkJsonError(wrong, 403, 'control-header-required', 'POST /api/pair 错控制头')
      check(source.pairCalls === pairCallsBefore, '被拒绝的控制 API 请求仍打开了配对窗口')
      const getPair = await httpRequest(port, { path: '/api/pair' })
      check(getPair.status === 405, `GET /api/pair 期望 405，实际 ${getPair.status}`)
      check(headerValue(getPair, 'allow') === 'POST', 'GET /api/pair 的 Allow 不是 POST')
      const jsonBody = await postControlJson(port, '/api/pair', {})
      check(jsonBody.status === 200, `带空 JSON 对象 body 的 /api/pair 期望 200，实际 ${jsonBody.status}`)
      return '缺头/错值都是 403 + control-header-required，GET 405，空 JSON body 正常 200'
    })


    await step('POST /devices/revoke 带 CSRF → 303，调用撤销并模拟 remote.deviceRevoked', async () => {
      const targetId = 'a'.repeat(32)
      const response = await postForm(port, '/devices/revoke', { csrf, id: targetId })
      check(response.status === 303, `状态码期望 303，实际 ${response.status}`)
      check(headerValue(response, 'location') === '/', '303 的 Location 不是 /')
      checkJsonEqual(source.revokeCalls, [targetId], 'source.revokeDevice 调用')
      checkJsonEqual(source.deviceRevokedEvents, [targetId], '模拟的 remote.deviceRevoked 推送')
      const state = parseJsonObject((await httpRequest(port, { path: '/api/state' })).body, '/api/state')
      const devices = asJsonArray(state.devices, 'devices')
      const revoked = asRecord(devices[0], 'devices[0]')
      check(typeof revoked.revokedAt === 'number', '撤销后 state 里没有 revokedAt')
      const html = (await httpRequest(port, { path: '/' })).body
      const activeForms = html.split('action="/devices/revoke"').length - 1
      check(activeForms === 1, `撤销后有效设备的撤销表单应剩 1 个，实际 ${activeForms} 个`)
      check(html.includes('已撤销'), '撤销后页面没有已撤销状态')
      return `deviceRevoked 推送 ${targetId.slice(0, 8)}…，/api/state 带 revokedAt，有效表单 1 个`
    })

    await step('POST /devices/revoke 未知设备 → 303 且日志 result=not-revoked', async () => {
      const unknownId = 'f'.repeat(32)
      const response = await postForm(port, '/devices/revoke', { csrf, id: unknownId })
      check(response.status === 303, `状态码期望 303，实际 ${response.status}`)
      const actionLog = logRecords.find(record => record.event === 'pairing-page-action'
        && record.fields?.action === 'device-revoke'
        && record.fields?.deviceId === unknownId)
      check(actionLog !== undefined, '没有找到未知设备撤销的动作日志')
      check(actionLog.fields?.result === 'not-revoked', `日志 result 期望 not-revoked，实际 ${String(actionLog.fields?.result)}`)
      return `${unknownId.slice(0, 8)}… 未生效但正常重定向，日志 result=not-revoked`
    })

    await step('POST /devices/revoke 非法设备 id → 400 且不调用撤销', async () => {
      const callsBefore = source.revokeCalls.length
      const response = await postForm(port, '/devices/revoke', { csrf, id: '../../etc/passwd' })
      check(response.status === 400, `状态码期望 400，实际 ${response.status}`)
      check(source.revokeCalls.length === callsBefore, '非法 id 仍调用了 source.revokeDevice')
      return '非法 id → 400，撤销入口没有被调用'
    })

    await step('POST /api/devices/revoke 带控制头 + JSON → 200 最新 state，设备出现 revokedAt', async () => {
      const targetId = 'b'.repeat(32)
      const response = await postControlJson(port, '/api/devices/revoke', { deviceId: targetId })
      check(response.status === 200, `状态码期望 200，实际 ${response.status}: ${response.body.slice(0, 160)}`)
      check(headerValue(response, 'content-type').startsWith('application/json'), 'Content-Type 不是 JSON')
      const state = parseJsonObject(response.body, '/api/devices/revoke')
      checkJsonEqual(Object.keys(state).sort(), ['devices', 'host', 'pairing', 'usbPairUrl'], '/api/devices/revoke 应返回完整 state')
      const devices = asJsonArray(state.devices, 'devices')
      const revoked = devices.map(entry => asRecord(entry, 'devices[]')).find(device => device.id === targetId)
      check(revoked !== undefined, '返回的 state 里没有目标设备')
      check(typeof revoked.revokedAt === 'number', '撤销后 state 里没有 revokedAt')
      check(source.revokeCalls.includes(targetId), '控制 API 没有调用 source.revokeDevice')
      check(source.deviceRevokedEvents.includes(targetId), '控制 API 撤销后没有模拟 remote.deviceRevoked')
      const action = logRecords.find(record => record.event === 'pairing-page-action'
        && record.fields?.action === 'api-device-revoke'
        && record.fields?.result === 'revoked')
      check(action !== undefined, '控制 API 撤销缺少 result=revoked 的动作日志')
      check(action.fields?.deviceId === targetId, '控制 API 撤销日志的 deviceId 不符')
      return `200 + state，${targetId.slice(0, 8)}… 出现 revokedAt，日志 result=revoked`
    })

    await step('POST /api/devices/revoke 错误分支：缺头 403 / 非 JSON 415 / 非法请求 400 / 未知 404 / 已撤销 409', async () => {
      const targetId = 'b'.repeat(32)
      const revokeCallsBefore = source.revokeCalls.length
      const missingHeader = await httpRequest(port, {
        method: 'POST',
        path: '/api/devices/revoke',
        body: JSON.stringify({ deviceId: 'c'.repeat(32) }),
        headers: { 'Content-Type': 'application/json' },
      })
      checkJsonError(missingHeader, 403, 'control-header-required', 'POST /api/devices/revoke 缺控制头')
      const wrongType = await postControlJson(port, '/api/devices/revoke', { deviceId: 'c'.repeat(32) }, { 'Content-Type': 'text/plain' })
      checkJsonError(wrongType, 415, 'unsupported-media-type', 'POST /api/devices/revoke 非 JSON 内容类型')
      const badJson = await httpRequest(port, {
        method: 'POST',
        path: '/api/devices/revoke',
        body: 'not-json',
        headers: { 'Content-Type': 'application/json', [CONTROL_HEADER]: '1' },
      })
      checkJsonError(badJson, 400, 'invalid-request', 'POST /api/devices/revoke 非法 JSON')
      const badId = await postControlJson(port, '/api/devices/revoke', { deviceId: '../../etc/passwd' })
      checkJsonError(badId, 400, 'invalid-request', 'POST /api/devices/revoke 非法 deviceId')
      const missingField = await postControlJson(port, '/api/devices/revoke', {})
      checkJsonError(missingField, 400, 'invalid-request', 'POST /api/devices/revoke 缺 deviceId')
      check(
        source.revokeCalls.length === revokeCallsBefore,
        `被前置校验拒绝的请求仍调用了 source.revokeDevice（多 ${source.revokeCalls.length - revokeCallsBefore} 次）`,
      )
      const unknown = await postControlJson(port, '/api/devices/revoke', { deviceId: 'f'.repeat(32) })
      checkJsonError(unknown, 404, 'device-not-found', 'POST /api/devices/revoke 未知设备')
      const alreadyRevoked = await postControlJson(port, '/api/devices/revoke', { deviceId: targetId })
      checkJsonError(alreadyRevoked, 409, 'device-already-revoked', 'POST /api/devices/revoke 已撤销设备')
      const getRevoke = await httpRequest(port, { path: '/api/devices/revoke' })
      check(getRevoke.status === 405, `GET /api/devices/revoke 期望 405，实际 ${getRevoke.status}`)
      check(headerValue(getRevoke, 'allow') === 'POST', 'GET /api/devices/revoke 的 Allow 不是 POST')
      return '403/415/400×3/404/409 与 405 都符合，前置校验失败没有触发撤销'
    })


    await step('POST /api/devices/delete 有效设备 → 先撤销断连再永久删除记录', async () => {
      const activeId = 'e'.repeat(32)
      source.setDevices([...source.devices(), {
        id: activeId,
        label: '要删除的手机',
        createdAt: START_TIME,
        lastSeenAt: START_TIME,
        expiresAt: START_TIME + 90 * 24 * 3_600_000,
      }])
      const eventsBefore = source.deviceRevokedEvents.length
      const response = await postControlJson(port, '/api/devices/delete', { deviceId: activeId })
      check(response.status === 200, `状态码期望 200，实际 ${response.status}: ${response.body.slice(0, 160)}`)
      check(headerValue(response, 'content-type').startsWith('application/json'), 'Content-Type 不是 JSON')
      const state = parseJsonObject(response.body, '/api/devices/delete')
      checkJsonEqual(Object.keys(state).sort(), ['devices', 'host', 'pairing', 'usbPairUrl'], '/api/devices/delete 应返回完整 state')
      const devices = asJsonArray(state.devices, 'devices')
      check(devices.every(entry => asRecord(entry, 'devices[]').id !== activeId), '删除后 state 仍包含该设备')
      check(source.deleteCalls.includes(activeId), '控制 API 没有调用 source.deleteDevice')
      check(source.deviceRevokedEvents.length === eventsBefore + 1, '有效设备删除前没有走撤销路径（remote.deviceRevoked 未推送）')
      const action = logRecords.find(record => record.event === 'pairing-page-action'
        && record.fields?.action === 'api-device-delete'
        && record.fields?.deviceId === activeId)
      check(action !== undefined, '控制 API 删除缺少动作日志')
      check(action.fields?.result === 'deleted', `删除日志 result 期望 deleted，实际 ${String(action.fields?.result)}`)
      check(action.fields?.wasActive === true, '删除日志没有如实标记 wasActive')
      return `200 + state，${activeId.slice(0, 8)}… 先断连再消失，日志 wasActive=true`
    })

    await step('POST /api/devices/delete 已撤销/已过期 → 直接删除；未知与重复删除 → 404', async () => {
      const revokedId = 'a'.repeat(32)
      const expiredId = 'd'.repeat(32)
      const eventsBefore = source.deviceRevokedEvents.length
      const deletedRevoked = await postControlJson(port, '/api/devices/delete', { deviceId: revokedId })
      check(deletedRevoked.status === 200, `删除已撤销设备期望 200，实际 ${deletedRevoked.status}`)
      const state = parseJsonObject(deletedRevoked.body, '/api/devices/delete')
      check(
        asJsonArray(state.devices, 'devices').every(entry => asRecord(entry, 'devices[]').id !== revokedId),
        '已撤销设备删除后仍在 state 里',
      )
      const deletedExpired = await postControlJson(port, '/api/devices/delete', { deviceId: expiredId })
      check(deletedExpired.status === 200, `删除已过期设备期望 200，实际 ${deletedExpired.status}`)
      check(source.deviceRevokedEvents.length === eventsBefore, '删除已撤销/已过期设备不应再触发撤销通知')
      const unknown = await postControlJson(port, '/api/devices/delete', { deviceId: '9'.repeat(32) })
      checkJsonError(unknown, 404, 'device-not-found', 'POST /api/devices/delete 未知设备')
      const repeated = await postControlJson(port, '/api/devices/delete', { deviceId: revokedId })
      checkJsonError(repeated, 404, 'device-not-found', 'POST /api/devices/delete 重复删除')
      return '已撤销/已过期记录直接删除且不再断连；未知与重复删除 404'
    })

    await step('POST /api/devices/delete 防护：缺头 403 / 非 JSON 415 / 非法请求 400 / 方法 405，且无副作用', async () => {
      const deletesBefore = source.deleteCalls.length
      const missingHeader = await httpRequest(port, {
        method: 'POST',
        path: '/api/devices/delete',
        body: JSON.stringify({ deviceId: 'c'.repeat(32) }),
        headers: { 'Content-Type': 'application/json' },
      })
      checkJsonError(missingHeader, 403, 'control-header-required', 'POST /api/devices/delete 缺控制头')
      const wrongType = await postControlJson(port, '/api/devices/delete', { deviceId: 'c'.repeat(32) }, { 'Content-Type': 'text/plain' })
      checkJsonError(wrongType, 415, 'unsupported-media-type', 'POST /api/devices/delete 非 JSON 内容类型')
      const badJson = await httpRequest(port, {
        method: 'POST',
        path: '/api/devices/delete',
        body: 'not-json',
        headers: { 'Content-Type': 'application/json', [CONTROL_HEADER]: '1' },
      })
      checkJsonError(badJson, 400, 'invalid-request', 'POST /api/devices/delete 非法 JSON')
      const badId = await postControlJson(port, '/api/devices/delete', { deviceId: '../../etc/passwd' })
      checkJsonError(badId, 400, 'invalid-request', 'POST /api/devices/delete 非法 deviceId')
      const missingField = await postControlJson(port, '/api/devices/delete', {})
      checkJsonError(missingField, 400, 'invalid-request', 'POST /api/devices/delete 缺 deviceId')
      check(
        source.deleteCalls.length === deletesBefore,
        `被前置校验拒绝的请求仍调用了 source.deleteDevice（多 ${source.deleteCalls.length - deletesBefore} 次）`,
      )
      const getDelete = await httpRequest(port, { path: '/api/devices/delete' })
      check(getDelete.status === 405, `GET /api/devices/delete 期望 405，实际 ${getDelete.status}`)
      check(headerValue(getDelete, 'allow') === 'POST', 'GET /api/devices/delete 的 Allow 不是 POST')
      return '403/415/400×3/405 全部符合，前置校验失败没有删除任何记录'
    })

    await step('POST 缺 CSRF / 错 CSRF / 重复 CSRF 一律 403 且无副作用', async () => {
      const pairCallsBefore = source.pairCalls
      const missing = await postForm(port, '/pair/reopen', {})
      check(missing.status === 403, `缺 CSRF 期望 403，实际 ${missing.status}`)
      const wrong = await postForm(port, '/pair/reopen', { csrf: 'z'.repeat(43) })
      check(wrong.status === 403, `错 CSRF 期望 403，实际 ${wrong.status}`)
      const duplicated = await httpRequest(port, {
        method: 'POST',
        path: '/pair/reopen',
        body: `csrf=${csrf}&csrf=${csrf}`,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      })
      check(duplicated.status === 403, `重复 CSRF 期望 403，实际 ${duplicated.status}`)
      check(source.pairCalls === pairCallsBefore, 'CSRF 被拒绝的请求仍产生了副作用')
      return '缺 / 错 / 重复 CSRF 都回 403，重开窗口没有被调用'
    })

    await step('POST 非表单 Content-Type → 415', async () => {
      const response = await httpRequest(port, {
        method: 'POST',
        path: '/pair/reopen',
        body: JSON.stringify({ csrf }),
        headers: { 'Content-Type': 'application/json' },
      })
      check(response.status === 415, `状态码期望 415，实际 ${response.status}`)
      return 'application/json → 415'
    })

    await step('POST 超大表单体 → 413', async () => {
      const response = await httpRequest(port, {
        method: 'POST',
        path: '/pair/reopen',
        body: `csrf=${'x'.repeat(8 * 1024)}`,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      })
      check(response.status === 413, `状态码期望 413，实际 ${response.status}`)
      return '8 KiB 表单体 → 413'
    })

    await step('伪造 Host 头（DNS rebinding）→ 403', async () => {
      for (const path of ['/', '/api/state', '/qr.svg']) {
        const response = await httpRequest(port, { path, headers: { Host: `evil.example:${port}` } })
        check(response.status === 403, `${path} 的伪造 Host 期望 403，实际 ${response.status}`)
        check(!response.body.includes('#instance='), `${path} 的 403 响应泄漏了配对链接`)
      }
      const pairCallsBefore = source.pairCalls
      const apiWithHeader = await httpRequest(port, {
        method: 'POST',
        path: '/api/pair',
        headers: { Host: `evil.example:${port}`, [CONTROL_HEADER]: '1' },
      })
      check(apiWithHeader.status === 403, `POST /api/pair 的伪造 Host 期望 403，实际 ${apiWithHeader.status}`)
      check(source.pairCalls === pairCallsBefore, '伪造 Host 的 POST /api/pair 仍打开了配对窗口')
      return '/、/api/state、/qr.svg 与 POST /api/pair 的伪造 Host 都是 403，无副作用'
    })

    await step('Host 端口不符 → 403', async () => {
      const response = await httpRequest(port, { path: '/api/state', headers: { Host: '127.0.0.1:1' } })
      check(response.status === 403, `状态码期望 403，实际 ${response.status}`)
      return '127.0.0.1:1 → 403'
    })

    await step('Host 用 localhost（含大小写）→ 200', async () => {
      const lower = await httpRequest(port, { path: '/api/state', headers: { Host: `localhost:${port}` } })
      check(lower.status === 200, `localhost 期望 200，实际 ${lower.status}`)
      const upper = await httpRequest(port, { path: '/api/state', headers: { Host: `LOCALHOST:${port}` } })
      check(upper.status === 200, `LOCALHOST 期望 200，实际 ${upper.status}`)
      return 'localhost / LOCALHOST 都允许'
    })

    await step('跨站 Origin → 403 且请求没有副作用', async () => {
      const page = await httpRequest(port, { path: '/', headers: { Origin: 'http://evil.example' } })
      check(page.status === 403, `跨站 GET 期望 403，实际 ${page.status}`)
      const pairCallsBefore = source.pairCalls
      const post = await postForm(port, '/pair/reopen', { csrf }, { Origin: 'http://evil.example' })
      check(post.status === 403, `跨站 POST 期望 403，实际 ${post.status}`)
      check(source.pairCalls === pairCallsBefore, '跨站 POST 仍打开了配对窗口')
      // 控制 API：即使攻击者猜到了控制头，跨站 Origin 仍然先被拒绝。
      const controlPost = await postControlJson(port, '/api/pair', undefined, { Origin: 'http://evil.example' })
      check(controlPost.status === 403, `跨站控制 API 期望 403，实际 ${controlPost.status}`)
      check(source.pairCalls === pairCallsBefore, '跨站控制 API 仍打开了配对窗口')
      const sameOrigin = await postForm(port, '/pair/reopen', { csrf }, { Origin: `http://127.0.0.1:${port}` })
      check(sameOrigin.status === 303, `同源 POST 期望 303，实际 ${sameOrigin.status}`)
      const html = (await httpRequest(port, { path: '/' })).body
      csrf = extractCsrf(html)
      return '跨站 GET/POST（表单与控制 API）都是 403，同源 POST 正常 303'
    })

    await step('方法错误回 405（带 Allow），未知路径回 404', async () => {
      const getPost = await httpRequest(port, { path: '/pair/reopen' })
      check(getPost.status === 405, `GET /pair/reopen 期望 405，实际 ${getPost.status}`)
      check(headerValue(getPost, 'allow') === 'POST', 'GET /pair/reopen 的 Allow 不是 POST')
      const postPage = await httpRequest(port, {
        method: 'POST',
        path: '/',
        body: `csrf=${csrf}`,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      })
      check(postPage.status === 405, `POST / 期望 405，实际 ${postPage.status}`)
      check(headerValue(postPage, 'allow') === 'GET', 'POST / 的 Allow 不是 GET')
      const postState = await httpRequest(port, { method: 'POST', path: '/api/state' })
      check(postState.status === 405, `POST /api/state 期望 405，实际 ${postState.status}`)
      const postQr = await httpRequest(port, { method: 'POST', path: '/qr.svg' })
      check(postQr.status === 405, `POST /qr.svg 期望 405，实际 ${postQr.status}`)
      check(headerValue(postQr, 'allow') === 'GET', 'POST /qr.svg 的 Allow 不是 GET')
      const unknown = await httpRequest(port, { path: '/nope' })
      check(unknown.status === 404, `未知路径期望 404，实际 ${unknown.status}`)
      return '表单/JSON/QR 端点的 405 + Allow 与未知路径 404 都符合'
    })

    await step('没有 Host 头的原始请求 → 400/403', async () => {
      const raw = await rawExchange(port, 'GET / HTTP/1.1\r\nConnection: close\r\n\r\n')
      // Node 24 的 HTTP 服务器默认要求 Host（requireHostHeader），这类请求先被 Node 以 400 拒绝；
      // 若运行时放宽了该检查，则由页面的 Host 校验回 403。两条路径都必须在进入路由前拒绝。
      check(
        raw.startsWith('HTTP/1.1 400') || raw.startsWith('HTTP/1.1 403'),
        `缺 Host 期望 400/403，实际响应首行：${raw.slice(0, 40)}`,
      )
      return `HTTP/1.1 无 Host → ${raw.startsWith('HTTP/1.1 400') ? '400（Node requireHostHeader）' : '403（页面 Host 校验）'}`
    })

    await step('动作失败回 500 且日志 result=failed', async () => {
      source.failPairOnce = true
      const response = await postForm(port, '/pair/reopen', { csrf })
      check(response.status === 500, `状态码期望 500，实际 ${response.status}`)
      const failed = logRecords.find(record => record.event === 'pairing-page-action'
        && record.fields?.action === 'pair-reopen'
        && record.fields?.result === 'failed')
      check(failed !== undefined, '失败路径没有 result=failed 的动作日志')
      source.failPairOnce = true
      const apiResponse = await postControlJson(port, '/api/pair')
      checkJsonError(apiResponse, 500, 'pair-failed', 'POST /api/pair 失败路径')
      return '注入失败 → 表单 500 + 控制 API 500 pair-failed，均带 result=failed 日志'
    })

    await step('长窗口（> 1 小时）页面显示「长期有效」，不显示秒级倒计时', async () => {
      source.pairingTtlMs = LONG_PAIRING_TTL_MS
      source.pair()
      const ticket = source.currentPairing()
      check(ticket !== undefined, '长窗口自检数据源没有窗口')
      check(ticket.expiresAt === fakeNow + LONG_PAIRING_TTL_MS, '长窗口有效期没有按数据源生效')
      const html = (await httpRequest(port, { path: '/' })).body
      check(html.includes('长期有效'), '长窗口页面没有「长期有效」文案')
      check(!html.includes('id="remaining"'), '长窗口页面仍渲染秒级倒计时元素')
      check(html.includes('长期窗口等于长期可配对入口'), '长窗口页面没有长期配对的提示')
      check(html.includes(formatPageTimestamp(ticket.expiresAt)), '长窗口页面没有展示真实过期时间')
      const state = parseJsonObject((await httpRequest(port, { path: '/api/state' })).body, '/api/state')
      check(asRecord(state.pairing, 'pairing').expiresAt === ticket.expiresAt, '/api/state 没有反映长窗口到期时间')
      // 恢复默认窗口，后续步骤（stop/端口占用）不依赖长 TTL。
      source.pairingTtlMs = PAIRING_TTL_MS
      source.pair()
      return '30 天窗口 → 页面「长期有效」+ 过期时间，无 remaining 倒计时'
    })

    await step('CSRF 每个实例随机，日志里不出现任何令牌', async () => {
      const second = new PairingPageServer({ port: 0, source, log, now: clock })
      try {
        const started = await second.start()
        check(started.listening, '第二个实例没有进入监听状态')
        const secondHtml = (await httpRequest(started.port, { path: '/' })).body
        const secondCsrf = extractCsrf(secondHtml)
        check(secondCsrf !== csrf, '两个实例的 CSRF token 相同（应为进程/实例级随机值）')
      } finally {
        await second.stop()
      }
      const serializedLogs = JSON.stringify(logRecords)
      check(!serializedLogs.includes(csrf), '日志里出现了 CSRF token')
      for (const token of source.issuedTokens) {
        check(!serializedLogs.includes(token), '日志里出现了配对令牌')
      }
      check(!serializedLogs.includes('#instance='), '日志里出现了配对链接')
      const actions = logRecords.filter(record => record.event === 'pairing-page-action')
      check(actions.some(record => record.fields?.action === 'pair-reopen' && record.fields?.method === 'POST' && record.fields?.result === 'ok'), '成功重开窗口缺少动作日志')
      check(actions.some(record => record.fields?.action === 'device-revoke' && record.fields?.result === 'revoked'), '撤销成功缺少动作日志')
      check(actions.some(record => record.fields?.action === 'api-pair' && record.fields?.result === 'ok'), '控制 API 重开窗口缺少动作日志')
      check(actions.some(record => record.fields?.action === 'api-device-revoke' && record.fields?.result === 'revoked'), '控制 API 撤销缺少动作日志')
      check(actions.some(record => record.fields?.action === 'api-device-delete' && record.fields?.result === 'deleted'), '控制 API 删除缺少动作日志')
      check(actions.some(record => record.fields?.result === 'rejected'), '拒绝路径缺少动作日志')
      return `${actions.length} 条动作日志只有 action/method/result 与设备 id，无 CSRF、无配对令牌`
    })

    await step('stop 释放端口，再次 start 复用同一进程级 CSRF token', async () => {
      const stoppedPort = port
      await server.stop()
      check(server.port === undefined, 'stop 之后 port 仍不是 undefined')
      check(!(await canConnect(stoppedPort)), `stop 之后 127.0.0.1:${stoppedPort} 仍可连接`)
      await server.stop()
      const restarted = await server.start()
      check(restarted.listening, '重新 start 没有进入监听状态')
      check(restarted.port > 0, '重新 start 没有拿到端口')
      port = restarted.port
      const html = (await httpRequest(port, { path: '/' })).body
      check(extractCsrf(html) === csrf, '重启后 CSRF token 变了（应保持实例级不变）')
      return `端口 ${stoppedPort} 已释放；重新监听 ${port}，CSRF token 不变`
    })

    await step('端口被占用时 start 返回 listening:false 且只记 warn，不抛错', async () => {
      let blocker: Server | undefined
      let blockedPort = 0
      try {
        blocker = createHttpServer((_request, response) => {
          response.end('blocked')
        })
        blockedPort = await new Promise<number>((resolve, reject) => {
          const opened = blocker
          check(opened !== undefined, '阻挡服务器没有创建')
          opened.once('error', reject)
          opened.listen(0, '127.0.0.1', () => {
            const address = opened.address()
            resolve(typeof address === 'object' && address !== null ? address.port : 0)
          })
        })
        check(blockedPort > 0, '阻挡服务器没有拿到端口')
        const blockedLog: RemoteLogRecord[] = []
        const blocked = new PairingPageServer({
          port: blockedPort,
          source,
          log: (record) => {
            blockedLog.push(record)
          },
          now: clock,
        })
        const started = await blocked.start()
        check(started.listening === false, '端口被占用时 start 仍报告监听成功')
        check(blocked.port === undefined, '绑定失败后 port 仍不是 undefined')
        check(blocked.url === undefined, '绑定失败后 url 仍不是 undefined')
        const warn = blockedLog.find(record => record.event === 'pairing-page-failed' && record.level === 'warn')
        check(warn !== undefined, '端口占用没有写 pairing-page-failed warn 日志')
        check(warn.fields?.port === blockedPort, 'pairing-page-failed 的 fields.port 与实际端口不一致')
        await blocked.stop()
        return `127.0.0.1:${blockedPort} 冲突 → listening:false + warn，进程继续运行`
      } finally {
        if (blocker !== undefined) {
          await new Promise<void>((resolve) => {
            blocker?.close(() => {
              resolve()
            })
          })
        }
      }
    })
  } finally {
    await server.stop()
  }

  console.log('')
  if (failures.length > 0) {
    console.log(`FAIL  ${passed}/${total} 项通过，${failures.length} 项失败`)
    for (const failure of failures) console.log(`  - ${failure}`)
    return 1
  }
  console.log(`PASS  ${passed}/${passed} 项全部通过（页面/JSON/QR 契约 + 控制 API + Host/CSRF/CORS 防护 + 生命周期降级）`)
  return 0
}

// 兜底看门狗：任何一步把句柄留在事件循环里时，不能让自检一直挂着。
const watchdog = setTimeout(() => {
  console.error('FAIL  本机配对页自检在 60 s 内没有结束，判定有套接字或定时器未收尾。')
  process.exit(1)
}, 60_000)
watchdog.unref()

process.exitCode = await main().catch((error: unknown) => {
  console.error(`FAIL  自检主体抛出：${describeError(error)}`)
  return 1
})
