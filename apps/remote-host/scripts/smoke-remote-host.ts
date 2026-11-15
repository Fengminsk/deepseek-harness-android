/**
 * 远程 DSH PC 宿主的端到端冒烟：真实 TLS、真实 wss 升级、真实 JSON-RPC 帧、真实配对接口。
 *
 * 用真实实现而不是桩来覆盖本轮闭环：`./devices.ts` 的设备表与摘要落盘、`./pairing.ts` 的
 * 一次性窗口、`./index.ts` 的 `createPairingSurface` / `authenticationOutcome`，以及
 * `./server.ts` 的升级准入、握手门禁与设备撤销。
 *
 * 逐项断言（对应 `apps/android/docs/remote-dsh/protocol.md`）：
 * a. 缺 `Authorization` 的升级被 401 拒绝（§2.2 第 3 步）；
 * b. `Origin` 不匹配的升级被 403 拒绝（§2.2 第 2 步）；
 * c. `GET /ca.cer` 回 CA 证书 DER，其 SHA-256 等于宿主 instanceId（§2 配对第二步）；
 * d. `POST /pair` 用一次性令牌换到 `{deviceId, deviceToken, expiresAt}`（§2 配对第三步）；
 * e. `devices.json` 只存令牌摘要，磁盘上没有明文令牌（§2.2）；
 * f. 首帧不是 `protocol.hello` → `-32000 / handshake-required` + 关闭 `4002`（§3.3）；
 * g. 同一连接第二次 `protocol.hello` → `-32000 / duplicate-hello` + 关闭 `4002`（§3.3）；
 * h. 握手窗口内没有 `protocol.hello` → 关闭 `4002 / handshake-timeout`（§3.3）；
 * i. 配对令牌只能消耗一次（403），同一对端的错误尝试超限后回 429（§2.2 限速）；
 * j. 用配对得到的设备令牌连上并完成握手，`methods` / `unsupported` / `capabilities` 齐全（§3.2）；
 * k. 普通请求拿回 `result`，未注册方法拿回 JSON-RPC `error`（§4.1）；
 * l. 宿主主动 `notify` 的通知客户端能收到（§8.1）；
 * m. 撤销设备：收到 `remote.deviceRevoked` → 连接以 `4001` 关闭 → 重连被 `4001` 拒绝（§8.4）；
 * n. 断开后服务端连接数归零，且全程没有未处理的 rejection / 未捕获异常。
 *
 * 运行：`pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts`
 * 退出码：全部通过为 0；任一项失败为 1。临时目录与监听端口在 finally 里清理。
 *
 * 本机依赖缺陷开关（默认走发布态路径）：
 * `selfsigned@5` 依赖 `@peculiar/x509`，而当前 lockfile 把 `@peculiar/x509` 的
 * `@peculiar/asn1-schema` 解析成 2.9.4、把 `@peculiar/asn1-x509` 的解析成 2.11.1。
 * 两份实例各有自己的 schema 注册表，`new BasicConstraintsExtension()` 于是抛
 * `Cannot get schema for 'BasicConstraints' target`，`ensureTlsMaterial` 无法签发 CA。
 * 这属于安装态缺陷，脚本默认如实失败；设置 `SMOKE_REMOTE_HOST_UNIFY_ASN1=1` 时，
 * 本进程内把该依赖收敛成单一实例以便继续验证传输层——它不改变宿主代码，
 * 也不能作为发布态证据。
 *
 * @module @deepseek-ai/dsh-remote-host/scripts/smoke-remote-host
 */

import { createHash, randomBytes, randomUUID, X509Certificate } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import type { ClientRequest, IncomingHttpHeaders, IncomingMessage } from 'node:http'
import { request as httpsRequest, type RequestOptions } from 'node:https'
import { createRequire, registerHooks } from 'node:module'
import { connect as connectTcp } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import WebSocket, { type RawData } from 'ws'
import { DeviceStore } from '../src/devices.ts'
import { Identity, certificateFingerprint } from '../src/identity.ts'
import { authenticationOutcome, createPairingSurface } from '../src/index.ts'
import { PairingWindow } from '../src/pairing.ts'
import {
  REMOTE_CA_PATH,
  REMOTE_ORIGIN,
  REMOTE_PAIR_PATH,
  RemoteHostServer,
  type RemoteCloseOutcome,
  type RemoteConnection,
  type RemoteHandshake,
  type RemoteNativeProvider,
  type RemotePairingSurface,
} from '../src/server.ts'
import type { TlsMaterial } from '../src/tls.ts'

/** 打开「依赖收敛」开关的环境变量名。 */
const UNIFY_ASN1_ENV = 'SMOKE_REMOTE_HOST_UNIFY_ASN1'

/** 升级被拒的等待上限。 */
const UPGRADE_TIMEOUT_MS = 5_000

/** 单条帧 / 单次关闭的等待上限。 */
const FRAME_TIMEOUT_MS = 5_000

/** 断言「没有未处理的异步失败」前的观察窗口，给微任务与定时器一次浮出机会。 */
const REJECTION_SETTLE_MS = 150

/** 清理确认时探测端口的上限。 */
const PORT_PROBE_TIMEOUT_MS = 2_000

/** 断言总项数：进度行与汇总都用它，避免多一项就漏打印。 */
const TOTAL_STEPS = 14

/**
 * 本进程内的握手窗口。
 *
 * 协议 §3.3 的默认窗口是 10 s；冒烟把它压到 1 s，好让「没有 hello 就关闭」这一项不用
 * 等满 10 秒。其余步骤都在连接后立刻发 hello，不受影响。
 */
const SMOKE_HANDSHAKE_TIMEOUT_MS = 1_000

/** 冒烟用的配对窗口有效期。 */
const SMOKE_PAIRING_TTL_MS = 60_000

/** 冒烟签发的设备令牌有效期（180 天，与插件默认值一致）。 */
const SMOKE_DEVICE_TTL_MS = 180 * 24 * 60 * 60 * 1000

/** 故意不匹配 `REMOTE_ORIGIN` 的源，用于验证 403 分支。 */
const WRONG_ORIGIN = 'https://evil.example.com'

/** 一条 JSON-RPC 帧；字段按需读取，未认识字段一律忽略（协议 §0 硬规则 4）。 */
type Frame = Record<string, unknown>

/** 一次 await 帧的登记项。 */
interface FrameWaiter {
  readonly predicate: (frame: Frame) => boolean
  readonly resolve: (frame: Frame) => void
  readonly reject: (error: Error) => void
}

/** 逐项结果的状态。 */
type StepStatus = 'PASS' | 'FAIL' | 'SKIP'

/** 一项断言的结果。 */
interface StepResult {
  readonly id: string
  readonly label: string
  readonly status: StepStatus
  readonly detail: string
}

/** 一次 WS 关闭的事实。 */
interface CloseFact {
  readonly code: number
  readonly reason: string
}

const results: StepResult[] = []
let stepIndex = 0

/** 观察到但尚未断言的异步失败；`n` 项要求它保持为空。 */
const asyncFailures: string[] = []

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
 * 等待若干毫秒。
 * @param ms - 毫秒数。
 * @returns 计时结束即兑现。
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

