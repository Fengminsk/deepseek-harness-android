/**
 * UDP 局域网发现：让手机在同一网段里自动找到这台电脑的远程宿主。
 *
 * 手机广播一帧探测，宿主单播回一帧应答：宿主名、`wss` origin、instanceId（CA 指纹）
 * 与配对窗口状态。完整协议与字段表在 `apps/android/docs/remote-dsh/discovery.md`，
 * 本文件是它的宿主实现。
 *
 * 为什么值得单独做发现：配对链接里有 107 个必须原样保留的字符，手输不现实；二维码
 * 解决「PC → 手机」的传递，发现解决「手机 → PC」的自动寻址——拿到的是**同一条**
 * 配对链接，配对与信任语义完全不变。发现本身不建立任何信任，也不能连上宿主。
 *
 * 安全约束（每条都在实现里成立）：
 * - 只有配对窗口打开时才在应答里带 `pairUrl`，窗口关闭只回 `{open:false}`；
 * - 应答不含任何设备令牌，也不含设备表；
 * - 坏帧一律静默丢弃、不回包（避免被当成 UDP 放大反射点）；
 * - 同一来源地址 1 秒只应答一次，来源表有上限且表满时失败关闭；
 * - 出站 TTL 固定 1 跳，探测方也应以 TTL=1 广播（不跨路由）。
 *
 * 失败是增强能力的失败：端口被占用或没有权限时只写一条 warn，宿主照常启动。
 * @module remote-host/discovery
 */

import { createSocket, type RemoteInfo, type Socket } from 'node:dgram'
import {
  describeRemoteError,
  writeRemoteLog,
  type RemoteLogRecord,
  type RemoteLogger,
} from './server.ts'

/** 探测帧 `probe` 字段的值；与 `v` 拼起来就是协议字面量 `DSH-REMOTE-DISCOVER/1`。 */
const DISCOVERY_PROBE = 'DSH-REMOTE-DISCOVER'

/** 协议版本；探测帧与应答帧都用 `v` 携带。 */
const DISCOVERY_VERSION = 1

/** 应答帧的 `kind` 字段，App 用它区分同一 UDP 端口上的其它服务。 */
const DISCOVERY_KIND = 'dsh-remote-host'

/** 默认 UDP 发现端口（`Config.discoveryPort` 的默认值）。 */
export const DEFAULT_DISCOVERY_PORT = 4778

/** 出站 TTL 的默认值：只在本网段内可见，不跨路由。 */
const DEFAULT_TTL = 1

/** 同一来源地址两次应答之间的最短间隔（毫秒）。 */
const DEFAULT_RATE_LIMIT_MS = 1_000

/** 来源表容量上限；表满后新来源一律不应答（失败关闭，不无限记账）。 */
const DEFAULT_MAXIMUM_TRACKED_PEERS = 256

/** 默认绑定地址：局域网可达，与 wss 监听一致。 */
const DEFAULT_BIND_HOST = '0.0.0.0'

/** 探测帧的字节上限；合法帧远小于它，超过一律按坏帧丢弃。 */
const MAXIMUM_PROBE_BYTES = 512

/** 探测帧 `nonce` 的形态：4–128 个 base64url 字符，应答原样回显。 */
const PROBE_NONCE_PATTERN = /^[A-Za-z0-9_-]{4,128}$/u

/**
 * 配对窗口打开时随应答发出的材料。
 *
 * `pairUrl` 就是 PC 日志与二维码里的那一条链接（含一次性配对令牌），因此只在
 * 配对窗口打开期间存在；窗口关闭或配对成功后快照里不再有它。
 */
export interface DiscoveryPairing {
  /** 完整配对链接（`wss://…#instance=…&token=…`），与二维码里的一致。 */
  readonly pairUrl: string
  /** 配对窗口关闭时间（Unix 毫秒）。 */
  readonly expiresAt: number
}

/**
 * 构造应答时的宿主快照。
 *
 * 由装配方（`./index.ts`）注入：发现模块不读身份、不看配对窗口，避免两处判断窗口状态。
 */
