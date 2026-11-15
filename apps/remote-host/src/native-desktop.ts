/**
 * 桌面宿主对 `native.*` 反向请求的本地应答。
 *
 * 远程模式下门面代码仍在 PC 上运行，并继续用 `transport.request('native.…')`
 * 反向要资源；区别只是这个请求落在宿主自己身上，而不是手机。本类只应答语义
 * 属于 PC 的那几个方法：DSH 数据根、附件/导出目录、凭据读写、Web 访问偏好与
 * 网卡地址，以及桌面没有 Alarm 约束的后台唤醒确认（协议 §5.2）。
 *
 * 其余方法由上层路由决定去向：
 * - `native.documents.*` 的语义是“手机上的文件”，上层应转发给 App；
 * - PTC / workflow / Linux VM 等 Android 专属能力在桌面不存在，
 *   上层应直接回 `-32601`（协议 §5.3），不要静默丢弃。
 */
import { randomUUID } from 'node:crypto'
import { mkdir, readFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write'
import { credentialRef, type CredentialInfo, type CredentialRef } from '@deepseek-ai/dsh-credentials'

/** 附件目录在 DSH 数据根下的名字，与手机侧同名，便于两侧日志对照。 */
const ATTACHMENTS_DIRECTORY = 'app-attachments'
/** 会话导出 ZIP 的落盘目录。 */
const EXPORTS_DIRECTORY = 'exports'
/** 宿主状态目录（身份、TLS、设备表与 Web 偏好共用的 `<DSH_HOME>/remote-host`）。 */
const STATE_DIRECTORY = 'remote-host'
/** 保存 `native.web.*` 偏好的文件名。 */
const WEB_PREFERENCES_FILE = 'web-preferences.json'
/** Web 监听端口下限；App 侧 `WebPreferences` 按同一区间校验。 */
const WEB_PORT_MINIMUM = 1024
/** Web 监听端口上限。 */
const WEB_PORT_MAXIMUM = 65535
/** 后台唤醒 generation 的线上形态：uuidv4，与 App 侧 `NativeScheduleWakeup` 的校验一致。 */
const SCHEDULE_WAKEUP_GENERATION = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u

/** 凭据值需要能写进 POSIX 风格的环境变量与 dotenv 文件，与 App 门面的校验保持一致。 */
const CREDENTIAL_VALUE = /^[\x21-\x7e]+$/u

/** `native.web.*` 的 Web 访问偏好；字段名即线上字段名。 */
export interface WebPreferences {
  /** 是否启用 Web 访问。 */
  readonly enabled: boolean
  /** 监听范围：仅本机，或局域网可达。 */
  readonly scope: 'local' | 'lan'
  /** 监听端口，1024–65535。 */
  readonly port: number
}

/**
 * 应用侧从未保存过 Web 偏好时的默认值。
 *
 * 与 App 的 `WebPreferences.get()` 返回一致：默认关闭、只听本机、3080 端口。
 */
const DEFAULT_WEB_PREFERENCES: WebPreferences = Object.freeze({ enabled: false, scope: 'local', port: 3080 })

/**
 * 桌面宿主需要的凭据能力：`ctx.credentials` 的三个引用读写方法。
 *
 * 只声明用到的部分，宿主就不必为了一个 `native.credentials.set` 依赖整个凭据服务类型。
 */
export interface DesktopCredentialPort {
  /**
   * 读取一个引用当前是否已配置，以及它的来源。
   * @param ref - 环境变量式引用名，例如 `DEEPSEEK_API_KEY`。
   * @returns 配置状态、来源与可写性；不含密钥值。
   */
  describe(ref: CredentialRef): Promise<CredentialInfo>

  /**
   * 写入一个引用的值。
   * @param ref - 目标引用。
   * @param value - 非空的可打印 ASCII 值。
   */
  set(ref: CredentialRef, value: string): Promise<void>

  /**
   * 删除一个引用的存储值；参考层（进程环境、`.env`）可能因此重新生效。
   * @param ref - 目标引用。
   */
  unset(ref: CredentialRef): Promise<void>
}

/** 构造 {@link DesktopNativeProvider} 所需的宿主事实。 */
export interface DesktopNativeProviderOptions {
  /** DSH 用户数据根目录，通常取 `resolveDshHome()` 的结果。 */
  dshHome: string
  /** 宿主侧凭据服务，`native.credentials.*` 直接转发给它。 */
  credentials: DesktopCredentialPort
  /**
   * 本机可用于监听/展示的 IPv4 地址，第一项是默认路由地址（手机最可能连上的那一个）。
   * 由装配方注入：地址排序与配对链接 origin 的选择共用同一套选路逻辑。
   * @returns 非内部 IPv4 地址；没有可用地址时为空数组。
   */
  readonly ipv4Addresses: () => Promise<readonly string[]>
}

/** 一条“桌面不实现”的方法前缀规则。 */
interface UnsupportedRule {
  /** 方法名前缀；`native.documents.` 之类带尾点，避免误伤同名前缀的其它方法。 */
  readonly prefix: string
  /** true 表示语义属于手机，上层应转发给 App；false 表示两侧都不该应答。 */
  readonly forwardToDevice: boolean
  /** 直接写进错误信息的原因说明。 */
  readonly reason: string
}

/**
 * 桌面宿主明确不实现的 `native.*` 方法。
 *
 * 顺序无关：前缀之间没有包含关系，只有 `native.toolCallback` 这类无尾点的规则
 * 同时覆盖 `.cancel` 变体。
 */
const UNSUPPORTED_RULES: readonly UnsupportedRule[] = [
  { prefix: 'native.documents.', forwardToDevice: true, reason: '手机侧文档访问由 App 应答' },
  { prefix: 'native.toolCallback', forwardToDevice: false, reason: '桌面 PTC 在宿主进程内执行，不使用设备回调' },
  { prefix: 'native.workflowCallback', forwardToDevice: false, reason: '桌面 workflow 在宿主进程内执行，不使用设备回调' },
  { prefix: 'native.linuxVm.', forwardToDevice: false, reason: '桌面宿主不提供 Linux 虚拟机' },
  { prefix: 'native.linuxCommand.', forwardToDevice: false, reason: '桌面宿主不提供隔离的 Linux 命令通道' },
  { prefix: 'native.isolated.', forwardToDevice: false, reason: '桌面宿主不提供 App 的隔离执行器' },
  { prefix: 'native.workflow.', forwardToDevice: false, reason: '桌面宿主不提供 App 私有的 workflow 运行时' },
  // 协议没有 `native.scheduleWake.*` 这个拼写（协议 §5.2 只有 scheduleWakeup.begin/update）；
  // 未知拼写仍按明确不支持处理，避免它被转发给手机后只剩一个静默后果不明确的 -32601。
  { prefix: 'native.scheduleWake.', forwardToDevice: false, reason: '桌面宿主只确认 native.scheduleWakeup.begin/update' },
  { prefix: 'native.networkChanged', forwardToDevice: false, reason: 'Android 专属通知，远程模式不发送' },
  { prefix: 'native.appDisconnected', forwardToDevice: false, reason: 'Android 专属通知，远程模式不发送' },
]

/**
 * 远程宿主没有实现某个 `native.*` 方法时抛出的错误。
 *
 * 上层路由据此回协议 §5.3 的 `-32601`：`code` 直接作为 `error.data.code`，
 * `forwardToDevice` 区分“该交给手机”与“谁都不应答”。
 */
export class NativeMethodUnsupportedError extends Error {
  /** 协议 §5.3 规定的 `error.data.code`。 */
  readonly code = 'unsupported-method'
  /** 触发失败的方法名。 */
  readonly method: string
  /** true 表示该方法语义属于手机，上层应转发给 App。 */
  readonly forwardToDevice: boolean

  /**
   * @param method - 未被本地实现的方法名。
   * @param options - 是否应转发给手机，以及写进错误信息的原因。
   */
  constructor(method: string, options: { readonly forwardToDevice: boolean; readonly reason: string }) {
    super(options.forwardToDevice
      ? `${method} 由手机侧应答，远程宿主本地不支持。`
      : `远程宿主不支持 ${method}：${options.reason}。`)
    this.name = 'NativeMethodUnsupportedError'
    this.method = method
    this.forwardToDevice = options.forwardToDevice
  }
}

/**
 * 读取一个必填字符串参数。
 *
 * `native.*` 的 params 来自 JSON-RPC 线缆，是不受信任输入，因此在进入目录或
 * 凭据操作前先逐项校验。
 * @param params - JSON-RPC 的 params。
 * @param key - 需要读取的字段名。
 * @returns 该字段的字符串值。
 * @throws TypeError 当 params 不是对象或字段不是非空字符串时。
 */
function requiredStringParam(params: unknown, key: string): string {
  if (typeof params !== 'object' || params === null || Array.isArray(params)) {
    throw new TypeError('native.* 的 params 必须是对象')
  }
  const value = (params as Record<string, unknown>)[key]
  if (typeof value !== 'string' || value.length === 0) {
    throw new TypeError(`native.* 的 params.${key} 必须是非空字符串`)
  }
  return value
}

/**
 * 读取并校验 `native.credentials.*` 的引用参数。
 * @param params - JSON-RPC 的 params。
 * @returns 品牌化后的凭据引用。
 * @throws TypeError 当引用不是合法的环境变量名时。
 */
function credentialRefParam(params: unknown): CredentialRef {
  const ref = requiredStringParam(params, 'ref')
  try {
    return credentialRef(ref)
  } catch {
    // 原始错误只说明正则不匹配，换成面向宿主日志的中文说明。
    throw new TypeError(`凭据引用 ${ref} 不是合法的环境变量名`)
  }
}

/** 查找与方法名匹配的不支持规则；没有匹配返回 undefined。 */
function unsupportedRule(method: string): UnsupportedRule | undefined {
  return UNSUPPORTED_RULES.find(rule => method.startsWith(rule.prefix))
}

/**
 * 校验一份 Web 访问偏好。
 *
 * `native.web.save` 的 params 由门面组装后交过来，落盘前逐项校验；读回的文件同样走这里，
 * 因此损坏的偏好不会被当成默认值继续使用。
 * @param value - 待校验值。
 * @returns 三个字段收敛后的偏好对象。
 * @throws TypeError 当字段缺失、类型不对或端口越界时。
 */
function parseWebPreferences(value: unknown): WebPreferences {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new TypeError('Web 访问偏好的 params 必须是对象')
  }
  const record = value as Record<string, unknown>
  const enabled = record.enabled
  const scope = record.scope
  const port = record.port
  if (typeof enabled !== 'boolean') throw new TypeError('Web 访问偏好的 enabled 必须是布尔值')
  if (scope !== 'local' && scope !== 'lan') throw new TypeError('Web 访问偏好的 scope 必须是 local 或 lan')
  if (typeof port !== 'number' || !Number.isSafeInteger(port) || port < WEB_PORT_MINIMUM || port > WEB_PORT_MAXIMUM) {
    throw new TypeError(`Web 访问偏好的 port 必须是 ${WEB_PORT_MINIMUM} 到 ${WEB_PORT_MAXIMUM} 之间的整数`)
  }
  return Object.freeze({ enabled, scope, port })
}

