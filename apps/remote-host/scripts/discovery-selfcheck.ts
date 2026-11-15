/**
 * 局域网发现自检：证明 `../src/discovery.ts` 的协议字段、限速与失败降级成立。
 *
 * 运行：`node --import tsx/esm apps/remote-host/scripts/discovery-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本不写文件、不改防火墙、不开固定端口。
 *
 * 覆盖：
 * 1. 真实 UDP 回环单播（127.0.0.1）：应答字段、nonce 回显、窗口关闭不带配对链接、
 *    坏帧静默丢弃、同一来源限速与恢复、stop/start 生命周期；
 * 2. 注入假套接字：绑定地址、出站 TTL=1、`unref()`、stop 关闭、最坏字段长度下应答
 *    仍是单个 UDP 包（≤ 1400 字节，不 IP 分片）；
 * 3. 端口占用：真实 UDP 端口冲突时 `start()` 返回 `{listening:false}` 且只记 warn，
 *    不抛错、不影响进程——发现是增强能力。
 *
 * 为什么不测广播：Windows 防火墙可能拦截入站 UDP，而自检不该改防火墙设置。回环单播
 * 覆盖协议与限速；广播与跨设备可达性留给真机阶段（见 `discovery.md` §5）。
 * @module @deepseek-ai/dsh-remote-host/scripts/discovery-selfcheck
 */

import { createSocket, type RemoteInfo, type Socket } from 'node:dgram'
import {
  DiscoveryResponder,
  type DiscoverySnapshot,
  type DiscoverySocket,
} from '../src/discovery.ts'
import type { RemoteLogRecord } from '../src/server.ts'

/** 正常应答的等待上限。 */
const PROBE_TIMEOUT_MS = 500

/** 断言「没有应答」时的观察窗口；回环单播远快于它。 */
const SILENCE_TIMEOUT_MS = 300

/** 自检用的宿主显示名。 */
const SAMPLE_NAME = 'DESKTOP-SELFCHECK'

/** 自检用的 wss origin。 */
const SAMPLE_ORIGIN = 'wss://192.168.5.21:4777'

/** 自检用的 instanceId（64 位小写十六进制）。 */
const SAMPLE_INSTANCE_ID = 'a'.repeat(64)

/** 自检用的配对链接（与日志/二维码同一条形态）。 */
const SAMPLE_PAIR_URL = `${SAMPLE_ORIGIN}#instance=${SAMPLE_INSTANCE_ID}&token=${'b'.repeat(43)}`

/** 自检用的配对窗口过期时间（Unix 毫秒）。 */
const SAMPLE_EXPIRES_AT = 1_700_000_000_000

/** 自检的限速间隔（毫秒）；与假时钟配合，不产生真实等待。 */
const SAMPLE_RATE_LIMIT_MS = 1_000

/** 单个 UDP 数据报的合理上限：最坏字段长度下也不能 IP 分片（以太网 MTU 1500）。 */
const MAXIMUM_REPLY_BYTES = 1_400

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
 * 断言两段 JSON 值相等（按对象键排序，避免键顺序造成假失败）。
 * @param actual - 实际值。
 * @param expected - 期望值。
 * @param label - 失败说明里的字段名。
 */
function checkJsonEqual(actual: unknown, expected: unknown, label: string): void {
  check(canonical(actual) === canonical(expected), `${label} 不符：期望 ${canonical(expected)}，实际 ${canonical(actual)}`)
}

/**
 * 把 JSON 值按对象键递归排序后序列化。
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
 * 把应答文本解析成 JSON 对象。
 * @param text - 收到的数据报文本。
 * @returns 解析后的对象。
 * @throws 不是 UTF-8 JSON 对象时抛出。
 */
function parseReply(text: string): Record<string, unknown> {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    throw new SelfCheckFailure(`应答不是合法 JSON：${describeError(error)}；原文 ${text.slice(0, 120)}`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new SelfCheckFailure(`应答不是 JSON 对象：${text.slice(0, 120)}`)
  }
  return parsed as Record<string, unknown>
}

/**
 * 拼一帧合法探测。
 * @param nonce - 4–128 个 base64url 字符的随机串。
 * @returns UTF-8 JSON 文本。
 */