export interface DiscoverySnapshot {
  /** 宿主显示名，进入应答的 `name`（协议 §3.2 的 `host.name`）。 */
  readonly name: string
  /** 对外宣告的 `wss://host[:port]` origin。 */
  readonly origin: string
  /** 64 位小写十六进制 instanceId（等于 CA 证书 sha256，App 的信任判据）。 */
  readonly instanceId: string
  /** 配对窗口打开时的配对材料；窗口关闭时省略。 */
  readonly pairing?: DiscoveryPairing
}

/** 一帧应答的线上内容（协议 `discovery.md` §2.2）。 */
interface DiscoveryReply {
  readonly v: number
  readonly kind: string
  readonly name: string
  readonly origin: string
  readonly instanceId: string
  readonly pairing:
    | { readonly open: true; readonly pairUrl: string; readonly expiresAt: number }
    | { readonly open: false }
  readonly nonce: string
}

/**
 * 发现应答者只依赖的 dgram 套接字表面。
 *
 * 只有这 8 个动作；默认实现包住 `node:dgram` 的套接字，自检与单测可以注入自己的实现
 * （例如无法绑定端口的场景）。
 */
export interface DiscoverySocket {
  /**
   * 登记收帧处理；`start()` 内部调用一次。
   * @param listener - 收到 UDP 数据报时的回调。
   */
  onMessage(listener: (message: Buffer, remote: RemoteInfo) => void): void

  /**
   * 登记套接字错误处理（含绑定失败）；`start()` 内部调用一次。
   * @param listener - 错误回调。
   */
  onError(listener: (error: Error) => void): void

  /**
   * 绑定 UDP 端口。
   * @param port - 端口号；0 表示交给系统分配（只用于自检与本地调试）。
   * @param address - 绑定地址。
   * @param callback - 绑定成功后的回调。
   */
  bind(port: number, address: string, callback: () => void): void

  /**
   * 关闭套接字。
   * @param callback - 关闭完成后的回调；省略时不等关闭。
   */
  close(callback?: () => void): void

  /**
   * 单播一帧文本。
   * @param text - 帧文本（UTF-8 JSON）。
   * @param port - 目的端口。
   * @param address - 目的地址。
   * @param callback - 发送完成回调；失败时带错误。
   */
  send(text: string, port: number, address: string, callback: (error: Error | null) => void): void

  /**
   * 设置出站 TTL。
   * @param ttl - 跳数上限。
   */
  setTTL(ttl: number): void

  /** 让这个套接字不再把进程留在事件循环里。 */
  unref(): void

  /** @returns 实际绑定的端口；未绑定时为 0。 */
  localPort(): number
}

/** {@link DiscoveryResponder} 的构造参数。 */
export interface DiscoveryResponderOptions {
  /** UDP 端口；0 表示交给系统分配（只用于自检与本地调试）。 */
  readonly port: number
  /** 绑定地址；默认 `0.0.0.0`（局域网可达）。 */
  readonly host?: string
  /** 出站 TTL；默认 1（不跨路由）。 */
  readonly ttl?: number
  /** 同一来源地址两次应答之间的最短间隔（毫秒）；默认 1000。 */
  readonly rateLimitMs?: number
  /** 来源表容量上限；默认 256，表满后新来源不应答。 */
  readonly maximumTrackedPeers?: number
  /** 时间来源，默认 `Date.now`；自检注入假时钟来验证限速。 */
  readonly clock?: () => number
  /** 当前宿主快照提供者；每次应答现取，不做缓存。 */
  readonly snapshot: () => DiscoverySnapshot
  /** 结构化日志接收器；省略时用 `./server.ts` 的 stderr 实现。 */
  readonly log?: RemoteLogger
  /** 套接字工厂；省略时创建真实 `udp4` 套接字。 */
  readonly socketFactory?: () => DiscoverySocket
}

/**
 * 一次启动的结论。
 *
 * `listening: false` 表示发现没起来（端口占用、权限不足等）；宿主应当照常运行，
 * 因为发现只是「免手输」的增强能力。
 */