/**
 * 读取已保存的 Web 访问偏好。
 * @param filePath - `web-preferences.json` 的路径。
 * @returns 已保存的偏好；文件还不存在时是 {@link DEFAULT_WEB_PREFERENCES}。
 * @throws 文件读不了或内容不合法时抛出：损坏的偏好不能被静默当成默认值。
 */
async function readWebPreferences(filePath: string): Promise<WebPreferences> {
  let serialized: string
  try {
    serialized = await readFile(filePath, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException | null)?.code === 'ENOENT') return DEFAULT_WEB_PREFERENCES
    throw new Error(`读取 Web 访问偏好失败：${filePath}。`, { cause: error })
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(serialized)
  } catch (error) {
    throw new Error(`Web 访问偏好文件不是合法 JSON：${filePath}。`, { cause: error })
  }
  try {
    return parseWebPreferences(parsed)
  } catch (error) {
    throw new Error(`Web 访问偏好文件内容不合法：${filePath}。`, { cause: error })
  }
}

/**
 * 原子写入 Web 访问偏好：同目录临时文件 + rename，权限与设备表同一口径。
 * @param filePath - `web-preferences.json` 的路径。
 * @param preferences - 已校验的完整偏好。
 */
async function writeWebPreferences(filePath: string, preferences: WebPreferences): Promise<void> {
  await mkdir(dirname(filePath), { recursive: true })
  await writeFileAtomic(filePath, `${JSON.stringify(preferences, null, 2)}\n`, { mode: 0o600, dirMode: 0o700 })
}

