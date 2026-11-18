/**
 * 远程 DSH 的 PC 宿主插件：启用后在桌面 DSH 进程里监听 `wss://<host>:<port>/app`，
 * 让手机用同一套 JSON-RPC 门面方法表连上这台电脑。
 *
 * 本文件只做装配：
 * 1. 读取 `$DSH_HOME/remote-host` 下的身份、TLS 材料与设备表（分别由 `./identity.ts`、`./tls.ts`、
 *    `./devices.ts` 实现）；
 * 2. 开一个配对窗口，把可扫码的配对链接写进日志，并把配对 HTTP 面（`GET /ca.cer`、`POST /pair`）
 *    接到 {@link PairingWindow} 与 {@link DeviceStore} 上；`Config.pairingLongTerm` 为 true 时，
 *    配对成功后自动开下一个窗口，保持「长期可配对」入口；
 * 3. 启动 {@link RemoteHostServer}，并把每条新连接接到运行时门面上：手机发来的方法交给门面的
 *    `dispatch`，门面发起的反向请求与通知走这条连接；`native.*` 里语义属于 PC 的方法由
 *    `./native-desktop.ts` 就地应答，不上线；同一条连接上再经 `./notifications.ts` 把页面线的
 *    `task.completed` / `interactions.changed` / `session/title` 追加成协议 §8 的 `remote.*` 系统通知线；
 * 4. 提供 `remoteHost` 服务（`devices()` / `revokeDevice()` / `deleteDevice()` / `pair()`），
 *    作为 PC 侧设备管理、
 *    撤销设备与重新打开配对窗口的入口；
 * 5. 启用 UDP 局域网发现（`./discovery.ts`）：同网段的手机广播一帧探测就能拿到当前配对
 *    链接，省掉扫码与粘贴。发现端口绑定失败只记 warn，不影响宿主启动；
 * 6. 在回环地址上提供本机配对设置页（`./pairing-page.ts`）：二维码、窗口状态、明文链接、
 *    USB 提示与设备撤销都能在电脑浏览器里完成，不需要读终端日志；同一服务器还提供本机
 *    控制面 JSON API（`/api/state`、`/api/pair`、`/api/devices/revoke`、`/qr.svg`）供设备互联
 *    插件等本机程序读取状态、长期配对与撤销设备；页面端口绑定失败同样只记 warn。
 *
 * 注册即 effect：插件卸载时关闭配对窗口、断开全部连接、停止发现、停止配对页并停止监听。
 *
 * 与 `./identity.ts`、`./tls.ts`、`./devices.ts`、`./pairing.ts` 的接口约定：
 * `ensureTlsMaterial({ dir, hosts, commonName })` 先跑（新签 CA 时它会把 instanceId 绑定为 CA 指纹），
 * 随后 `Identity.load(dir)`、`DeviceStore.open(filePath)`、`new PairingWindow()` +
 * `open(ttlMs)` / `redeem(token, peer?)` / `close()`，以及 `pairUrl(origin, instanceId, token)`。
 * 这四个模块都不在这里重新实现。
 *
 * @module @deepseek-ai/dsh-remote-host
 */