function probeFrame(nonce: string): string {
  return JSON.stringify({ v: 1, probe: 'DSH-REMOTE-DISCOVER', nonce })
}

/**
 * 一帧在协议层不合法的探测；宿主要一律静默丢弃。
 *
 * 第一个是协议字面量本身——它是文档里的记号，不是线上帧；App 必须发 JSON。
 */
const BAD_PROBES: readonly (string | Buffer)[] = [
  'DSH-REMOTE-DISCOVER/1',
  'not json at all',
  JSON.stringify({}),
  JSON.stringify({ v: 2, probe: 'DSH-REMOTE-DISCOVER', nonce: 'abcdefgh' }),
  JSON.stringify({ v: 1, probe: 'DSH-REMOTE-DISCOVER/1', nonce: 'abcdefgh' }),
  JSON.stringify({ v: 1, probe: 'DSH-REMOTE-DISCOVER' }),
  JSON.stringify({ v: 1, probe: 'DSH-REMOTE-DISCOVER', nonce: 'abc' }),
  JSON.stringify({ v: 1, probe: 'DSH-REMOTE-DISCOVER', nonce: 'x'.repeat(129) }),
  Buffer.alloc(600, 0x61),
]

/**
 * 回环 UDP 探测客户端：发探测、收应答、断言沉默。
 *
 * 一个客户端复用同一个本地地址，所以限速按来源地址生效的路径是真实被走到的。
 */
class ProbeClient {
  private readonly socket: Socket
  private readonly inbox: string[] = []
  private readonly waiters: ((text: string | undefined) => void)[] = []
  private closed = false

  /** @param socket - 已绑定到回环地址的 udp4 套接字。 */
  private constructor(socket: Socket) {
    this.socket = socket
    socket.on('message', (message: Buffer) => {
      const text = message.toString('utf8')
      const waiter = this.waiters.shift()
      if (waiter === undefined) {
        this.inbox.push(text)
        return
      }
      waiter(text)
    })
    socket.on('error', () => {
      // 探测已关闭的端口时 Windows 可能回 ICMP unreachable：由超时给出结论，这里只吸收错误。
    })
  }

  /**
   * 打开一个绑定到回环地址的客户端。
   * @returns 已就绪的客户端。
   */
  static async open(): Promise<ProbeClient> {
    const socket = createSocket('udp4')
    await new Promise<void>((resolve, reject) => {
      socket.once('error', reject)
      socket.bind(0, '127.0.0.1', () => {
        resolve()
      })
    })
    return new ProbeClient(socket)
  }

  /**
   * 单播一帧。
   * @param port - 目标 UDP 端口。
   * @param payload - 数据报内容；字符串按 UTF-8 发送。
   */
  send(port: number, payload: string | Buffer): void {
    this.socket.send(payload, port, '127.0.0.1')
  }

  /**
   * 取下一帧应答；没有应答时等到超时。
   * @param timeoutMs - 等待上限。
   * @returns 应答文本；超时为 undefined。
   */
  async take(timeoutMs: number = PROBE_TIMEOUT_MS): Promise<string | undefined> {
    const buffered = this.inbox.shift()
    if (buffered !== undefined) return buffered
    return await new Promise<string | undefined>((resolve) => {
      let timer: ReturnType<typeof setTimeout> | undefined
      const settle = (text: string | undefined): void => {
        if (timer !== undefined) clearTimeout(timer)
        const index = this.waiters.indexOf(settle)
        if (index >= 0) this.waiters.splice(index, 1)
        resolve(text)
      }
      timer = setTimeout(() => {
        settle(undefined)
      }, timeoutMs)
      this.waiters.push(settle)
    })
  }

  /** @returns 已经到达但尚未取走的应答；断言「没有多余应答」用。 */
  drain(): string[] {
    return this.inbox.splice(0, this.inbox.length)
  }

  /** 关闭客户端套接字。 */
  close(): void {
    if (this.closed) return
    this.closed = true
    this.socket.close()
  }
}

/** 一次假套接字 `bind` 的记录。 */
interface FakeBindCall {
  readonly port: number
  readonly address: string
}

