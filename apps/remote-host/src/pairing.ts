/**
 * 一次性配对窗口与配对链接。
 *
 * 配对 = 把整台 PC 的控制权交给这台手机，所以窗口按下面的规则收紧：
 * - 令牌是 32 字节随机值的 base64url（43 字符），只展示一次，**单次有效**；
 * - 过期即拒，判定只看当前时间，不依赖定时器；
 * - 比较用 `timingSafeEqual`，且先过对端限速再比较，连续失败直接拒绝；
 * - 对端表有容量上限，表满时一律拒绝（失败关闭），避免用伪造对端把内存撑爆；
 * - 只有本地（PC 界面）能 open / close，这两个动作会清空失败计数。
 *
 * PC 不生成二维码图片：{@link pairUrl} 只给出链接文本，由 App 用 qr_flutter 渲染。
 * @module remote-host/pairing
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'

/** 配对令牌的线上形态：32 字节 base64url。 */
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u

/** 配对窗口的有效期上限（15 分钟）；再长就没有「当场配对」的意义了。 */
const MAXIMUM_TTL_MS = 15 * 60 * 1000

/** 每个对端在计数窗口内允许的尝试次数。 */
const DEFAULT_MAXIMUM_ATTEMPTS = 5

/** 对端计数的固定窗口长度。 */
const DEFAULT_ATTEMPT_WINDOW_MS = 60 * 1000

/** 对端表的容量上限；表满后新对端一律拒绝。 */
const DEFAULT_MAXIMUM_PEERS = 256

/** instanceId 的线上形态：64 位小写十六进制。 */
const INSTANCE_ID_PATTERN = /^[0-9a-f]{64}$/u

/** 一次打开的配对窗口。 */
export interface PairingOpening {
  /** 明文配对令牌，只交给展示它的一方。 */
  readonly token: string
  /** 窗口关闭时间（Unix 毫秒）。 */
  readonly expiresAt: number
}

/**
 * 一次令牌兑换的结论。
 *
 * 失败原因只用于让配对接口区分 HTTP 状态码（401 令牌无效 / 403 窗口已关闭或过期 /
 * 429 尝试过于频繁），**不进响应体**，避免把窗口状态泄露给未持有链接的一方。
 */
export type PairingRedemption =
  | { readonly ok: true }
  | {
    readonly ok: false
    /** `window-closed`：没有打开过窗口，或本轮窗口已被消耗。 */
    readonly reason: 'window-closed' | 'window-expired' | 'invalid-token' | 'rate-limited'
  }

/** {@link PairingWindow} 的构造参数；不传即用默认安全参数。 */
export interface PairingWindowOptions {
  /** 时钟来源，默认 `Date.now`；测试可替换。 */
  readonly now?: () => number
  /** 每个对端在计数窗口内的最大尝试次数，默认 5。 */
  readonly maximumAttemptsPerPeer?: number
  /** 对端计数的固定窗口长度（毫秒），默认 60 000。 */
  readonly attemptWindowMs?: number
  /** 对端表容量上限，默认 256。 */
  readonly maximumPeers?: number
}

/** 当前窗口：只留摘要，不留在内存里留明文。 */
interface OpenWindow {
  readonly digest: Buffer
  readonly expiresAt: number
}

/** 单个对端的失败计数。 */
interface PeerAttempts {
  count: number
  readonly resetAt: number
}

/** 计算 sha256 摘要。 */
function sha256(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest()
}

/**
 * 校验构造参数是正整数。
 * @param value - 待校验值。
 * @param name - 参数名，用于报错。
 * @returns 该值。
 * @throws 不是正整数时抛出。
 */
function requirePositiveInteger(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`配对窗口的 ${name} 必须是正整数。`)
  }
  return value
}

/**
 * 一次性的配对窗口。
 *
 * 一个实例代表 PC 上「当前这一个」配对入口：同一时刻最多一个窗口，重新
 * {@link PairingWindow.open} 会顶掉旧窗口（旧令牌立即失效）。
 */
export class PairingWindow {
  private window: OpenWindow | undefined
  private readonly attempts = new Map<string, PeerAttempts>()
  private readonly now: () => number
  private readonly maximumAttemptsPerPeer: number
  private readonly attemptWindowMs: number
  private readonly maximumPeers: number

  /**
   * @param options - 限速与时钟参数；省略即用默认值。
   * @throws 参数不是正整数时抛出。
   */
  constructor(options: PairingWindowOptions = {}) {
    this.now = options.now ?? Date.now
    this.maximumAttemptsPerPeer = requirePositiveInteger(options.maximumAttemptsPerPeer ?? DEFAULT_MAXIMUM_ATTEMPTS, 'maximumAttemptsPerPeer')
    this.attemptWindowMs = requirePositiveInteger(options.attemptWindowMs ?? DEFAULT_ATTEMPT_WINDOW_MS, 'attemptWindowMs')
    this.maximumPeers = requirePositiveInteger(options.maximumPeers ?? DEFAULT_MAXIMUM_PEERS, 'maximumPeers')
  }