import { X509Certificate, randomUUID } from 'node:crypto'
import { createSocket } from 'node:dgram'
import { hostname, networkInterfaces } from 'node:os'
import { join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import z from '@deepseek-ai/schemastery'
import { DesktopRelayClient } from './desktop-relay-client.ts'
import { DeviceStore, type DeviceAuthorization, type DeviceSummary } from './devices.ts'
import { DEFAULT_DISCOVERY_PORT, DiscoveryResponder, type DiscoverySnapshot } from './discovery.ts'
import { Identity } from './identity.ts'
import { DesktopNativeProvider, type DesktopCredentialPort } from './native-desktop.ts'
import {
  RemoteNotifications,
  sessionFactsFromCatalog,
  type RemoteSessionFacts,
  type RemoteSessionLookup,
} from './notifications.ts'
import {
  DEFAULT_PAIRING_PAGE_PORT,
  PairingPageServer,
  type PairingPageSource,
  type PairingPageTicket,
  type RelayNotificationInput,
} from './pairing-page.ts'
import { encodeQrMatrix, renderTerminalQr } from './pairing-qr.ts'
import { MAXIMUM_PAIRING_TTL_MS, PairingWindow, pairUrl } from './pairing.ts'
import {
  describeRemoteError,
  RemoteHostServer,
  writeRemoteLog,
  type RemoteAuthOutcome,
  type RemoteCloseOutcome,
  type RemoteConnection,
  type RemoteDeviceDeleteResult,
  type RemoteDeviceRevokeResult,
  type RemoteHandshake,
  type RemoteLogger,
  type RemoteNativeProvider,
  type RemotePairingSurface,
  type RemotePairOutcome,
  type RemotePairRequest,
} from './server.ts'
import { dispatchWithSessionRelay } from './session-relay.ts'
import { ensureTlsMaterial } from './tls.ts'

/**
 * 把配对链接编码成二维码并渲染成内联 SVG（纯函数，无 I/O）。
 *
 * 与宿主页面内联二维码、`GET /qr.svg` 用的是同一份实现。导出它是为了给设备互联等
 * 本机插件复用，免得到处复制 QR 编码器；编码器容量不足时抛错，由调用方决定降级方式。
 * @param pairUrl - 完整的配对链接（`wss://…#instance=…&token=…`）。
 * @returns `viewBox` 定尺寸、含 4 模块安静区的内联 SVG 文本。
 * @throws 链接超出 `./pairing-qr.ts` 内置编码器容量时抛出。
 */
export { renderPairingQrSvg } from './pairing-page.ts'

/** Cordis 插件名。 */
export const name = 'remote-host'

/**
 * 装配本插件需要的宿主服务。
 *
 * 监听、鉴权与配对本身不消费这些服务；它们声明在这里是因为业务方法转发要用，
 * 而提前声明能让缺服务的 profile 在加载期就停下，不必等到第一条请求才失败。
 *
 * `appRuntimeFacade` 由 `android-runtime` 在 `platform: desktop` 下提供；当前 Cordis 的
 * `inject` 只有「必给」语义，声明它同时也是装配顺序的保证——门面在 android-runtime 的
 * 注入回调末尾才 provide，本插件必须等它出现之后才能读到。读服务仍用 `ctx.get`，
 * 拿不到时保留 {@link pendingDispatch} 的报错行为。
 *
 * `credentials` 是 `native.credentials.*` 的宿主侧提供者：远程模式下凭据必须留在 PC，
 * 因此它没有可选语义——缺了就直接让插件加载失败，而不是等手机请求时才报错。
 */
export const inject = [
  'agents',
  'sessions',
  'workingDirectory',
  'settings',
  'tools',
  'connection',
  'sessionController',
  'typertGateway',
  'appRuntimeFacade',
  'credentials',
]

/** 插件配置。 */
export interface Config {
  /** 监听端口；0 表示交给系统分配，只用于本地调试。 */
  port: number
  /** 监听地址；默认 `0.0.0.0`，即局域网可达。 */
  host: string
  /** 是否真的开监听；默认关闭，避免别的 profile 把整台电脑意外开到网上。 */
  enabled: boolean
  /**
   * 配对窗口有效期（毫秒）；默认 120 s，单次使用。上限 {@link MAXIMUM_PAIRING_TTL_MS}（90 天）。
   *
   * 有效期超过 15 分钟、或打开 {@link pairingLongTerm} 时，宿主启动日志会写一条 warn 安全提示：
   * 长期窗口等于长期可配对入口，只适合个人可信网络，建议配合设备撤销与不用时关闭宿主。
   */
  pairingTtlMs: number
  /**
   * 长期配对模式；默认关闭。
   *
   * 为 true 时配对窗口按 {@link pairingTtlMs} 打开，并且**每配对成功一台设备就自动打开
   * 下一个窗口**（同一 TTL、新 token），会话期间不需要用户手动重开；失败与撤销不改变
   * 这个语义，宿主重启后照常开新窗口。适合「设置页里长期展示一张二维码」的用法
   * （设备互联插件），代价是配对入口长期存在——只应部署在个人可信网络里。
   */
  pairingLongTerm: boolean
  /** 配对签发的设备令牌有效期（毫秒）；默认 180 天。 */
  deviceTtlMs: number
  /**
   * 配对链接里使用的主机名或地址；空字符串表示自动选择默认路由的本机 IPv4。
   *
   * 自动检测在多网卡机器上可能选到虚拟网卡（VPN、Hyper-V、WSL），手机因此连
   * 不上；这台电脑实际提供服务的地址与自动结果不一致时在这里显式指定。
   */
  publicHost: string
  /**
   * 对外宣告的配对 origin（`wss://host[:port]`）；空字符串表示按 {@link publicHost}
   * 或默认路由地址加监听端口自动生成。
   *
   * 给两类部署用：TLS 直通的 TCP 反向代理（保留 SNI，证书原样透传），或手机按
   * 域名而不是 IP 连入。设置后配对链接与日志里的 origin 换成这里写的地址，监听
   * 仍然绑定 {@link host} / {@link port}；instanceId（CA 指纹）不变，已有设备无需
   * 重新配对。origin 的主机名会加入服务器证书 SAN，叶子证书按需重签（CA 复用），
   * 所以域名型部署也能通过 App 的固定 CA 校验。
   *
   * 只接受 `wss://`：协议 §1.1 的配对链接就是 `wss://host[:port]#instance=…&token=…`，
   * App 的配对解析也拒绝路径前缀；`https://` 虽有客户端容忍，但不是宿主直接提供的
   * 端点，不在这里接受。不允许路径、查询串、片段与账号信息。
   */
  publicOrigin: string
  /**
   * 是否启用 UDP 局域网发现；默认开启。
   *
   * 开启后宿主在 {@link discoveryPort} 上应答同网段手机的探测，把当前配对链接直接交给
   * 手机，省掉扫码与粘贴。发现不建立信任、也不改变配对语义；关掉后手机只能扫码或粘贴。
   */
  discoveryEnabled: boolean
  /**
   * UDP 局域网发现端口；默认 4778。0 表示交给系统分配，只用于本地调试。
   *
   * 与 {@link port} 是不同的协议（UDP / TCP），同一台电脑上两者互不冲突。
   */
  discoveryPort: number
  /**
   * 是否启用本机配对设置页（`./pairing-page.ts`）；默认开启。
   *
   * 页面只监听回环地址 127.0.0.1，用来展示配对二维码/链接、重开配对窗口与撤销设备。
   * 关掉它不影响配对本身：配对链接仍会写进日志。
   */
  pagesEnabled: boolean
  /**
   * 本机配对页的 HTTP 端口；默认 4780。0 表示交给系统分配，只用于本地调试。
   *
   * 与 {@link port}（wss / TCP）和 {@link discoveryPort}（UDP）都不同，互不冲突；
   * 页面只绑回环地址，不会对局域网开放。
   */
  pagesPort: number
  /**
   * Plan-B 桌面中继描述文件（<DSH_HOME>/device-interconnect/relay.json）。
   * 空字符串表示禁用中继：写句柄冲突保持原错误，不去桌面进程重试。
   */
  desktopRelayFile: string
}

/** 配置校验：越界值在加载期就失败，不做静默兜底。 */
export const Config: z<Config> = z.object({
  port: z.number().step(1).min(0).max(65535).default(4777),
  host: z.string().default('0.0.0.0'),
  enabled: z.boolean().default(false),
  pairingTtlMs: z.number().step(1).min(1_000).max(MAXIMUM_PAIRING_TTL_MS).default(120_000),
  pairingLongTerm: z.boolean().default(false),
  deviceTtlMs: z.number().step(1).min(60_000).max(3_153_600_000_000).default(180 * 24 * 60 * 60 * 1000),
  publicHost: z.string().default(''),
  publicOrigin: z.transform(z.string(), value => normalizePublicOrigin(value)).default(''),
  discoveryEnabled: z.boolean().default(true),
  discoveryPort: z.number().step(1).min(0).max(65535).default(DEFAULT_DISCOVERY_PORT),
  pagesEnabled: z.boolean().default(true),
  pagesPort: z.number().step(1).min(0).max(65535).default(DEFAULT_PAIRING_PAGE_PORT),
  desktopRelayFile: z.string().default(''),
})

/** 服务器叶子证书的 CN；只影响证书展示，SAN 才是连得上与否的判据。 */
const SERVER_CERTIFICATE_COMMON_NAME = 'DeepSeek Harness 远程宿主'

/** 宿主在 v1 支持的能力（协议 §10.3：v1 只定义 `window-ack`）。 */
const HOST_CAPABILITIES: readonly string[] = ['window-ack']

/**
 * 放宽前的配对窗口上限（15 分钟）。
 *
 * 只用于启动日志区分「普通短窗口」与「配置成了长窗口」；真正的上限是
 * `./pairing.ts` 的 {@link MAXIMUM_PAIRING_TTL_MS}。
 */
const LEGACY_PAIRING_TTL_CAP_MS = 15 * 60 * 1000

/**
 * 门面分发表（`apps/android/runtime/index.mjs` 的 `facadeDispatch` + 6 组前缀分支）在
 * `platform: desktop` 下可应答的方法清单（协议 §4.2、§10.1）。
 *
 * 协议 §10.1 要求 `methods` 是**完整清单**而不是增量，所以这里逐条列出而不是用通配
 * 掩盖缺口。门面自己提供 `methods` 时（见 {@link AppRuntimeFacade.methods}）以门面为准，
 * 这张表只在门面没有声明时兜底。
 */
const FACADE_METHODS: readonly string[] = [
  'protocol.hello',
  // runtime.*
  'runtime.info',
  'runtime.permissions',
  'runtime.live',
  'runtime.transition.reserve',
  'runtime.transition.commit',
  'runtime.transition.release',
  // session.*
  'session.send',
  'session.ensure',
  'session.selectPreset',
  'session.command',
  'session.cancel',
  'session.readWindow',
  'session.read',
  'session.read.release',
  'session.turnOutline',
  'session.export.prepare',
  'session.export.cancel',
  'session.export.release',
  'session.attachmentFile.prepare',
  'session.attachmentFile.info',
  'session.attachmentFile.read',
  'session.attachmentFile.cancel',
  'session.attachmentFile.release',
  // api.*
  'api.call',
  'api.subscribe',
  'api.ack',
  'api.unsubscribe',
  // workspace.files.*
  'workspace.files.info',
  'workspace.files.list',
  'workspace.files.read',
  'workspace.files.search',
  // document.*（渲染在设备侧，字节源在 PC）
  'document.mediaPolicy',
  'document.call',
  'document.bytes',
  'document.cancel',
  'document.release',
  // terminal.*
  'terminal.list',
  'terminal.shells',
  'terminal.create',
  'terminal.read',
  'terminal.write',
  'terminal.resize',
  'terminal.rename',
  'terminal.close',
  // tasks.* / interactions.* / settings.*
  'tasks.summary',
  'tasks.list',
  'tasks.session',
  'tasks.cancel',
  'tasks.killUnownedJob',
  'tasks.removeQueued',
  'interactions.list',
  'interactions.reply',
  'interactions.dismiss',
  'interactions.wait',
  'settings.describe',
  'settings.mutate',
  // library.*
  'library.catalog',
  'library.directoryList',
  'library.directoryCreate',
  'library.workspaceCreate',
  'library.workspaceRename',
  'library.workspaceReorder',
  'library.sessionCreate',
  'library.sessionRename',
  'library.sessionPin',
  'library.sessionArchive',
  'library.sessionReorder',
  'library.sessionFork',
  // attachments.* / subagents.* / workspaceChanges.* / references.*
  'attachments.prepare',
  'attachments.preview',
  'attachments.release',
  'subagents.catalog',
  'subagents.inspect',
  'subagents.page',
  'subagents.send',
  'subagents.interrupt',
  'workspaceChanges.summary',
  'workspaceChanges.diff',
  'workspaceChanges.cancel',
  'references.list',
  // 无前缀
  'sessions.list',
  'account.signIn',
  'credentials.describe',
  'credentials.set',
  'credentials.unset',
  'configuration.transfer.export',
  'configuration.transfer.preview',
  'configuration.transfer.apply',
  'configuration.transfer.release',
  'chat.image.preview',
  'workflow.inspect',
  'userText.mask',
]

/**
 * 明确不支持的方法（协议 §4.2、§11）。
 *
 * `documents.*` 的语义是「手机上的文件」，v1 由宿主列入 `unsupported`（§11）；
 * `web.*` 在远程模式没有意义（§4.2 建议列入 `unsupported`）；`linuxVm.*` 与
 * `scheduleWake.*` 是 Android 专属能力，桌面宿主没有实现。
 */
const FACADE_UNSUPPORTED: readonly string[] = [
  'documents.*',
  'linuxVm.*',
  'scheduleWake.*',
  'web.*',
]

/** 宿主提供给其他插件/界面的远程宿主服务名。 */
const REMOTE_HOST_SERVICE = 'remoteHost'

/**
 * 一次新打开的配对窗口。
 *
 * `usbPairUrl` 是回环地址（`wss://127.0.0.1:<port>`）的同一张配对票据：手机 USB 连接
 * 方式与局域网方式用的是同一个令牌与 instanceId，只是主机名不同。终端二维码、日志与
 * 本机配对页展示的都是这一份事实。
 */
type RemotePairingTicket = PairingPageTicket

/** 一次成功启动的远程宿主。 */
interface RemoteHostHandle {
  /**
   * 关闭配对窗口、断开全部连接并停止监听。幂等。
   * @returns 全部收尾完成后兑现。
   */
  stop(): Promise<void>

  /** @returns 已配对设备（含已撤销与已过期），不含令牌摘要。 */
  devices(): readonly DeviceSummary[]

  /**
   * 撤销一台设备：先落盘删除，再关闭它的全部在线连接并推 `remote.deviceRevoked`（协议 §8.4）。
   * 撤销成功后自动打开一个新的配对窗口并写日志，配对下一台手机不需要重启宿主。
   * @param deviceId - 设备 id。
   * @returns 撤销是否生效，以及被关闭的连接数。
   */
  revokeDevice(deviceId: string): Promise<RemoteDeviceRevokeResult>

  /**
   * 永久删除一台设备记录：有效设备先走撤销路径（关闭连接并推 `remote.deviceRevoked`），
   * 再把它从设备表移除；已撤销/已过期的记录直接删除。
   * @param deviceId - 设备 id。
   * @returns 删除是否生效、删除前是否有效、被关闭的连接数。
   */
  deleteDevice(deviceId: string): Promise<RemoteDeviceDeleteResult>

  /**
   * 打开一个新的配对窗口（有效期取 `Config.pairingTtlMs`，默认 120 s），并把链接写进日志。
   * 此前未用的窗口立即失效；PC 侧界面用它重新展示配对链接，不需要重启宿主。
   * @returns 配对链接与新窗口的过期时间。
   */
  pair(): RemotePairingTicket

  /**
   * 本机配对页的数据源：当前窗口、重开窗口、设备列表、撤销与宿主身份。
   * 页面不自己判断窗口状态，宿主把内部记账投影成它需要的事实。
   * @returns 交给 `./pairing-page.ts` 的数据源。
   */
  pages(): PairingPageSource

  /**
   * 把桌面插件中继来的页面线通知交给当前连接上的 §8 通知观察者；没有 ready 连接时安全丢弃。
   * @param notifications - 已经过控制 API 形状校验的页面线通知。
   */
  relayNotifications(notifications: readonly RelayNotificationInput[]): void
}

/**
 * 业务方法转发尚未接入：门面服务缺席时，所有方法都以此失败。
 */
export class RemoteDispatchPendingError extends Error {
  /** 入站业务方法名。 */
  readonly method: string

  /** @param method - 入站业务方法名。 */
  constructor(method: string) {
    super(`门面服务不可用，无法转发远程方法「${method}」。`)
    this.name = 'RemoteDispatchPendingError'
    this.method = method
  }
}

/**
 * 门面反向请求与通知的出口，绑定在一条已鉴权的 wss 连接上。
 */
interface RemoteFacadeSink {
  /**
   * 门面发起的反向 `native.*` 请求。
   * @param method - `native.*` 方法名。
   * @param params - 请求参数对象。
   * @returns JSON-RPC `result`，可以是同步值或 Promise。
   */
  request(method: string, params: Record<string, unknown>): unknown

  /**
   * 门面发起的出站通知。
   * @param method - 通知方法名，例如 `remote.taskCompleted`。
   * @param params - 通知参数；省略时不写 `params` 成员。
   */
  notify(method: string, params?: Record<string, unknown>): void
}

/**
 * `apps/android/runtime/index.mjs` 在 `platform: desktop` 下提供的门面服务。
 *
 * 该插件是纯 JavaScript（`.mjs`），没有可导入的类型，因此消费方在这里声明自己用到的那部分表面。
 */
interface AppRuntimeFacade {
  /**
   * 执行一次门面方法。
   * @param method - 手机发来的方法名，例如 `session.send`。
   * @param params - 帧里的 `params` 对象。
   * @param owner - 这条连接的 owner。协议 §6.4 的 owner 是本地概念、不上线：门面据此把
   *   按 owner 管理的方法参数补齐，并在连接关闭时释放该 owner 的资源。省略时按无 owner 处理。
   * @returns JSON-RPC `result`，可以是同步值或 Promise；抛错由传输层转成 `-32603`。
   */
  dispatch(method: string, params: Record<string, unknown>, owner?: string): unknown

  /**
   * 把一条连接安装成门面的转发端。
   * @param sink - 反向请求与通知的出口。
   * @param owner - 这条连接的 owner；门面记住它与 sink 的对应关系，解除绑定时释放。
   */
  bind(sink: RemoteFacadeSink, owner?: string): void

  /**
   * 解除绑定：只有当前绑定的就是 `sink` 时才生效，随后释放该连接的 owner。
   * @param sink - 之前交给 {@link AppRuntimeFacade.bind} 的同一个对象。
   * @returns 清理异步进行时可 await；宿主不等待。
   */
  unbind(sink: RemoteFacadeSink): void | Promise<unknown>

  /**
   * 门面的方法清单（协议 §10.1 语法）。门面声明时优先于 {@link FACADE_METHODS}：
   * 协议要求 `methods` 由分发表生成，而不是由宿主手写一份可能与门面漂移的副本。
   */
  readonly methods?: readonly string[]

  /** 门面明确不支持的方法清单，优先级高于 `methods`。 */
  readonly unsupported?: readonly string[]
}

/**
 * 加载远程宿主：读身份、生成/复用 TLS 材料、打开设备表、开配对窗口，最后启动 wss 监听。
 * 注册即 effect：插件卸载时关闭配对窗口、断开全部连接并停止监听。
 * @param ctx - 插件上下文，需已注入 {@link inject} 中的服务。
 * @param config - 校验后的 {@link Config}。
 * @returns 监听成功且清理 effect 已注册后兑现；启动失败时拒绝，让 Loader 把这条插件标成失败。
 */
export async function apply(ctx: Context, config: Config): Promise<void> {
  if (!config.enabled) {
    writeRemoteLog({
      level: 'info',
      event: 'disabled',
      message: '远程宿主未启用，没有监听任何端口（Config.enabled = false）。',
    })
    return
  }
  // 门面是纯 JavaScript 插件提供的服务，这里按消费方用到的表面声明并读取。
  const facade = ctx.get('appRuntimeFacade') as AppRuntimeFacade | undefined
  const credentials = ctx.get('credentials') as DesktopCredentialPort | undefined
  if (credentials === undefined) {
    // 协议 §5.2 要求 native.credentials.* 由宿主拦截：凭据必须留在 PC，缺了这个服务就无法满足。
    throw new Error('远程宿主需要宿主侧凭据服务（ctx.credentials）来应答 native.credentials.*，但当前 profile 没有提供它。')
  }
  const handle = await startRemoteHost(config, facade, credentials)
  ctx.effect(() => () => handle.stop(), 'remote-host: wss /app 监听')
  // PC 侧的设备管理入口（协议 §8.4 的唯一真实调用点）。配对窗口是单次有效的，
  // 所以这里同时暴露 pair()：PC 界面可以在不重启宿主的情况下重新展示配对链接。
  ctx.provide(REMOTE_HOST_SERVICE, {
    devices: () => handle.devices(),
    revokeDevice: (deviceId: string) => handle.revokeDevice(deviceId),
    deleteDevice: (deviceId: string) => handle.deleteDevice(deviceId),
    pair: () => handle.pair(),
  })
  // 本机配对页：只绑 127.0.0.1 的增强能力。`start()` 自己把端口绑定失败降级成 warn，
  // 所以这里没有错误分支；effect 逆序释放，页面会先于 wss 监听停止。
  if (!config.pagesEnabled) {
    writeRemoteLog({
      level: 'info',
      event: 'pairing-page-disabled',
      message: '本机配对页已关闭（Config.pagesEnabled = false）：配对链接仍会写进日志。',
    })
    return
  }
  const pages = new PairingPageServer({
    port: config.pagesPort,
    source: handle.pages(),
    log: writeRemoteLog,
    onNotificationsRelay: notifications => { handle.relayNotifications(notifications) },
  })
  ctx.effect(() => () => pages.stop(), 'remote-host: 本机配对页')
  await pages.start()
}

/**
 * 组装并启动远程宿主。
 * @param config - 校验后的 {@link Config}。
 * @param facade - 运行时门面；`undefined` 表示服务不可用，连接会退回 {@link pendingDispatch}。
 * @param credentials - 宿主侧凭据服务，供 `native.credentials.*` 使用。
 * @returns 可以停止这次监听的句柄。
 */
async function startRemoteHost(
  config: Config,
  facade: AppRuntimeFacade | undefined,
  credentials: DesktopCredentialPort,
): Promise<RemoteHostHandle> {
  const stateDir = join(resolveDshHome(), 'remote-host')
  // ./tls.ts 的契约：先确保 TLS 材料（新签 CA 时会把 instanceId 绑定为 CA 指纹），再读身份；
  // 反过来的话读到的是占位 instanceId，配对链接里的指纹就会对不上。
  const tls = await ensureTlsMaterial({
    dir: stateDir,
    hosts: advertisedHosts(publicOriginNames(config.publicOrigin)),
    commonName: SERVER_CERTIFICATE_COMMON_NAME,
  })
  const identity = await Identity.load(stateDir)
  const devices = await DeviceStore.open(join(stateDir, 'devices.json'))
  // 配对窗口只留摘要：明文令牌只在 open() 与配对链接里各出现一次。
  const pairing = new PairingWindow()
  // 桌面应答者：`native.storage.root`、附件/导出目录、凭据、Web 偏好与网卡地址、
  // 后台唤醒确认都在本进程内回答，不上线（协议 §5.2）。
  const nativeProvider: RemoteNativeProvider = new DesktopNativeProvider({
    dshHome: resolveDshHome(),
    credentials,
    ipv4Addresses: orderedIpv4Addresses,
  })
  const handshake = createHandshake(identity, facade)
  // 发现应答里的配对链接与日志/二维码是同一条：窗口打开期间保留当前票据，配对成功后
  // 立刻作废，否则发现会在「窗口已被消费但未过期」这段时间里继续宣布可以配对。
  let currentPairing: RemotePairingTicket | undefined
  /**
   * 打开下一个配对窗口的入口（长期配对用）。
   *
   * 只有 `server.start()` 之后才知道实际端口，所以这个引用先留空、监听成功后再赋值；
   * 配对只可能发生在监听之后，赋值与监听在同一个 tick 里完成，因此运行时不会读到空值
   * （真读到也只会记 warn，不影响已经签发的设备）。
   */
  let reopenNextPairingWindow: (() => void) | undefined
  const basePairingSurface = createPairingSurface(tls.caPem, pairing, devices, config.deviceTtlMs)
  const pairingSurface: RemotePairingSurface = withLongTermPairingReopen(basePairingSurface, {
    longTerm: config.pairingLongTerm,
    onRedemptionConsumed: () => {
      currentPairing = undefined
    },
    reopen: () => {
      const reopen = reopenNextPairingWindow
      if (reopen === undefined) {
        throw new Error('配对窗口重开入口还没有就绪（wss 监听尚未完成）。')
      }
      reopen()
    },
    log: writeRemoteLog,
  })
  // 协议 §11：一台 PC 同时只服务一台设备。当前绑定的连接、门面出口与 §8 通知观察者成对记录。
  let binding: {
    readonly connection: RemoteConnection
    readonly sink: RemoteFacadeSink
    readonly notifications: RemoteNotifications
  } | undefined
  /**
   * 解除一条连接的门面绑定；门面随即释放这条连接的 owner 资源（流、历史租约等）。
   *
   * 清理异步进行：同步抛错与 Promise 拒绝都只记一条 `facade-unbind-failed`，既不打断
   * 连接关闭流程，也不留下未处理的 rejection。
   * @param connection - 被解除绑定的那条连接（用于日志字段）。
   * @param sink - 之前交给门面 `bind` 的同一个对象。
   * @returns 无返回值。
   */
  const unbindFacade = (connection: RemoteConnection, sink: RemoteFacadeSink): void => {
    const report = (error: unknown): void => {
      writeRemoteLog({
        level: 'error',
        event: 'facade-unbind-failed',
        message: '解除门面绑定失败，门面后续的通知可能仍指向这条已关闭的连接。',
        fields: { connectionId: connection.id, error: describeRemoteError(error) },
      })
    }
    try {
      void Promise.resolve(facade?.unbind(sink)).catch(report)
    } catch (error) {
      report(error)
    }
  }
  /** 查询会话标题与所属项目的宿主本地读（协议 §8.2 补全字段）。 */
  const lookupSession = createSessionFactsLookup(facade, writeRemoteLog)
  const desktopRelay = config.desktopRelayFile === ''
    ? undefined
    : new DesktopRelayClient({ file: config.desktopRelayFile })
  const server = new RemoteHostServer({
    port: config.port,
    host: config.host,
    tls: { certPem: tls.certPem, keyPem: tls.keyPem },
    authenticate: (token: string) => authenticateDevice(devices, token),
    nativeProvider,
    handshake,
    pairing: pairingSurface,
    onConnection: (connection: RemoteConnection) => {
      if (facade === undefined) {
        // 门面缺席：保留 pendingDispatch，让每个方法都回一个可展示的失败而不是静默丢弃。
        connection.onRequest(pendingDispatch)
        writeRemoteLog({
          level: 'warn',
          event: 'dispatch-pending',
          message: '门面服务 appRuntimeFacade 不可用，这条连接上的业务方法都会失败。',
          fields: { connectionId: connection.id, deviceId: connection.deviceId },
        })
        return
      }
      const previous = binding
      if (previous !== undefined) {
        // 先摘旧绑定再挂新绑定：旧连接关闭期间，门面的通知不能写到一个正在关闭的 socket 上。
        // 通知观察者在 unbind 之后 dispose：被替换连接的在途 `remote.*` 构造不再落帧。
        unbindFacade(previous.connection, previous.sink)
        previous.notifications.dispose()
        writeRemoteLog({
          level: 'warn',
          event: 'connection-replaced',
          message: '已有另一台设备在线，协议 v1 同时只服务一台设备，正在关闭旧连接。',
          fields: {
            connectionId: connection.id,
            deviceId: connection.deviceId,
            previousConnectionId: previous.connection.id,
            previousDeviceId: previous.connection.deviceId,
          },
        })
        void previous.connection.close(1000, 'replaced-by-new-device').catch((error: unknown) => {
          writeRemoteLog({
            level: 'error',
            event: 'connection-close-failed',
            message: '关闭被替换的旧连接失败，它可能仍然占着这台电脑的设备位。',
            fields: { connectionId: previous.connection.id, error: describeRemoteError(error) },
          })
        })
      }
      // 每条连接一个通知观察者：页面线照旧走门面 sink，`remote.*` 系统通知线追加在同一条连接上。
      const notifications = new RemoteNotifications({
        target: connection,
        log: writeRemoteLog,
        lookupSession,
      })
      const sink = createFacadeSink(connection, nativeProvider, notifications)
      // 每条连接一个独立 owner（协议 §6.4 的 owner 是本地概念、不上线）：门面用它把
      // `api.subscribe` 等按 owner 管理的资源隔离开，并在解除绑定时释放——连接关闭后
      // 这些记录与上游流不能留到下一条连接。这里的 UUID 只在宿主进程内使用。
      const owner = randomUUID()
      binding = { connection, sink, notifications }
      facade.bind(sink, owner)
      connection.onRequest((method, params) => dispatchWithSessionRelay({
        method,
        params,
        local: () => facade.dispatch(method, params, owner),
        relay: desktopRelay,
      }))
      writeRemoteLog({
        level: 'info',
        event: 'connection-ready',
        message: '已把这条连接接到门面方法表上。',
        fields: { connectionId: connection.id, deviceId: connection.deviceId, owner },
      })
    },
    onClose: (connection: RemoteConnection, outcome: RemoteCloseOutcome) => {
      // 被替换的连接晚于新连接关闭：只有绑定的仍是它时才解除，否则会摘掉新连接的绑定。
      const released = binding !== undefined && binding.connection === connection ? binding : undefined
      if (released !== undefined) {
        binding = undefined
        released.notifications.dispose()
        unbindFacade(released.connection, released.sink)
      }
      writeRemoteLog({
        level: 'info',
        event: 'connection-closed',
        message: '远程连接已关闭。',
        fields: {
          connectionId: connection.id,
          deviceId: connection.deviceId,
          code: outcome.code,
          reason: outcome.reason,
          byPeer: outcome.byPeer,
        },
      })
    },
    log: writeRemoteLog,
  })
  // UDP 局域网发现：start() 自己把「端口占用/权限不足」降级成 warn，宿主照常启动。
  let discovery: DiscoveryResponder | undefined
  try {
    const bound = await server.start()
    // `publicOrigin` 只换对外宣告的地址；监听地址与端口仍是 Config.host / Config.port。
    const origin = config.publicOrigin === ''
      ? `wss://${await originHost(config)}:${bound.port}`
      : config.publicOrigin
    /**
     * 打开一个新的配对窗口，并把可直接展示的配对链接写进日志。
     *
     * 窗口是单次有效的（协议 §2.2）：兑换成功后必须再开一个，否则「配下一台」只能重启宿主。
     * @param event - 日志事件名，区分开机、手动重开与撤销设备后的自动重开。
     * @param message - 写进日志的中文说明。
     * @param fields - 额外日志字段（不含令牌以外的敏感值）。
     * @returns 配对链接与窗口过期时间。
     */
    const openPairingWindow = (
      event: string,
      message: string,
      fields: Readonly<Record<string, unknown>> = {},
    ): RemotePairingTicket => {
      const opened = pairing.open(config.pairingTtlMs)
      const ticket: RemotePairingTicket = {
        pairUrl: pairUrl(origin, identity.instanceId, opened.token),
        // USB 连接方式：同一张叶子证书的 SAN 恒包含 127.0.0.1（tls.ts 的 MANDATORY_HOSTS），
        // 因此用户在电脑上 `adb reverse tcp:<port> tcp:<port>` 后，可以用回环地址的同一张
        // 配对票据完成配对，不需要手机与电脑同网段。令牌与 instanceId 与原链接完全相同。
        usbPairUrl: pairUrl(`wss://127.0.0.1:${bound.port}`, identity.instanceId, opened.token),
        expiresAt: opened.expiresAt,
      }
      // 当前配对票据也是发现应答与本机配对页的唯一来源：窗口未开或已消费时没有票据。
      currentPairing = ticket
      writeRemoteLog({
        level: 'info',
        event,
        message,
        fields: {
          ...fields,
          origin,
          instanceId: identity.instanceId,
          pairUrl: ticket.pairUrl,
          usbPairUrl: ticket.usbPairUrl,
          expiresAt: ticket.expiresAt,
        },
      })
      // 链接里的令牌与指纹合计 107 个字符，手输不现实；在真终端里额外画一张二维码。
      // 日志被重定向（非 TTY）时只保留上面那条结构化日志，不往日志文件里撒块字符。
      writePairingQr(ticket.pairUrl, ticket.usbPairUrl, bound.port)
      return ticket
    }
    // 长期配对：配对成功后由 `withLongTermPairingReopen` 调这里换下一张链接。事件名与
    // 撤销重开区分开，排障时能看出「窗口是配对成功自动续的」还是「撤销后重开的」。
    reopenNextPairingWindow = () => {
      openPairingWindow(
        'pairing-window-reopened-longterm',
        '配对成功，长期配对模式已自动打开下一个窗口：用下面的配对链接配对其他手机。',
        { longTerm: true },
      )
    }
    openPairingWindow(
      'listening',
      `远程宿主已就绪：${origin}/app。用下面的配对链接在手机上添加这台电脑。`,
      { deviceName: identity.displayName, listen: `${bound.host}:${bound.port}` },
    )
    // 长期配对窗口等于「长期可配对入口」：窗口开着期间，任何能连到端口的人都可以尝试
    // 兑换。默认 120 s 不受影响；这里把风险写进启动日志，避免用户在公网部署里无意打开。
    if (config.pairingLongTerm) {
      writeRemoteLog({
        level: 'warn',
        event: 'pairing-longterm-enabled',
        message: '长期配对已开启：配对窗口按配置有效期保持可配对，且每配对成功一台设备后自动换一张新链接。'
          + '长期窗口等于长期可配对入口，只适合个人可信网络；请配合撤销设备与不用时关闭宿主。',
        fields: { pairingTtlMs: config.pairingTtlMs },
      })
    } else if (config.pairingTtlMs > LEGACY_PAIRING_TTL_CAP_MS) {
      writeRemoteLog({
        level: 'warn',
        event: 'pairing-window-long',
        message: '配对窗口有效期超过 15 分钟：窗口开着期间任何能连到配对端口的人都可以尝试配对。'
          + '只适合个人可信网络；配完请撤销不再使用的设备或关闭宿主。',
        fields: { pairingTtlMs: config.pairingTtlMs },
      })
    }
    // 发现应答只回答「这台电脑是谁、当前配对链接是什么」，所以起点必须在配对窗口打开之后：
    // 手机发现到宿主时拿到的一定是此刻可用的链接。
    const discoverySnapshot = (): DiscoverySnapshot => {
      const snapshot: DiscoverySnapshot = {
        name: identity.displayName,
        origin,
        instanceId: identity.instanceId,
      }
      const ticket = currentPairing
      // 窗口过期后不再宣布可以配对：票据有没有被消费由配对接口自己兜底（403）。
      if (ticket !== undefined && ticket.expiresAt > Date.now()) {
        return { ...snapshot, pairing: { pairUrl: ticket.pairUrl, expiresAt: ticket.expiresAt } }
      }
      return snapshot
    }
    if (config.discoveryEnabled) {
      discovery = new DiscoveryResponder({
        port: config.discoveryPort,
        log: writeRemoteLog,
        snapshot: discoverySnapshot,
      })
      await discovery.start()
    } else {
      writeRemoteLog({
        level: 'info',
        event: 'discovery-disabled',
        message: '局域网发现已关闭（Config.discoveryEnabled = false）：手机只能扫码或粘贴配对链接。',
      })
    }
    /** 打开配对窗口：`remoteHost.pair()` 与本机配对页的「重新打开」按钮共用。 */
    const reopenPairing = (): RemotePairingTicket => openPairingWindow(
      'pairing-window-opened',
      '已打开新的配对窗口：用下面的配对链接在手机上添加这台电脑。',
    )
    /** 撤销设备：`remoteHost.revokeDevice()` 与本机配对页的「撤销」按钮共用。 */
    const revokeDevice = async (deviceId: string): Promise<RemoteDeviceRevokeResult> => {
      const result = await server.revokeDevice(devices, deviceId, 'user-revoked')
      // 撤销之后旧配对链接已经消费或过期：自动重开一个，省掉「重启宿主才能配下一台」的步骤。
      if (result.revoked) {
        openPairingWindow(
          'pairing-window-reopened',
          '设备已撤销，宿主自动打开了新的配对窗口：用下面的配对链接配对新手机，无需重启宿主。',
          { revokedDeviceId: deviceId },
        )
      }
      return result
    }
    /** 永久删除设备：有效设备先按撤销路径断连并通知，再移除记录。 */
    const deleteDevice = async (deviceId: string): Promise<RemoteDeviceDeleteResult> => {
      const record = devices.list().find(candidate => candidate.id === deviceId)
      if (record === undefined) return { deleted: false, wasActive: false, closedConnections: 0 }
      const wasActive = record.revokedAt === undefined && record.expiresAt > Date.now()
      let closedConnections = 0
      if (wasActive) {
        const revoked = await server.revokeDevice(devices, deviceId, 'user-revoked')
        closedConnections = revoked.closed
      }
      const deleted = await devices.delete(deviceId)
      if (deleted) {
        writeRemoteLog({
          level: 'info',
          event: 'device-deleted',
          message: '已永久删除一台设备记录（有效设备已先撤销并断开连接）。',
          fields: { deviceId, wasActive, closedConnections },
        })
      }
      return { deleted, wasActive, closedConnections }
    }
    /**
     * 本机配对页看到的「当前窗口」：过期或被消费的窗口如实返回 undefined，
     * 页面据此显示「已过期/已使用」而不是继续展示一张扫了也会失败的二维码。
     * @returns 仍可用的窗口票据；没有时为 undefined。
     */
    const currentPairingForPage = (): RemotePairingTicket | undefined => {
      const ticket = currentPairing
      if (ticket === undefined || ticket.expiresAt <= Date.now()) return undefined
      return ticket
    }
    return {
      stop: async () => {
        // 先停通知观察者：连接关闭过程中门面可能还在收尾，不再追加 `remote.*` 帧。
        binding?.notifications.dispose()
        if (discovery !== undefined) await discovery.stop()
        pairing.close()
        // 停止后页面数据源不应再交出一张仍含令牌的票据。
        currentPairing = undefined
        await server.stop()
      },
      devices: () => devices.list(),
      revokeDevice,
      deleteDevice,
      pair: reopenPairing,
      relayNotifications: notifications => {
        const current = binding
        if (current === undefined) return
        for (const notification of notifications) current.notifications.observe(notification.method, notification.params)
      },
      pages: () => ({
        currentPairing: currentPairingForPage,
        pair: reopenPairing,
        devices: () => devices.list(),
        revokeDevice,
        deleteDevice,
        host: () => ({
          name: identity.displayName,
          instanceId: identity.instanceId,
          origin,
          port: bound.port,
          discovery: { enabled: config.discoveryEnabled, port: config.discoveryPort },
          // 页面数据源只在 server.start() 成功后构造，所以这里恒为 true；字段单独给
          // 本机控制面客户端一个明确的监听事实。
          listening: true,
        }),
      }),
    }
  } catch (error) {
    if (discovery !== undefined) await discovery.stop()
    pairing.close()
    await server.stop().catch((stopError: unknown) => {
      writeRemoteLog({
        level: 'error',
        event: 'stop-failed',
        message: '启动失败后关闭监听也失败，端口可能仍被占用。',
        fields: { error: describeRemoteError(stopError) },
      })
    })
    throw error
  }
}

/**
 * 握手响应里属于宿主的那一半（协议 §3.2）。
 *
 * `methods` / `unsupported` 优先取门面自己声明的清单；门面没有声明时才用
 * {@link FACADE_METHODS} 兜底，并记一条 warn，方便发现门面与表漂移。
 * @param identity - 宿主身份（显示名）。
 * @param facade - 运行时门面；`undefined` 时只给出宿主信息与能力。
 * @returns 交给 {@link RemoteHostServer} 的握手材料。
 */
function createHandshake(identity: Identity, facade: AppRuntimeFacade | undefined): RemoteHandshake {
  const declaredMethods = facade?.methods
  const declaredUnsupported = facade?.unsupported
  const hasDeclaredTable = Array.isArray(declaredMethods) && declaredMethods.length > 0
  if (!hasDeclaredTable) {
    writeRemoteLog({
      level: 'warn',
      event: 'methods-fallback',
      message: '门面没有声明 methods，握手清单退回宿主维护的协议 §4.2 方法表；两者可能漂移。',
      fields: { methods: FACADE_METHODS.length },
    })
  }
  return {
    hostName: identity.displayName,
    hostHome: resolveDshHome(),
    methods: hasDeclaredTable ? declaredMethods : FACADE_METHODS,
    unsupported: Array.isArray(declaredUnsupported) ? declaredUnsupported : FACADE_UNSUPPORTED,
    capabilities: HOST_CAPABILITIES,
  }
}

/**
 * 配对 HTTP 面的宿主实现：`GET /ca.cer` 直接回 CA 证书 DER，`POST /pair` 兑换一次性令牌
 * 并签发设备令牌（协议 §2）。
 *
 * 顺序固定为「先校验请求体 → 再消耗配对窗口 → 最后写设备表」：请求体不合法时不消耗窗口，
 * 窗口兑换失败时不写设备表。失败原因到 HTTP 状态码的映射与 App 的
 * `remote_pairing.dart` 一致：401 令牌无效、403 窗口已关闭或过期、429 尝试过于频繁。
 *
 * 导出是为了让冒烟脚本验证的就是宿主真正在用的这一份实现，而不是脚本里另写一遍。
 * @param caPem - 配对要固定的 CA 证书 PEM（来自 `./tls.ts`）。
 * @param pairing - 一次性配对窗口。
 * @param devices - 设备表；成功配对时在这里签发设备令牌。
 * @param deviceTtlMs - 设备令牌有效期（毫秒）。
 * @returns 交给 {@link RemoteHostServer} 的配对 HTTP 面。
 */
export function createPairingSurface(
  caPem: string,
  pairing: PairingWindow,
  devices: DeviceStore,
  deviceTtlMs: number,
): RemotePairingSurface {
  return {
    // App 用响应体 DER 的 SHA-256 核对 instanceId，所以这里必须是证书 DER，不是 PEM 文本。
    caCertificateDer: new X509Certificate(caPem).raw,
    redeem: async (request: RemotePairRequest): Promise<RemotePairOutcome> => {
      const redemption = pairing.redeem(request.token, request.peer)
      if (!redemption.ok) {
        switch (redemption.reason) {
          case 'invalid-token':
            return {
              ok: false,
              status: 401,
              message: '配对令牌无效或已过期。请在电脑上重新打开配对二维码，再扫描一次。',
            }
          case 'window-expired':
          case 'window-closed':
            return {
              ok: false,
              status: 403,
              message: '电脑上的配对窗口已经关闭或过期。请在电脑上重新打开配对二维码。',
            }
          case 'rate-limited':
            return {
              ok: false,
              status: 429,
              message: '配对尝试过于频繁。请在电脑上重新打开配对二维码，稍等一会儿再扫描。',
            }
          default: {
            // 配对结论是封闭联合；新增原因必须同时决定 HTTP 状态码。
            const unexpected: never = redemption.reason
            throw new Error(`配对窗口返回了未知的失败原因：${String(unexpected)}`)
          }
        }
      }
      let issued: Awaited<ReturnType<DeviceStore['add']>>
      try {
        issued = await devices.add({ label: request.deviceLabel, ttlMs: deviceTtlMs })
      } catch (error) {
        // 窗口已经消耗掉：这里失败不重置窗口，避免用一次失败的签发反复试探设备表。
        return {
          ok: false,
          status: 500,
          message: `电脑没有签发设备凭证：${describeRemoteError(error)}。请重新打开配对二维码后再试。`,
        }
      }
      writeRemoteLog({
        level: 'info',
        event: 'device-issued',
        message: '配对成功，已签发设备令牌（令牌只出现在响应里）。',
        fields: {
          deviceId: issued.id,
          deviceLabel: request.deviceLabel,
          appVersion: request.appVersion,
          expiresAt: issued.expiresAt,
        },
      })
      return { ok: true, deviceId: issued.id, deviceToken: issued.token, expiresAt: issued.expiresAt }
    },
  }
}

/**
 * {@link withLongTermPairingReopen} 的选项。
 */
export interface LongTermPairingReopenOptions {
  /** 是否为长期配对模式（`Config.pairingLongTerm`）。 */
  readonly longTerm: boolean

  /**
   * 兑换成功后、打开下一个窗口前的回调。
   *
   * 宿主用它作废 {@link PairingWindow} 已被消费的窗口票据（`currentPairing`）；它总是先于
   * {@link reopen} 执行，保证新票据不会被旧票据覆盖。
   */
  readonly onRedemptionConsumed: () => void

  /** 打开下一个配对窗口（与 `remoteHost.pair()` 同一条路径，含日志与终端二维码）。 */
  readonly reopen: () => void

  /** 打开失败时的日志出口。 */
  readonly log: RemoteLogger
}

/**
 * 给配对面加「配对成功后自动开下一个窗口」的长期配对行为。
 *
 * 语义：
 * - 兑换失败（令牌无效/窗口过期/限速/签发失败）不改变窗口，也不重开；
 * - 兑换成功时先调 {@link LongTermPairingReopenOptions.onRedemptionConsumed}，长期模式下再调
 *   {@link LongTermPairingReopenOptions.reopen}，让本机控制面在 App 收到设备令牌时已经能读到
 *   下一张配对链接；
 * - 重开失败只记一条 warn 并保留成功的配对结果：设备已经签发，不能因为「下一张链接没开出来」
 *   让这次配对失败（本机控制面可以再手动重开）。
 *
 * 抽成纯组合函数是为了让长期配对能脱离 TLS/设备表被自检覆盖；宿主装配与自检用的是同一份实现。
 * @param surface - 底层配对面（`createPairingSurface` 的结果）。
 * @param options - 长期模式开关、票据清理、重开动作与日志出口。
 * @returns 只在兑换成功结果上追加长期配对语义的配对面。
 */
export function withLongTermPairingReopen(
  surface: RemotePairingSurface,
  options: LongTermPairingReopenOptions,
): RemotePairingSurface {
  return {
    caCertificateDer: surface.caCertificateDer,
    redeem: async (request: RemotePairRequest): Promise<RemotePairOutcome> => {
      const outcome = await surface.redeem(request)
      if (!outcome.ok) return outcome
      options.onRedemptionConsumed()
      if (!options.longTerm) return outcome
      try {
        options.reopen()
      } catch (error) {
        options.log({
          level: 'warn',
          event: 'pairing-longterm-reopen-failed',
          message: '长期配对：设备已配对，但自动打开下一个配对窗口失败；可在本机控制面手动重开。',
          fields: { error: describeRemoteError(error) },
        })
      }
      return outcome
    },
  }
}

/**
 * 用设备表校验升级请求里的令牌。摘要比对由设备表负责（协议 §2.2 第 4 步要求 `timingSafeEqual`）。
 * @param devices - 已打开的设备表。
 * @param token - 升级头里的 43 字符 base64url 令牌。
 * @returns 有效设备返回其 id；已撤销返回 `auth-revoked`；未知或已过期返回 `auth-failed`。
 */
async function authenticateDevice(
  devices: DeviceStore,
  token: string,
): Promise<RemoteAuthOutcome> {
  return authenticationOutcome(await devices.authorize(token))
}

/**
 * 把设备表的鉴权结论映射成升级后的关闭码语义（协议 §2.2 第 4、5 步）。
 *
 * 单独导出是为了让冒烟与宿主装配共用同一份映射，避免「已撤销返回 4000」这类偏差只能在
 * 真机上发现。
 * @param authorization - `DeviceStore.authorize` 的结论。
 * @returns 认证结果；`revoked` 映射成 `auth-revoked`（关闭 4001），其余失败映射成 `auth-failed`（4000）。
 */
export function authenticationOutcome(authorization: DeviceAuthorization): RemoteAuthOutcome {
  switch (authorization.status) {
    case 'active':
      return { ok: true, deviceId: authorization.deviceId }
    case 'revoked':
      return { ok: false, code: 'auth-revoked' }
    case 'expired':
    case 'unknown':
      return { ok: false, code: 'auth-failed' }
    default: {
      // 设备表的鉴权结论是封闭联合；新增状态必须同时决定关闭码。
      const unexpected: never = authorization
      throw new Error(`设备表返回了未知的鉴权结论：${JSON.stringify(unexpected)}`)
    }
  }
}

/**
 * 门面服务缺席时的兜底处理器：所有方法都回一个明确的失败，让手机看到可展示的错误，
 * 而不是静默丢弃或等到超时。
 * @param method - 入站业务方法名。
 * @param params - 帧里的 `params` 对象。
 * @returns 永远不返回；总是抛 {@link RemoteDispatchPendingError}。
 */
function pendingDispatch(method: string, params: Record<string, unknown>): Promise<unknown> {
  writeRemoteLog({
    level: 'error',
    event: 'dispatch-unavailable',
    message: `门面服务不可用，远程方法「${method}」无法转发。`,
    fields: { method, paramNames: Object.keys(params) },
  })
  throw new RemoteDispatchPendingError(method)
}

/**
 * 为一条连接构造门面出口：宿主本地能应答的 `native.*` 就地应答，其余转发给手机。
 *
 * 页面线通知原样写给连接；写成功后再交给 {@link RemoteNotifications} 观察，按协议 §8 追加
 * `remote.*` 系统通知线。观察发生在页面线之后，所以页面线的时机、内容与抛错语义都不变。
 * @param connection - 已鉴权的远程连接。
 * @param nativeProvider - 宿主本地 `native.*` 应答者。
 * @param notifications - 这条连接上的 §8 推送通知观察者。
 * @returns 交给 `appRuntimeFacade.bind` 的 sink。
 */
function createFacadeSink(
  connection: RemoteConnection,
  nativeProvider: RemoteNativeProvider,
  notifications: RemoteNotifications,
): RemoteFacadeSink {
  return {
    // 本地拦截必须优先于转发（协议附录 B 约束 3）：否则手机的 -32601 会盖掉 PC 本来能满足的请求。
    request: (method: string, params: Record<string, unknown>) => nativeProvider.handles(method)
      ? nativeProvider.request(method, params)
      : connection.request(method, params),
    notify: (method: string, params?: Record<string, unknown>) => {
      connection.notify(method, params)
      notifications.observe(method, params)
    },
  }
}

/**
 * 用门面本地读补全会话标题与所属项目（协议 §8.2 的 `title` / `workspaceId`）。
 *
 * 数据源是门面的 `library.catalog`（`apps/android/runtime/library.mjs`）：会话行带 `title`
 * 投影，workspace 行的 `sessionIds` 给出会话归属。读失败只记一条 warn 并返回 `undefined`，
 * 由通知层用 sessionId 兜底标题——系统通知不是关键路径，不能反过来影响页面线。
 * @param facade - 运行时门面；`undefined` 时永远查不到（这种情况下也没有绑定的连接）。
 * @param log - 宿主日志出口。
 * @returns 会话信息查询函数。
 */
function createSessionFactsLookup(
  facade: AppRuntimeFacade | undefined,
  log: RemoteLogger,
): RemoteSessionLookup {
  if (facade === undefined) return () => undefined
  let failureReported = false
  return async (sessionId: string): Promise<RemoteSessionFacts | undefined> => {
    try {
      return sessionFactsFromCatalog(await facade.dispatch('library.catalog', {}), sessionId)
    } catch (error) {
      if (!failureReported) {
        failureReported = true
        log({
          level: 'warn',
          event: 'remote-notify-lookup-failed',
          message: '读取会话标题与所属项目失败，remote.taskCompleted 的标题用 sessionId 兜底。',
          fields: { sessionId, error: describeRemoteError(error) },
        })
      }
      return undefined
    }
  }
}

/**
 * 本机对外可达的主机名清单，用作自签证书的 SAN。
 * @param extra - 额外需要覆盖的主机名或 IP 字面量（对外宣告的 origin 的主机）。
 * @returns 主机名、回环名、额外主机与本机非内部 IPv4 地址。
 */
function advertisedHosts(extra: readonly string[] = []): string[] {
  const hosts = new Set<string>(['localhost', '127.0.0.1', hostname(), ...extra])
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === 'IPv4' && !address.internal) hosts.add(address.address)
    }
  }
  return [...hosts]
}

