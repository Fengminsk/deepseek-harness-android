import Schema from '@deepseek-ai/schemastery'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { establishAttachmentHome } from '@deepseek-ai/dsh-attachment-local'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { AndroidCredentials } from './credentials.mjs'
import { registerAndroidShell } from './tool-android-shell.mjs'
import { registerModelFileReadGuard } from './model-file-read-guard.mjs'
import { registerAndroidFilesTool } from './tool-android-files.mjs'
import { registerAndroidAttachmentsTool } from './tool-android-attachments.mjs'
import { NativeIsolatedToolCallbacks } from './native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from './isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from './native-isolated-execution-bridge.mjs'
import { createAppOwnedPtcOwner } from './model-ptc-reviewed-owner.mjs'
import { modelPtcCapability, registerAndroidPtcTool } from './tool-model-ptc.mjs'
import { NativeWorkflowGuestCallbacks } from './native-workflow-guest-callbacks.mjs'
import { createNativeWorkflowPrivateOwner } from './native-workflow-private-owner.mjs'
import { modelWorkflowCapability, registerAndroidWorkflowTool } from './tool-native-workflow.mjs'
import { NativeLinuxCommands } from './native-linux-commands.mjs'
import { registerIsolatedLinuxTool } from './tool-isolated-linux.mjs'
import { NativeLinuxVm } from './native-linux-vm.mjs'
import { createNativeLinuxNetworkBridge } from './native-linux-network.mjs'
import { createLinuxNetworkAdmission } from './linux-network-admission.mjs'
import { registerLinuxVmTool, registerLinuxImportTool, registerLinuxExportTool, registerLinuxInspectTool } from './tool-linux-vm.mjs'
import AndroidShell from './android-shell.mjs'
import { WebAccess } from './web-access.mjs'
import { AppSessions } from './sessions.mjs'
import { AppSessionHistory } from './session-history.mjs'
import { AppLiveState, presentSessionEvent } from './live-state.mjs'
import { AppInteractions } from './interactions.mjs'
import { InteractionReceipts } from './interaction-receipts.mjs'
import { AppStreams } from './streams.mjs'
import { AppExports } from './exports.mjs'
import { AppAttachmentFiles } from './attachment-files.mjs'
import AndroidAccountCallback from './account-callback.mjs'
import { AppAttachments } from './attachments.mjs'
import { DesktopAppAttachments } from './attachments-desktop.mjs'
import { createRuntimeTransport } from './transport.mjs'
import { AppDocumentSearch } from './document-search.mjs'
import { AppDocumentReads } from './document-reads.mjs'
import { AppDocumentPreview, PRIVATE_WORKSPACE_SCOPE } from './document-preview.mjs'
import { AppChatImages } from './chat-images.mjs'
import { AppReferenceDiscovery } from './reference-discovery.mjs'
import { AppWorkspaceChanges } from './workspace-changes.mjs'
import { maskUserText } from './user-text-mask.mjs'
import { AppTasks } from './tasks.mjs'
import { AppTaskCompletion } from './task-completion.mjs'
import { NativeScheduleWakeup } from './native-schedule-wakeup.mjs'
import { AppPackageOperations } from './package-operations.mjs'
import { AppConfigurationTransfers } from './configuration-transfer.mjs'
import { AppSubagents } from './subagents.mjs'
import { AppLibrary } from './library.mjs'
import { AppWorkspaceFiles } from './workspace-files.mjs'
import { AppTerminals } from './terminals.mjs'
import { DesktopAppTerminals } from './terminal-desktop.mjs'
import { describeAndroidSettings } from './settings-presentation.mjs'

export const name = 'android-runtime'
export const inject = ['agents', 'sessions', 'workingDirectory', 'settings', 'tools', 'appReady', 'sessionPersistence']
export const Config = Schema.object({
  // 同一套门面既跑在 App 里，也跑在远程宿主（PC）上；desktop 只关闭 Android 专属注册。
  platform: Schema.union(['android', 'desktop']).default('android'),
  shellTimeoutMs: Schema.natural().min(1).max(3600000).default(60000).volatile(),
  shellOutputLimit: Schema.natural().min(1024).max(1048576).default(65536).volatile(),
  appStreamMaxSubscriptions: Schema.natural().min(1).max(128).default(32).volatile(),
  appStreamMaxFrameBytes: Schema.natural().min(4096).max(16777216).default(16777216).volatile(),
  streamPublishMs: Schema.natural().min(16).max(250).default(50).volatile(),
  scheduleWakeupRequestTimeoutMs: Schema.natural().min(100).max(60000).default(15000).volatile(),
  scheduleWakeupCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  documentReadMaxDurationMs: Schema.natural().min(100).max(300000).default(30000).volatile(),
  documentReadMaxRequests: Schema.natural().min(1).max(4).default(2).volatile(),
  documentSearchFileBytes: Schema.natural().min(1024).max(67108864).default(8388608).volatile(),
  documentSearchTotalBytes: Schema.natural().min(1024).max(268435456).default(67108864).volatile(),
  documentSearchMaxEntries: Schema.natural().min(1).max(10000).default(2000).volatile(),
  documentSearchMaxFiles: Schema.natural().min(1).max(10000).default(1000).volatile(),
  documentSearchMaxDepth: Schema.natural().min(1).max(64).default(32).volatile(),
  documentSearchMaxMatches: Schema.natural().min(1).max(1000).default(200).volatile(),
  documentSearchPreviewChars: Schema.natural().min(512).max(2000).default(600).volatile(),
  documentSearchMaxDurationMs: Schema.natural().min(100).max(300000).default(30000).volatile(),
  documentSearchMaxRequests: Schema.natural().min(1).max(4).default(4).volatile(),
  documentPreviewMaxRequests: Schema.natural().min(1).max(32).default(8).volatile(),
  documentPreviewMaxOwnerRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  documentPreviewMaxLeaseBytes: Schema.natural().min(1024).max(268435456).default(67108864).volatile(),
  documentPreviewMaxLeases: Schema.natural().min(1).max(128).default(32).volatile(),
  documentPreviewLeaseTimeoutMs: Schema.natural().min(1000).max(600000).default(120000).volatile(),
  documentPreviewRequestTimeoutMs: Schema.natural().min(100).max(300000).default(90000).volatile(),
  documentPreviewCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  chatImagePreviewMaxBytes: Schema.natural().min(1024).max(8388608).default(8388608).volatile(),
  chatImagePreviewMaxRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  chatImagePreviewTimeoutMs: Schema.natural().min(100).max(300000).default(30000).volatile(),
  chatImagePreviewCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  referenceMaxRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  referenceRequestTimeoutMs: Schema.natural().min(100).max(300000).default(15000).volatile(),
  referenceCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  workspaceChangesMaxRequests: Schema.natural().min(1).max(32).default(8).volatile(),
  workspaceChangesMaxOwnerRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  workspaceChangesRequestTimeoutMs: Schema.natural().min(100).max(300000).default(90000).volatile(),
  workspaceChangesCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  workspaceReadPageBytes: Schema.natural().min(1024).max(1048576).default(65536).volatile(),
  workspacePreviewMaxFileBytes: Schema.natural().min(1024).max(104857600).default(33554432).volatile(),
  workspacePreviewWindowBytes: Schema.natural().min(1024).max(2097152).default(2097152).volatile(),
  workspacePreviewOfficeInputBytes: Schema.natural().min(1024).max(104857600).default(52428800).volatile(),
  workspaceDirectoryMaxEntries: Schema.natural().min(1).max(10000).default(5000).volatile(),
  workspaceDirectoryPageSize: Schema.natural().min(1).max(500).default(100).volatile(),
  attachmentFileMaxBytes: Schema.natural().min(1024).max(2147483648).default(268435456).volatile(),
  attachmentFileReadPageBytes: Schema.natural().min(1024).max(1048576).default(65536).volatile(),
  attachmentFileMaxRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  workspaceFilesCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  libraryCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
})