/**
 * 从帧里取出错误对象。
 * @param frame - 已解析的帧。
 * @returns `{ code, message, data }`；不是错误帧时 undefined。
 */
function frameError(frame: Frame): { code: number; message: string; data: Record<string, unknown> } | undefined {
  const error = frame.error
  if (typeof error !== 'object' || error === null) return undefined
  const record = error as Record<string, unknown>
  // 协议 §1.2 要求 error 携带数字 code 与 message；缺失说明对端实现不合法，交给断言报告。
  const code = typeof record.code === 'number' ? record.code : Number.NaN
  const message = typeof record.message === 'string' ? record.message : ''
  const data = typeof record.data === 'object' && record.data !== null ? record.data as Record<string, unknown> : {}
  return { code, message, data }
}

/**
 * 断言条件成立；条件里的类型收窄在调用点继续生效。
 * @param condition - 待验证的条件，任意真值表达式。
 * @param message - 不成立时的中文原因。
 * @returns 无返回值。
 * @throws 条件不成立时抛出。
 */
function ensure(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

/**
 * 计算 UTF-8 文本的 sha256 十六进制摘要。
 * @param value - 待摘要的文本。
 * @returns 64 位小写十六进制。
 */
function sha256Hex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex')
}

/**
 * 找出本机安装里 `@peculiar/asn1-schema` 的「另一份」实例。
 *
 * 走 `selfsigned → @peculiar/x509 → @peculiar/asn1-x509 → @peculiar/asn1-schema`
 * 这条链，拿到的就是与 `@peculiar/x509` 自己那份不同的版本。
 * @returns 统一后应使用的模块绝对路径。
 */
function locateUnifiedAsn1Schema(): string {
  const fromScript = createRequire(import.meta.url)
  const selfsignedMain = fromScript.resolve('selfsigned')
  const fromSelfsigned = createRequire(selfsignedMain)
  const x509Package = fromSelfsigned.resolve('@peculiar/x509/package.json')
  const fromX509 = createRequire(x509Package)
  const asn1X509Package = fromX509.resolve('@peculiar/asn1-x509/package.json')
  return createRequire(asn1X509Package).resolve('@peculiar/asn1-schema')
}

/**
 * 在需要时把 `@peculiar/asn1-schema` 收敛成单一实例（仅本进程）。
 *
 * 只影响模块解析，不改变宿主代码；所以它能让冒烟继续跑，但不是发布态证据。
 * @returns 实际统一到的版本目录；未启用开关时 undefined。
 */
function maybeUnifyAsn1Schema(): string | undefined {
  if (process.env[UNIFY_ASN1_ENV] !== '1') return undefined
  const unified = locateUnifiedAsn1Schema()
  const url = pathToFileURL(unified).href
  const resolve: Parameters<typeof registerHooks>[0]['resolve'] = (specifier, context, nextResolve) => {
    if (specifier === '@peculiar/asn1-schema') return { url, shortCircuit: true }
    return nextResolve(specifier, context)
  }
  registerHooks({ resolve })
  return dirname(unified)
}

/**
 * 报告 TLS 备料失败，并在命中已知依赖缺陷时给出可执行的结论。
 * @param error - `ensureTlsMaterial` 抛出的值。
 * @returns 无返回值。
 */
function reportTlsFailure(error: unknown): void {
  const message = describeError(error)
  console.log(`FAIL  准备 TLS 材料失败（ensureTlsMaterial）：${message}`)
  if (!message.includes('Cannot get schema')) return
  console.log('  诊断：本机 node_modules 里有两份 @peculiar/asn1-schema——')
  console.log('    @peculiar/x509@1.14.3      → @peculiar/asn1-schema@2.9.4')
  console.log('    @peculiar/asn1-x509@2.11.1 → @peculiar/asn1-schema@2.11.1')
  console.log('  两份实例各有独立的 schema 注册表，装饰器注册的 schema 与序列化查的注册表不是同一张。')
  console.log('  修复方向：把 @peculiar/asn1-schema 收敛到单一版本（pnpm overrides + 重新安装），')
  console.log('  不要降级 selfsigned：tls.ts 需要 v5 的 ca 签发能力，v4（node-forge）没有。')
  console.log(`  仅验证传输层时可设置 ${UNIFY_ASN1_ENV}=1 再跑一次。`)
}

/**
 * 一条已升级的客户端连接：收帧、按条件等帧、发请求、等关闭。
 *
 * 收到的帧全部留在 `received` 里并被「消费」标记，所以同一帧不会被两项断言重复领取。
 */
class SmokeClient {
  private readonly socket: WebSocket
  private readonly received: Frame[] = []
  private readonly consumed = new Set<Frame>()
  private readonly waiters: FrameWaiter[] = []
  private readonly closeWaiters: ((fact: CloseFact) => void)[] = []
  private protocolViolation: Error | undefined
  private closeFact: CloseFact | undefined
  private closed = false

  /** @param socket - 已由 `connectOpen` 建立并处于 OPEN 的套接字。 */
  constructor(socket: WebSocket) {
    this.socket = socket
    socket.on('message', this.onMessage)
    socket.on('close', this.onClose)
    socket.on('error', this.onError)
  }

  /**
   * 发一个请求并等它的响应帧。
   * @param method - 方法名。
   * @param params - `params` 对象，缺省为 `{}`。
   * @returns 与本次请求 `id` 匹配的响应帧。
   */
  async call(method: string, params: Record<string, unknown> = {}): Promise<Frame> {
    const id = `a-${randomUUID()}`
    const response = this.waitFor(frame => frame.id === id, `方法 ${method} 的响应`)
    this.send({ jsonrpc: '2.0', id, method, params })
    return await response
  }