/**
 * 系统默认路由会使用的本机 IPv4 地址。
 *
 * 本机常有多块网卡（VPN、Hyper-V、WSL、Docker），按网卡枚举顺序取第一个地址很容易
 * 拿到手机根本连不上的虚拟网卡。这里让内核给出路由决策：UDP `connect` 只解析路由、
 * 不发送数据包，因此没有网络也能立即返回。
 * @returns 默认路由的源地址；没有可用路由时返回 undefined。
 */
async function defaultRouteIpv4(): Promise<string | undefined> {
  const socket = createSocket('udp4')
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once('error', reject)
      // 目的地址只用于选路，不会真的发出包；连接失败时退回枚举结果。
      socket.connect(80, '203.0.113.1', () => {
        resolve()
      })
    })
    const { address } = socket.address()
    return typeof address === 'string' ? undefined : address
  } catch {
    return undefined
  } finally {
    socket.close()
  }
}

/**
 * 本机可用的 IPv4 地址，默认路由地址排在最前。
 *
 * 门面把第一项当作 `native.web` 的 LAN 监听地址（`apps/android/runtime/web-access.mjs`）；
 * 与配对链接的 origin 一样，默认路由地址最可能是手机连得上的那一个。
 * @returns 非内部（非回环）的 IPv4 地址；没有可用地址时为空数组。
 */
