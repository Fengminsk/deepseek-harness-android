/**
 * 远程宿主的 TLS 材料：一张长期自签 CA + 一张短期服务器叶子证书。
 *
 * 信任模型与 App 的配对流程一一对应：
 * 1. CA 由本机自签，证书 DER 的 sha256 指纹就是宿主的 instanceId；
 * 2. App 在配对时以「不校验」的方式取回 CA，比较指纹后才固定，此后只信这张 CA；
 * 3. 服务器叶子证书由该 CA 签发，SAN 覆盖当前网卡地址与主机名，因此换 IP
 *    只需要重签叶子，已配对的手机不需要重新配对。
 *
 * 因此 {@link ensureTlsMaterial} 在**新签** CA 时把指纹绑定到
 * {@link Identity}，在**复用**已有 CA 时用 {@link assertCaBinding} 校验
 * identity.json 与 CA 仍然一致；两者不一致说明持久状态被替换或只恢复了一半，
 * 直接报错而不是悄悄改写身份。
 * @module remote-host/tls
 */

import { createPrivateKey, X509Certificate } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { isIP } from 'node:net'
import { join } from 'node:path'
import { generate } from 'selfsigned'
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write'
import { Identity, certificateFingerprint } from './identity.ts'

/** TLS 材料所在的子目录名（相对宿主数据目录）。 */
const TLS_DIRECTORY_NAME = 'tls'

/** CA 证书文件名。 */
const CA_CERT_FILE_NAME = 'ca.pem'

/** CA 私钥文件名。 */
const CA_KEY_FILE_NAME = 'ca-key.pem'

/** 服务器叶子证书文件名。 */
const SERVER_CERT_FILE_NAME = 'server.pem'

/** 服务器叶子私钥文件名。 */
const SERVER_KEY_FILE_NAME = 'server-key.pem'

/** CA 的 CN；CN 只用于人工排障，信任判据是证书指纹。 */
const AUTHORITY_COMMON_NAME = 'DeepSeek Harness 远程 PC CA'

/** CA 有效期（年）。 */
const AUTHORITY_LIFETIME_YEARS = 10

/** 服务器叶子有效期（年）。 */
const SERVER_LIFETIME_YEARS = 1

/** CA 到期前多久开始重签。 */
const AUTHORITY_RENEWAL_MARGIN_MS = 30 * 24 * 60 * 60 * 1000

/** 叶子到期前多久开始重签。 */
const SERVER_RENEWAL_MARGIN_MS = 7 * 24 * 60 * 60 * 1000

/** 证书生效时间向前留的时钟偏差容差。 */
const NOT_BEFORE_SKEW_MS = 5 * 60 * 1000

/** 叶子 SAN 恒包含的回环地址，覆盖本机调试连接。 */
const MANDATORY_HOSTS: readonly string[] = ['127.0.0.1', 'localhost']

/** 允许写进 DNS 类型 SAN 的字符集合（主机名与内网域名的公共子集）。 */
const DNS_NAME_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/u

/** {@link ensureTlsMaterial} 的输入。 */
export interface TlsMaterialOptions {
  /** 宿主数据目录；TLS 材料写入其下的 tls/ 子目录，identity.json 也在该目录。 */
  readonly dir: string
  /** 叶子证书 SAN 必须覆盖的主机名或 IP 字面量；127.0.0.1 与 localhost 恒被加入。 */
  readonly hosts: readonly string[]
  /** 叶子证书的 CN，1–64 个字符。 */
  readonly commonName: string
}

/** {@link ensureTlsMaterial} 的产物，可直接交给 TLS 服务器使用。 */
export interface TlsMaterial {
  /** 服务器叶子证书 PEM。 */
  readonly certPem: string
  /** 服务器叶子私钥 PEM。 */
  readonly keyPem: string
  /** 签发上面这张叶子的 CA 证书 PEM；App 固定它。 */
  readonly caPem: string
}

/** 一个需要写进 SAN 的名字。 */
interface ServerName {
  readonly kind: 'dns' | 'ip'
  readonly value: string
}

/** selfsigned 接受的 SAN 条目。 */
interface SubjectAltName {
  readonly type: 2 | 7
  readonly value?: string
  readonly ip?: string
}

/** 一次 ensure 内部使用的 CA 状态。 */
interface CertificateAuthority {
  readonly certPem: string
  readonly keyPem: string
  readonly fingerprint: string
  /** 是否复用了磁盘上已有的 CA；只有新签时才允许绑定 instanceId。 */
  readonly reused: boolean
}