/**
 * 读取并校验 `native.scheduleWakeup.update` 需要回显的字段（协议 §5.2）。
 * @param params - JSON-RPC 的 params。
 * @returns 门面这一代的 generation 与本次修订号。
 * @throws TypeError 当 version / generation / revision 不合法时。
 */
function parseScheduleWakeupUpdate(params: unknown): { readonly generation: string; readonly revision: number } {
  if (typeof params !== 'object' || params === null || Array.isArray(params)) {
    throw new TypeError('native.scheduleWakeup.update 的 params 必须是对象')
  }
  const record = params as Record<string, unknown>
  if (record.version !== 1) throw new TypeError('native.scheduleWakeup.update 的 version 必须是 1')
  const generation = record.generation
  if (typeof generation !== 'string' || !SCHEDULE_WAKEUP_GENERATION.test(generation)) {
    throw new TypeError('native.scheduleWakeup.update 的 generation 必须是 uuidv4')
  }
  const revision = record.revision
  if (typeof revision !== 'number' || !Number.isSafeInteger(revision) || revision < 1) {
    throw new TypeError('native.scheduleWakeup.update 的 revision 必须是正安全整数')
  }
  return { generation, revision }
}

/**
 * 桌面宿主的 `native.*` 提供者。
 *
 * 与手机侧提供者接口一致：`handles()` 先筛出本机应答的方法，`request()` 只处理
 * 这些方法。`request()` 收到未实现的方法时抛
 * {@link NativeMethodUnsupportedError}，绝不返回 `undefined`——反向请求静默落空
 * 会让 PC 侧的 `packageOperations.runWork` 永久悬挂。
 *
 * 凭据方法的 params 与凭据服务的引用口径一致：`{ ref }`、`{ ref, value }`，
 * 其中 `ref` 是 `DEEPSEEK_API_KEY` 这类环境变量名，不是手机侧的
 * `refs/<ref>`、`records/<key>` 名字。
 */