function requiredString(value, label) {
  if (typeof value !== 'string' || value.length === 0) throw new TypeError(`${label} must be a non-empty string`)
  return value
}

// JSON-RPC line transport otherwise collapses thrown domain errors into -32603.
// Preserve the original Gateway result vocabulary for native conflict handling.
function remoteFailure(error) {
  return { _pocket_error: {
    code: typeof error?.code === 'string' ? error.code : error instanceof TypeError ? 'gateway/bad-request' : 'gateway/internal',
    message: String(error?.message ?? error),
    ...(error?.details === undefined ? {} : { details: error.details }),
  } }
}

/**
 * 桌面宿主（`platform: desktop`）的门面传输：没有自己的入站字节流，反向请求与出站通知
 * 都要等一条 wss 连接建立后，由远端宿主通过 bind(sink) 挂上来。
 *
 * 方法名与 JsonRpcLineTransport 同形，入站帧不经过这里：宿主拿到手机的请求后直接调用
 * `appRuntimeFacade.dispatch`。返回值与 createRuntimeTransport() 一致，装配处只认
 * `{ transport, close }`。
 *
 * 设备接入与门面初始化的先后顺序（只在桌面分支成立）：
 * 门面的初始化由 `appReady` 在进程启动时触发，它的第一步就是反向请求
 * `native.storage.root`；而远程模式下第一条设备可能几分钟后才连上。因此这里
 * 1. 把「设备接入前发出的反向请求」挂起等待第一次 bind，而不是立刻失败——否则初始化
 *    永远不完成，手机上什么状态都收不到；
 * 2. 记住最后一条阶段状态，并在 bind 时补发一条 `runtime.status`（协议 §3.4 的就绪判据
 *    是 `runtime.status.params.phase == "ready"`），因为设备接入之前产生的阶段通知没有
 *    sink 可写；
 * 3. 把门面的初始化完成信号 `runtime.ready` 翻译成 `runtime.status { phase: "ready" }`
 *    一起发出去，两端都保留原有语义。
 *
 * Android 走 `createRuntimeTransport()`，不会构造本传输，因此以上行为不影响本地链路。
 *
 * @param {(message: string) => void} warn 未绑定设备与写帧失败时的记录出口
 * @returns {{ transport: object, close: () => void }} 晚绑定传输及其幂等关闭函数
 */
function createLateBoundTransport(warn) {
  if (typeof warn !== 'function') throw new TypeError('晚绑定传输需要一个 warn 记录出口')
  // 入站处理器按传输缝的要求存起来（安装即替换）；门面在 apply 里把同一个处理器直接
  // 交给 appRuntimeFacade.dispatch，不从这里取。
  const handlers = { request: undefined, notification: undefined }
  let sink
  let closed = false
  // 等第一次 bind 的反向请求：每个元素是「现在可以试着发了」的续体。
  const bindWaiters = []
  // 最后一条阶段状态；bind 时补发给新接入的设备。
  let lastStatus

  /**
   * 记录阶段状态，供 bind 时补发。
   * @param {string} method 通知方法名
   * @param {object} [params] 通知参数
   * @returns {void}
   */
  const recordStatus = (method, params) => {
    // runtime.ready 是门面的初始化完成信号；远程的就绪判据是 runtime.status.phase（协议 §3.4）。
    if (method === 'runtime.ready') lastStatus = { phase: 'ready' }
    else if (method === 'runtime.status' && params && typeof params === 'object') lastStatus = { ...params }
  }

  /**
   * 把一条通知写给当前设备，并对 runtime.ready 追加一条 runtime.status。
   * @param {object} target 已绑定的转发端
   * @param {string} method 通知方法名
   * @param {object} [params] 通知参数
   * @returns {void}
   */
  const deliver = (target, method, params) => {
    target.notify(method, params)
    if (method === 'runtime.ready') target.notify('runtime.status', lastStatus)
  }

  const transport = {
    /**
     * 门面的反向请求。只有 native.* 有归属：宿主本地拦截，或转给手机。
     *
     * 失败以拒绝的 Promise 返回（与 JsonRpcLineTransport 一致）：调用方既有
     * `await` 也有 `.then` 写法，同步抛会从调用点跳出去。设备尚未接入时挂起等待
     * 第一次 bind，见上面的说明。
     * @param {string} method 反向请求方法名，必须以 native. 开头
     * @param {object} [params] 请求参数
     * @returns {Promise<unknown>} sink 的应答；未绑定且传输已关闭时以明确的错误拒绝
     */
    request(method, params) {
      if (closed) return Promise.reject(new Error(`门面传输已关闭，无法发送反向请求「${method}」。`))
      if (typeof method !== 'string' || !method.startsWith('native.')) {
        return Promise.reject(new Error(`门面只承载 native.* 反向请求，收到「${method}」。`))
      }
      return new Promise((resolve, reject) => {
        const send = () => {
          const target = sink
          if (closed || target === undefined) {
            reject(new Error(closed
              ? `门面传输已关闭，无法发送反向请求「${method}」。`
              : `远程宿主还没有绑定设备，无法发送反向请求「${method}」。`))
            return
          }
          Promise.resolve().then(() => target.request(method, params ?? {})).then(resolve, reject)
        }
        if (sink !== undefined) {
          send()
          return
        }
        bindWaiters.push(send)
      })
    },

    /**
     * 门面的出站通知。没有绑定就记一条 warn：通知没有应答，为它抛错只会
     * 连带打断会话事件与会话状态的推进。
     *
     * 阶段通知（`runtime.ready` / `runtime.status`）在没有设备时被记为「待补发的状态」，
     * 由 {@link bind} 在设备接入时补发；其余通知照旧丢弃并记录。
     * @param {string} method 通知方法名
     * @param {object} [params] 通知参数；省略时不写 params 成员
     * @returns {void}
     */
    notify(method, params) {
      if (closed) {
        warn(`门面传输已关闭，通知「${method}」已丢弃。`)
        return
      }
      recordStatus(method, params)
      const target = sink
      if (target === undefined) {
        if (method === 'runtime.ready' || method === 'runtime.status') return
        warn(`远程宿主没有已绑定的设备，通知「${method}」已丢弃。`)
        return
      }
      try {
        deliver(target, method, params)
      } catch (error) {
        warn(`向远程设备转发通知「${method}」失败：${error instanceof Error ? error.message : String(error)}`)
      }
    },

    /** 记录入站请求处理器；安装即替换，与 JsonRpcLineTransport 同语义。 */
    onRequest(handler) { handlers.request = handler },
    /** 记录入站通知处理器；安装即替换，与 JsonRpcLineTransport 同语义。 */
    onNotification(handler) { handlers.notification = handler },

    /** 没有入站字节流需要挂监听；保留 start 只为与 JsonRpcLineTransport 调用形状一致。 */
    start() {},

    /** 解除与设备的绑定，让挂起的反向请求明确失败。幂等。 */
    close() {
      closed = true
      sink = undefined
      for (const resume of bindWaiters.splice(0)) resume()
    },

    /**
     * 绑定一条远程连接的转发端：放行挂起的反向请求，并补发最后一条阶段状态。
     * @param {{ request: (method: string, params: object) => Promise<unknown>, notify: (method: string, params?: object) => void }} next 宿主的转发端
     * @returns {void}
     */
    bind(next) {
      // 插件卸载与连接建立的竞态会走到这里：抛错会变成宿主 onConnection 里的未处理拒绝。
      if (closed) {
        warn('门面传输已关闭，拒绝绑定远程设备。')
        return
      }
      sink = next
      for (const resume of bindWaiters.splice(0)) resume()
      // 设备接入之前产生的阶段状态在这里补发，否则 App 永远等不到 phase=ready（协议 §3.4）。
      if (lastStatus !== undefined) {
        try {
          next.notify('runtime.status', lastStatus)
        } catch (error) {
          warn(`向远程设备补发 runtime.status 失败：${error instanceof Error ? error.message : String(error)}`)
        }
      }
    },

    /**
     * 解除绑定。只有当前绑定的就是它时才清除，避免旧连接关闭时摘掉新连接的绑定。
     * @param {object} current 之前交给 bind 的同一个对象
     * @returns {boolean} 是否真的解除了当前绑定（调用方据此回收连接级终端附件）
     */
    unbind(current) {
      if (sink !== current) return false
      sink = undefined
      return true
    },
  }

  return { transport, close: () => transport.close() }
}

