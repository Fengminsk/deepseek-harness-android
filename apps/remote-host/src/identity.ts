/**
 * 远程宿主的身份：instanceId（64 位小写十六进制）与显示名。
 *
 * instanceId 是这台 PC 的信任根标识：配对链接携带它，App 取到宿主的自签 CA
 * 后按「CA 证书 DER 的 sha256 == instanceId」决定是否固定该 CA。因此只要磁盘
 * 上已经有 CA，instanceId 就必须等于该 CA 的指纹；`ensureTlsMaterial`
 * （见 ./tls.ts）在新签 CA 之后用 {@link Identity.bindInstanceId} 把指纹写回
 * identity.json。首次启动、还没有 CA 时 {@link Identity.load} 先给出一个随机
 * instanceId 占位，CA 一旦生成就会被覆盖。
 * @module remote-host/identity
 */

import { createHash, randomBytes, X509Certificate } from 'node:crypto'
import type { Stats } from 'node:fs'
import { lstat, readFile } from 'node:fs/promises'
import { hostname } from 'node:os'
import { join } from 'node:path'
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write'

/** identity.json 在宿主数据目录下的文件名。 */
const IDENTITY_FILE_NAME = 'identity.json'

/** instanceId 的线上形态：32 字节随机值的十六进制小写表示。 */
const INSTANCE_ID_PATTERN = /^[0-9a-f]{64}$/u

/** 显示名上限，与协议 §3.2 的 `host.name`（≤ 120 字符）一致。 */
const DISPLAY_NAME_MAXIMUM_LENGTH = 120

/** 主机名不可用时的兜底显示名。 */
const FALLBACK_DISPLAY_NAME = 'DSH 电脑'

/** identity.json 的磁盘内容。 */
interface IdentityFile {
  readonly instanceId: string
  readonly displayName: string
}

/**
 * 计算证书 PEM 的 DER 字节 sha256 指纹。
 *
 * 这是配对信任的唯一判据：App 拿到 `/ca.cer` 后只比较这个值与配对链接里的
 * instanceId，相等才固定该 CA。
 * @param certPem - PEM 编码的 X.509 证书。
 * @returns 64 位小写十六进制指纹。
 * @throws 证书无法解析时抛出。
 */
export function certificateFingerprint(certPem: string): string {
  let certificate: X509Certificate
  try {
    certificate = new X509Certificate(certPem)
  } catch (error) {
    throw new Error('证书 PEM 无法解析，无法计算指纹。', { cause: error })
  }
  return createHash('sha256').update(certificate.raw).digest('hex')
}

/**
 * 把任意文本收敛成一个可展示的显示名。
 *
 * 主机名来自运行环境，可能为空、含控制字符或超长，因此收敛而不是拒绝：
 * 去控制字符、折叠空白、按码点截断到上限。
 * @param raw - 原始文本（通常是 `os.hostname()`）。
 * @returns 合法的显示名；清洗后为空时使用兜底文案。
 */
function sanitizeDisplayName(raw: string): string {
  const cleaned = raw.normalize('NFC').replace(/[\u0000-\u001f\u007f]/gu, ' ').replace(/\s+/gu, ' ').trim()
  if (cleaned.length === 0) return FALLBACK_DISPLAY_NAME
  return Array.from(cleaned).slice(0, DISPLAY_NAME_MAXIMUM_LENGTH).join('')
}

/** 已持久化的显示名是否满足本文件写入时的约束。 */
function isValidDisplayName(value: string): boolean {
  const trimmed = value.trim()
  return trimmed.length > 0
    && Array.from(trimmed).length <= DISPLAY_NAME_MAXIMUM_LENGTH
    && !/[\u0000-\u001f\u007f]/u.test(value)
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

/**
 * 校验 identity.json 的结构。
 * @param value - `JSON.parse` 的结果。
 * @returns 校验通过的身份内容。
 * @throws 字段缺失或越界时抛出，绝不猜测缺失字段。
 */
function parseIdentityFile(value: unknown): IdentityFile {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`身份文件 ${IDENTITY_FILE_NAME} 必须是一个 JSON 对象。`)
  }
  const record = value as Record<string, unknown>
  const instanceId = record.instanceId
  const displayName = record.displayName
  if (typeof instanceId !== 'string' || !INSTANCE_ID_PATTERN.test(instanceId)) {
    throw new Error(`身份文件 ${IDENTITY_FILE_NAME} 的 instanceId 必须是 64 位小写十六进制。`)
  }
  if (typeof displayName !== 'string' || !isValidDisplayName(displayName)) {
    throw new Error(`身份文件 ${IDENTITY_FILE_NAME} 的 displayName 必须是 1–${DISPLAY_NAME_MAXIMUM_LENGTH} 个非控制字符。`)
  }
  return { instanceId, displayName }
}

