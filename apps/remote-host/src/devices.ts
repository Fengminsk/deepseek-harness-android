/**
 * 设备令牌表（devices.json）：配对成功后签发的长期设备凭证。
 *
 * 安全约束（协议 §2.2）：
 * - 明文 token 只在配对应答里出现一次，磁盘上只存 sha256 摘要；
 * - 令牌比较用 `timingSafeEqual`，并且遍历整张表，不按位置提前返回；
 * - 撤销先落盘再生效，落盘后该令牌立刻不可用；
 * - 过期由读取时刻判定，不依赖后台清理任务。
 *
 * 撤销会留下 `revokedAt` 墓碑而不是直接删除记录：宿主需要把「令牌有效但已撤销」
 * 与「令牌无效」区分成关闭码 `4001 auth-revoked` 和 `4000 auth-failed`，直接删除
 * 记录就再也分不出来。墓碑保留 {@link TOMBSTONE_RETENTION_MS} 天后清理。
 * @module remote-host/devices
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import type { Stats } from 'node:fs'
import { lstat, readFile } from 'node:fs/promises'
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write'

/** devices.json 当前格式版本。 */
const DEVICES_FILE_VERSION = 2

/** 同时有效的设备上限；超过后必须先在 PC 上撤销旧设备。 */
const MAXIMUM_ACTIVE_DEVICES = 256

/** 记录总上限（含撤销墓碑），防止损坏的文件把内存撑爆。 */
const MAXIMUM_RETAINED_RECORDS = 1024

/** 撤销墓碑的保留时长：足够让 App 拿到 4001 提示，之后清理。 */
const TOMBSTONE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000

/** 设备显示名上限，与协议 §3.1 的 `deviceLabel`（1–120 字符）一致。 */
const LABEL_MAXIMUM_LENGTH = 120

/** 单台设备表的文件大小上限。 */
const MAXIMUM_FILE_BYTES = 1024 * 1024

/** 设备 id 的线上形态：16 字节随机值的十六进制小写表示。 */
const DEVICE_ID_PATTERN = /^[0-9a-f]{32}$/u

/** 令牌摘要的形态。 */
const TOKEN_DIGEST_PATTERN = /^[0-9a-f]{64}$/u

/** 设备令牌的线上形态：32 字节 base64url。 */
const DEVICE_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u

/** 落盘的一条设备记录。 */
export interface DeviceRecord {
  /** 设备 id（32 位小写十六进制）。 */
  readonly id: string
  /** 设备显示名。 */
  readonly label: string
  /** 设备令牌的 sha256 摘要（64 位小写十六进制），绝不含明文。 */
  readonly tokenDigest: string
  /** 配对成功时间（Unix 毫秒）。 */
  readonly createdAt: number
  /** 最近一次通过鉴权的时间（Unix 毫秒）。 */
  readonly lastSeenAt: number
  /** 令牌到期时间（Unix 毫秒）。 */
  readonly expiresAt: number
  /** 撤销时间（Unix 毫秒）；存在该字段即表示令牌已失效。 */
  readonly revokedAt?: number
}

/** devices.json 的磁盘格式。 */
export interface DevicesFile {
  readonly version: typeof DEVICES_FILE_VERSION
  readonly devices: readonly DeviceRecord[]
}

/** 对外展示的设备摘要，不含令牌摘要。 */
export interface DeviceSummary {
  /** 设备 id。 */
  readonly id: string
  /** 设备显示名。 */
  readonly label: string
  /** 配对成功时间（Unix 毫秒）。 */
  readonly createdAt: number
  /** 最近一次通过鉴权的时间（Unix 毫秒）。 */
  readonly lastSeenAt: number
  /** 令牌到期时间（Unix 毫秒）。 */
  readonly expiresAt: number
  /** 撤销时间（Unix 毫秒）；存在即表示已撤销。 */
  readonly revokedAt?: number
}

/** 一次成功鉴权的身份。 */
export interface DeviceIdentity {
  /** 设备 id。 */
  readonly deviceId: string
  /** 设备显示名。 */
  readonly label: string
}