// A source-controlled release gate, never a model argument, profile setting
// or remote switch. Open only after the isolated UID, callback retirement and
// process-death suites have passed on a non-rooted production-class device.
const MODEL_PTC_DEVICE_ACCEPTED = true
const MODEL_WORKFLOW_DEVICE_ACCEPTED = true
const LINUX_VM_DEVICE_ACCEPTED = true
// Guest networking has its own approval and routing acceptance boundary.
const LINUX_VM_NETWORK_DEVICE_ACCEPTED = false
// The native launcher overwrites this marker using the APK's BuildConfig.
// An ordinary build without the verified guest must not advertise Linux tools.
const LINUX_VM_AVAILABLE = LINUX_VM_DEVICE_ACCEPTED && process.env.DSH_ANDROID_LINUX_VM_ENABLED === '1'

// 门面分发表（下面的 facadeDispatch）在 platform: desktop 下可应答的方法清单。远端宿主
// 用它生成握手响应里的 methods（协议 §10.1 要求清单来自分发表，不是宿主手写副本）；
// apps/remote-host/src/index.ts 保留的副本只作门面缺席时的兜底。增删 facadeDispatch 的
// 分支时同步这里。
const FACADE_METHODS = Object.freeze([
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
  'tasks.editQueued',
  'tasks.steerQueued',
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
])
// 远程连接上明确不提供的能力（协议 §4.2 / §11）：documents.* 的语义是“手机上的文件”，
// v1 由宿主声明为 unsupported；web.* 只在 App 本机有意义；linuxVm.* 与 scheduleWake.*
// 是 Android 专属能力，桌面宿主没有实现。优先级高于 methods（协议 §10.1）。
const FACADE_UNSUPPORTED = Object.freeze(['documents.*', 'linuxVm.*', 'scheduleWake.*', 'web.*'])

// terminal.* 的分发表。create/write/resize/rename 会改动终端状态，必须与其它写操作一样
// 经过包操作切换门禁；list/shells/read/close 是读取或收尾，不进该门禁。
const TERMINAL_ACTIONS = Object.freeze(['list', 'shells', 'create', 'read', 'write', 'resize', 'rename', 'close'])
const TERMINAL_WRITE_ACTIONS = Object.freeze(['create', 'write', 'resize', 'rename'])

// `owner` 是协议 §6.4 的本地概念、不上线：Android 本地链路由原生 Binder 注入，远程连接上由
// 宿主在 dispatch 前注入。只有这些方法按 owner 管理资源；其它方法原样转交，避免给参数校验
// 严格的方法塞一个它不认识的字段。
const OWNER_SCOPED_METHODS = new Set(['api.subscribe', 'api.ack', 'api.unsubscribe'])
const OWNER_SCOPED_PREFIXES = Object.freeze([
  'references.', 'workspaceChanges.', 'document.', 'documents.', 'session.attachmentFile.',
])

/**
 * 远程连接的 owner 生命周期。
 *
 * 协议 §6.6 要求连接关闭时终止该连接的全部流；`native.appDisconnected` 只在 Android 本地
 * Binder 链路上出现，远程宿主没有等价的注释。这里把 owner 释放集中到一条路径：宿主给每条
 * 连接分配独立 owner，解除绑定时释放该 owner 的全部资源。owner 逐连接唯一，否则同一条
 * `AppStreams` 上的订阅记录会跨 App 重启/重连累积，触顶 `appStreamMaxSubscriptions` 后
 * 新订阅被拒（`App stream limit reached`），上游生产者也会一直挂着。
 */
export class RemoteConnectionOwners {
  /**
   * @param {object} options 资源清单与记录出口
   * @param {{ label: string, closeOwner: (owner: string) => Promise<unknown> }[]} options.ownerResources 按 owner 释放的资源
   * @param {{ label: string, release: () => unknown }[]} [options.sharedResources] 连接切换时整体释放的共享资源（会话历史租约）
   * @param {(message: string) => void} options.warn 清理失败的记录出口
   */
  constructor({ ownerResources, sharedResources = [], warn }) {
    this.ownerResources = ownerResources
    this.sharedResources = sharedResources
    this.warn = warn
    this.owners = new Map()
  }

  /**
   * 给按 owner 管理的方法注入连接 owner；其它方法、已有客户端 owner 与非对象参数原样返回。
   *
   * 客户端自带的 owner（App 的「本次变更」页面）属于页面自己的生命周期，连接关闭时不代它
   * 释放：那会把页面 owner 记进资源的已关闭集合，页面重连后同一个 owner 就被永久拒绝。
   * @param {string} method 门面方法名
   * @param {unknown} params 入站参数
   * @param {string} [owner] 当前连接的 owner
   * @returns {unknown} 注入后的参数
   */
  scopedParams(method, params, owner) {
    if (typeof owner !== 'string' || owner === '') return params
    if (typeof params !== 'object' || params === null || Array.isArray(params)) return params
    if (params.owner !== undefined) return params
    if (typeof method !== 'string') return params
    if (!OWNER_SCOPED_METHODS.has(method) && !OWNER_SCOPED_PREFIXES.some(prefix => method.startsWith(prefix))) {
      return params
    }
    return { ...params, owner }
  }

  /**
   * 记录一条连接的 sink 与其 owner。同一个 sink 换成新 owner 时先释放旧 owner，避免静默泄漏。
   * @param {object} sink 连接的转发端
   * @param {string} owner 这条连接的 owner
   * @returns {void}
   */
  bind(sink, owner) {
    const previous = this.owners.get(sink)
    this.owners.set(sink, owner)
    if (previous !== undefined && previous !== owner) void this.release(previous)
  }

  /**
   * 解除绑定并释放该 owner 的全部资源。
   * @param {object} sink 连接的转发端
   * @returns {Promise<boolean>} 是否确有绑定被解除
   */
  async unbind(sink) {
    const owner = this.owners.get(sink)
    if (owner === undefined) return false
    this.owners.delete(sink)
    await this.release(owner)
    return true
  }

  /**
   * 释放一个 owner 的资源。共享资源先释放（副作用同步生效，赶在下一条连接开始工作之前），
   * 单条清理失败只记录，不把连接关闭流程变成失败。
   * @param {string} owner 要释放的 owner
   * @returns {Promise<void>} 全部清理尝试结束后兑现
   */
  async release(owner) {
    if (typeof owner !== 'string' || owner === '') return
    const tasks = []
    const fail = (label, error) => this.warn(`${label}: ${error instanceof Error ? error.message : String(error)}`)
    for (const { label, release } of this.sharedResources) {
      try {
        const result = release()
        if (result !== undefined && result !== null) tasks.push(Promise.resolve(result).catch(error => fail(label, error)))
      } catch (error) {
        fail(label, error)
      }
    }
    for (const { label, closeOwner } of this.ownerResources) {
      try {
        tasks.push(Promise.resolve(closeOwner(owner)).catch(error => fail(label, error)))
      } catch (error) {
        fail(label, error)
      }
    }
    await Promise.all(tasks)
  }
}