async function orderedIpv4Addresses(): Promise<readonly string[]> {
  const addresses: string[] = []
  const append = (address: string): void => {
    if (!addresses.includes(address)) addresses.push(address)
  }
  const routed = await defaultRouteIpv4()
  if (routed !== undefined) append(routed)
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) append(entry.address)
    }
  }
  return addresses
}

/**
 * 配对链接里用的主机：显式配置优先，否则取默认路由地址，再退回主机名。
 * @param config - 插件配置，`publicHost` 非空时直接使用。
 * @returns 主机名或点分十进制地址。
 */
async function originHost(config: Config): Promise<string> {
  if (config.publicHost.trim() !== '') return config.publicHost.trim()
  const routed = await defaultRouteIpv4()
  if (routed !== undefined) return routed
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === 'IPv4' && !address.internal) return address.address
    }
  }
  return hostname()
}

/**
 * 归一化 `Config.publicOrigin`：把部署者填写的对外地址收敛成配对链接里的 origin。
 *
 * 只接受 `wss://host[:port]`（协议 §1.1 的配对链接形态）。`https://` 也被拒绝：
 * App 的配对解析虽然容忍它，但宿主宣布的端点必须是手机直接拨号的 wss 地址，
 * 而配对链接的生成函数（`./pairing.ts`）只接受 wss。路径、查询串、片段与账号
 * 信息同样拒绝——App 的配对解析不接受路径前缀，这些都会生成手机连不上的链接。
 * @param value - 配置里的原始值；空字符串表示不覆盖自动生成的 origin。
 * @returns 归一化后的 `wss://host[:port]`（主机名小写；显式写的 `:443` 会保留，
 *   因为 WHATWG URL 会把它当默认端口省略掉）；未配置时为空串。
 * @throws 不是绝对 wss origin、或带路径/查询串/片段/账号信息时抛出，让配置在加载期失败。
 */