export type DiscoveryStart =
  | { readonly listening: true; readonly port: number }
  | { readonly listening: false }

/**
 * 局域网发现应答者：绑定一个 UDP 端口，把合法探测翻译成一帧宿主信息。
 *
 * 生命周期与宿主一致：`start()` 绑定端口并登记收帧处理，`stop()` 关闭套接字。
 * 启动失败不会抛出（写 warn 日志后给出 `{listening:false}`），所以装配方不必为
 * 「发现没起来」单独写错误分支。
 */
export class DiscoveryResponder {
  private readonly requestedPort: number
  private readonly bindHost: string
  private readonly ttl: number
  private readonly rateLimitMs: number
  private readonly maximumTrackedPeers: number
  private readonly clock: () => number
  private readonly snapshot: () => DiscoverySnapshot
  private readonly log: RemoteLogger
  private readonly socketFactory: () => DiscoverySocket
  /** 来源地址 → 恢复应答的时间点（Unix 毫秒）。 */
  private readonly peers = new Map<string, number>()
  private socket: DiscoverySocket | undefined
  private boundPort: number | undefined

  /**
   * @param options - 端口、限速与快照提供者；见 {@link DiscoveryResponderOptions}。
   * @throws 端口、TTL、限速或来源表上限不是整数/越界时抛出：这是装配错误，不应静默兜底。
   */
  constructor(options: DiscoveryResponderOptions) {
    this.requestedPort = requireIntegerInRange(options.port, 0, 65_535, 'port')
    this.bindHost = options.host ?? DEFAULT_BIND_HOST
    this.ttl = requireIntegerInRange(options.ttl ?? DEFAULT_TTL, 1, 255, 'ttl')
    this.rateLimitMs = requireIntegerInRange(options.rateLimitMs ?? DEFAULT_RATE_LIMIT_MS, 1, 3_600_000, 'rateLimitMs')
    this.maximumTrackedPeers = requireIntegerInRange(options.maximumTrackedPeers ?? DEFAULT_MAXIMUM_TRACKED_PEERS, 1, 100_000, 'maximumTrackedPeers')
    this.clock = options.clock ?? Date.now
    this.snapshot = options.snapshot
    this.log = options.log ?? writeRemoteLog
    this.socketFactory = options.socketFactory ?? createUdpSocket
  }

  /** @returns 已绑定的 UDP 端口；没有在监听时为 undefined。 */
  get port(): number | undefined {
    return this.boundPort
  }

  /**
   * 绑定端口并开始应答探测。
   *
   * 幂等：已经在监听时直接返回同一个结论。绑定失败只写一条 warn 日志并返回
   * `{listening:false}`，不抛错、不影响宿主启动。
   * @returns 监听状态与实际端口。
   */
  start(): Promise<DiscoveryStart> {
    if (this.socket !== undefined) {
      return Promise.resolve({ listening: true, port: this.boundPort ?? this.requestedPort })
    }
    const socket = this.socketFactory()
    this.socket = socket
    return new Promise<DiscoveryStart>((resolve) => {
      let settled = false
      const settle = (result: DiscoveryStart): void => {
        if (settled) return
        settled = true
        resolve(result)
      }
      const fail = (error: unknown, phase: string): void => {
        this.socket = undefined
        this.boundPort = undefined
        closeSocket(socket, this.log)
        this.log({
          level: 'warn',
          event: 'discovery-failed',
          message: '局域网发现没有起来（UDP 端口绑定失败），宿主照常启动；手机仍可扫码或粘贴配对链接。',
          fields: {
            port: this.requestedPort,
            address: this.bindHost,
            phase,
            error: describeRemoteError(error),
          },
        })
        settle({ listening: false })
      }
      socket.onError((error: Error) => {
        if (!settled) {
          fail(error, 'bind')
          return
        }
        // 监听期间套接字层面的错误：只记录，进程与远程连接都不受影响。
        this.log({
          level: 'warn',
          event: 'discovery-failed',
          message: '局域网发现的 UDP 套接字出错，发现能力可能已不可用；远程连接不受影响。',
          fields: {
            port: this.boundPort ?? this.requestedPort,
            phase: 'runtime',
            error: describeRemoteError(error),
          },
        })
      })
      socket.onMessage((message: Buffer, remote: RemoteInfo) => {
        this.handleProbe(message, remote)
      })
      try {
        socket.bind(this.requestedPort, this.bindHost, () => {
          const assigned = socket.localPort()
          const port = assigned === 0 ? this.requestedPort : assigned
          this.boundPort = port
          socket.setTTL(this.ttl)
          // 发现是增强能力：不能因为一个 UDP 套接字让宿主进程无法退出。
          socket.unref()
          this.log({
            level: 'info',
            event: 'discovery-listening',
            message: `局域网发现已就绪：手机在同一网段内可以自动找到这台电脑（UDP ${port}）。`,
            fields: { port, address: this.bindHost, ttl: this.ttl },
          })
          settle({ listening: true, port })
        })
      } catch (error) {
        // 部分平台对非法绑定参数是同步抛出：与异步 bind 失败同一种处理。
        fail(error, 'bind-sync')
      }
    })
  }