/**
 * 远端宿主使用的门面服务表面：入站请求按连接 owner 注入参数，bind/unbind 维护 owner 生命周期。
 * Android 本地链路也拿到同一个表面，但那里没有可绑定的宿主，bind/unbind 不会被调用。
 * @param {object} options 组装依赖
 * @param {(method: string, params: object) => unknown} options.dispatch 门面分发表
 * @param {RemoteConnectionOwners} options.owners 连接 owner 生命周期
 * @param {{ bind?: (sink: object) => void, unbind?: (sink: object) => boolean }} options.transport 晚绑定传输
 * @param {() => void} [options.detachConnection] 解除当前绑定时回收连接级终端/附件资源
 * @returns {{ dispatch: (method: string, params: object, owner?: string) => unknown, bind: (sink: object, owner: string) => void, unbind: (sink: object) => Promise<boolean> }} 门面服务表面
 */
export function createRemoteFacadeService({ dispatch, owners, transport, detachConnection }) {
  return {
    dispatch: (method, params, owner) => dispatch(method, owners.scopedParams(method, params, owner)),
    bind(sink, owner) {
      transport.bind?.(sink)
      owners.bind(sink, owner)
    },
    unbind(sink) {
      const unbound = transport.unbind?.(sink) === true
      if (unbound) detachConnection?.()
      return owners.unbind(sink)
    },
  }
}