  /**
   * 等一条满足条件的帧：先查已收到的，再登记等待。
   * @param predicate - 帧匹配条件。
   * @param label - 超时信息里的中文说明。
   * @param timeoutMs - 等待上限。
   * @returns 匹配到的帧。
   */
  async waitFor(
    predicate: (frame: Frame) => boolean,
    label: string,
    timeoutMs: number = FRAME_TIMEOUT_MS,
  ): Promise<Frame> {
    const buffered = this.received.find(frame => !this.consumed.has(frame) && predicate(frame))
    if (buffered !== undefined) {
      this.consumed.add(buffered)
      return buffered
    }
    if (this.protocolViolation !== undefined) throw this.protocolViolation
    if (this.closed) throw new Error(`等待「${label}」时连接已经关闭`)
    return await new Promise<Frame>((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.waiters.findIndex(waiter => waiter.resolve === resolve)
        if (index >= 0) this.waiters.splice(index, 1)
        reject(new Error(`等待「${label}」超时（${timeoutMs} ms）`))
      }, timeoutMs)
      this.waiters.push({
        predicate,
        resolve: (frame) => {
          clearTimeout(timer)
          resolve(frame)
        },
        reject: (error) => {
          clearTimeout(timer)
          reject(error)
        },
      })
    })
  }

  /**
   * 等这条连接关闭。
   * @param timeoutMs - 等待上限。
   * @returns 关闭码与原因。
   */
  async waitForClose(timeoutMs: number = FRAME_TIMEOUT_MS): Promise<CloseFact> {
    const fact = this.closeFact
    if (fact !== undefined) return fact
    return await new Promise<CloseFact>((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.closeWaiters.indexOf(settle)
        if (index >= 0) this.closeWaiters.splice(index, 1)
        reject(new Error(`等待连接关闭超时（${timeoutMs} ms）`))
      }, timeoutMs)
      const settle = (value: CloseFact): void => {
        clearTimeout(timer)
        resolve(value)
      }
      this.closeWaiters.push(settle)
    })
  }

  /**
   * 发一条原始帧。
   * @param frame - 待发送的帧对象，按单行 JSON 写出（协议 §1.2）。
   * @returns 无返回值。
   */
  send(frame: Frame): void {
    ensure(
      this.socket.readyState === WebSocket.OPEN,
      `连接不在 OPEN 状态（readyState=${this.socket.readyState}），无法发送「${String(frame.method ?? frame.id)}」`,
    )
    this.socket.send(`${JSON.stringify(frame)}\n`)
  }

  /**
   * 客户端主动关闭。
   * @returns 关闭握手完成或超时断开后兑现。
   */
  async close(): Promise<void> {
    if (this.socket.readyState === WebSocket.CLOSED) return
    const done = new Promise<void>((resolve) => {
      if (this.closeFact !== undefined) {
        resolve()
        return
      }
      this.socket.once('close', () => {
        resolve()
      })
    })
    this.socket.close(1000, 'smoke-done')
    await Promise.race([done, sleep(UPGRADE_TIMEOUT_MS)])
    this.socket.terminate()
  }

  private readonly onMessage = (data: RawData): void => {
    const text = Buffer.isBuffer(data) ? data.toString('utf8') : Buffer.from(data as ArrayBuffer).toString('utf8')
    for (const line of text.split('\n')) {
      const trimmed = line.trim()
      if (trimmed.length === 0) continue
      let parsed: unknown
      try {
        parsed = JSON.parse(trimmed)
      } catch (error) {
        // 帧必须是一行合法 JSON（协议 §1.2）；解析不了就记成协议违规，让等待方立刻失败。
        this.protocolViolation = new Error(`收到无法解析的帧：${describeError(error)}；原文 ${trimmed.slice(0, 120)}`)
        this.failWaiters(this.protocolViolation)
        return
      }
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        this.protocolViolation = new Error(`收到的帧不是 JSON 对象：${trimmed.slice(0, 120)}`)
        this.failWaiters(this.protocolViolation)
        return
      }
      this.accept(parsed as Frame)
    }
  }

  private accept(frame: Frame): void {
    this.received.push(frame)
    const index = this.waiters.findIndex(waiter => waiter.predicate(frame))
    if (index < 0) return
    const waiter = this.waiters[index]
    if (waiter === undefined) return
    this.waiters.splice(index, 1)
    this.consumed.add(frame)
    waiter.resolve(frame)
  }

  private readonly onClose = (code: number, reason: Buffer): void => {
    this.closed = true
    this.closeFact = { code, reason: reason.toString('utf8') }
    for (const settle of this.closeWaiters.splice(0)) settle(this.closeFact)
    this.failWaiters(new Error('连接已关闭'))
  }

  private readonly onError = (error: Error): void => {
    this.failWaiters(error)
  }

  private failWaiters(error: Error): void {
    const pending = this.waiters.splice(0, this.waiters.length)
    for (const waiter of pending) waiter.reject(error)
  }
}

/**
 * 建立一条已升级的客户端连接。
 * @param port - 宿主监听端口，连接到 `wss://127.0.0.1:<port>/app`。
 * @param caPem - CA 证书 PEM；客户端按 CA 校验证书链，与 App 配对后的信任方式一致。
 * @param headers - 升级请求头。
 * @returns 已打开的客户端。
 */
async function connectOpen(port: number, caPem: string, headers: Record<string, string>): Promise<SmokeClient> {
  const socket = new WebSocket(`wss://127.0.0.1:${port}/app`, { ca: caPem, headers })
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.terminate()
      reject(new Error(`连接在 ${UPGRADE_TIMEOUT_MS} ms 内没有建立`))
    }, UPGRADE_TIMEOUT_MS)
    socket.once('open', () => {
      clearTimeout(timer)
      resolve()
    })
    socket.once('error', (error: Error) => {
      clearTimeout(timer)
      reject(error)
    })
  })
  return new SmokeClient(socket)
}

/**
 * 用设备令牌连上并完成握手。
 * @param port - 宿主端口。
 * @param caPem - CA 证书 PEM。
 * @param token - 设备令牌。
 * @param label - 握手里的设备显示名。
 * @returns 客户端与握手响应帧。
 */
async function connectAndHello(
  port: number,
  caPem: string,
  token: string,
  label: string,
): Promise<{ client: SmokeClient; hello: Frame }> {
  const client = await connectOpen(port, caPem, {
    Origin: REMOTE_ORIGIN,
    Authorization: `Bearer ${token}`,
  })
  const hello = await client.call('protocol.hello', {
    protocolVersion: 1,
    appVersion: '0.1.0+smoke',
    deviceLabel: label,
    capabilities: ['window-ack'],
  })
  return { client, hello }
}

/**
 * 发一次注定被拒的升级，取回 HTTP 状态码与响应体。
 * @param port - 宿主监听端口。
 * @param caPem - CA 证书 PEM。
 * @param headers - 升级请求头。
 * @param label - 失败信息里的中文说明。
 * @returns 状态码与响应体文本。
 */
async function expectRejectedUpgrade(
  port: number,
  caPem: string,
  headers: Record<string, string>,
  label: string,
): Promise<{ status: number; body: string }> {
  const socket = new WebSocket(`wss://127.0.0.1:${port}/app`, { ca: caPem, headers })
  return await new Promise<{ status: number; body: string }>((resolve, reject) => {
    let settled = false
    const finish = (action: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.terminate()
      action()
    }
    const timer = setTimeout(() => {
      finish(() => {
        reject(new Error(`${label}：${UPGRADE_TIMEOUT_MS} ms 内没有拿到 HTTP 状态码`))
      })
    }, UPGRADE_TIMEOUT_MS)
    socket.once('unexpected-response', (request: ClientRequest, response: IncomingMessage) => {
      const status = response.statusCode ?? 0
      const chunks: Buffer[] = []
      const settle = (): void => {
        finish(() => {
          resolve({ status, body: Buffer.concat(chunks).toString('utf8') })
        })
      }
      response.on('data', (chunk: Buffer) => {
        chunks.push(chunk)
      })
      // 服务端写完拒绝响应就断开：'end' 是常规路径，'close' 与 'error' 兜住被提前切断的情况。
      response.on('end', settle)
      response.on('close', settle)
      response.on('error', settle)
      void request
    })
    socket.once('open', () => {
      finish(() => {
        reject(new Error(`${label}：服务端错误地接受了这次升级`))
      })
    })
    // 被拒的升级同时会触发 'error'；状态码由 'unexpected-response' 给出，这里只吸收不让它变成未捕获异常。
    socket.once('error', () => {})
  })
}