export class DesktopNativeProvider {
  readonly #dshHome: string
  readonly #credentials: DesktopCredentialPort
  readonly #ipv4Addresses: () => Promise<readonly string[]>
  /** `web-preferences.json` 的绝对路径。 */
  readonly #webPreferencesFile: string
  /** 附件目录的创建结果，避免每个附件都重复 mkdir。 */
  #attachments: Promise<string> | undefined

  /**
   * @param options - DSH 数据根、宿主凭据服务与网卡地址来源。
   */
  constructor(options: DesktopNativeProviderOptions) {
    this.#dshHome = options.dshHome
    this.#credentials = options.credentials
    this.#ipv4Addresses = options.ipv4Addresses
    this.#webPreferencesFile = join(options.dshHome, STATE_DIRECTORY, WEB_PREFERENCES_FILE)
  }

  /**
   * 本机是否应答该方法。
   * @param method - `native.*` 方法名。
   * @returns 只有本类实现的方法返回 true；其余（含明确不支持与未知方法）返回 false。
   */
  handles(method: string): boolean {
    switch (method) {
      case 'native.storage.root':
      case 'native.attachments.directory':
      case 'native.exports.directory':
      case 'native.attachmentFiles.directory':
      case 'native.web.preferences':
      case 'native.web.save':
      case 'native.network.addresses':
      case 'native.scheduleWakeup.begin':
      case 'native.scheduleWakeup.update':
      case 'native.credentials.describe':
      case 'native.credentials.set':
      case 'native.credentials.unset':
        return true
      default:
        return false
    }
  }