export function normalizePublicOrigin(value: string): string {
  const trimmed = value.trim()
  if (trimmed === '') return ''
  if (/[\u0000-\u0020\u007f]/u.test(trimmed)) {
    throw new Error('publicOrigin 不能包含空白或控制字符：填写形如 wss://host:port 的绝对地址。')
  }
  let url: URL
  try {
    url = new URL(trimmed)
  } catch (error) {
    throw new Error(`publicOrigin 不是合法 URL：${trimmed}。填写形如 wss://host:port 的绝对地址。`, { cause: error })
  }
  if (url.protocol !== 'wss:') {
    throw new Error(`publicOrigin 必须是 wss:// 地址（收到 ${url.protocol}）；协议 v1 只提供加密的 wss 端点。`)
  }
  if (url.username !== '' || url.password !== '') {
    throw new Error('publicOrigin 不能包含用户名或密码。')
  }
  if (url.search !== '' || url.hash !== '') {
    throw new Error('publicOrigin 不能带查询串或片段：配对链接自己会追加 #instance=…&token=…。')
  }
  if (url.hostname === '') {
    throw new Error('publicOrigin 缺少主机名：填写形如 wss://host:port 的绝对地址。')
  }
  if (url.pathname !== '' && url.pathname !== '/') {
    throw new Error('publicOrigin 不能带路径前缀：v1 只接受直连的 wss://<host>:<port>，反向代理请用 TCP 直通。')
  }
  // WHATWG URL 会把 wss 的默认端口 443 归一化掉（`wss://h:443` → `wss://h`），而配对链接
  // 原样使用该 origin，App 对缺失端口会按 4777 补全，导致连到错误端口。部署者显式写了
  // :443 时保留端口；未写端口的地址仍按默认端口处理（App 侧见 remote_pairing.dart）。
  if (url.port === '' && /:443\/?$/u.test(trimmed)) return `wss://${url.hostname}:443`
  return url.origin
}