/** 一次 ensure 内部使用的叶子状态。 */
interface ServerCertificate {
  readonly certPem: string
  readonly keyPem: string
}

/** 文件不存在的 errno 判定；其余错误照常抛出。 */
function isMissingFile(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | null)?.code === 'ENOENT'
}

/**
 * 读取可选文件。
 * @param file - 绝对路径。
 * @returns 文件内容；文件不存在时返回 undefined。
 */
async function readOptionalFile(file: string): Promise<string | undefined> {
  try {
    return await readFile(file, 'utf8')
  } catch (error) {
    if (isMissingFile(error)) return undefined
    throw error
  }
}

/**
 * 把 `now` 往后推整数年，避开按天累加时闰年的误差。
 * @param now - 基准时间。
 * @param years - 年数。
 * @returns 新的时间点。
 */
function yearsFrom(now: Date, years: number): Date {
  const later = new Date(now.getTime())
  later.setFullYear(later.getFullYear() + years)
  return later
}

/**
 * 证书是否已经进入重签窗口。
 *
 * `validTo` 是 OpenSSL 的文本时间；解析失败时按需要重签处理，宁可多签一次也
 * 不把可能已过期的证书继续发出去。
 * @param certificate - 已解析的证书。
 * @param marginMs - 提前重签的毫秒数。
 * @returns 需要重签时为 true。
 */
function needsRenewal(certificate: X509Certificate, marginMs: number): boolean {
  const validTo = Date.parse(certificate.validTo)
  if (Number.isNaN(validTo)) return true
  return validTo - marginMs <= Date.now()
}

/**
 * 归一化 IP 字面量的文本形态，用于比较 SAN 与期望值。
 *
 * IPv6 的压缩形态因打印者而异（`::1` 与 `0:0:0:0:0:0:0:1`），交给 WHATWG URL
 * 解析可以拿到统一形态；IPv4 与 DNS 名按小写原样返回。
 * @param value - IP 字面量。
 * @returns 规范化后的小写文本。
 */
function normalizeIpText(value: string): string {
  try {
    return new URL(`http://[${value}]/`).hostname.slice(1, -1).toLowerCase()
  } catch (error) {
    // 不是 IPv6 字面量（IPv4 或非法值）：小写原样参与比较，由 isIP 预先把关。
    void error
    return value.toLowerCase()
  }
}

/**
 * 把调用方给的主机列表收敛成去重后的 SAN 名字集合。
 * @param hosts - 主机名或 IP 字面量，允许为空数组。
 * @returns 至少包含 127.0.0.1 与 localhost 的名字列表。
 * @throws 出现既不是 IP 也不是合法 DNS 名的条目时抛出（配置错误应当立刻可见）。
 */
function serverNames(hosts: readonly string[]): readonly ServerName[] {
  const names: ServerName[] = []
  const seen = new Set<string>()
  for (const raw of [...MANDATORY_HOSTS, ...hosts]) {
    // IPv6 的作用域后缀（`%eth0`）不能出现在 SAN 里。
    const value = raw.trim().replace(/%.*$/u, '')
    if (value.length === 0) continue
    const version = isIP(value)
    if (version === 0 && !DNS_NAME_PATTERN.test(value)) {
      throw new Error(`TLS 主机名不合法：${JSON.stringify(value)}。请传入 IP 字面量或合法主机名。`)
    }
    const kind: ServerName['kind'] = version === 0 ? 'dns' : 'ip'
    const key = kind === 'ip' ? `ip:${normalizeIpText(value)}` : `dns:${value.toLowerCase()}`
    if (seen.has(key)) continue
    seen.add(key)
    names.push({ kind, value })
  }
  return names
}

/**
 * 构造 selfsigned 需要的 SAN 条目。
 * @param names - {@link serverNames} 的结果。
 * @returns SAN 扩展的 `altNames`。
 */
function subjectAltNames(names: readonly ServerName[]): SubjectAltName[] {
  return names.map((name): SubjectAltName => (name.kind === 'ip' ? { type: 7, ip: name.value } : { type: 2, value: name.value }))
}

/**
 * 判断已有叶子证书的 SAN 是否覆盖全部期望名字。
 * @param raw - `X509Certificate.subjectAltName` 的文本形态，无 SAN 时为 undefined。
 * @param names - 期望覆盖的名字。
 * @returns 全部覆盖时为 true。
 */