  /**
   * 关闭套接字并停止应答。幂等；没在监听时立即完成。
   * @returns 套接字关闭后兑现。
   */
  stop(): Promise<void> {
    const socket = this.socket
    this.socket = undefined
    this.boundPort = undefined
    this.peers.clear()
    if (socket === undefined) return Promise.resolve()
    return new Promise<void>((resolve) => {
      let settled = false
      const settle = (): void => {
        if (settled) return
        settled = true
        resolve()
      }
      try {
        socket.close(settle)
      } catch (error) {
        this.log({
          level: 'warn',
          event: 'discovery-failed',
          message: '关闭局域网发现端口失败，端口可能仍被占用。',
          fields: { error: describeRemoteError(error) },
        })
        settle()
      }
    })
  }

  /**
   * 处理一帧探测：解析 → 限速 → 现取快照 → 单播应答。
   * @param message - 收到的数据报。
   * @param remote - 数据报来源地址与端口。
   */
  private handleProbe(message: Buffer, remote: RemoteInfo): void {
    const nonce = parseProbe(message)
    // 坏帧静默丢弃：端口可被同网段任何设备探测，不回包才不会被当成放大反射点。
    if (nonce === undefined) return
    if (!this.acceptPeer(remote.address, this.clock())) return
    this.sendReply(JSON.stringify(this.buildReply(nonce)), remote)
  }

  /**
   * 按来源地址做固定窗口限速，并清理过期条目。
   * @param address - 来源地址。
   * @param now - 当前时间（Unix 毫秒）。
   * @returns 允许应答时为 true；窗口内重复或来源表已满时为 false。
   */
  private acceptPeer(address: string, now: number): boolean {
    for (const [peer, retryAt] of this.peers) {
      if (retryAt <= now) this.peers.delete(peer)
    }
    if (this.peers.has(address)) return false
    if (this.peers.size >= this.maximumTrackedPeers) return false
    this.peers.set(address, now + this.rateLimitMs)
    return true
  }

  /**
   * 用当前快照拼出应答帧；窗口状态只看快照里有没有配对材料。
   * @param nonce - 探测帧里的 nonce，原样回显。
   * @returns 待发送的应答对象。
   */
  private buildReply(nonce: string): DiscoveryReply {
    const snapshot = this.snapshot()
    const pairing = snapshot.pairing
    return {
      v: DISCOVERY_VERSION,
      kind: DISCOVERY_KIND,
      name: snapshot.name,
      origin: snapshot.origin,
      instanceId: snapshot.instanceId,
      pairing: pairing === undefined
        ? { open: false }
        : { open: true, pairUrl: pairing.pairUrl, expiresAt: pairing.expiresAt },
      nonce,
    }
  }