/**
 * 对外宣告的 origin 里需要写进服务器证书 SAN 的主机名。
 *
 * 域名型部署（TCP 直通代理保留 SNI）要求手机看到的名字出现在 SAN 里，否则 App
 * 固定 CA 的校验仍会因主机名不匹配失败。配置错误已经在 {@link normalizePublicOrigin}
 * 拒绝，这里只做形态转换。
 * @param origin - 已归一化的 `Config.publicOrigin`；空字符串表示未配置。
 * @returns 单个 IP 字面量（IPv6 去掉方括号）或主机名；未配置时为空数组。
 */
function publicOriginNames(origin: string): readonly string[] {
  if (origin === '') return []
  const hostname = new URL(origin).hostname
  return [hostname.startsWith('[') && hostname.endsWith(']') ? hostname.slice(1, -1) : hostname]
}

// ───────────────────────────── 终端配对二维码 ─────────────────────────────
//
// 配对链接里有 107 个必须原样保留的字符（instance 64 + token 43），手机配对页又只有
// 「粘贴链接」一个入口。stderr 直接连终端时把链接画成二维码，用户扫码后复制文本再粘贴；
// 编码与渲染在 `./pairing-qr.ts`，本文件只做「是否 TTY → 打印」这一步接线。

/**
 * 在真终端里打印配对二维码与明文链接；stderr 被重定向时什么都不写。
 *
 * 二维码只是过渡手段：扫码工具把链接当文本复制，再由用户粘进 App。渲染失败只记
 * 一条 warn，配对链接本身照常可用（它在上面那条结构化日志里）。
 *
 * 导出是为了让 `apps/remote-host/scripts/qr-selfcheck.ts` 覆盖「终端 vs 重定向」
 * 这条分支，验证的就是宿主真正在用的实现。
 * @param pairUrl - 这次配对窗口的完整链接。
 * @param usbPairUrl - 回环地址（`wss://127.0.0.1:<port>`）的同一张配对票据，供 USB 连接方式使用。
 * @param port - 监听端口，用于打印 `adb reverse` 命令；缺省时不打印 USB 段落。
 */
export function writePairingQr(pairUrl: string, usbPairUrl?: string, port?: number): void {
  if (!process.stderr.isTTY) return
  try {
    const block = renderTerminalQr(encodeQrMatrix(pairUrl))
    process.stderr.write(
      '[remote-host] 用手机扫码得到配对链接（链接也可以直接从下面这一行整段复制）：\n'
      + `${block}\n`
      + `${pairUrl}\n`,
    )
    if (usbPairUrl !== undefined && port !== undefined) {
      process.stderr.write(
        '\n[remote-host] USB 连接（手机与电脑不在同一网段时）：在电脑上执行\n'
        + `  adb reverse tcp:${port} tcp:${port}\n`
        + '然后在 App 的配对页粘贴这一行（回环地址的同一张配对票据）：\n'
        + `  ${usbPairUrl}\n`,
      )
    }
  } catch (error) {
    writeRemoteLog({
      level: 'warn',
      event: 'pairing-qr-failed',
      message: '终端配对二维码没有画出来，配对链接照常可用。',
      fields: { error: describeRemoteError(error) },
    })
  }
}