function subjectAltNamesCover(raw: string | undefined, names: readonly ServerName[]): boolean {
  if (raw === undefined) return false
  const dnsNames = new Set<string>()
  const ipAddresses = new Set<string>()
  for (const entry of raw.split(', ')) {
    if (entry.startsWith('DNS:')) dnsNames.add(entry.slice(4).toLowerCase())
    else if (entry.startsWith('IP Address:')) ipAddresses.add(normalizeIpText(entry.slice(11)))
  }
  return names.every(name => (name.kind === 'ip' ? ipAddresses.has(normalizeIpText(name.value)) : dnsNames.has(name.value.toLowerCase())))
}

/**
 * 已有 CA 是否还能继续用。
 * @param certPem - CA 证书 PEM。
 * @param keyPem - CA 私钥 PEM。
 * @returns 可复用时为 true。
 */
function isReusableAuthority(certPem: string, keyPem: string): boolean {
  try {
    const certificate = new X509Certificate(certPem)
    return certificate.ca
      && certificate.checkPrivateKey(createPrivateKey(keyPem))
      && !needsRenewal(certificate, AUTHORITY_RENEWAL_MARGIN_MS)
  } catch (error) {
    // 任意一侧被截断或被替换：当作不可复用，交给调用方重签。
    void error
    return false
  }
}

/**
 * 已有叶子证书是否还能继续用。
 *
 * 复用判据是「由当前 CA 签发 + 私钥匹配 + 未进入重签窗口 + SAN 覆盖全部名字」；
 * CN 只影响证书展示，不参与判断。
 * @param certPem - 叶子证书 PEM。
 * @param keyPem - 叶子私钥 PEM。
 * @param authority - 当前 CA。
 * @param names - 期望覆盖的名字。
 * @returns 可复用时为 true。
 */
function isReusableServerCertificate(
  certPem: string,
  keyPem: string,
  authority: CertificateAuthority,
  names: readonly ServerName[],
): boolean {
  try {
    const certificate = new X509Certificate(certPem)
    const issuer = new X509Certificate(authority.certPem)
    return !certificate.ca
      && certificate.verify(issuer.publicKey)
      && certificate.checkPrivateKey(createPrivateKey(keyPem))
      && !needsRenewal(certificate, SERVER_RENEWAL_MARGIN_MS)
      && subjectAltNamesCover(certificate.subjectAltName, names)
  } catch (error) {
    // 证书、签发者或私钥任意一项无法解析时重签，不影响已完成配对的手机。
    void error
    return false
  }
}

/**
 * 读取或新签 CA。
 * @param directory - TLS 材料目录。
 * @returns CA 状态；`reused` 表示本次是否沿用了磁盘上的 CA。
 */
async function ensureAuthority(directory: string): Promise<CertificateAuthority> {
  const certFile = join(directory, CA_CERT_FILE_NAME)
  const keyFile = join(directory, CA_KEY_FILE_NAME)
  const certPem = await readOptionalFile(certFile)
  const keyPem = await readOptionalFile(keyFile)
  if (certPem !== undefined && keyPem !== undefined && isReusableAuthority(certPem, keyPem)) {
    return { certPem, keyPem, fingerprint: certificateFingerprint(certPem), reused: true }
  }
  const now = new Date()
  const generated = await generate([{ name: 'commonName', value: AUTHORITY_COMMON_NAME }], {
    keyType: 'ec',
    curve: 'P-256',
    algorithm: 'sha256',
    notBeforeDate: new Date(now.getTime() - NOT_BEFORE_SKEW_MS),
    notAfterDate: yearsFrom(now, AUTHORITY_LIFETIME_YEARS),
    extensions: [
      { name: 'basicConstraints', cA: true, critical: true },
      { name: 'keyUsage', digitalSignature: true, keyCertSign: true, cRLSign: true, critical: true },
    ],
  })
  await writeFileAtomic(keyFile, generated.private, { mode: 0o600, dirMode: 0o700 })
  await writeFileAtomic(certFile, generated.cert, { mode: 0o644, dirMode: 0o700 })
  return { certPem: generated.cert, keyPem: generated.private, fingerprint: certificateFingerprint(generated.cert), reused: false }
}

/**
 * 读取或重签服务器叶子证书。
 * @param directory - TLS 材料目录。
 * @param authority - 签发它的 CA。
 * @param names - SAN 必须覆盖的名字。
 * @param commonName - 叶子证书的 CN。
 * @returns 叶子证书与私钥。
 */