/** Android is an additional carrier over the same DSH services and session log. */
export function apply(ctx, config) {
  // 远程宿主复用同一套门面，但设备侧能力（Shell、Keystore、隔离执行、Linux VM）不存在。
  // 只有显式配置成 desktop 才走桌面分支，缺省（含未套用默认值的直接调用）保持 Android 行为。
  const android = config.platform !== 'desktop'
  registerModelFileReadGuard(ctx)
  // Android 用 App 的 IPC 通道（现状，行为不变）；桌面宿主没有这条通道，
  // 改用晚绑定传输，等 wss 连接建立后由远端宿主把 sink 挂上来。
  const ipc = android ? createRuntimeTransport() : createLateBoundTransport(message => ctx.logger.warn(message))
  const { transport } = ipc
  const nativeToolCallbacks = new NativeIsolatedToolCallbacks(transport,
    new IsolatedToolCallJournal(join(resolveDshHome(), 'isolated-tool-call-journal')))
  // 跨进程回调、PTC 与 workflow 工具只在 Android 侧注册；桌面宿主不提供这些回调。
  if (android) ctx.provide('nativeIsolatedToolCallbacks', nativeToolCallbacks)
  // Capture the original scoped definition only when an actual Agent execution
  // needs a reviewed callback; the guest never receives native file/network grants.
  if (android) {
    const modelPtcBridge = createNativeIsolatedExecutionBridge(transport)
    ctx.inject(['subagents', 'sandboxPolicy'], modelCtx => {
      const owner = createAppOwnedPtcOwner({
        bridge: modelPtcBridge, callbacks: nativeToolCallbacks, runtime: modelCtx.tools,
        services: { subagents: modelCtx.subagents, agents: modelCtx.agents,
          sessions: modelCtx.sessions, sandboxPolicy: modelCtx.sandboxPolicy },
      })
      modelCtx.provide('appModelPtcOwner', owner)
      modelCtx.effect(() => () => owner.close())
      registerAndroidPtcTool(modelCtx, {
        owner, available: () => MODEL_PTC_DEVICE_ACCEPTED,
      })
    })
  }
  const nativeWorkflowCallbacks = new NativeWorkflowGuestCallbacks(transport)
  if (android) ctx.provide('nativeWorkflowGuestCallbacks', nativeWorkflowCallbacks)
  let privateWorkflowOwner
  // Only trusted App code can attach an already admitted run and live parent.
  // Model workflows use the isolated owner; Node-hosted workflow modules stay disabled.
  if (android) {
    ctx.inject(['subagents', 'agentPresets', 'sessionQuery', 'jobs', 'systemPrompt'], workflowCtx => {
      const workflowOwner = createNativeWorkflowPrivateOwner(workflowCtx, nativeWorkflowCallbacks, transport)
      privateWorkflowOwner = workflowOwner
      workflowCtx.provide('nativeWorkflowPrivateOwner', workflowOwner)
      registerAndroidWorkflowTool(workflowCtx, { owner: workflowOwner,
        available: () => MODEL_WORKFLOW_DEVICE_ACCEPTED })
      workflowCtx.effect(() => async () => {
        if (privateWorkflowOwner === workflowOwner) privateWorkflowOwner = undefined
        await workflowOwner.dispose()
      })
    })
  }
  let nativeLinuxCommands
  let nativeLinuxVm
  if (android) {
    nativeLinuxCommands = new NativeLinuxCommands(transport)
    ctx.provide('nativeLinuxCommands', nativeLinuxCommands)
    registerIsolatedLinuxTool(ctx, nativeLinuxCommands)
    nativeLinuxVm = new NativeLinuxVm(transport)
    ctx.provide('nativeLinuxVm', nativeLinuxVm)
    ctx.inject(['fs', 'sandboxPolicy', 'approval'], linuxCtx => {
      const networkAdmission = LINUX_VM_AVAILABLE && LINUX_VM_NETWORK_DEVICE_ACCEPTED
        ? createLinuxNetworkAdmission(linuxCtx, createNativeLinuxNetworkBridge(transport)) : undefined
      registerLinuxVmTool(linuxCtx, nativeLinuxVm, LINUX_VM_AVAILABLE, networkAdmission)
      registerLinuxImportTool(linuxCtx, nativeLinuxVm, LINUX_VM_AVAILABLE, process.cwd())
      registerLinuxExportTool(linuxCtx, nativeLinuxVm, LINUX_VM_AVAILABLE, process.cwd())
      registerLinuxInspectTool(linuxCtx, nativeLinuxVm, LINUX_VM_AVAILABLE)
    })
  }
  const credentials = android ? new AndroidCredentials(ctx, transport) : undefined
  // 桌面 profile 用 credentials-local 条目提供凭据；Android 用 Keystore 提供者。
  const credentialService = () => {
    const service = credentials ?? ctx.get('credentials')
    if (!service) throw new Error('Credential service is unavailable')
    return service
  }
  if (android) ctx.plugin(AndroidShell)
  ctx.plugin(AndroidAccountCallback)
  ctx.effect(() => {
    transport.start()
    return async () => {
      await nativeToolCallbacks.dispose()
      await nativeWorkflowCallbacks.dispose()
      await nativeLinuxCommands?.dispose()
      await nativeLinuxVm?.dispose()
      ipc.close()
    }
  })
  // Connection needs the Keystore provider before the shared Session controller can activate.
  process.env.DSH_EMBEDDED_DIAGNOSTIC === '1' && (globalThis.__dshEmbeddedProgress ??= []).push('scheduling facade injection')
  const facadeDependencies = ['sessionController', 'typertGateway', 'connection', 'accountCallback', 'fileUploads',
    'pluginManager', 'jobs', 'sessionProjections', 'subagents', 'workspaceRegistry']
  ctx.inject(facadeDependencies, ctx => {
  process.env.DSH_EMBEDDED_DIAGNOSTIC === '1' && (globalThis.__dshEmbeddedProgress ??= []).push('facade callback start')
  try {
  // These Loader entries define the native carrier and App-controlled HTTP boundary.
  // The manager applies the same protection to App, Web, tools, and bundle overlays.
  const requiredEntries = new Set(['android-runtime', 'credentials', 'authorization', 'deepseek-account',
    'web-startup', 'webserver', 'web-runtime', 'connection', 'session-controller',
    'session-persistence-jsonl', 'android-session-persistence', 'settings', 'file-upload',
    'attachment-local', 'android-attachment-store', 'working-directory', 'agent-loop',
    'workspace', 'workspace-controller', 'android-directory-picker', 'android-filesystem',
    // Disabled model-authored programs must remain disabled after boot too.
    // Android lacks the original per-run OS confinement for these modules.
    'ptc-runtime', 'workflow-ptc', 'tool-workflow'])
  const loaderEntries = [...ctx.get('loader').entries()]
  // The official desktop plugin manager does not expose the Android-only
  // protectModules capability; the App carrier's protection is unnecessary
  // when the runtime runs inside the desktop Host.
  ctx.pluginManager.protectModules?.(loaderEntries.filter(entry => requiredEntries.has(entry.options.id))
    .map(entry => entry.options.name))
  const web = new WebAccess(ctx, transport)
  let appPeer
  const peer = () => appPeer ??= ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'none' })
  const invoke = (namespace, method, args, signal) => {
    return ctx.typertGateway.invoke({ namespace, method, args, peer: peer(), signal })
  }
  const references = new AppReferenceDiscovery({ invoke, limits: () => ({
    maxRequests: config.referenceMaxRequests.get(), requestTimeoutMs: config.referenceRequestTimeoutMs.get(),
    closeTimeoutMs: config.referenceCloseTimeoutMs.get(),
  }) })
  const changesHandler = ctx.connection.createSharedFetchHandler('/api')
  const workspaceChanges = new AppWorkspaceChanges({
    fetch: request => changesHandler.fetch(request, peer()),
    available: () => !!ctx.get('workspaceChanges'),
    limits: () => ({ maxRequests: config.workspaceChangesMaxRequests.get(),
      maxOwnerRequests: config.workspaceChangesMaxOwnerRequests.get(),
      requestTimeoutMs: config.workspaceChangesRequestTimeoutMs.get(),
      closeTimeoutMs: config.workspaceChangesCloseTimeoutMs.get() }),
  })
  const library = new AppLibrary(ctx, {
    invoke,
    closeTimeoutMs: () => config.libraryCloseTimeoutMs.get(),
    follow: signal => ctx.typertGateway.stream({
      namespace: 'workspace', method: 'follow', args: {}, peer: peer(), signal,
    }),
  })
  let attachments
  let packageOperations
  const sessions = new AppSessions(ctx, (method, request) => invoke('session', method, { request }),
    (sessionId, ids) => attachments.content(sessionId, ids), {
      content: (sessionId, ids) => attachments.commandContent(sessionId, ids),
      execute: args => invoke('commands', 'execute', args),
    }, (agentId, agentPreset) => invoke('agentPresets', 'select', { agentId, agentPreset }),
    () => packageOperations?.assertWorkAllowed())
  // 本地链路从手机的私有缓存目录读草稿；桌面宿主没有手机文件系统，改为在 prepare 内用
  // 反向请求 `native.attachments.read` 分页拉取（protocol §5.2，设计 §3.4）。
  attachments = android
    ? new AppAttachments(ctx, {
        directory: () => transport.request('native.attachments.directory', {}),
        ensureSession: sessionId => sessions.ensure(sessionId),
      })
    : new DesktopAppAttachments(ctx, {
        request: (method, params) => transport.request(method, params),
        ensureSession: sessionId => sessions.ensure(sessionId),
        limits: () => ({ maxFileBytes: config.attachmentFileMaxBytes.get() }),
      })
  const live = new AppLiveState(ctx, transport, { streamPublishMs: () => config.streamPublishMs.get() })
  const history = new AppSessionHistory(ctx.sessionController)
  // 桌面宿主没有 App 的 android_shell 审批通道，命令执行归桌面 profile 的审批与终端。
  const shell = android ? registerAndroidShell(ctx, config) : undefined
  const interactionReceipts = new InteractionReceipts()
  let tasks
  const interactions = new AppInteractions(ctx, {
    notify(method, params) {
      transport.notify(method, params)
      if (method === 'interactions.changed') tasks?.interactionsChanged()
    },
  }, { shellContext: (sessionId, callId) => shell?.context(sessionId, callId), receipts: interactionReceipts })
  tasks = new AppTasks(ctx, transport, { interactions: () => interactions.snapshot() })
  const taskCompletion = new AppTaskCompletion(ctx, transport)
  const scheduleWakeup = new NativeScheduleWakeup({ invoke, transport,
    subscribe: listener => ctx.on('schedule/changed', listener),
    warn: message => ctx.logger.warn(message),
    limits: () => ({ requestTimeoutMs: config.scheduleWakeupRequestTimeoutMs.get(),
      closeTimeoutMs: config.scheduleWakeupCloseTimeoutMs.get() }),
  })
  packageOperations = new AppPackageOperations(ctx, {
    pendingAppSessions: () => sessions.pendingCount(),
    terminalActivity: () => terminals.activitySnapshot(),
  })
  const subagents = new AppSubagents(ctx, {
    invoke,
    follow: (request, signal) => ctx.typertGateway.stream({
      namespace: 'session', method: 'follow', args: { request }, peer: peer(), signal,
    }),
    taskSession: params => tasks.session(params),
    presentEvent: presentSessionEvent,
  })
  const configurationTransfers = new AppConfigurationTransfers(ctx, { protectedNamespaces: requiredEntries })
  const exports = new AppExports(ctx, { directory: () => transport.request('native.exports.directory', {}) })
  const attachmentFiles = new AppAttachmentFiles(ctx, {
    directory: () => transport.request('native.attachmentFiles.directory', {}),
    limits: () => ({ maxBytes: config.attachmentFileMaxBytes.get(),
      readPageBytes: config.attachmentFileReadPageBytes.get(), maxRequests: config.attachmentFileMaxRequests.get() }),
  })
  const searchLimits = () => ({
      fileBytes: config.documentSearchFileBytes.get(), totalBytes: config.documentSearchTotalBytes.get(),
      maxEntries: config.documentSearchMaxEntries.get(), maxFiles: config.documentSearchMaxFiles.get(),
      maxDepth: config.documentSearchMaxDepth.get(), maxMatches: config.documentSearchMaxMatches.get(),
      previewChars: config.documentSearchPreviewChars.get(), maxDurationMs: config.documentSearchMaxDurationMs.get(),
  })
  const documentReads = new AppDocumentReads(transport, {
    timeoutMs: () => config.documentReadMaxDurationMs.get(), maxRequests: () => config.documentReadMaxRequests.get(),
  })
  const documentSearch = new AppDocumentSearch(transport, {
    maxRequests: () => config.documentSearchMaxRequests.get(), limits: searchLimits,
  })
  // Resolve the original media route's MIME dependency from its owning package.
  const mediaMime = createRequire(import.meta.resolve('@deepseek-ai/dsh-api-session-controller/package.json'))('mime-types')
  const workspaceFiles = new AppWorkspaceFiles({
    root: process.cwd(),
    limits: () => ({
      readPageBytes: config.workspaceReadPageBytes.get(),
      maxDirectoryEntries: config.workspaceDirectoryMaxEntries.get(),
      listPageSize: config.workspaceDirectoryPageSize.get(),
      closeTimeoutMs: config.workspaceFilesCloseTimeoutMs.get(),
      maxSearches: config.documentSearchMaxRequests.get(), search: searchLimits(),
    }),
  })
  const privateDocument = async (namespace, method, args, signal) => {
    signal.throwIfAborted()
    if (namespace === 'workspaceFiles') {
      return workspaceFiles.document(method, args, signal, {
        maxFileBytes: config.workspacePreviewMaxFileBytes.get(),
        maxWindowBytes: config.workspacePreviewWindowBytes.get(),
      })
    }
    if (namespace === 'officeToPdf' && method === 'generation') {
      const service = ctx.get('officeToPdf')
      if (!service) throw new Error('Office renderer is unavailable')
      return service.getGeneration(signal)
    }
    if (namespace === 'officeToPdf' && method === 'render') {
      const source = await workspaceFiles.document('stat', { path: args.path }, signal, {
        maxFileBytes: config.workspacePreviewMaxFileBytes.get(), maxWindowBytes: config.workspacePreviewWindowBytes.get(),
      })
      const service = ctx.get('officeToPdf')
      if (!service) throw new Error('Office renderer is unavailable')
      const extension = args.path.split('.').at(-1)?.toLowerCase()
      if (!['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'].includes(extension)) {
        throw new TypeError('Unsupported Office document format')
      }
      const rendered = await service.convert({ extension, priority: args.priority,
        source: { key: JSON.stringify([PRIVATE_WORKSPACE_SCOPE, source.absolutePath]),
          version: source.version, bytes: source.bytes,
          read: async (readSignal, maxBytes) => {
            const current = await workspaceFiles.document('readBytes', { path: args.path }, readSignal, {
              maxFileBytes: Math.min(maxBytes, config.workspacePreviewOfficeInputBytes.get()),
              maxWindowBytes: config.workspacePreviewWindowBytes.get(),
            })
            if (current.version !== source.version || current.absolutePath !== source.absolutePath) {
              throw new Error('Office document changed during conversion')
            }
            return { bytes: current.data, version: current.version }
          } },
      }, signal)
      signal.throwIfAborted()
      const current = await workspaceFiles.document('stat', { path: args.path }, signal, {
        maxFileBytes: config.workspacePreviewMaxFileBytes.get(), maxWindowBytes: config.workspacePreviewWindowBytes.get(),
      })
      if (current.version !== source.version || current.absolutePath !== source.absolutePath) {
        throw new Error('Office document changed during conversion')
      }
      return { absolutePath: source.absolutePath, version: source.version,
        offset: 0, eof: true, bytes: rendered.pdf.byteLength, data: rendered.pdf,
        missingFonts: rendered.missingFonts, generation: rendered.generation }
    }
    throw new TypeError('Unsupported private document method')
  }
  const documentPreview = new AppDocumentPreview({ invoke, privateWorkspace: privateDocument,
    mediaPolicy: path => ({ maxBytes: ctx.get('attachments')?.imageLimits?.maxImageBytes,
      mimeType: mediaMime.lookup(path) || 'application/octet-stream' }), limits: () => ({
    maxRequests: config.documentPreviewMaxRequests.get(), maxOwnerRequests: config.documentPreviewMaxOwnerRequests.get(),
    maxLeaseBytes: config.documentPreviewMaxLeaseBytes.get(), maxLeases: config.documentPreviewMaxLeases.get(),
    leaseTimeoutMs: config.documentPreviewLeaseTimeoutMs.get(), requestTimeoutMs: config.documentPreviewRequestTimeoutMs.get(),
    closeTimeoutMs: config.documentPreviewCloseTimeoutMs.get(),
  }) })
  const chatImages = new AppChatImages({ invoke, mimeType: path => mediaMime.lookup(path) || null,
    limits: () => ({ maxBytes: Math.min(config.chatImagePreviewMaxBytes.get(),
      ctx.get('attachments')?.imageLimits?.maxImageBytes ?? 0),
    maxRequests: config.chatImagePreviewMaxRequests.get(), timeoutMs: config.chatImagePreviewTimeoutMs.get(),
    closeTimeoutMs: config.chatImagePreviewCloseTimeoutMs.get() }) })
  // App 本地用 Android PTY helper 实现；桌面宿主没有 helper，改为经 Gateway 驱动真实的
  // terminal-controller，再把双工 attach 流投影成同一套请求/响应（见 remote-dsh 终端设计 §3）。
  const terminals = android
    ? new AppTerminals({
        resolveDirectory: async sessionId => {
          const found = await ctx.sessionController.resolveAgent(sessionId)
          if ('error' in found) throw found.error
          const directory = found.agent.ctx.get('workingDirectory')
          if (!directory) throw new Error('Session working directory is unavailable')
          return { cwd: await directory.ensure(found.agent), owner: found.agent.ctx }
        },
      })
    : new DesktopAppTerminals({
        available: () => ctx.get('terminalController') !== undefined,
        resolveAgent: sessionId => ctx.sessionController.resolveAgent(sessionId),
        invoke,
        stream: request => ctx.typertGateway.stream({ ...request, peer: peer() }),
      })
  const streams = new AppStreams(ctx, transport, peer, {
    maxSubscriptions: () => config.appStreamMaxSubscriptions.get(),
    maxFrameBytes: () => config.appStreamMaxFrameBytes.get(),
  })
  const connectionOwners = new RemoteConnectionOwners({
    warn: message => ctx.logger.warn(message),
    ownerResources: [
      { label: 'App reference cleanup failed', closeOwner: owner => references.closeOwner(owner) },
      { label: 'App change comparison cleanup failed', closeOwner: owner => workspaceChanges.closeOwner(owner) },
      { label: 'App stream cleanup failed', closeOwner: owner => streams.closeOwner(owner) },
      { label: 'App file read cleanup failed', closeOwner: owner => documentReads.closeOwner(owner) },
      { label: 'App file search cleanup failed', closeOwner: owner => documentSearch.closeOwner(owner) },
      { label: 'App document preview cleanup failed', closeOwner: owner => documentPreview.closeOwner(owner) },
      { label: 'App attachment file cleanup failed', closeOwner: owner => attachmentFiles.closeOwner(owner) },
    ],
    sharedResources: [
      { label: 'App session history cleanup failed', release: () => history.releaseAll() },
    ],
  })
  transport.onNotification((method, params) => {
    if (method === 'native.networkChanged') {
      void web.refresh().catch(error => web.publish({ phase: 'failed', host: null, url: null, error: String(error) }))
    }
    if (method === 'native.appDisconnected') {
      // 原生 Binder 的页面/Activity 断连与远程连接关闭走同一条 owner 释放路径。
      void connectionOwners.release(params.owner)
    }
  })
  const describe = () => describeAndroidSettings(ctx)
  // 门面方法表：Android 下由上面的 IPC 传输安装，桌面宿主下由 appRuntimeFacade.dispatch 调用
  // （见 apply 末尾 provide 的服务）。两条路径用的是同一个处理器。
  const facadeDispatch = async (method, params) => {
    if (method === 'native.toolCallback') return nativeToolCallbacks.call(params)
    if (method === 'native.toolCallback.cancel') return nativeToolCallbacks.close(params)
    if (method === 'native.workflowCallback') return nativeWorkflowCallbacks.call(params)
    if (method === 'native.workflowCallback.cancel') return nativeWorkflowCallbacks.close(params)
    if (method === 'userText.mask') return maskUserText(params)
    if (method.startsWith('workspaceChanges.')) {
      const action = method.slice('workspaceChanges.'.length)
      if (action === 'summary' || action === 'diff') {
        return packageOperations.runWork(() => workspaceChanges.call(action, params))
      }
      return workspaceChanges.call(action, params)
    }
    if (method.startsWith('references.')) {
      const action = method.slice('references.'.length)
      try {
        return await (action === 'list'
          ? packageOperations.runWork(() => references.call(action, params))
          : references.call(action, params))
      }
      catch (error) { return remoteFailure(error) }
    }
    if (method.startsWith('library.')) {
      const action = method.slice('library.'.length)
      try { return await packageOperations.runWork(() => library.call(action, params)) }
      catch (error) { return remoteFailure(error) }
    }
    if (method.startsWith('workspace.files.')) {
      const action = method.slice('workspace.files.'.length)
      if (action === 'search') return packageOperations.runWork(() => workspaceFiles.call(action, params))
      return workspaceFiles.call(action, params)
    }
    if (method.startsWith('document.')) {
      const action = method.slice('document.'.length)
      if (action === 'call') return packageOperations.runWork(() => documentPreview.call(action, params))
      return documentPreview.call(action, params)
    }
    if (method.startsWith('terminal.')) {
      const action = method.slice('terminal.'.length)
      if (!TERMINAL_ACTIONS.includes(action)) {
        throw new Error(`Unsupported terminal action: ${action}`)
      }
      if (android) {
        if (TERMINAL_WRITE_ACTIONS.includes(action)) {
          return packageOperations.runWork(() => terminals[action](params))
        }
        return terminals[action](params)
      }
      // 桌面分支：终端进程在 PC 上，失败按协议 §9.2 以 result._pocket_error 返回结构化 code。
      try {
        if (TERMINAL_WRITE_ACTIONS.includes(action)) {
          return await packageOperations.runWork(() => terminals[action](params))
        }
        return await terminals[action](params)
      } catch (error) {
        return remoteFailure(error)
      }
    }
    switch (method) {
      case 'runtime.info': return { node: process.version, platform: process.platform, arch: process.arch,
        uid: process.getuid?.(), workspace: process.cwd(), profile: 'android' }
      case 'runtime.permissions': return {
        // 桌面宿主的 shell 由桌面 profile 决定，这里不复述 App 的 android_shell 状态。
        shell: shell ? shell.policy() : {
          tool: 'desktop-host', available: false, reason: 'desktop-remote-host',
          executionIdentity: null, approval: 'unavailable', workspaceConfinement: false,
        },
        fileTools: { sandboxMode: ctx.get('fs')?.sandboxMode ?? null },
        presets: { available: !!ctx.get('permissionPresets') },
        programmaticTools: {
          available: false,
          filesystem: 'read-only',
          writableRoots: [],
          network: 'off',
          reason: 'isolated-executor-unwired',
          // 桌面模式没有注册 PTC/workflow 工具，不能对外宣称这两个能力可用。
          modelPtc: modelPtcCapability(android && MODEL_PTC_DEVICE_ACCEPTED),
          modelWorkflow: modelWorkflowCapability(android && MODEL_WORKFLOW_DEVICE_ACCEPTED),
        },
      }
      case 'runtime.live': return live.snapshot()
      case 'runtime.transition.reserve': return packageOperations.reserve(params)
      case 'runtime.transition.commit': return packageOperations.commit(params)
      case 'runtime.transition.release': return packageOperations.release(params)
      case 'tasks.summary': return tasks.summary()
      case 'tasks.list': return tasks.list(params)
      case 'tasks.session': return tasks.session(params)
      case 'tasks.cancel': return tasks.cancel(params)
      case 'tasks.killUnownedJob': return tasks.killUnownedJob(params)
      case 'tasks.removeQueued': return tasks.removeQueued(params)
      case 'tasks.editQueued': return tasks.editQueued(params)
      case 'tasks.steerQueued': return tasks.steerQueued(params)
      case 'subagents.catalog': return subagents.call('catalog', params)
      case 'subagents.inspect': return subagents.call('inspect', params)
      case 'subagents.page': return subagents.call('page', params)
      case 'subagents.send': return packageOperations.runWork(() => subagents.call('send', params))
      case 'subagents.interrupt': return packageOperations.runWork(() => subagents.call('interrupt', params))
      case 'account.signIn': {
        const client = params.client
        if (typeof client !== 'object' || client === null || typeof client.version !== 'string'
          || typeof client.locale !== 'string' || !Number.isSafeInteger(client.timezoneOffsetSeconds)) {
          throw new TypeError('Account client version, locale, and timezone are required')
        }
        return packageOperations.runWork(() => ctx.accountCallback.signIn(client))
      }
      case 'interactions.list': return interactions.snapshot()
      case 'interactions.reply': return packageOperations.runWork(() => interactions.reply(params))
      case 'interactions.dismiss': return packageOperations.runWork(() => interactions.dismiss(params))
      case 'interactions.wait': return interactions.wait(params)
      case 'web.status': return web.status()
      case 'web.configure': return packageOperations.runWork(() => web.configure(params))
      case 'web.rotate': return packageOperations.runWork(() => web.rotate())
      case 'api.call': {
        try {
          return await packageOperations.runWork(() => invoke(requiredString(params.namespace, 'namespace'),
            requiredString(params.method, 'method'), params.args ?? {}))
        } catch (error) { return remoteFailure(error) }
      }
      case 'chat.image.preview': return packageOperations.runWork(() => chatImages.preview(params))
      case 'api.subscribe': return streams.subscribe(params)
      case 'api.ack': return streams.ack(params)
      case 'api.unsubscribe': return streams.unsubscribe(params)
      case 'session.send': return sessions.send(params)
      case 'session.ensure': return sessions.ensure(params)
      case 'session.selectPreset': {
        try { return await sessions.selectPreset(params) }
        catch (error) { return remoteFailure(error) }
      }
      case 'session.command': return sessions.command(params)
      // 本地分支保持原有错误形状（prepare 走包操作门禁，preview/release 裸抛）；
      // 桌面分支的附件实现会抛协议词汇表的 code，统一包成 _pocket_error 让手机可分类（设计 §3.4.3）。
      case 'attachments.prepare':
      case 'attachments.preview':
      case 'attachments.release': {
        const action = method.slice('attachments.'.length)
        if (android) {
          if (action === 'prepare') return packageOperations.runWork(() => attachments.prepare(params))
          return attachments[action](params)
        }
        try {
          if (action === 'prepare') return await packageOperations.runWork(() => attachments.prepare(params))
          return await attachments[action](params)
        } catch (error) {
          return remoteFailure(error)
        }
      }
      case 'session.export.prepare': return packageOperations.runWork(() => exports.prepare(params))
      case 'session.export.cancel': return exports.cancel(params)
      case 'session.export.release': return exports.release(params)
      case 'session.attachmentFile.prepare': return packageOperations.runWork(() => attachmentFiles.prepare(params))
      case 'session.attachmentFile.info': return attachmentFiles.info(params)
      case 'session.attachmentFile.read': return attachmentFiles.read(params)
      case 'session.attachmentFile.cancel': return attachmentFiles.cancel(params)
      case 'session.attachmentFile.release': return attachmentFiles.release(params)
      case 'settings.describe': return describe()
      case 'configuration.transfer.export': return configurationTransfers.export()
      case 'configuration.transfer.preview': return configurationTransfers.preview(params)
      case 'configuration.transfer.apply': return packageOperations.runWork(() => configurationTransfers.apply(params))
      case 'configuration.transfer.release': return configurationTransfers.release(params)
      case 'settings.mutate': {
        requiredString(params.ns, 'ns')
        if (!Array.isArray(params.ops) || !Number.isSafeInteger(params.revision)) throw new TypeError('ops and revision are required')
        try {
          await packageOperations.runWork(() => ctx.settings.mutate(params.ns, params.ops, params.revision))
        } catch (error) {
          if (error.code !== 'SETTINGS_CONFLICT') throw error
          return { _pocket_error: { code: error.code, message: error.message,
            expectedRevision: error.expected, actualRevision: error.actual } }
        }
        return describe()
      }
      case 'credentials.describe': return credentialService().describe(credentialRef(requiredString(params.ref, 'ref')))
      // The App keeps one device token per paired computer. `describe` only
      // reports presence, so this case is the only path that returns the secret
      // a cold start needs to reconnect without pairing again.
      case 'credentials.read': {
        const resolved = await credentialService().resolve(credentialRef(requiredString(params.ref, 'ref')))
        const value = resolved !== null && typeof resolved === 'object' ? resolved.value : resolved
        return { value: typeof value === 'string' ? value : null }
      }
      case 'credentials.set': {
        const value = requiredString(params.value, 'value').trim()
        if (!/^[\x21-\x7e]+$/.test(value)) throw new TypeError('API Key must contain printable ASCII without spaces')
        await packageOperations.runWork(() => credentialService().set(credentialRef(requiredString(params.ref, 'ref')), value))
        return { configured: true }
      }
      case 'credentials.unset': {
        await packageOperations.runWork(() => credentialService().unset(credentialRef(requiredString(params.ref, 'ref'))))
        return { configured: false }
      }
      // Child transcripts require their durable parent address and belong to the subagent/task entry points.
      case 'sessions.list': return library.sidebar()
      case 'session.readWindow': {
        try { return await history.readWindow(params) }
        catch (error) { return remoteFailure(error) }
      }
      case 'session.turnOutline': {
        try { return await history.turnOutline(params) }
        catch (error) { return remoteFailure(error) }
      }
      case 'session.read': {
        try { return await history.read(params) }
        catch (error) { return remoteFailure(error) }
      }
      case 'session.read.release': return history.release(params)
      case 'workflow.inspect': {
        if (!privateWorkflowOwner) throw new Error('Private workflow owner is unavailable')
        return privateWorkflowOwner.inspectRun(params)
      }
      case 'session.cancel': return tasks.cancel(params)
      case 'documents.roots': return transport.request('native.documents.roots', {})
      case 'documents.list': return transport.request('native.documents.list', params)
      case 'documents.read': return documentReads.run(params, { owner: params.owner })
      case 'documents.read.cancel': return documentReads.cancel(params, { owner: params.owner })
      case 'documents.revoke': return packageOperations.runWork(() => transport.request('native.documents.revoke', params))
      case 'documents.search': return packageOperations.runWork(() => documentSearch.run(params, { owner: params.owner }))
      case 'documents.search.cancel': return documentSearch.cancel(params, { owner: params.owner })
      default: throw new Error(`Unsupported App method: ${method}`)
    }
  }
  transport.onRequest(facadeDispatch)
  ctx.on('session/event', (session, event) => {
    transport.notify('session.event', { sessionId: String(session.id), event: presentSessionEvent(event) })
    if (event.type === 'session/title') transport.notify('sessions.changed', {})
  })
  ctx.on('session/created', () => transport.notify('sessions.changed', {}))
  ctx.on('domain/changed', change => {
    if (change.domain === 'workspace') transport.notify('sessions.changed', {})
  })
  ctx.on('settings/document-updated', () => transport.notify('settings.changed'))
  registerAndroidFilesTool(ctx, transport, documentSearch, documentReads)
  registerAndroidAttachmentsTool(ctx)
  ctx.effect(() => {
    const remove = ctx.appReady.onReady(() => {
      void transport.request('native.storage.root', {}).then(async root => {
        const privateRoot = requiredString(root, 'native storage root')
        await interactionReceipts.initialize(privateRoot)
        await establishAttachmentHome(resolveDshHome(), privateRoot)
      }).then(() => library.initialize()).then(() => interactions.start()).then(() => {
        transport.notify('runtime.ready', { node: process.version })
        tasks.publish()
        // A failed wake projection is reported by its owner; other Agent work remains available.
        void scheduleWakeup.start().catch(_error => { /* The projection owner already reports its failure. */ })
        return web.restore().catch(error =>
          transport.notify('web.changed', { ...web.status(), phase: 'failed', error: String(error) }),
        )
      }).catch(error => {
        transport.notify('runtime.status', { phase: 'failed', error: `运行时初始化失败：${error.message}` })
      })
    })
    return async () => {
      remove()
      const results = await Promise.allSettled([
        () => taskCompletion.close(),
        () => scheduleWakeup.close(),
        () => documentReads.close(), () => documentSearch.close(), () => attachments.close(), () => attachmentFiles.close(), () => exports.close(), () => tasks.close(),
        () => packageOperations.close(),
        () => configurationTransfers.close(), () => subagents.close(), () => workspaceFiles.close(), () => library.close(),
        () => terminals.dispose(),
        () => live.close(),
        () => history.close(),
        () => streams.close(), () => documentPreview.close(), () => chatImages.close(), () => references.close(), () => workspaceChanges.close(),
        () => interactions.close(), () => web.close(),
      ].map(close => Promise.resolve().then(close)))
      // Stream and interaction owners release their peer before the shared API peer.
      results.push(...await Promise.allSettled([Promise.resolve().then(() => appPeer?.dispose())]))
      const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
      if (errors.length) throw new AggregateError(errors, 'Android runtime cleanup did not complete')
    }
  })
  // 门面服务：远端宿主（platform: desktop）通过它把 wss 连接接到同一套方法表上。
  // dispatch 就是上面安装到传输上的那个处理器；bind/unbind 委托给晚绑定传输。
  // Android 的传输自带 IPC 通道，没有可绑定的宿主，所以 bind/unbind 是空操作。
  // methods/unsupported 供远端宿主生成握手清单（协议 §10.1），Android 本地链路不读它们。
  //
  // 桌面 profile 可能没有启用 terminal-controller（App 组合会关掉它）。握手清单必须反映
  // 实际可应答的面：缺失时把 terminal.* 从 methods 移除并列入 unsupported，避免 App 显示
  // 一个点击即失败的入口。getter 让每次握手都重新读取当前服务状态。
  const terminalSupported = () => android || ctx.get('terminalController') !== undefined
  process.env.DSH_EMBEDDED_DIAGNOSTIC === '1' && (globalThis.__dshEmbeddedProgress ??= []).push('providing facade')
  ctx.provide('appRuntimeFacade', {
    ...createRemoteFacadeService({
      dispatch: facadeDispatch,
      owners: connectionOwners,
      transport,
      // 连接级资源不随 sink 自动回收：终端附件与保留流属于这条连接，不 detach 会一直占着
      // PC 上的输入权和保留额度；附件上传的分页拉取同理，断连后不再推进。
      detachConnection: android ? undefined : () => {
        terminals.detachAll()
        attachments.detachAll()
      },
    }),
    get methods() {
      return terminalSupported()
        ? FACADE_METHODS
        : FACADE_METHODS.filter(method => !method.startsWith('terminal.'))
    },
    get unsupported() {
      return terminalSupported() ? FACADE_UNSUPPORTED : ['terminal.*', ...FACADE_UNSUPPORTED]
    },
  })
  } catch (error) {
    // 门面的初始化失败不能让插件看起来正常：远端宿主注入 appRuntimeFacade 会永远
    // 等下去，整条远程链路只剩「等待服务」。记录可读原因后重新抛出，让加载器把
    // 这次激活判为失败。
    ctx.logger.error(`Android 门面初始化失败：${error instanceof Error ? error.message : String(error)}`)
    if (process.env.DSH_EMBEDDED_DIAGNOSTIC === '1') {
      globalThis.__dshEmbeddedFacadeError = error instanceof Error ? (error.stack ?? error.message) : String(error)
      ;(globalThis.__dshEmbeddedProgress ??= []).push('facade error: ' + (error instanceof Error ? error.message : String(error)))
    }
    throw error
  }
  })
}