  /**
   * 应答一个本机方法。
   * @param method - `native.*` 方法名，调用前应先用 {@link handles} 判断。
   * @param params - JSON-RPC 的 params；目录/地址类方法忽略它，凭据方法读 `ref`（及 `value`），
   *   Web 保存读 `enabled` / `scope` / `port`，后台唤醒确认读 `version` / `generation` / `revision`。
   * @returns 方法结果；凭据只返回 `{ configured }`，不回传密钥；Web 保存返回落盘后的偏好。
   * @throws NativeMethodUnsupportedError 当方法没有桌面实现时。
   */
  async request(method: string, params?: unknown): Promise<unknown> {
    switch (method) {
      case 'native.storage.root':
        return this.#dshHome
      case 'native.attachments.directory':
        return this.#attachmentDirectory()
      // 附件文件的宿主目录与附件目录同一个（协议 §5.2）。
      case 'native.attachmentFiles.directory':
        return this.#attachmentDirectory()
      case 'native.exports.directory':
        return join(this.#dshHome, EXPORTS_DIRECTORY)
      case 'native.web.preferences':
        return readWebPreferences(this.#webPreferencesFile)
      case 'native.web.save': {
        const preferences = parseWebPreferences(params)
        await writeWebPreferences(this.#webPreferencesFile, preferences)
        return preferences
      }
      case 'native.network.addresses':
        return { addresses: [...await this.#ipv4Addresses()] }
      // 桌面没有 Android 的 Alarm 约束（协议 §5.2：直接确认），所以 begin 只发一代
      // generation，update 原样确认修订号，不排任何系统闹钟。
      case 'native.scheduleWakeup.begin':
        return { version: 1, generation: randomUUID() }
      case 'native.scheduleWakeup.update': {
        const { generation, revision } = parseScheduleWakeupUpdate(params)
        return { version: 1, generation, revision, accepted: true }
      }
      case 'native.credentials.describe':
        return this.#credentials.describe(credentialRefParam(params))
      case 'native.credentials.set': {
        const ref = credentialRefParam(params)
        const value = requiredStringParam(params, 'value')
        if (!CREDENTIAL_VALUE.test(value)) {
          throw new TypeError('凭据值必须是不含空格的可打印 ASCII 字符')
        }
        await this.#credentials.set(ref, value)
        return { configured: true }
      }
      case 'native.credentials.unset':
        await this.#credentials.unset(credentialRefParam(params))
        return { configured: false }
      default: {
        const rule = unsupportedRule(method)
        throw new NativeMethodUnsupportedError(method, {
          forwardToDevice: rule?.forwardToDevice ?? false,
          reason: rule?.reason ?? '桌面宿主没有该方法对应的实现',
        })
      }
    }
  }

  /**
   * 返回附件目录并确保它存在。
   * @returns `<DSH_HOME>/app-attachments` 的绝对路径。
   */
  #attachmentDirectory(): Promise<string> {
    if (this.#attachments) return this.#attachments
    const directory = join(this.#dshHome, ATTACHMENTS_DIRECTORY)
    // 失败时清掉缓存，让下一次请求重新尝试创建，而不是永久记住一次 IO 错误。
    this.#attachments = mkdir(directory, { recursive: true }).then(() => directory)
      .catch((error: unknown) => {
        this.#attachments = undefined
        throw error
      })
    return this.#attachments
  }
}