/**
 * 用已撤销的设备令牌连一次，取回服务端发的连接级错误帧与关闭码。
 *
 * 协议 §2.2 第 5 步把令牌校验放在升级之后，所以这里必须先让升级成功、再从 `id: null`
 * 的错误帧里读原因。
 * @param port - 宿主端口。
 * @param caPem - CA 证书 PEM。
 * @param token - 已撤销的设备令牌。
 * @returns 错误帧（可能是 undefined）与关闭事实。
 */
async function expectAuthRejected(
  port: number,
  caPem: string,
  token: string,
): Promise<{ frame: Frame | undefined; close: CloseFact; upgradeStatus: number | undefined }> {
  const socket = new WebSocket(`wss://127.0.0.1:${port}/app`, {
    ca: caPem,
    headers: { Origin: REMOTE_ORIGIN, Authorization: `Bearer ${token}` },
  })
  return await new Promise((resolve, reject) => {
    let frame: Frame | undefined
    let upgradeStatus: number | undefined
    let close: CloseFact | undefined
    let settled = false
    const finish = (): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.terminate()
      resolve({
        frame,
        close: close ?? { code: 0, reason: '' },
        upgradeStatus,
      })
    }
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      socket.terminate()
      reject(new Error(`已撤销设备的连接在 ${UPGRADE_TIMEOUT_MS} ms 内没有关闭`))
    }, UPGRADE_TIMEOUT_MS)
    socket.on('message', (data: RawData) => {
      const text = Buffer.isBuffer(data) ? data.toString('utf8') : Buffer.from(data as ArrayBuffer).toString('utf8')
      for (const line of text.split('\n')) {
        const trimmed = line.trim()
        if (trimmed.length === 0) continue
        try {
          const parsed: unknown = JSON.parse(trimmed)
          if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) frame = parsed as Frame
        } catch (error) {
          // 错误帧解析失败本身就是被测行为的一部分，交给断言按「没有错误帧」报告。
          void error
        }
      }
    })
    socket.on('close', (code: number, reason: Buffer) => {
      close = { code, reason: reason.toString('utf8') }
      finish()
    })
    socket.on('unexpected-response', (_request: ClientRequest, response: IncomingMessage) => {
      upgradeStatus = response.statusCode ?? 0
      finish()
    })
    socket.on('error', () => {
      // 关闭过程中的 socket 错误不改变结论：帧与关闭码已经足以判定。
    })
  })
}

/** 一次 HTTP 往返的结果。 */
interface HttpResult {
  readonly status: number
  readonly headers: IncomingHttpHeaders
  readonly body: Buffer
}

/** `https.request` 选项加上可选的请求体；请求体由本适配器写出。 */
interface SmokeRequestOptions extends RequestOptions {
  readonly body?: string
}

/**
 * 对宿主发一次 HTTPS 请求。
 * @param port - 宿主端口。
 * @param options - `https.request` 的选项；`host` / `port` 由本函数补齐，`body` 由本函数写出。
 * @returns 状态码、响应头与响应体。
 */
async function httpRequest(port: number, options: SmokeRequestOptions): Promise<HttpResult> {
  return await new Promise<HttpResult>((resolve, reject) => {
    const request = httpsRequest({ host: '127.0.0.1', port, method: 'GET', ...options }, (response) => {
      const chunks: Buffer[] = []
      response.on('data', (chunk: Buffer) => {
        chunks.push(chunk)
      })
      response.on('end', () => {
        resolve({
          status: response.statusCode ?? 0,
          headers: response.headers,
          body: Buffer.concat(chunks),
        })
      })
    })
    const timer = setTimeout(() => {
      request.destroy(new Error(`HTTP 请求在 ${FRAME_TIMEOUT_MS} ms 内没有完成`))
    }, FRAME_TIMEOUT_MS)
    request.on('error', (error: Error) => {
      clearTimeout(timer)
      reject(error)
    })
    request.on('close', () => {
      clearTimeout(timer)
    })
    const body = options.body
    if (typeof body === 'string') request.write(body)
    request.end()
  })
}

/**
 * 发一次 `POST /pair`。
 * @param port - 宿主端口。
 * @param caPem - 已固定的 CA 证书 PEM。
 * @param payload - 请求体对象。
 * @returns 状态码与响应体文本。
 */
async function postPair(
  port: number,
  caPem: string,
  payload: Record<string, unknown>,
): Promise<{ status: number; body: string; headers: IncomingHttpHeaders }> {
  const body = JSON.stringify(payload)
  const result = await httpRequest(port, {
    path: REMOTE_PAIR_PATH,
    method: 'POST',
    ca: caPem,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(body, 'utf8'),
    },
    body,
  })
  return { status: result.status, body: result.body.toString('utf8'), headers: result.headers }
}

/**
 * 探测端口是否已经不再监听。
 * @param port - 监听端口。
 * @returns `true` 表示连接被拒（已释放）；`false` 表示还能连上；`undefined` 表示无法确认。
 */
async function probePortReleased(port: number): Promise<boolean | undefined> {
  return await new Promise<boolean | undefined>((resolve) => {
    const socket = connectTcp({ port, host: '127.0.0.1' })
    let settled = false
    const finish = (value: boolean | undefined): void => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(value)
    }
    socket.setTimeout(PORT_PROBE_TIMEOUT_MS, () => {
      // 超时既可能是防火墙丢包也可能是仍在监听，不足以作结论。
      finish(undefined)
    })
    socket.once('connect', () => {
      finish(false)
    })
    socket.once('error', () => {
      finish(true)
    })
  })
}

/**
 * 跑一项断言并逐项打印结果。失败不中断后续项，但会在最后计入退出码。
 * @param id - 断言编号（a–n）。
 * @param label - 中文说明。
 * @param run - 断言本体，返回通过时展示的细节。
 * @returns 无返回值。
 */
async function step(id: string, label: string, run: () => Promise<string>): Promise<void> {
  stepIndex += 1
  const index = stepIndex
  try {
    const detail = await run()
    results.push({ id, label, status: 'PASS', detail })
    console.log(`[${index}/${TOTAL_STEPS}] ${id}. ${label} → PASS：${detail}`)
  } catch (error) {
    const detail = describeError(error)
    results.push({ id, label, status: 'FAIL', detail })
    console.log(`[${index}/${TOTAL_STEPS}] ${id}. ${label} → FAIL：${detail}`)
  }
}

/**
 * 记录一项因前置失败而无法执行的断言。
 * @param id - 断言编号。
 * @param label - 中文说明。
 * @param reason - 跳过原因。
 * @returns 无返回值。
 */
function skip(id: string, label: string, reason: string): void {
  stepIndex += 1
  const index = stepIndex
  results.push({ id, label, status: 'SKIP', detail: reason })
  console.log(`[${index}/${TOTAL_STEPS}] ${id}. ${label} → SKIP：${reason}`)
}

/**
 * 打印逐项结果并给出退出码。
 * @param cleanup - 清理确认结果。
 * @returns 进程退出码。
 */