/** 一次假套接字 `send` 的记录。 */
interface FakeSendCall {
  readonly text: string
  readonly port: number
  readonly address: string
}

/**
 * 可注入的假套接字：记录调用并让自检直接向应答者投递数据报。
 *
 * 真实套接字能覆盖协议；这里覆盖的是从外部观察不到的动作——绑定地址、TTL、`unref()`
 * 与端口绑定失败的确定路径。
 */
class FakeSocket implements DiscoverySocket {
  /** 全部 `bind` 调用。 */
  readonly bindCalls: FakeBindCall[] = []
  /** 全部 `send` 调用。 */
  readonly sends: FakeSendCall[] = []
  /** 全部 `setTTL` 参数。 */
  readonly ttls: number[] = []
  /** `unref()` 是否被调用。 */
  unrefCalled = false
  /** `close()` 被调用的次数。 */
  closeCalls = 0
  private readonly localPortValue: number
  private readonly bindError: Error | undefined
  private messageListener: ((message: Buffer, remote: RemoteInfo) => void) | undefined
  private errorListener: ((error: Error) => void) | undefined

  /**
   * @param localPortValue - `localPort()` 返回的端口。
   * @param bindError - 非空时 `bind` 通过 error 事件失败，模拟端口占用/权限不足。
   */
  constructor(localPortValue: number, bindError?: Error) {
    this.localPortValue = localPortValue
    this.bindError = bindError
  }

  /** @param listener - 收帧回调。 */
  onMessage(listener: (message: Buffer, remote: RemoteInfo) => void): void {
    this.messageListener = listener
  }

  /** @param listener - 错误回调。 */
  onError(listener: (error: Error) => void): void {
    this.errorListener = listener
  }

  /**
   * @param port - 请求的端口。
   * @param address - 请求的绑定地址。
   * @param callback - 绑定成功回调。
   */
  bind(port: number, address: string, callback: () => void): void {
    this.bindCalls.push({ port, address })
    const failure = this.bindError
    setImmediate(() => {
      if (failure !== undefined) {
        this.errorListener?.(failure)
        return
      }
      callback()
    })
  }

  /** @param callback - 关闭完成回调。 */
  close(callback?: () => void): void {
    this.closeCalls += 1
    if (callback === undefined) return
    setImmediate(() => {
      callback()
    })
  }

  /**
   * @param text - 应答文本。
   * @param port - 目的端口。
   * @param address - 目的地址。
   * @param callback - 发送完成回调。
   */
  send(text: string, port: number, address: string, callback: (error: Error | null) => void): void {
    this.sends.push({ text, port, address })
    setImmediate(() => {
      callback(null)
    })
  }

  /** @param ttl - TTL 参数。 */
  setTTL(ttl: number): void {
    this.ttls.push(ttl)
  }

  unref(): void {
    this.unrefCalled = true
  }

  /** @returns 构造时给定的端口。 */
  localPort(): number {
    return this.localPortValue
  }

  /**
   * 投递一帧数据报，走应答者登记的处理函数。
   * @param text - 数据报文本。
   * @param remote - 来源地址与端口。
   */
  deliver(text: string, remote: RemoteInfo): void {
    this.messageListener?.(Buffer.from(text, 'utf8'), remote)
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
    console.log(`PASS  ${passed}. ${label}：${detail}`)
  } catch (error) {
    const detail = describeError(error)
    failures.push(`${label}：${detail}`)
    console.log(`FAIL  ${total}. ${label}：${detail}`)
  }
}

/**
 * 自检主体：真实 UDP 协议验证 → 假套接字验证 → 端口占用降级 → 收尾。
 * @returns 进程退出码：全部通过为 0。
 */