  /**
   * 打开一个新的配对窗口，并使此前未用的窗口失效。
   * @param ttlMs - 有效期毫秒数，1 毫秒到 15 分钟。
   * @returns 明文令牌与过期时间；令牌只在此处出现一次。
   * @throws ttlMs 越界时抛出。
   */
  open(ttlMs: number): PairingOpening {
    if (!Number.isSafeInteger(ttlMs) || ttlMs <= 0 || ttlMs > MAXIMUM_TTL_MS) {
      throw new Error(`配对窗口的有效期必须是 1 到 ${MAXIMUM_TTL_MS} 毫秒之间的整数。`)
    }
    const token = randomBytes(32).toString('base64url')
    const expiresAt = this.now() + ttlMs
    this.window = Object.freeze({ digest: sha256(token), expiresAt })
    // 打开窗口是本地可信动作；用户重新点开配对时应当清掉此前的失败计数。
    this.attempts.clear()
    return Object.freeze({ token, expiresAt })
  }

  /**
   * 消耗配对令牌。
   *
   * 成功即关闭窗口（单次有效）；失败按对端计数，计数用尽后本窗口内一律拒绝。
   * 失败原因用于选择配对接口的 HTTP 状态码；调用方不得把它当作可展示文案。
   * @param token - 待校验的明文令牌。
   * @param peer - 对端标识（源地址或源地址 + 端口）；省略时所有对端共用同一个计数桶。
   * @returns 兑换结论；只有 `{ ok: true }` 表示窗口已消耗并可用于签发设备。
   */
  redeem(token: string, peer?: string): PairingRedemption {
    const now = this.now()
    const current = this.window
    if (current === undefined) return { ok: false, reason: 'window-closed' }
    if (current.expiresAt <= now) {
      this.window = undefined
      return { ok: false, reason: 'window-expired' }
    }
    if (!this.takeAttempt(peer ?? '', now)) return { ok: false, reason: 'rate-limited' }
    if (!TOKEN_PATTERN.test(token)) return { ok: false, reason: 'invalid-token' }
    if (!timingSafeEqual(sha256(token), current.digest)) return { ok: false, reason: 'invalid-token' }
    this.window = undefined
    this.attempts.clear()
    return { ok: true }
  }

  /**
   * 关闭当前窗口并清空计数；对已关闭的窗口重复调用无副作用。
   */
  close(): void {
    this.window = undefined
    this.attempts.clear()
  }

  /**
   * 记一次尝试并判断是否仍在预算内。
   * @param peer - 对端标识。
   * @param now - 当前时间（Unix 毫秒）。
   * @returns 允许继续尝试时为 true；对端表已满或预算用尽时为 false。
   */
  private takeAttempt(peer: string, now: number): boolean {
    for (const [candidate, attempts] of this.attempts) {
      if (attempts.resetAt <= now) this.attempts.delete(candidate)
    }
    const current = this.attempts.get(peer)
    if (current === undefined) {
      if (this.attempts.size >= this.maximumPeers) return false
      this.attempts.set(peer, { count: 1, resetAt: now + this.attemptWindowMs })
      return true
    }
    if (current.count >= this.maximumAttemptsPerPeer) return false
    current.count += 1
    return true
  }
}

/**
 * 归一化配对链接里的 origin。
 *
 * App 用 `wss://<host>:<port>/app` 连接，所以链接里只放 scheme + host + port
 * （以及反向代理前缀路径）；主机名小写、默认端口省略，保证同一台 PC 每次生成
 * 的链接一致。
 * @param origin - `wss://` 地址。
 * @returns 去掉末尾斜杠、查询串与片段的 origin。
 * @throws 不是 `wss://`、带查询串/片段/账号信息时抛出。
 */
function normalizeOrigin(origin: string): string {
  let url: URL
  try {
    url = new URL(origin)
  } catch (error) {
    throw new Error(`配对 origin 不是合法 URL：${origin}`, { cause: error })
  }
  if (url.protocol !== 'wss:') {
    throw new Error('配对 origin 必须是 wss:// 地址（v1 只允许加密连接）。')
  }
  if (url.search !== '' || url.hash !== '') {
    throw new Error('配对 origin 不能带查询串或片段：片段位置留给 instance 与 token。')
  }
  if (url.username !== '' || url.password !== '') {
    throw new Error('配对 origin 不能包含用户名或密码。')
  }
  return `${url.origin}${url.pathname.replace(/\/+$/u, '')}`
}

/**
 * 生成配对链接：`<origin>#instance=<64hex>&token=<43chars>`。
 *
 * 片段里只放两个定长字段，不需要 URL 编码；App 扫到后按 `#` 切分即可。
 * @param origin - 宿主可达的 `wss://` 地址。
 * @param instanceId - 宿主 instanceId（64 位小写十六进制，等于 CA 指纹）。
 * @param token - {@link PairingWindow.open} 给出的令牌（43 字符 base64url）。
 * @returns 可直接编码成二维码的链接文本。
 * @throws 任一参数不合法时抛出：宁可拒绝生成，也不给出无法校验的二维码。
 */
export function pairUrl(origin: string, instanceId: string, token: string): string {
  const base = normalizeOrigin(origin)
  if (!INSTANCE_ID_PATTERN.test(instanceId)) {
    throw new Error('instanceId 必须是 64 位小写十六进制（32 字节 CA 指纹）。')
  }
  if (!TOKEN_PATTERN.test(token)) {
    throw new Error('配对令牌必须是 43 个字符的 base64url 字符串。')
  }
  return `${base}#instance=${instanceId}&token=${token}`
}