/**
 * 读取并校验身份文件。
 * @param dir - 宿主数据目录。
 * @returns 已持久化的身份；文件不存在时返回 undefined。
 * @throws 文件被替换为符号链接、内容不是 JSON、或字段非法时抛出。
 */
async function readIdentityFile(dir: string): Promise<IdentityFile | undefined> {
  const file = join(dir, IDENTITY_FILE_NAME)
  const entry = await statOrNull(file)
  if (entry === undefined) return undefined
  if (!entry.isFile() || entry.isSymbolicLink()) {
    throw new Error(`身份路径 ${file} 必须是常规文件，不能是符号链接或目录。`)
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(await readFile(file, 'utf8'))
  } catch (error) {
    throw new Error(`身份文件 ${file} 不是合法 JSON。`, { cause: error })
  }
  return parseIdentityFile(parsed)
}

/**
 * 原子写入身份文件：同目录临时文件 + rename，权限 0600。
 * @param dir - 宿主数据目录。
 * @param content - 完整的新内容。
 */
async function writeIdentityFile(dir: string, content: IdentityFile): Promise<void> {
  await writeFileAtomic(join(dir, IDENTITY_FILE_NAME), `${JSON.stringify(content, null, 2)}\n`, {
    mode: 0o600,
    dirMode: 0o700,
  })
}

/**
 * 一台远程宿主（PC）的持久身份。
 *
 * 通过 {@link Identity.load} 获得；除加载/绑定时的一次读写外不再触碰磁盘。
 */
export class Identity {
  /** 64 位小写十六进制实例 id；磁盘上有 CA 时等于该 CA 证书的 sha256 指纹。 */
  readonly instanceId: string

  /** 主机显示名，用于配对页与 App 的电脑列表。 */
  readonly displayName: string

  private constructor(instanceId: string, displayName: string) {
    this.instanceId = instanceId
    this.displayName = displayName
  }

  /**
   * 读取宿主数据目录下的身份，文件不存在时用随机 instanceId 创建。
   *
   * 调用顺序要求：宿主启动时先 `ensureTlsMaterial`（见 ./tls.ts）再 load，否则
   * 拿到的是占位 instanceId（CA 签发后会被绑定为 CA 指纹）。
   * @param dir - 宿主数据目录（identity.json 所在目录）。
   * @returns 已持久化的身份。
   * @throws 身份文件损坏、不可读，或路径不是常规文件时抛出；不会静默换一个新 id。
   */
  static async load(dir: string): Promise<Identity> {
    const existing = await readIdentityFile(dir)
    if (existing !== undefined) return new Identity(existing.instanceId, existing.displayName)
    const created: IdentityFile = {
      instanceId: randomBytes(32).toString('hex'),
      displayName: sanitizeDisplayName(hostname()),
    }
    await writeIdentityFile(dir, created)
    return new Identity(created.instanceId, created.displayName)
  }

  /**
   * 把 instanceId 绑定为已签发 CA 的指纹，由 `ensureTlsMaterial`（见 ./tls.ts）在
   * **新签** CA 时调用；显示名保持不变。
   *
   * 只在新签 CA 时调用：已有 CA 却与 identity.json 不一致属于持久状态错乱，
   * 由 tls.ts 的 `assertCaBinding` 报错，不在这里悄悄改写。
   * @param dir - 宿主数据目录。
   * @param instanceId - CA 证书 DER 的 sha256 指纹（64 位小写十六进制）。
   * @returns 绑定后的身份。
   * @throws instanceId 形状非法或写入失败时抛出。
   */
  static async bindInstanceId(dir: string, instanceId: string): Promise<Identity> {
    if (!INSTANCE_ID_PATTERN.test(instanceId)) {
      throw new Error('instanceId 必须是 64 位小写十六进制（32 字节 CA 指纹）。')
    }
    const existing = await readIdentityFile(dir)
    if (existing !== undefined && existing.instanceId === instanceId) {
      return new Identity(existing.instanceId, existing.displayName)
    }
    const displayName = existing?.displayName ?? sanitizeDisplayName(hostname())
    await writeIdentityFile(dir, { instanceId, displayName })
    return new Identity(instanceId, displayName)
  }

  /**
   * 计算证书的 CA 绑定指纹。
   *
   * 与 {@link certificateFingerprint} 同一算法，保留实例方法是为了让调用方从
   * 身份对象直接拿到比较基准。
   * @param certPem - PEM 编码的证书（通常是本宿主的 CA 证书）。
   * @returns 64 位小写十六进制 sha256 指纹。
   * @throws 证书无法解析时抛出。
   */
  fingerprintOf(certPem: string): string {
    return certificateFingerprint(certPem)
  }
}