async function main(): Promise<number> {
  const logRecords: RemoteLogRecord[] = []
  const log = (record: RemoteLogRecord): void => {
    logRecords.push(record)
  }
  let fakeNow = 1_700_000_000_000
  const advanceClock = (): void => {
    fakeNow += SAMPLE_RATE_LIMIT_MS
  }
  let pairingOpen = true
  const snapshot = (): DiscoverySnapshot => {
    if (!pairingOpen) {
      return { name: SAMPLE_NAME, origin: SAMPLE_ORIGIN, instanceId: SAMPLE_INSTANCE_ID }
    }
    return {
      name: SAMPLE_NAME,
      origin: SAMPLE_ORIGIN,
      instanceId: SAMPLE_INSTANCE_ID,
      pairing: { pairUrl: SAMPLE_PAIR_URL, expiresAt: SAMPLE_EXPIRES_AT },
    }
  }

  const responder = new DiscoveryResponder({
    port: 0,
    host: '127.0.0.1',
    rateLimitMs: SAMPLE_RATE_LIMIT_MS,
    clock: () => fakeNow,
    snapshot,
    log,
  })
  const client = await ProbeClient.open()
  const blocker = createSocket('udp4')
  try {
    let port = 0
    await step('启动应答者并记录 discovery-listening', async () => {
      const started = await responder.start()
      check(started.listening, '应答者没有进入监听状态')
      check(responder.port === started.port, `应答者端口 ${String(responder.port)} 与启动结果 ${String(started.port)} 不一致`)
      const listening = logRecords.filter(record => record.event === 'discovery-listening')
      check(listening.length === 1, `discovery-listening 日志应为 1 条，实际 ${listening.length} 条`)
      check(listening[0]?.level === 'info', 'discovery-listening 应当是 info 级别')
      check(listening[0]?.fields?.port === started.port, 'discovery-listening 的 fields.port 与实际端口不一致')
      port = started.port
      return `UDP 127.0.0.1:${port}，日志含 discovery-listening`
    })

    await step('合法探测收到完整应答且 nonce 原样回显', async () => {
      advanceClock()
      client.send(port, probeFrame('nonce-answer-01'))
      const text = await client.take()
      check(text !== undefined, '没有收到应答')
      const reply = parseReply(text)
      check(reply.v === 1, `v 期望 1，实际 ${JSON.stringify(reply.v)}`)
      check(reply.kind === 'dsh-remote-host', `kind 期望 dsh-remote-host，实际 ${JSON.stringify(reply.kind)}`)
      check(reply.name === SAMPLE_NAME, `name 期望 ${SAMPLE_NAME}，实际 ${JSON.stringify(reply.name)}`)
      check(reply.origin === SAMPLE_ORIGIN, `origin 期望 ${SAMPLE_ORIGIN}，实际 ${JSON.stringify(reply.origin)}`)
      check(reply.instanceId === SAMPLE_INSTANCE_ID, 'instanceId 与快照不一致')
      check(reply.nonce === 'nonce-answer-01', `nonce 没有原样回显：${JSON.stringify(reply.nonce)}`)
      checkJsonEqual(
        reply.pairing,
        { open: true, pairUrl: SAMPLE_PAIR_URL, expiresAt: SAMPLE_EXPIRES_AT },
        'pairing',
      )
      checkJsonEqual(
        Object.keys(reply).sort(),
        ['instanceId', 'kind', 'name', 'nonce', 'origin', 'pairing', 'v'],
        '应答字段集合',
      )
      return `${String(Object.keys(reply).length)} 个字段全部匹配，pairing.open=true`
    })

    await step('配对窗口关闭时只回 {open:false} 且不带配对链接', async () => {
      pairingOpen = false
      advanceClock()
      client.send(port, probeFrame('nonce-window-closed'))
      const text = await client.take()
      check(text !== undefined, '没有收到应答')
      const reply = parseReply(text)
      checkJsonEqual(reply.pairing, { open: false }, 'pairing')
      check(!text.includes('pairUrl'), '窗口关闭时应答里出现了 pairUrl')
      check(!text.includes('&token='), '窗口关闭时应答里出现了配对令牌')
      check(reply.nonce === 'nonce-window-closed', 'nonce 没有原样回显')
      pairingOpen = true
      return 'pairing={open:false}，应答里没有 pairUrl / token'
    })

    await step('坏帧一律静默丢弃，且不影响后续合法探测', async () => {
      advanceClock()
      for (const bad of BAD_PROBES) client.send(port, bad)
      client.send(port, probeFrame('nonce-after-bad'))
      const text = await client.take()
      check(text !== undefined, '坏帧之后合法探测没有得到应答')
      const reply = parseReply(text)
      check(reply.nonce === 'nonce-after-bad', `收到的不是最后那帧合法探测的应答：${JSON.stringify(reply.nonce)}`)
      check(client.drain().length === 0, '坏帧收到了应答（应当静默丢弃）')
      return `${String(BAD_PROBES.length)} 种坏帧（非 JSON / 版本不符 / 字面量 / 缺字段 / nonce 越界 / 超长）全部无应答`
    })

    await step('同一来源 1 秒内第二次探测被限速', async () => {
      advanceClock()
      client.send(port, probeFrame('nonce-rate-limit-1'))
      const first = await client.take()
      check(first !== undefined, '第一次探测没有收到应答')
      client.send(port, probeFrame('nonce-rate-limit-2'))
      const extra = await client.take(SILENCE_TIMEOUT_MS)
      check(extra === undefined, `限速窗口内仍收到了应答：${extra ?? ''}`)
      return `${SAMPLE_RATE_LIMIT_MS} ms 窗口内只应答 1 次`
    })

    await step('限速窗口过后恢复应答', async () => {
      advanceClock()
      client.send(port, probeFrame('nonce-rate-limit-3'))
      const text = await client.take()
      check(text !== undefined, '限速窗口过后没有恢复应答')
      check(parseReply(text).nonce === 'nonce-rate-limit-3', '恢复后的应答 nonce 不符')
      return '同来源下一次探测被正常应答'
    })

    await step('stop 之后不再应答', async () => {
      await responder.stop()
      check(responder.port === undefined, 'stop 之后 port 仍不是 undefined')
      client.send(port, probeFrame('nonce-after-stop'))
      const text = await client.take(SILENCE_TIMEOUT_MS)
      check(text === undefined, `stop 之后仍收到了应答：${text ?? ''}`)
      return 'UDP 端口已关闭，探测无应答'
    })

    await step('再次 start 能重新监听（生命周期幂等）', async () => {
      advanceClock()
      const restarted = await responder.start()
      check(restarted.listening, '重新 start 没有进入监听状态')
      client.send(restarted.port, probeFrame('nonce-restart-01'))
      const text = await client.take()
      check(text !== undefined, '重新监听后没有应答')
      check(parseReply(text).nonce === 'nonce-restart-01', '重新监听后的应答 nonce 不符')
      port = restarted.port
      return `重新监听 UDP 127.0.0.1:${port}，探测正常`
    })

    await step('假套接字：绑定 0.0.0.0、TTL=1、unref()、stop 时关闭', async () => {
      const fake = new FakeSocket(4_778)
      const fakeResponder = new DiscoveryResponder({
        port: 4_778,
        snapshot,
        log: (record) => {
          logRecords.push(record)
        },
        socketFactory: () => fake,
      })
      const started = await fakeResponder.start()
      check(started.listening, '假套接字应当绑定成功')
      check(fake.bindCalls.length === 1, `bind 应调用 1 次，实际 ${fake.bindCalls.length} 次`)
      checkJsonEqual(fake.bindCalls[0], { port: 4_778, address: '0.0.0.0' }, 'bind 参数')
      check(fake.ttls.join(',') === '1', `setTTL 期望 [1]，实际 [${fake.ttls.join(',')}]`)
      check(fake.unrefCalled, '没有调用 unref()，UDP 套接字会把宿主进程留在事件循环里')
      await fakeResponder.stop()
      check(fake.closeCalls === 1, `stop 应关闭套接字 1 次，实际 ${fake.closeCalls} 次`)
      return 'bind(0.0.0.0:4778)、setTTL(1)、unref()、close 均被调用'
    })

    await step('假套接字：最坏字段长度下应答仍是单个 UDP 包', async () => {
      const fake = new FakeSocket(4_778)
      const longOrigin = `wss://${'a'.repeat(120)}.example.com:8443`
      const longSnapshot = (): DiscoverySnapshot => ({
        name: 'N'.repeat(120),
        origin: longOrigin,
        instanceId: SAMPLE_INSTANCE_ID,
        pairing: {
          pairUrl: `${longOrigin}#instance=${SAMPLE_INSTANCE_ID}&token=${'c'.repeat(43)}`,
          expiresAt: SAMPLE_EXPIRES_AT,
        },
      })
      const fakeResponder = new DiscoveryResponder({
        port: 4_778,
        snapshot: longSnapshot,
        log: (record) => {
          logRecords.push(record)
        },
        socketFactory: () => fake,
      })
      const started = await fakeResponder.start()
      check(started.listening, '假套接字应当绑定成功')
      advanceClock()
      const remote: RemoteInfo = { address: '192.168.5.140', family: 'IPv4', port: 55_555, size: 96 }
      fake.deliver(probeFrame('x'.repeat(128)), remote)
      await new Promise<void>((resolve) => {
        setImmediate(resolve)
      })
      check(fake.sends.length === 1, `应当发出 1 帧应答，实际 ${fake.sends.length} 帧`)
      const sent = fake.sends[0]
      check(sent !== undefined, '没有记录到应答')
      const bytes = Buffer.byteLength(sent.text, 'utf8')
      check(bytes <= MAXIMUM_REPLY_BYTES, `应答 ${bytes} 字节超过 ${MAXIMUM_REPLY_BYTES} 字节上限，会被 IP 分片`)
      check(sent.port === remote.port && sent.address === remote.address, '应答没有单播回探测来源')
      check(parseReply(sent.text).pairing !== undefined, '应答缺少 pairing')
      await fakeResponder.stop()
      return `${bytes} 字节（name 120 + 长域名 origin + 128 字符 nonce）单包可达`
    })

    await step('端口被占用时 start 返回 listening:false 且只记 warn', async () => {
      await new Promise<void>((resolve, reject) => {
        blocker.once('error', reject)
        blocker.bind(0, '127.0.0.1', () => {
          resolve()
        })
      })
      const address = blocker.address()
      const blockedPort = typeof address === 'object' && 'port' in address ? address.port : 0
      check(blockedPort > 0, '占用端口的阻挡套接字没有拿到端口')
      const bindLog: RemoteLogRecord[] = []
      const occupied = new DiscoveryResponder({
        port: blockedPort,
        host: '127.0.0.1',
        snapshot,
        log: (record) => {
          bindLog.push(record)
        },
      })
      const started = await occupied.start()
      check(started.listening === false, '端口被占用时 start 仍报告监听成功')
      check(occupied.port === undefined, '绑定失败后 port 仍不是 undefined')
      const warn = bindLog.find(record => record.event === 'discovery-failed' && record.level === 'warn')
      check(warn !== undefined, '端口占用没有写 discovery-failed warn 日志')
      check(warn.fields?.port === blockedPort, 'discovery-failed 的 fields.port 与实际端口不一致')
      await occupied.stop()
      // 失败路径不抛错是断言本身：能走到这里说明宿主（本进程）仍然存活。
      return `UDP 127.0.0.1:${blockedPort} 冲突 → listening:false + warn，进程继续运行`
    })
  } finally {
    client.close()
    await responder.stop()
    try {
      blocker.close()
    } catch {
      // 阻挡套接字可能没有绑定成功；这里只负责清理。
    }
  }

  console.log('')
  if (failures.length > 0) {
    console.log(`FAIL  ${passed}/${total} 项通过，${failures.length} 项失败`)
    for (const failure of failures) console.log(`  - ${failure}`)
    return 1
  }
  console.log(`PASS  ${passed}/${passed} 项全部通过（UDP 协议 + 限速 + 假套接字 + 端口占用降级）`)
  return 0
}

// 兜底看门狗：任何一步把句柄留在事件循环里时，不能让自检一直挂着。
const watchdog = setTimeout(() => {
  console.error('FAIL  局域网发现自检在 60 s 内没有结束，判定有套接字或定时器未收尾。')
  process.exit(1)
}, 60_000)
watchdog.unref()

process.exitCode = await main().catch((error: unknown) => {
  console.error(`FAIL  自检主体抛出：${describeError(error)}`)
  return 1
})