async function ensureServerCertificate(
  directory: string,
  authority: CertificateAuthority,
  names: readonly ServerName[],
  commonName: string,
): Promise<ServerCertificate> {
  const certFile = join(directory, SERVER_CERT_FILE_NAME)
  const keyFile = join(directory, SERVER_KEY_FILE_NAME)
  const certPem = await readOptionalFile(certFile)
  const keyPem = await readOptionalFile(keyFile)
  if (certPem !== undefined && keyPem !== undefined && isReusableServerCertificate(certPem, keyPem, authority, names)) {
    return { certPem, keyPem }
  }
  const now = new Date()
  const generated = await generate([{ name: 'commonName', value: commonName }], {
    keyType: 'ec',
    curve: 'P-256',
    algorithm: 'sha256',
    notBeforeDate: new Date(now.getTime() - NOT_BEFORE_SKEW_MS),
    notAfterDate: yearsFrom(now, SERVER_LIFETIME_YEARS),
    ca: { cert: authority.certPem, key: authority.keyPem },
    extensions: [
      { name: 'basicConstraints', cA: false, critical: true },
      { name: 'keyUsage', digitalSignature: true, critical: true },
      { name: 'extKeyUsage', serverAuth: true },
      { name: 'subjectAltName', altNames: subjectAltNames(names) },
    ],
  })
  await writeFileAtomic(keyFile, generated.private, { mode: 0o600, dirMode: 0o700 })
  await writeFileAtomic(certFile, generated.cert, { mode: 0o644, dirMode: 0o700 })
  return { certPem: generated.cert, keyPem: generated.private }
}

/**
 * 校验 CA 指纹是否等于宿主 instanceId。
 *
 * 这是 App 侧固定 CA 的同一条规则在宿主侧的自检：不相等时 App 一定会拒绝
 * 固定该证书，所以宿主必须先失败。
 * @param caPem - CA 证书 PEM。
 * @param instanceId - 宿主 instanceId（64 位小写十六进制）。
 * @throws 指纹与 instanceId 不一致时抛出。
 */
export function assertCaBinding(caPem: string, instanceId: string): void {
  const fingerprint = certificateFingerprint(caPem)
  if (fingerprint !== instanceId) {
    throw new Error(
      `CA 指纹与 instanceId 不一致（CA ${fingerprint}，身份 ${instanceId}）：App 会拒绝固定这张证书。`
      + '请确认数据目录下的 identity.json 与 tls/ 来自同一次签发；一并删除后重启会重新签发，但已配对的手机需要重新配对。',
    )
  }
}

/**
 * 确保持久化目录下有一对可用的 CA 与服务器证书。
 *
 * 已有材料满足「CA 未进重签窗口、叶子由该 CA 签发、SAN 覆盖全部 hosts」时直接
 * 复用；否则只重签失效的那一半。CA 私钥与叶子私钥落盘权限为 0600，证书为
 * 0644，两者都用同目录临时文件 + rename 原子替换。
 *
 * CA 一旦重签（文件损坏、被删除或到期），指纹随之改变，已配对的手机必须重新配对；
 * 叶子重签不影响配对结果。
 * @param options - 数据目录、SAN 需要覆盖的主机、叶子 CN。
 * @returns 可直接交给 TLS 服务器的证书与私钥 PEM。
 * @throws 数据目录状态错乱（instanceId 与已有 CA 不一致）、CN 非法、主机名非法、
 * 或材料写入失败时抛出。
 */
export async function ensureTlsMaterial(options: TlsMaterialOptions): Promise<TlsMaterial> {
  const commonName = options.commonName.trim()
  if (commonName.length === 0 || Array.from(commonName).length > 64) {
    throw new Error('证书 CN 必须是 1–64 个字符。')
  }
  const names = serverNames(options.hosts)
  const directory = join(options.dir, TLS_DIRECTORY_NAME)
  const authority = await ensureAuthority(directory)
  if (authority.reused) {
    // 复用已有 CA 时必须与已持久化身份一致；不一致属于持久状态错乱，报错而不是改写。
    const identity = await Identity.load(options.dir)
    assertCaBinding(authority.certPem, identity.instanceId)
  } else {
    // 新签 CA 是信任根的诞生点，instanceId 随之确定。
    await Identity.bindInstanceId(options.dir, authority.fingerprint)
  }
  const server = await ensureServerCertificate(directory, authority, names, commonName)
  return { certPem: server.certPem, keyPem: server.keyPem, caPem: authority.certPem }
}