/**
 * 鉴权结论。
 *
 * 比 {@link DeviceStore.verify} 多出 `revoked` / `expired`，用于协议 §2.2 要求的
 * `4001 auth-revoked` 与 `4000 auth-failed` 区分。
 */
export type DeviceAuthorization =
  | { readonly status: 'active'; readonly deviceId: string; readonly label: string }
  | { readonly status: 'revoked'; readonly deviceId: string; readonly label: string }
  | { readonly status: 'expired'; readonly deviceId: string; readonly label: string }
  | { readonly status: 'unknown' }

/** 新签发设备凭证的结果。 */
export interface IssuedDevice {
  /** 设备 id。 */
  readonly id: string
  /** 明文设备令牌，只返回这一次。 */
  readonly token: string
  /** 令牌到期时间（Unix 毫秒）。 */
  readonly expiresAt: number
}

/** {@link DeviceStore.add} 的输入。 */
export interface DeviceCreation {
  /** 设备显示名，1–120 个非控制字符。 */
  readonly label: string
  /** 有效期毫秒数，正整数。 */
  readonly ttlMs: number
}

/** 计算 sha256 摘要。 */
function sha256(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest()
}

/** 计算 sha256 摘要的十六进制形态。 */
function sha256Hex(value: string): string {
  return sha256(value).toString('hex')
}

/** 文件不存在的 errno 判定；其余错误照常抛出。 */
function isMissingFile(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | null)?.code === 'ENOENT'
}

/** 读取文件元数据；文件不存在时返回 undefined。 */
async function statOrNull(file: string): Promise<Stats | undefined> {
  try {
    return await lstat(file)
  } catch (error) {
    if (isMissingFile(error)) return undefined
    throw error
  }
}

/** 显示名是否满足本文件写入时的约束。 */
function isValidLabel(value: string): boolean {
  const trimmed = value.trim()
  return trimmed.length > 0
    && Array.from(trimmed).length <= LABEL_MAXIMUM_LENGTH
    && !/[\u0000-\u001f\u007f]/u.test(value)
}

/**
 * 收敛调用方给的设备显示名。
 * @param raw - 配对流或握手里上报的设备名。
 * @returns NFC 规范化并去掉首尾空白后的显示名。
 * @throws 长度越界或含控制字符时抛出。
 */
function normalizeLabel(raw: string): string {
  const label = raw.normalize('NFC').trim()
  if (!isValidLabel(label)) {
    throw new Error(`设备名必须是 1–${LABEL_MAXIMUM_LENGTH} 个非控制字符。`)
  }
  return label
}

/**
 * 读取并校验一个时间戳字段。
 * @param value - 待校验值。
 * @param field - 字段名，用于报错。
 * @returns 该时间戳。
 * @throws 不是非负安全整数时抛出。
 */
function requireTimestamp(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`设备表的 ${field} 必须是非负整数（Unix 毫秒）。`)
  }
  return value
}

/**
 * 校验一条设备记录。
 * @param value - `JSON.parse` 结果里的一项。
 * @returns 校验通过的记录。
 * @throws 字段类型非法或时间戳自相矛盾时抛出。
 */
function parseDeviceRecord(value: unknown): DeviceRecord {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('设备表里存在不是对象的记录。')
  }
  const record = value as Record<string, unknown>
  const id = record.id
  const label = record.label
  const tokenDigest = record.tokenDigest
  if (typeof id !== 'string' || !DEVICE_ID_PATTERN.test(id)) {
    throw new Error('设备表里存在 id 非法的记录。')
  }
  if (typeof label !== 'string' || !isValidLabel(label)) {
    throw new Error('设备表里存在显示名非法的记录。')
  }
  if (typeof tokenDigest !== 'string' || !TOKEN_DIGEST_PATTERN.test(tokenDigest)) {
    throw new Error('设备表里存在令牌摘要非法的记录。')
  }
  const createdAt = requireTimestamp(record.createdAt, 'createdAt')
  const expiresAt = requireTimestamp(record.expiresAt, 'expiresAt')
  const lastSeenAt = requireTimestamp(record.lastSeenAt, 'lastSeenAt')
  const revokedAt = record.revokedAt === undefined ? undefined : requireTimestamp(record.revokedAt, 'revokedAt')
  if (expiresAt <= createdAt || lastSeenAt < createdAt || (revokedAt !== undefined && revokedAt < createdAt)) {
    throw new Error('设备表里存在时间戳自相矛盾的记录。')
  }
  return Object.freeze({
    id,
    label,
    tokenDigest,
    createdAt,
    expiresAt,
    lastSeenAt,
    ...(revokedAt === undefined ? {} : { revokedAt }),
  })
}