function report(cleanup: { readonly homeRemoved: boolean; readonly portReleased: boolean | undefined }): number {
  const portText = cleanup.portReleased === true
    ? '已释放（连接被拒）'
    : cleanup.portReleased === false
      ? '仍在监听（残留！）'
      : '无法确认（探测超时）'
  console.log('')
  console.log(`清理：临时目录 ${cleanup.homeRemoved ? '已删除' : '删除失败（残留！）'}；监听端口 ${portText}`)

  const failed = results.filter(result => result.status === 'FAIL')
  const skipped = results.filter(result => result.status === 'SKIP')
  const passed = results.filter(result => result.status === 'PASS')
  console.log('')
  if (failed.length > 0) {
    console.log(`FAIL  ${passed.length}/${TOTAL_STEPS} 项通过，${failed.length} 项失败${skipped.length > 0 ? `，${skipped.length} 项跳过` : ''}`)
    for (const result of failed) console.log(`  - ${result.id}. ${result.label}：${result.detail}`)
    return 1
  }
  console.log(`PASS  ${passed.length}/${TOTAL_STEPS} 项全部通过${skipped.length > 0 ? `（${skipped.length} 项跳过）` : ''}`)
  if (cleanup.portReleased === false || !cleanup.homeRemoved) {
    console.log('WARN  清理不完整：见上方「清理」一行。')
    return 1
  }
  return 0
}

/**
 * 冒烟主体：备料、起服务、按协议逐项验证、收尾。
 *
 * 任何阶段抛出都收敛成打印 + 非零退出码，绝不把异常留成未处理的 rejection。
 * @param ensureTlsMaterial - 与生产同一份 TLS 备料实现。
 * @returns 进程退出码：全部通过为 0。
 */