  /**
   * 把应答单播回探测来源；发送失败只记录，不影响后续探测。
   * @param text - 应答帧文本。
   * @param remote - 探测来源地址与端口。
   */
  private sendReply(text: string, remote: RemoteInfo): void {
    const socket = this.socket
    if (socket === undefined) return
    socket.send(text, remote.port, remote.address, (error: Error | null) => {
      if (error === null) return
      this.log({
        level: 'warn',
        event: 'discovery-failed',
        message: '局域网发现的应答没能发出去，探测方会按超时处理。',
        fields: { phase: 'send', remoteAddress: remote.address, error: describeRemoteError(error) },
      })
    })
  }
}

/**
 * 校验一个整数参数在闭区间内。
 * @param value - 待校验值。
 * @param minimum - 允许的最小值。
 * @param maximum - 允许的最大值。
 * @param name - 参数名，写进报错。
 * @returns 该值。
 * @throws 不是整数或越界时抛出。
 */
function requireIntegerInRange(value: number, minimum: number, maximum: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`局域网发现的 ${name} 必须是 ${minimum}–${maximum} 之间的整数（收到 ${value}）。`)
  }
  return value
}

/**
 * 解析探测帧。
 *
 * 只接受单帧 UTF-8 JSON 对象，字段严格按协议：`v` 必须为 1、`probe` 必须是
 * `DSH-REMOTE-DISCOVER`、`nonce` 是 4–128 个 base64url 字符。其它形态（非 JSON、
 * 数组、版本不符、缺字段、超长）全部返回 undefined，由调用方静默丢弃。
 * @param message - 收到的数据报。
 * @returns 合法的 nonce；坏帧返回 undefined。
 */
function parseProbe(message: Buffer): string | undefined {
  if (message.length === 0 || message.length > MAXIMUM_PROBE_BYTES) return undefined
  let parsed: unknown
  try {
    parsed = JSON.parse(message.toString('utf8'))
  } catch {
    // 坏帧是常态：非 JSON 字节、半截包、其它服务误发；一律丢弃。
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return undefined
  const record = parsed as Record<string, unknown>
  if (record.v !== DISCOVERY_VERSION) return undefined
  if (record.probe !== DISCOVERY_PROBE) return undefined
  const nonce = record.nonce
  if (typeof nonce !== 'string' || !PROBE_NONCE_PATTERN.test(nonce)) return undefined
  return nonce
}

/**
 * 创建并包装一个真实的 `udp4` 套接字。
 * @returns 发现模块使用的套接字表面。
 */
function createUdpSocket(): DiscoverySocket {
  return wrapUdpSocket(createSocket('udp4'))
}

/**
 * 把 `node:dgram` 套接字收敛成 {@link DiscoverySocket}。
 * @param socket - 真实套接字。
 * @returns 只暴露发现需要的 8 个动作。
 */
function wrapUdpSocket(socket: Socket): DiscoverySocket {
  return {
    onMessage: (listener) => {
      socket.on('message', listener)
    },
    onError: (listener) => {
      socket.on('error', listener)
    },
    bind: (port, address, callback) => {
      socket.bind(port, address, callback)
    },
    close: (callback) => {
      socket.close(callback)
    },
    send: (text, port, address, callback) => {
      socket.send(text, port, address, callback)
    },
    setTTL: (ttl) => {
      socket.setTTL(ttl)
    },
    unref: () => {
      socket.unref()
    },
    localPort: () => {
      const address = socket.address()
      return typeof address === 'object' && 'port' in address ? address.port : 0
    },
  }
}

/**
 * 关闭套接字，把「关闭已经关闭的套接字」这类错误收敛成日志。
 * @param socket - 待关闭的套接字。
 * @param log - 结构化日志接收器。
 */
function closeSocket(socket: DiscoverySocket, log: RemoteLogger): void {
  const record = (error: unknown): void => {
    const entry: RemoteLogRecord = {
      level: 'warn',
      event: 'discovery-failed',
      message: '关闭局域网发现的 UDP 套接字失败，端口可能仍被占用。',
      fields: { error: describeRemoteError(error) },
    }
    log(entry)
  }
  try {
    socket.close()
  } catch (error) {
    record(error)
  }
}