/**
 * 校验一组设备记录的规模与唯一性。
 * @param devices - 已逐条校验过的记录。
 * @returns 同一组记录，便于链式使用。
 * @throws 有效设备数、总记录数或唯一性越界时抛出。
 */
function assertDevicesUsable(devices: readonly DeviceRecord[]): readonly DeviceRecord[] {
  if (devices.length > MAXIMUM_RETAINED_RECORDS) {
    throw new Error(`设备表记录数超过上限 ${MAXIMUM_RETAINED_RECORDS}，文件可能已损坏。`)
  }
  const active = devices.filter(record => record.revokedAt === undefined).length
  if (active > MAXIMUM_ACTIVE_DEVICES) {
    throw new Error(`有效设备数超过上限 ${MAXIMUM_ACTIVE_DEVICES}，请先在电脑上撤销不再使用的设备。`)
  }
  if (new Set(devices.map(record => record.id)).size !== devices.length) {
    throw new Error('设备表里存在重复的设备 id。')
  }
  if (new Set(devices.map(record => record.tokenDigest)).size !== devices.length) {
    throw new Error('设备表里存在重复的令牌摘要。')
  }
  return devices
}

/**
 * 校验 devices.json 的结构。
 * @param value - `JSON.parse` 的结果。
 * @returns 校验通过的设备记录。
 * @throws 版本不符、结构非法或违反规模/唯一性约束时抛出。
 */
function parseDevicesFile(value: unknown): readonly DeviceRecord[] {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('devices.json 必须是一个 JSON 对象。')
  }
  const file = value as Record<string, unknown>
  if (file.version !== DEVICES_FILE_VERSION) {
    throw new Error(`devices.json 的版本必须是 ${DEVICES_FILE_VERSION}。`)
  }
  const devices = file.devices
  if (!Array.isArray(devices)) {
    throw new Error('devices.json 的 devices 必须是数组。')
  }
  return assertDevicesUsable(devices.map(parseDeviceRecord))
}

/**
 * 读取并校验 devices.json。
 * @param filePath - devices.json 的路径。
 * @returns 设备记录；文件不存在时返回 undefined。
 * @throws 路径被替换为符号链接、文件过大、不是 JSON 或校验失败时抛出。
 */
async function readDevicesFile(filePath: string): Promise<readonly DeviceRecord[] | undefined> {
  const entry = await statOrNull(filePath)
  if (entry === undefined) return undefined
  if (!entry.isFile() || entry.isSymbolicLink()) {
    throw new Error(`设备表路径 ${filePath} 必须是常规文件，不能是符号链接或目录。`)
  }
  if (entry.size > MAXIMUM_FILE_BYTES) {
    throw new Error(`设备表文件 ${filePath} 超过 ${MAXIMUM_FILE_BYTES} 字节，拒绝读取。`)
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(await readFile(filePath, 'utf8'))
  } catch (error) {
    throw new Error(`设备表文件 ${filePath} 不是合法 JSON。`, { cause: error })
  }
  return parseDevicesFile(parsed)
}

/**
 * 原子写入 devices.json：同目录临时文件 + rename，权限 0600。
 * @param filePath - 目标路径。
 * @param devices - 完整的新记录集合。
 */
async function writeDevicesFile(filePath: string, devices: readonly DeviceRecord[]): Promise<void> {
  const file: DevicesFile = { version: DEVICES_FILE_VERSION, devices }
  await writeFileAtomic(filePath, `${JSON.stringify(file, null, 2)}\n`, { mode: 0o600, dirMode: 0o700 })
}

/**
 * 清掉过期太久的撤销墓碑。
 * @param devices - 当前记录。
 * @param now - 当前时间（Unix 毫秒）。
 * @returns 保留的记录；没有变化时返回原数组本身。
 */