async function main(ensureTlsMaterial: typeof import('../src/tls.ts')['ensureTlsMaterial']): Promise<number> {
  // 异步失败的观察窗：运行期间任何未处理的 rejection / 未捕获异常都记下来，由 n 项断言。
  process.on('unhandledRejection', (reason: unknown) => {
    asyncFailures.push(`unhandledRejection ${describeError(reason)}`)
  })
  process.on('uncaughtException', (error: Error) => {
    asyncFailures.push(`uncaughtException ${describeError(error)}`)
  })

  // 1) 临时 DSH_HOME + 真实自签 TLS 材料（与 index.ts 相同的目录布局：<DSH_HOME>/remote-host）。
  const home = await mkdtemp(join(tmpdir(), 'dsh-remote-smoke-'))
  process.env.DSH_HOME = home
  const stateDir = join(home, 'remote-host')
  console.log(`临时 DSH_HOME：${home}`)

  let tls: TlsMaterial
  try {
    tls = await ensureTlsMaterial({ dir: stateDir, hosts: ['127.0.0.1', 'localhost'], commonName: 'DSH 冒烟宿主' })
  } catch (error) {
    reportTlsFailure(error)
    await rm(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
    return 1
  }
  console.log('TLS：已签发 CA 与服务器叶子证书')

  const identity = await Identity.load(stateDir)
  console.log(`宿主 instanceId（CA 指纹）：${identity.instanceId}`)

  // 2) 真实设备表与配对窗口：配对接口与鉴权都走生产实现。
  const devices = await DeviceStore.open(join(stateDir, 'devices.json'))
  const pairing = new PairingWindow()
  const pairingSurface: RemotePairingSurface = createPairingSurface(tls.caPem, pairing, devices, SMOKE_DEVICE_TTL_MS)
  const ticket = pairing.open(SMOKE_PAIRING_TTL_MS)
  console.log('配对窗口：已打开（令牌只在本进程内使用）')

  const hostInfo = { name: '冒烟宿主', platform: process.platform, home }
  const handshake: RemoteHandshake = {
    hostName: hostInfo.name,
    hostHome: home,
    methods: ['protocol.hello', 'echo.echo', 'runtime.info'],
    unsupported: ['documents.*', 'linuxVm.*', 'scheduleWake.*'],
    capabilities: ['window-ack'],
    timeoutMs: SMOKE_HANDSHAKE_TIMEOUT_MS,
  }
  const nativeProvider: RemoteNativeProvider = {
    handles: () => false,
    request: (method: string) => {
      throw new Error(`桩宿主没有 native.* 应答者，无法应答「${method}」。`)
    },
  }

  let openConnections = 0
  const closeWaiters: ((outcome: RemoteCloseOutcome) => void)[] = []
  let connectionRef: RemoteConnection | undefined

  const server = new RemoteHostServer({
    port: 0,
    host: '127.0.0.1',
    tls: { certPem: tls.certPem, keyPem: tls.keyPem },
    authenticate: async (token: string) => authenticationOutcome(await devices.authorize(token)),
    nativeProvider,
    handshake,
    pairing: pairingSurface,
    onConnection: (connection: RemoteConnection) => {
      openConnections += 1
      connectionRef = connection
      // 未注册方法在这里失败：传输层把抛出值转成 JSON-RPC error 帧。
      connection.onRequest((method: string, params: Record<string, unknown>) => {
        switch (method) {
          case 'echo.echo':
            return params
          case 'runtime.info':
            return { host: hostInfo, pid: process.pid, capabilities: ['window-ack'] }
          default:
            throw new Error(`未注册的方法：${method}`)
        }
      })
    },
    onClose: (_connection: RemoteConnection, outcome: RemoteCloseOutcome) => {
      openConnections -= 1
      const waiter = closeWaiters.shift()
      waiter?.(outcome)
    },
    log: () => {},
  })

  const bound = await server.start()
  console.log(`监听：wss://127.0.0.1:${bound.port}/app（协议路径 /app，Origin ${REMOTE_ORIGIN}）`)
  console.log('')

  let activeClient: SmokeClient | undefined
  // 配对成功的设备；后续连接与撤销都用它。
  let deviceToken: string | undefined
  let deviceId: string | undefined
  let cleanup: { readonly homeRemoved: boolean; readonly portReleased: boolean | undefined } = {
    homeRemoved: false,
    portReleased: undefined,
  }

  try {
    // a) 缺 Authorization：升级前必须 401（协议 §2.2 第 3 步）。
    await step('a', '缺 Authorization 的升级被拒', async () => {
      const rejected = await expectRejectedUpgrade(bound.port, tls.caPem, { Origin: REMOTE_ORIGIN }, '缺 Authorization')
      ensure(rejected.status === 401, `期望 HTTP 401，实际 ${rejected.status}（响应体 ${JSON.stringify(rejected.body)}）`)
      ensure(!rejected.body.includes(ticket.token), '401 响应体回显了配对令牌，违反协议 §2.2')
      return `HTTP 401，响应体 ${rejected.body.length} 字节`
    })

    // b) Origin 不匹配：即使令牌形态正确也必须 403（协议 §2.2 第 2 步，先于鉴权）。
    await step('b', 'Origin 不是协议源时被拒', async () => {
      const rejected = await expectRejectedUpgrade(
        bound.port,
        tls.caPem,
        { Origin: WRONG_ORIGIN, Authorization: `Bearer ${ticket.token}` },
        'Origin 不匹配',
      )
      ensure(rejected.status === 403, `期望 HTTP 403，实际 ${rejected.status}（响应体 ${JSON.stringify(rejected.body)}）`)
      return `HTTP 403（Origin=${WRONG_ORIGIN}）`
    })

    // c) /ca.cer：回 CA 证书 DER，指纹必须等于 instanceId（App 的 TOFU 判据）。
    await step('c', 'GET /ca.cer 的证书指纹等于 instanceId', async () => {
      const response = await httpRequest(bound.port, {
        path: REMOTE_CA_PATH,
        method: 'GET',
        // 首信任：此时还没有可信参照，与 App 的 fetchCa 一样先接受自签证书。
        rejectUnauthorized: false,
      })
      ensure(response.status === 200, `期望 HTTP 200，实际 ${response.status}`)
      const contentType = String(response.headers['content-type'] ?? '')
      ensure(
        contentType === 'application/x-x509-ca-cert' || contentType === 'application/pkix-cert',
        `content-type 期望 application/x-x509-ca-cert 或 application/pkix-cert，实际 ${JSON.stringify(contentType)}`,
      )
      const der = response.body
      ensure(der.length > 64 && der[0] === 0x30, `/ca.cer 的响应体不是 DER 证书（${der.length} 字节）`)
      const fingerprint = createHash('sha256').update(der).digest('hex')
      ensure(
        fingerprint === identity.instanceId,
        `CA 指纹期望 ${identity.instanceId}，实际 ${fingerprint}；App 会拒绝固定`,
      )
      // 与 tls.ts 的自检口径对齐：PEM → DER 的指纹必须与响应体一致。
      ensure(certificateFingerprint(tls.caPem) === fingerprint, 'PEM 与 /ca.cer 的 DER 指纹不一致')
      new X509Certificate(der)
      return `HTTP 200，content-type=${contentType}，DER ${der.length} 字节，sha256=${fingerprint.slice(0, 16)}…`
    })

    // d) POST /pair：一次性配对令牌换设备令牌（协议 §2 配对第三步）。
    await step('d', 'POST /pair 用一次性令牌换到设备令牌', async () => {
      const response = await postPair(bound.port, tls.caPem, {
        token: ticket.token,
        deviceLabel: '冒烟手机',
        appVersion: '0.1.0+smoke',
      })
      ensure(response.status === 200, `期望 HTTP 200，实际 ${response.status}（响应体 ${response.body}）`)
      ensure(
        String(response.headers['cache-control'] ?? '') === 'no-store',
        `配对响应必须 no-store，实际 ${JSON.stringify(response.headers['cache-control'])}`,
      )
      const parsed: unknown = JSON.parse(response.body)
      ensure(typeof parsed === 'object' && parsed !== null, '配对响应不是 JSON 对象')
      const body = parsed as Record<string, unknown>
      ensure(typeof body.deviceId === 'string' && /^[0-9a-f]{32}$/u.test(body.deviceId), `deviceId 非法：${JSON.stringify(body.deviceId)}`)
      ensure(
        typeof body.deviceToken === 'string' && /^[A-Za-z0-9_-]{43}$/u.test(body.deviceToken),
        'deviceToken 不是 43 字符 base64url',
      )
      ensure(typeof body.expiresAt === 'number' && body.expiresAt > Date.now(), `expiresAt 非法：${JSON.stringify(body.expiresAt)}`)
      deviceId = body.deviceId
      deviceToken = body.deviceToken
      return `deviceId=${deviceId}，expiresAt=${new Date(body.expiresAt).toISOString()}`
    })

    if (deviceToken === undefined || deviceId === undefined) {
      skip('e', 'devices.json 只存令牌摘要', '前置步骤 d 没有换到设备令牌')
      skip('f', '首帧不是 protocol.hello 时关闭 4002', '前置步骤 d 没有换到设备令牌')
      skip('g', '重复 protocol.hello 时关闭 4002', '前置步骤 d 没有换到设备令牌')
      skip('h', '握手窗口超时关闭 4002', '前置步骤 d 没有换到设备令牌')
      skip('i', '配对令牌单次有效与对端限速', '前置步骤 d 没有换到设备令牌')
      skip('j', '设备令牌能连上并完成握手', '前置步骤 d 没有换到设备令牌')
      skip('k', '普通请求与未注册方法', '前置步骤 d 没有换到设备令牌')
      skip('l', '宿主主动通知客户端能收到', '前置步骤 d 没有换到设备令牌')
      skip('m', '撤销设备后连接 4001 且重连被拒', '前置步骤 d 没有换到设备令牌')
      skip('n', '断开后连接数归零且无未处理 rejection', '前置步骤 d 没有换到设备令牌')
    } else {
      const token = deviceToken
      const id = deviceId

      // e) devices.json 只存摘要：明文令牌不得落盘（协议 §2.2）。
      await step('e', 'devices.json 只存令牌摘要', async () => {
        const file = join(stateDir, 'devices.json')
        const text = await readFile(file, 'utf8')
        ensure(!text.includes(token), 'devices.json 里出现了明文设备令牌')
        const parsed: unknown = JSON.parse(text)
        ensure(typeof parsed === 'object' && parsed !== null, 'devices.json 不是 JSON 对象')
        const records = (parsed as Record<string, unknown>).devices
        ensure(Array.isArray(records), 'devices.json 缺少 devices 数组')
        const record = records.find((entry: unknown) => (entry as Record<string, unknown> | undefined)?.id === id) as
          | Record<string, unknown>
          | undefined
        ensure(record !== undefined, `devices.json 里没有设备 ${id}`)
        ensure(record.tokenDigest === sha256Hex(token), 'devices.json 的 tokenDigest 不是设备令牌的 sha256')
        ensure(record.label === '冒烟手机', `设备显示名期望「冒烟手机」，实际 ${JSON.stringify(record.label)}`)
        return `1 条记录，tokenDigest=${String(record.tokenDigest).slice(0, 16)}…，无明文令牌`
      })

      // f) 首帧不是 protocol.hello：回 -32000 / handshake-required 再关闭 4002（协议 §3.3）。
      await step('f', '首帧不是 protocol.hello 时关闭 4002', async () => {
        const client = await connectOpen(bound.port, tls.caPem, {
          Origin: REMOTE_ORIGIN,
          Authorization: `Bearer ${token}`,
        })
        const response = await client.call('runtime.info')
        const error = frameError(response)
        ensure(error !== undefined, '握手前发业务请求没有收到错误帧')
        ensure(error.code === -32000, `error.code 期望 -32000，实际 ${error.code}`)
        ensure(error.data.code === 'protocol-mismatch', `error.data.code 期望 protocol-mismatch，实际 ${JSON.stringify(error.data.code)}`)
        ensure(error.data.detail === 'handshake-required', `error.data.detail 期望 handshake-required，实际 ${JSON.stringify(error.data.detail)}`)
        const close = await client.waitForClose()
        ensure(close.code === 4002, `关闭码期望 4002，实际 ${close.code}（reason=${close.reason}）`)
        return 'error=-32000 detail=handshake-required，关闭码 4002'
      })

      // g) 重复握手：回 -32000 / duplicate-hello 再关闭 4002（协议 §3.3）。
      await step('g', '重复 protocol.hello 时关闭 4002', async () => {
        const connected = await connectAndHello(bound.port, tls.caPem, token, '冒烟手机')
        ensure(frameError(connected.hello) === undefined, '首次握手失败了')
        const again = await connected.client.call('protocol.hello', {
          protocolVersion: 1,
          appVersion: '0.1.0+smoke',
          deviceLabel: '冒烟手机',
          capabilities: ['window-ack'],
        })
        const error = frameError(again)
        ensure(error !== undefined, '第二次握手没有收到错误帧')
        ensure(error.code === -32000, `error.code 期望 -32000，实际 ${error.code}`)
        ensure(error.data.detail === 'duplicate-hello', `error.data.detail 期望 duplicate-hello，实际 ${JSON.stringify(error.data.detail)}`)
        const close = await connected.client.waitForClose()
        ensure(close.code === 4002, `关闭码期望 4002，实际 ${close.code}（reason=${close.reason}）`)
        return '第二次握手 → error=-32000 detail=duplicate-hello，关闭码 4002'
      })

      // h) 握手窗口内没有 protocol.hello：关闭 4002 / handshake-timeout（协议 §3.3）。
      await step('h', '握手窗口内没有 hello 时关闭 4002', async () => {
        const client = await connectOpen(bound.port, tls.caPem, {
          Origin: REMOTE_ORIGIN,
          Authorization: `Bearer ${token}`,
        })
        const close = await client.waitForClose(SMOKE_HANDSHAKE_TIMEOUT_MS + FRAME_TIMEOUT_MS)
        ensure(close.code === 4002, `关闭码期望 4002，实际 ${close.code}`)
        ensure(
          close.reason === 'handshake-timeout',
          `关闭原因期望 handshake-timeout，实际 ${JSON.stringify(close.reason)}`,
        )
        return `关闭码 4002，reason=${close.reason}（${SMOKE_HANDSHAKE_TIMEOUT_MS} ms 窗口）`
      })

      // i) 配对令牌单次有效与对端限速（协议 §2.2）：401 令牌无效 / 403 窗口已关闭 / 429 限流。
      await step('i', '配对令牌单次有效与对端限速', async () => {
        const reused = await postPair(bound.port, tls.caPem, {
          token: ticket.token,
          deviceLabel: '冒烟手机',
          appVersion: '0.1.0+smoke',
        })
        ensure(reused.status === 403, `已消耗的令牌期望 HTTP 403，实际 ${reused.status}`)
        pairing.open(SMOKE_PAIRING_TTL_MS)
        const wrong = randomBytes(32).toString('base64url')
        const statuses: number[] = []
        for (let attempt = 0; attempt < 6; attempt += 1) {
          const rejected = await postPair(bound.port, tls.caPem, {
            token: wrong,
            deviceLabel: '冒烟手机',
            appVersion: '0.1.0+smoke',
          })
          statuses.push(rejected.status)
          ensure(!rejected.body.includes(wrong), '配对失败响应回显了令牌')
        }
        const firstFive = statuses.slice(0, 5)
        ensure(firstFive.every(status => status === 401), `前 5 次错误令牌期望 401，实际 ${firstFive.join(',')}`)
        const sixth = statuses[5]
        ensure(sixth === 429, `第 6 次错误令牌期望 429，实际 ${sixth}`)
        return '重复令牌 → 403；错误令牌 ×5 → 401，第 6 次 → 429'
      })

      // j) 设备令牌能连上并完成握手（协议 §3.2）。
      await step('j', '设备令牌能连上并完成握手', async () => {
        const connected = await connectAndHello(bound.port, tls.caPem, token, '冒烟手机')
        const error = frameError(connected.hello)
        ensure(error === undefined, `protocol.hello 返回了错误帧：${JSON.stringify(connected.hello.error)}`)
        const result = connected.hello.result
        ensure(typeof result === 'object' && result !== null, 'protocol.hello 的 result 不是对象')
        const hello = result as Record<string, unknown>
        ensure(hello.protocolVersion === 1, `protocolVersion 期望 1，实际 ${JSON.stringify(hello.protocolVersion)}`)
        const host = hello.host
        ensure(typeof host === 'object' && host !== null, '握手响应缺少 host 对象')
        const hostRecord = host as Record<string, unknown>
        ensure(hostRecord.name === hostInfo.name, `host.name 期望 ${hostInfo.name}，实际 ${JSON.stringify(hostRecord.name)}`)
        ensure(hostRecord.platform === process.platform, `host.platform 期望 ${process.platform}，实际 ${JSON.stringify(hostRecord.platform)}`)
        ensure(hostRecord.home === home, 'host.home 与宿主 DSH 主目录不一致')
        ensure(
          Array.isArray(hello.methods) && (hello.methods as unknown[]).length === handshake.methods.length,
          `methods 期望 ${handshake.methods.length} 项，实际 ${JSON.stringify(hello.methods)}`,
        )
        ensure(
          Array.isArray(hello.unsupported) && (hello.unsupported as string[]).includes('documents.*'),
          `unsupported 里没有 documents.*：${JSON.stringify(hello.unsupported)}`,
        )
        ensure(
          Array.isArray(hello.capabilities) && (hello.capabilities as string[]).includes('window-ack'),
          `capabilities 里没有 window-ack：${JSON.stringify(hello.capabilities)}`,
        )
        activeClient = connected.client
        return `methods=${(hello.methods as unknown[]).length} 项，unsupported 含 documents.*，capabilities 含 window-ack`
      })

      if (activeClient === undefined) {
        skip('k', '普通请求与未注册方法', '前置步骤 j 没有完成握手')
        skip('l', '宿主主动通知客户端能收到', '前置步骤 j 没有完成握手')
        skip('m', '撤销设备后连接 4001 且重连被拒', '前置步骤 j 没有完成握手')
        skip('n', '断开后连接数归零且无未处理 rejection', '前置步骤 j 没有完成握手')
      } else {
        const client = activeClient

        // k) 普通请求回 result；未注册方法回 error（协议 §4.1）。
        await step('k', '普通请求与未注册方法', async () => {
          const params = { text: '远程冒烟', nested: { n: 7 }, list: [1, 2, 3] }
          const echoed = await client.call('echo.echo', params)
          ensure(frameError(echoed) === undefined, `echo.echo 返回了错误帧：${JSON.stringify(echoed.error)}`)
          ensure(
            JSON.stringify(echoed.result) === JSON.stringify(params),
            `echo.echo 的 result 与 params 不一致：${JSON.stringify(echoed.result)}`,
          )
          const info = await client.call('runtime.info')
          ensure(frameError(info) === undefined, `runtime.info 返回了错误帧：${JSON.stringify(info.error)}`)
          ensure(typeof info.result === 'object' && info.result !== null, 'runtime.info 的 result 不是对象')
          ensure((info.result as Record<string, unknown>).pid === process.pid, 'runtime.info 的 pid 与宿主不一致')
          const unknown = await client.call('smoke.not-registered', { any: true })
          const error = frameError(unknown)
          ensure(error !== undefined, `未注册方法没有返回 error 帧：${JSON.stringify(unknown)}`)
          ensure(Number.isFinite(error.code) && error.code < 0, `error.code 不是负数：${JSON.stringify(error.code)}`)
          ensure(error.message.includes('smoke.not-registered'), `error.message 没有提到方法名：${JSON.stringify(error.message)}`)
          // 协议 §4.1 要求 -32601；传输层统一给 -32603（HANDOFF §7 第 2 条的已知偏差），这里只记录实际值。
          const note = error.code === -32601 ? '' : `（协议 §4.1 目标为 -32601，当前由传输层给出 ${error.code}）`
          return `echo.echo 原样回显 3 个字段；未注册方法 error.code=${error.code}${note}`
        })

        // l) 宿主 → App 的通知：没有 id，也不等应答（协议 §8.1）。
        await step('l', '宿主主动通知客户端能收到', async () => {
          const active = connectionRef
          ensure(active !== undefined, '服务端没有给出 RemoteConnection，无法发通知')
          if (active === undefined) throw new Error('服务端没有给出 RemoteConnection')
          const arrived = client.waitFor(
            frame => frame.method === 'runtime.status' && frame.id === undefined,
            '宿主通知 runtime.status',
          )
          active.notify('runtime.status', { phase: 'ready', generation: 1 })
          const frame = await arrived
          ensure(frame.jsonrpc === '2.0', `通知帧的 jsonrpc 期望 "2.0"，实际 ${JSON.stringify(frame.jsonrpc)}`)
          const params = frame.params
          ensure(typeof params === 'object' && params !== null, 'runtime.status 的 params 不是对象')
          ensure((params as Record<string, unknown>).phase === 'ready', 'runtime.status 的 phase 期望 ready')
          return '收到 method=runtime.status，params.phase=ready，帧里没有 id'
        })

        // m) 撤销设备：先落盘删除，再推 remote.deviceRevoked，最后 4001 关闭；重连必须被拒（协议 §8.4）。
        await step('m', '撤销设备后连接 4001 且重连被拒', async () => {
          const revokedNotification = client.waitFor(
            frame => frame.method === 'remote.deviceRevoked',
            '撤销通知 remote.deviceRevoked',
          )
          const revoked = await server.revokeDevice(devices, id, 'user-revoked')
          ensure(revoked.revoked, '设备没有被撤销（可能已经不处于有效状态）')
          ensure(revoked.closed === 1, `期望关闭 1 条连接，实际 ${revoked.closed}`)
          const frame = await revokedNotification
          const params = frame.params as Record<string, unknown>
          ensure(params.deviceId === id, `撤销通知的 deviceId 期望 ${id}，实际 ${JSON.stringify(params.deviceId)}`)
          ensure(params.reason === 'user-revoked', `撤销通知的 reason 期望 user-revoked，实际 ${JSON.stringify(params.reason)}`)
          ensure(typeof params.revokedAt === 'number' && params.revokedAt > 0, '撤销通知缺少 revokedAt')
          const close = await client.waitForClose()
          ensure(close.code === 4001, `连接关闭码期望 4001，实际 ${close.code}（reason=${close.reason}）`)
          activeClient = undefined
          const rejected = await expectAuthRejected(bound.port, tls.caPem, token)
          const error = rejected.frame === undefined ? undefined : frameError(rejected.frame)
          ensure(error !== undefined, '撤销后重连没有收到 id:null 的错误帧')
          ensure(error.code === -32002, `错误帧 code 期望 -32002，实际 ${error.code}`)
          ensure(error.data.code === 'auth-revoked', `error.data.code 期望 auth-revoked，实际 ${JSON.stringify(error.data.code)}`)
          ensure(rejected.close.code === 4001, `重连关闭码期望 4001，实际 ${rejected.close.code}`)
          ensure(!JSON.stringify(rejected.frame ?? {}).includes(token), '撤销错误帧回显了设备令牌')
          return '撤销通知 reason=user-revoked；在线连接 4001 关闭；重连 -32002 + 4001'
        })

        // n) 断开后服务端连接数归零，且全程没有未处理的异步失败。
        await step('n', '断开后连接数归零且无未处理 rejection', async () => {
          // 等待服务端把已断开的连接从表里摘掉（m 项已触发关闭）。
          const deadline = Date.now() + UPGRADE_TIMEOUT_MS
          while (openConnections !== 0 && Date.now() < deadline) await sleep(20)
          ensure(openConnections === 0, `服务端连接计数期望 0，实际 ${openConnections}`)
          await sleep(REJECTION_SETTLE_MS)
          ensure(asyncFailures.length === 0, `出现了未处理的异步失败：${asyncFailures.join('；')}`)
          return '服务端连接数 0，未处理异常 0 条'
        })
      }
    }

    if (activeClient !== undefined) {
      // 收尾前主动断开：让 onClose 走一次真实路径（撤销之外的关闭路径）。
      const closed = new Promise<RemoteCloseOutcome>((resolve) => {
        closeWaiters.push(resolve)
      })
      await activeClient.close()
      await Promise.race([closed, sleep(UPGRADE_TIMEOUT_MS)])
      activeClient = undefined
    }
  } catch (error) {
    // 兜底：准备阶段之外的意外抛出也必须变成 FAIL，而不是未处理的 rejection。
    results.push({ id: '!', label: '运行期意外抛出', status: 'FAIL', detail: describeError(error) })
    console.log(`[!] 运行期意外抛出 → FAIL：${describeError(error)}`)
  } finally {
    // 收尾：先断客户端，再停服务，最后删临时目录；任何一步都不跳过。
    if (activeClient !== undefined) {
      await activeClient.close().catch(() => {})
      activeClient = undefined
    }
    await server.stop().catch(() => {})
    await rm(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
    cleanup = {
      homeRemoved: !existsSync(home),
      portReleased: await probePortReleased(bound.port),
    }
  }

  return report(cleanup)
}

// 依赖收敛必须在加载 tls.ts（进而加载 selfsigned）之前完成，因此这里用动态 import。
const unifiedSchemaDir = maybeUnifyAsn1Schema()
if (unifiedSchemaDir !== undefined) {
  console.log(`注意：${UNIFY_ASN1_ENV}=1，已在本进程内把 @peculiar/asn1-schema 统一到 ${unifiedSchemaDir}`)
  console.log('      这是绕过本机安装缺陷的临时手段，不构成发布态证据。')
  console.log('')
}
const tlsModule = await import('../src/tls.ts')

// 兜底看门狗：收尾逻辑若把句柄留在事件循环里，不能让脚本一直挂着。
const watchdog = setTimeout(() => {
  console.error('FAIL  冒烟在 60 s 内没有结束，判定有句柄或连接未收尾。')
  process.exit(1)
}, 60_000)
watchdog.unref()

process.exitCode = await main(tlsModule.ensureTlsMaterial).catch((error: unknown) => {
  console.error(`FAIL  冒烟主体抛出：${describeError(error)}`)
  return 1
})