function pruneTombstones(devices: readonly DeviceRecord[], now: number): readonly DeviceRecord[] {
  const retained = devices.filter(record => record.revokedAt === undefined || record.revokedAt + TOMBSTONE_RETENTION_MS > now)
  return retained.length === devices.length ? devices : retained
}

/** 把记录投影成对外摘要。 */
function summarize(record: DeviceRecord): DeviceSummary {
  return Object.freeze({
    id: record.id,
    label: record.label,
    createdAt: record.createdAt,
    lastSeenAt: record.lastSeenAt,
    expiresAt: record.expiresAt,
    ...(record.revokedAt === undefined ? {} : { revokedAt: record.revokedAt }),
  })
}

/**
 * 设备令牌表。
 *
 * 所有状态变更都在同一个串行队列里执行：add / revoke / 最近活跃时间更新不会
 * 互相覆盖；每次变更先落盘、成功后才更新内存，因此内存永远不会领先于磁盘。
 */
export class DeviceStore {
  private devices: readonly DeviceRecord[] = []
  private mutation: Promise<void> = Promise.resolve()

  private constructor(private readonly filePath: string) {}

  /**
   * 打开（必要时创建）设备表文件。
   * @param filePath - devices.json 的路径；目录不存在时自动创建。
   * @returns 已装载的设备表。
   * @throws 文件损坏、越界或不可写时抛出；不会用空表覆盖读不懂的文件。
   */
  static async open(filePath: string): Promise<DeviceStore> {
    const store = new DeviceStore(filePath)
    const loaded = await readDevicesFile(filePath)
    if (loaded === undefined) {
      // 首次创建：立刻落盘，把目录与权限问题暴露在启动期，而不是第一次配对时。
      await store.commit([])
      return store
    }
    const retained = pruneTombstones(loaded, Date.now())
    if (retained === loaded) {
      store.devices = loaded
      return store
    }
    await store.commit(retained)
    return store
  }

  /**
   * 签发一台新设备。
   * @param creation - 设备显示名与有效期。
   * @returns 设备 id、明文令牌（只此一次）与到期时间。
   * @throws 显示名非法、有效期非法、有效设备数已达上限或落盘失败时抛出。
   */
  async add(creation: DeviceCreation): Promise<IssuedDevice> {
    const label = normalizeLabel(creation.label)
    const ttlMs = creation.ttlMs
    if (!Number.isSafeInteger(ttlMs) || ttlMs <= 0) {
      throw new Error('设备有效期必须是正整数毫秒。')
    }
    return this.exclusive(async () => {
      const now = Date.now()
      const expiresAt = now + ttlMs
      if (!Number.isSafeInteger(expiresAt)) throw new Error('设备有效期过大，到期时间溢出。')
      const active = this.devices.filter(record => record.revokedAt === undefined).length
      if (active >= MAXIMUM_ACTIVE_DEVICES) {
        throw new Error(`有效设备已达上限 ${MAXIMUM_ACTIVE_DEVICES} 台，请先在电脑上撤销不再使用的设备。`)
      }
      const id = randomBytes(16).toString('hex')
      const token = randomBytes(32).toString('base64url')
      const record: DeviceRecord = Object.freeze({
        id,
        label,
        tokenDigest: sha256Hex(token),
        createdAt: now,
        lastSeenAt: now,
        expiresAt,
      })
      await this.commit([...this.devices, record])
      return { id, token, expiresAt }
    })
  }

  /**
   * 校验设备令牌（协议 §2.1 的 `Authorization: Bearer` 值）。
   * @param token - 明文设备令牌。
   * @returns 有效时返回设备 id 与显示名，否则返回 null。
   */
  async verify(token: string): Promise<DeviceIdentity | null> {
    const authorization = await this.authorize(token)
    return authorization.status === 'active'
      ? { deviceId: authorization.deviceId, label: authorization.label }
      : null
  }

  /**
   * 校验设备令牌并区分失效原因。
   *
   * 通过校验时把 `lastSeenAt` 前移并落盘；时钟回拨时保持已有时间戳不变。
   * @param token - 明文设备令牌。
   * @returns 鉴权结论；未知、已撤销、已过期都不会被当作有效。
   */
  async authorize(token: string): Promise<DeviceAuthorization> {
    return this.exclusive(async () => {
      const record = this.matchToken(token)
      if (record === undefined) return { status: 'unknown' }
      if (record.revokedAt !== undefined) return { status: 'revoked', deviceId: record.id, label: record.label }
      const now = Date.now()
      if (record.expiresAt <= now) return { status: 'expired', deviceId: record.id, label: record.label }
      if (now > record.lastSeenAt) {
        const updated: DeviceRecord = Object.freeze({ ...record, lastSeenAt: now })
        await this.commit(this.devices.map(candidate => (candidate.id === record.id ? updated : candidate)))
      }
      return { status: 'active', deviceId: record.id, label: record.label }
    })
  }

  /**
   * 撤销一台设备。
   *
   * 落盘成功即生效；调用方随后负责关闭该设备的全部连接并推送 `remote.deviceRevoked`。
   * @param id - 设备 id。
   * @returns 本次是否撤销了一台此前有效的设备。
   */
  async revoke(id: string): Promise<boolean> {
    return this.exclusive(async () => {
      const index = this.devices.findIndex(record => record.id === id && record.revokedAt === undefined)
      const target = this.devices[index]
      if (index < 0 || target === undefined) return false
      const next = [...this.devices]
      next[index] = Object.freeze({ ...target, revokedAt: Date.now() })
      await this.commit(next)
      return true
    })
  }

  /**
   * 永久删除一台设备记录。
   *
   * 与 {@link revoke} 的区别：撤销保留 `revokedAt` 墓碑，让宿主仍能把「令牌有效但已撤销」
   * 与「令牌无效」区分成 `4001 auth-revoked` / `4000 auth-failed`；删除把记录从表中移除，
   * 之后该 id 与令牌都按未知处理。删除有效设备前，调用方应先走撤销路径关闭连接。
   * @param id - 设备 id。
   * @returns 本次是否删除了记录；记录不存在时为 false。
   */
  async delete(id: string): Promise<boolean> {
    return this.exclusive(async () => {
      const next = this.devices.filter(record => record.id !== id)
      if (next.length === this.devices.length) return false
      await this.commit(next)
      return true
    })
  }

  /**
   * 列出全部设备（含已撤销与已过期），按配对时间升序。
   * @returns 不含令牌摘要的摘要列表。
   */
  list(): readonly DeviceSummary[] {
    return [...this.devices]
      .sort((left, right) => left.createdAt - right.createdAt || left.id.localeCompare(right.id))
      .map(summarize)
  }

  /**
   * 在整张表上做常量时间比较。
   *
   * 不按位置提前返回：命中位置本身也是信息。令牌形状不对时直接判为未知，
   * 免得为超长输入做哈希。
   * @param token - 明文设备令牌。
   * @returns 命中的记录。
   */
  private matchToken(token: string): DeviceRecord | undefined {
    if (!DEVICE_TOKEN_PATTERN.test(token)) return undefined
    const candidate = sha256(token)
    let matched: DeviceRecord | undefined
    for (const record of this.devices) {
      if (timingSafeEqual(Buffer.from(record.tokenDigest, 'hex'), candidate) && matched === undefined) {
        matched = record
      }
    }
    return matched
  }

  /**
   * 串行执行一次状态变更。
   * @param operation - 需要独占状态的操作。
   * @returns 操作结果。
   */
  private async exclusive<T>(operation: () => Promise<T>): Promise<T> {
    const prior = this.mutation
    const gate = Promise.withResolvers<void>()
    this.mutation = gate.promise
    await prior
    try {
      return await operation()
    } finally {
      gate.resolve()
    }
  }

  /**
   * 校验并落盘一组记录，成功后才替换内存状态。
   * @param devices - 完整的新记录集合。
   */
  private async commit(devices: readonly DeviceRecord[]): Promise<void> {
    const validated = assertDevicesUsable(devices)
    await writeDevicesFile(this.filePath, validated)
    this.devices = validated
  }
}
