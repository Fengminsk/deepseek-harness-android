/**
 * 远程推送通知（协议 §8 的宿主发送端）。
 *
 * 页面线通知（`task.completed`、`interactions.changed`、`session.event`）由门面通过 sink 发给
 * App；本模块在 sink 的 `notify` 上只做一层观察，把它们映射成协议 §8 的系统通知线。两条线并行：
 * `remote.*` 帧是追加的，页面线的发送时机与内容不变，App 自己决定只对 `remote.*` 触发系统通知
 * （§8.1）。
 *
 * 本批映射：
 * - `task.completed` → `remote.taskCompleted`（§8.2）；
 * - `interactions.changed` 里新出现的 pending 交互 → `remote.approvalPending`（§8.3）；
 * - `session.event` 里的 `session/title` → `remote.sessionChanged`（§8.5，只覆盖标题变化；
 *   归档/删除需要 `sessions.changed` 触发器 + 门面目录 diff，本批不做，见 HANDOFF §9）。
 *
 * 每个 ready 连接一个实例，连接替换或关闭时 `dispose()`。字段上限、截断规则、帧上限与去重语义
 * 全部来自冻结的 `protocol.md` §8，本模块只做映射，不新增字段、不改 App 门面的方法表。
 *
 * 发送失败（连接已在关闭等）只记一条 `remote-notify-failed` warn，绝不影响页面线；被替换的连接
 * 可能还有在途的异步构造，`dispose()` 之后不再写帧。
 *
 * @module remote-host/notifications
 */

import {
  describeRemoteError,
  type RemoteConnectionState,
  type RemoteLogger,
} from './server.ts'

/** `remote.taskCompleted` 的帧上限（协议 §8.2，字节）。 */
export const TASK_COMPLETED_FRAME_LIMIT_BYTES = 8 * 1024

/** `remote.approvalPending` 的帧上限（协议 §8.3，字节）。 */
export const APPROVAL_PENDING_FRAME_LIMIT_BYTES = 16 * 1024

/** `remote.sessionChanged` 的帧上限（协议 §8.5，字节）。 */
export const SESSION_CHANGED_FRAME_LIMIT_BYTES = 4 * 1024

/** 协议 §8.2/§8.3 的字段字符上限；`truncated` 为真时表示至少一个字段被截断。 */
export const NOTIFICATION_FIELD_LIMITS = {
  /** id 类字段（`taskId` / `sessionId` / `workspaceId` / `interactionId` / `toolName`）的字符上限。 */
  id: 128,
  /** 标题字段的字符上限。 */
  title: 200,
  /** `remote.taskCompleted.summary` 的字符上限。 */
  taskSummary: 512,
  /** `remote.approvalPending.summary` 的字符上限。 */
  approvalSummary: 1024,
} as const

/**
 * 查询会话信息的上限。宿主本地读（门面 `library.catalog`），慢或失败都按查不到处理：
 * 通知本身不是关键路径，宁可标题退化成 sessionId，也不能让通知无限期悬挂。
 */
const SESSION_FACTS_TIMEOUT_MS = 2_000

/** 通知无法写出去时只报一次的 warn；成功写出一条后重新允许报告。 */
const NOTIFY_FAILED_EVENT = 'remote-notify-failed'

/** 每写出一条 `remote.*` 帧记录一条 info，便于真机联调时在宿主日志里看到系统通知线。 */
const NOTIFY_SENT_EVENT = 'remote-notify-sent'

/** 页面线通知形状不符合预期时记录的事件名。 */
const NOTIFY_IGNORED_EVENT = 'remote-notify-ignored'

/** 帧超限时 `title`（必填）逐级缩短的上限序列。 */
const TITLE_SHRINK_STEPS: readonly number[] = [64, 32, 16, 8, 1]

/** 一次 `task.completed` 页面线通知（`apps/android/runtime/task-completion.mjs`）里本模块用到的字段。 */
export interface TaskCompletedNotice {
  /** 所属会话 id。 */
  readonly sessionId: string
  /** 结束的轮次序号；页面线通常提供，缺失时退化为按 `endSeq` 区分。 */
  readonly turn?: number
  /** 该轮结束时的事件序号，仅用于 `turn` 缺失时构造 `taskId`。 */
  readonly endSeq?: number
  /** 结果摘要（运行时从最后一条 assistant 文本里截出的短预览）。 */
  readonly preview?: string
}

/** 会话的宿主本地补充信息；查不到时调用方用 `sessionId` 兜底标题。 */
export interface RemoteSessionFacts {
  /** 会话标题（`title` 投影或会话列表行标题）。 */
  readonly title?: string
  /** 所属项目 id（`workspaceRegistry` 的 workspace id）。 */
  readonly workspaceId?: string
}

/**
 * 查询一条会话的宿主本地信息。
 *
 * 由装配方（`./index.ts`）注入；实现必须自己吞掉读取失败并返回 `undefined`，本模块再做一次
 * 超时保护。同步或异步都接受。
 */
export type RemoteSessionLookup = (
  sessionId: string,
) => RemoteSessionFacts | undefined | Promise<RemoteSessionFacts | undefined>

/**
 * 通知接收端：门面 sink 绑定到的那条远程连接。
 *
 * 只依赖连接 id、生命周期状态与 `notify`，自检可以注入假实现。
 */
export interface RemoteNotificationTarget {
  /** 进程内唯一的连接 id，仅用于日志。 */
  readonly id: string
  /** 连接生命周期状态；只有 `ready` 时协议 §8.1 才允许发通知。 */
  readonly state: RemoteConnectionState
  /**
   * 写一条通知帧。
   * @param method - 通知方法名，例如 `remote.taskCompleted`。
   * @param params - 通知参数。
   */
  notify(method: string, params?: Record<string, unknown>): void
}

/** {@link RemoteNotifications} 的构造参数。 */
export interface RemoteNotificationsOptions {
  /** 接收 `remote.*` 帧的连接。 */
  readonly target: RemoteNotificationTarget
  /** 宿主日志出口。 */
  readonly log: RemoteLogger
  /** 会话标题与所属项目的本地读；省略时标题一律退化成 sessionId。 */
  readonly lookupSession?: RemoteSessionLookup
  /** 宿主时钟（Unix 毫秒），默认 `Date.now`；自检注入固定时钟。 */
  readonly now?: () => number
}

/** 一帧裁剪后的可发送参数。 */
export interface FittedNotificationFrame {
  /** 可发送的协议参数；`undefined` 表示连必填字段都装不下，调用方必须丢弃整条通知。 */
  readonly params?: Record<string, unknown>
  /** 是否发生过裁剪（丢弃可选字段或缩短 `title`）。 */
  readonly dropped: boolean
}

/**
 * 一条 ready 连接上的 `remote.*` 推送通知发送端。
 *
 * 输入只有页面线的 `notify(method, params)` 观察流：`task.completed` 映射成 §8.2，
 * `interactions.changed` 映射成 §8.3（仅对新出现的 pending 交互各发一条），`session.event` 里的
 * `session/title` 映射成 §8.5（只覆盖标题变化）。其它方法原样忽略。
 */
export class RemoteNotifications {
  private readonly options: RemoteNotificationsOptions
  private closed = false
  private failureReported = false
  /** 本连接上已发过 `remote.approvalPending` 的交互 id：同一 id 只通知一次（协议 §8.1 不重放）。 */
  private readonly notifiedInteractions = new Set<string>()
  /** §8.5 要求同一 `sessionId` 内 `revision` 单调递增：每条连接按会话维护下一个序号。 */
  private readonly sessionRevisions = new Map<string, number>()

  /** @param options - 连接、日志、宿主本地会话读与时钟。 */
  constructor(options: RemoteNotificationsOptions) {
    this.options = options
  }

  /**
   * 观察一条页面线通知，按需追加对应的 `remote.*` 帧。
   *
   * 只有连接处于 `ready` 时才观察（协议 §8.1：仅已进入 ready 的连接接收 `remote.*`）；未 ready
   * 期间丢弃不消耗去重集合，同一条交互在 ready 后的快照里仍会被通知。同步部分
   * （`interactions.changed` / `session.event`）立即发送；`task.completed` 需要补全会话标题，
   * 异步构造。观察失败只记日志，不向页面线抛错。
   * @param method - 页面线通知方法名。
   * @param params - 页面线通知参数。
   * @returns 无返回值。
   */
  observe(method: string, params?: Record<string, unknown>): void {
    if (this.closed || this.options.target.state !== 'ready') return
    try {
      switch (method) {
        case 'task.completed':
          this.observeTaskCompleted(params)
          return
        case 'interactions.changed':
          this.observeInteractionsChanged(params)
          return
        case 'session.event':
          this.observeSessionEvent(params)
          return
        default:
          return
      }
    } catch (error) {
      this.logIgnored(method, error)
    }
  }

  /**
   * 停止观察并丢弃在途构造的通知。幂等。
   * @returns 无返回值。
   */
  dispose(): void {
    this.closed = true
    this.notifiedInteractions.clear()
    this.sessionRevisions.clear()
  }

  /**
   * 把页面线 `session.event` 里的 `session/title` 映射成 §8.5 `remote.sessionChanged`。
   *
   * 只覆盖标题变化：`archived` / `removed` 不在会话事件里（归档/删除由 `sessions.changed` 触发器
   * 表达，而它不带 payload），要发这两类字段得在宿主侧做目录 diff，本批不做（见 HANDOFF §9）。
   * @param params - 页面线 `session.event` 参数：`{ sessionId, event }`。
   */
  private observeSessionEvent(params: Record<string, unknown> | undefined): void {
    if (!isRecord(params)) return
    const sessionId = params['sessionId']
    if (typeof sessionId !== 'string' || sessionId.length === 0) return
    const event = params['event']
    if (!isRecord(event) || event['type'] !== 'session/title') return
    const data = event['data']
    if (!isRecord(data)) return
    const title = data['title']
    if (typeof title !== 'string' || title.length === 0) return
    const updatedAt = isNonNegativeInteger(event['time']) ? event['time'] : this.now()
    const revision = this.sessionRevisions.get(sessionId) ?? 0
    this.sessionRevisions.set(sessionId, revision + 1)
    const built = buildSessionChangedNotification({ sessionId, title, revision, updatedAt })
    const fitted = fitNotificationFrame('remote.sessionChanged', built.params, SESSION_CHANGED_FRAME_LIMIT_BYTES, [])
    if (fitted.params === undefined) {
      this.logIgnored('remote.sessionChanged', new Error(`${SESSION_CHANGED_FRAME_LIMIT_BYTES} 字节帧上限内装不下必填字段`))
      return
    }
    this.send('remote.sessionChanged', built.truncated || fitted.dropped ? { ...fitted.params, truncated: true } : fitted.params)
  }

  /** @param params - 页面线 `task.completed` 参数；形状不符时只记日志。 */
  private observeTaskCompleted(params: Record<string, unknown> | undefined): void {
    const notice = taskCompletedNoticeOf(params)
    if (notice === undefined) {
      this.logIgnored('task.completed', new Error('缺少 sessionId 或 turn/endSeq/preview 类型不符'))
      return
    }
    void this.deliverTaskCompleted(notice)
  }

  /**
   * 补全会话信息后发一条 `remote.taskCompleted`。
   * @param notice - 页面线 `task.completed` 参数。
   */
  private async deliverTaskCompleted(notice: TaskCompletedNotice): Promise<void> {
    const facts = await this.sessionFacts(notice.sessionId)
    // 等待本地读期间连接可能已经关闭或被替换：只在 ready 时落帧（协议 §8.1）。
    if (this.closed || this.options.target.state !== 'ready') return
    const built = buildTaskCompletedNotification(notice, facts, this.now())
    const fitted = fitNotificationFrame(
      'remote.taskCompleted',
      built.params,
      TASK_COMPLETED_FRAME_LIMIT_BYTES,
      ['summary', 'workspaceId'],
    )
    if (fitted.params === undefined) {
      this.logIgnored('remote.taskCompleted', new Error(`${TASK_COMPLETED_FRAME_LIMIT_BYTES} 字节帧上限内装不下必填字段`))
      return
    }
    this.send('remote.taskCompleted', built.truncated || fitted.dropped ? { ...fitted.params, truncated: true } : fitted.params)
  }

  /** @param params - 页面线 `interactions.changed` 快照；形状不符时只记日志。 */
  private observeInteractionsChanged(params: Record<string, unknown> | undefined): void {
    if (!isRecord(params)) {
      this.logIgnored('interactions.changed', new Error('快照不是对象'))
      return
    }
    const requests = params['requests']
    if (!Array.isArray(requests)) {
      this.logIgnored('interactions.changed', new Error('快照缺少 requests 数组'))
      return
    }
    for (const request of requests) {
      if (!isRecord(request)) continue
      const id = request['id']
      if (typeof id !== 'string' || id.length === 0) continue
      if (request['kind'] !== 'approval' && request['kind'] !== 'question') continue
      if (this.notifiedInteractions.has(id)) continue
      this.notifiedInteractions.add(id)
      const built = buildApprovalPendingNotification(request, this.now())
      if (built === undefined) {
        this.logIgnored('remote.approvalPending', new Error(`交互 ${id} 缺少 id/sessionId 或 kind 不可映射`))
        continue
      }
      const fitted = fitNotificationFrame(
        'remote.approvalPending',
        built.params,
        APPROVAL_PENDING_FRAME_LIMIT_BYTES,
        ['summary', 'toolName'],
      )
      if (fitted.params === undefined) {
        this.logIgnored('remote.approvalPending', new Error(`${APPROVAL_PENDING_FRAME_LIMIT_BYTES} 字节帧上限内装不下必填字段`))
        continue
      }
      this.send('remote.approvalPending', built.truncated || fitted.dropped ? { ...fitted.params, truncated: true } : fitted.params)
    }
  }

  /**
   * 读会话的宿主本地信息；失败、超时都退化成 `undefined`。
   * @param sessionId - 会话 id。
   * @returns 标题与所属项目，查不到时为 `undefined`。
   */
  private async sessionFacts(sessionId: string): Promise<RemoteSessionFacts | undefined> {
    const lookup = this.options.lookupSession
    if (lookup === undefined) return undefined
    const timedOut = Symbol('session-facts-timeout')
    let timer: NodeJS.Timeout | undefined
    try {
      const timeout = new Promise<typeof timedOut>((resolve) => {
        timer = setTimeout(() => {
          resolve(timedOut)
        }, SESSION_FACTS_TIMEOUT_MS)
        timer.unref()
      })
      // race 会同时接住 lookup 的迟到拒绝，不会留下未处理 rejection。
      const facts = await Promise.race([Promise.resolve(lookup(sessionId)), timeout])
      if (facts === timedOut) {
        this.options.log({
          level: 'warn',
          event: 'remote-notify-lookup-timeout',
          message: `读取会话信息超过 ${SESSION_FACTS_TIMEOUT_MS} ms，remote.taskCompleted 用 sessionId 兜底。`,
          fields: { connectionId: this.options.target.id, sessionId },
        })
        return undefined
      }
      return facts
    } catch (error) {
      this.options.log({
        level: 'warn',
        event: 'remote-notify-lookup-failed',
        message: '读取会话信息失败，remote.taskCompleted 用 sessionId 兜底。',
        fields: { connectionId: this.options.target.id, sessionId, error: describeRemoteError(error) },
      })
      return undefined
    } finally {
      if (timer !== undefined) clearTimeout(timer)
    }
  }

  /**
   * 写一帧 `remote.*`；写不出去只记一条 warn，不向页面线传播。
   * @param method - 通知方法名。
   * @param params - 协议参数（已裁剪到帧上限内）。
   */
  private send(method: string, params: Record<string, unknown>): void {
    const target = this.options.target
    if (this.closed || target.state !== 'ready') return
    try {
      target.notify(method, params)
      this.failureReported = false
      this.options.log({
        level: 'info',
        event: NOTIFY_SENT_EVENT,
        message: '已向手机追加一条远程推送通知。',
        fields: {
          connectionId: target.id,
          method,
          bytes: Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method, params }), 'utf8'),
          truncated: params['truncated'] === true,
        },
      })
    } catch (error) {
      if (this.failureReported) return
      this.failureReported = true
      this.options.log({
        level: 'warn',
        event: NOTIFY_FAILED_EVENT,
        message: '远程推送通知没有写出去；页面线通知不受影响。',
        fields: { connectionId: target.id, method, error: describeRemoteError(error) },
      })
    }
  }

  /**
   * 记录一条被忽略的页面线输入，便于发现门面形状漂移。
   * @param method - 页面线方法名或本模块构造的 `remote.*` 方法名。
   * @param error - 忽略原因。
   */
  private logIgnored(method: string, error: unknown): void {
    this.options.log({
      level: 'warn',
      event: NOTIFY_IGNORED_EVENT,
      message: '页面线通知没有映射成 remote.* 推送。',
      fields: { connectionId: this.options.target.id, method, error: describeRemoteError(error) },
    })
  }

  /** @returns 当前宿主时钟（Unix 毫秒）。 */
  private now(): number {
    return this.options.now?.() ?? Date.now()
  }
}

/**
 * 从页面线 `task.completed` 参数里读出映射需要的字段。
 * @param params - 页面线通知参数。
 * @returns 形状合法时返回观察结果；缺 `sessionId` 或字段类型不符时返回 `undefined`。
 */
function taskCompletedNoticeOf(
  params: Record<string, unknown> | undefined,
): TaskCompletedNotice | undefined {
  if (!isRecord(params)) return undefined
  const sessionId = params['sessionId']
  if (typeof sessionId !== 'string' || sessionId.length === 0) return undefined
  const turn = params['turn']
  const endSeq = params['endSeq']
  const preview = params['preview']
  if (turn !== undefined && !isNonNegativeInteger(turn)) return undefined
  if (endSeq !== undefined && !isNonNegativeInteger(endSeq)) return undefined
  if (preview !== undefined && typeof preview !== 'string') return undefined
  return {
    sessionId,
    ...(turn === undefined ? {} : { turn }),
    ...(endSeq === undefined ? {} : { endSeq }),
    ...(preview === undefined ? {} : { preview }),
  }
}

/**
 * 构造 §8.2 `remote.taskCompleted` 的协议参数（尚未做帧上限裁剪）。
 *
 * `status` 固定为 `completed`：运行时的 `task.completed` 只在已注册投影判定该轮
 * `reason.kind === 'completed'` 时发出（失败/取消不产生这条页面线通知），因此这里不是臆造
 * 状态，而是沿用触发条件的确定结论。
 * @param notice - 页面线 `task.completed` 观察。
 * @param facts - 会话标题与所属项目；查不到时标题退化成 `sessionId`。
 * @param completedAt - 宿主时钟（Unix 毫秒）。
 * @returns 协议参数与字段截断标记。
 */
export function buildTaskCompletedNotification(
  notice: TaskCompletedNotice,
  facts: RemoteSessionFacts | undefined,
  completedAt: number,
): { readonly params: Record<string, unknown>; readonly truncated: boolean } {
  const ordinal = notice.turn !== undefined
    ? String(notice.turn)
    : notice.endSeq !== undefined ? `end-${String(notice.endSeq)}` : 'unknown'
  const taskId = truncateText(`turn:${notice.sessionId}:${ordinal}`, NOTIFICATION_FIELD_LIMITS.id)
  const sessionId = truncateText(notice.sessionId, NOTIFICATION_FIELD_LIMITS.id)
  const titleSource = cleanInlineText(facts?.title ?? '') || notice.sessionId
  const title = truncateText(titleSource, NOTIFICATION_FIELD_LIMITS.title)
  const summarySource = cleanParagraph(notice.preview ?? '')
  const summary = summarySource === '' ? undefined : truncateText(summarySource, NOTIFICATION_FIELD_LIMITS.taskSummary)
  const workspaceId = facts?.workspaceId === undefined
    ? undefined
    : truncateText(cleanInlineText(facts.workspaceId), NOTIFICATION_FIELD_LIMITS.id)
  const truncated = taskId.truncated || sessionId.truncated || title.truncated
    || summary?.truncated === true || workspaceId?.truncated === true
  return {
    params: {
      taskId: taskId.text,
      sessionId: sessionId.text,
      ...(workspaceId === undefined || workspaceId.text === '' ? {} : { workspaceId: workspaceId.text }),
      title: title.text,
      status: 'completed',
      ...(notice.turn === undefined ? {} : { turn: notice.turn }),
      completedAt,
      ...(summary === undefined ? {} : { summary: summary.text }),
      ...(truncated ? { truncated: true } : {}),
    },
    truncated,
  }
}

/**
 * 构造 §8.3 `remote.approvalPending` 的协议参数（尚未做帧上限裁剪）。
 *
 * `kind` 的映射：审批 → `approval`；计划审核提问 → `plan`；其余提问 → `question`。计划审核的
 * 判定与 App 侧 `apps/android/runtime/question-carrier.mjs` 的 `planReviewOf` 保持一致（单题、
 * `intent.kind === 'plan-review'`、有 `detail`、非多选、选项里能对上 `intent.approve`）；这里只
 * 用它选择通知类别，判定从严只会让通知显示成普通提问，不影响页面上的交互渲染。
 * @param request - `interactions.changed` 快照里的一条 pending 请求。
 * @param createdAt - 宿主时钟（Unix 毫秒）；快照本身不带创建时间。
 * @returns 协议参数与字段截断标记；缺 id/sessionId 或类别不可映射时返回 `undefined`。
 */
export function buildApprovalPendingNotification(
  request: Record<string, unknown>,
  createdAt: number,
): { readonly params: Record<string, unknown>; readonly truncated: boolean } | undefined {
  const id = request['id']
  const sessionId = request['sessionId']
  if (typeof id !== 'string' || id.length === 0) return undefined
  if (typeof sessionId !== 'string' || sessionId.length === 0) return undefined
  let description: InteractionDescription | undefined
  if (request['kind'] === 'approval') description = describeApproval(request)
  else if (request['kind'] === 'question') description = describeQuestion(request)
  if (description === undefined) return undefined
  const interactionId = truncateText(id, NOTIFICATION_FIELD_LIMITS.id)
  const truncatedSessionId = truncateText(sessionId, NOTIFICATION_FIELD_LIMITS.id)
  const title = truncateText(description.title, NOTIFICATION_FIELD_LIMITS.title)
  const summary = description.summary === undefined
    ? undefined
    : truncateText(description.summary, NOTIFICATION_FIELD_LIMITS.approvalSummary)
  const toolName = description.toolName === undefined
    ? undefined
    : truncateText(cleanInlineText(description.toolName), NOTIFICATION_FIELD_LIMITS.id)
  const truncated = interactionId.truncated || truncatedSessionId.truncated || title.truncated
    || summary?.truncated === true || toolName?.truncated === true
  return {
    params: {
      interactionId: interactionId.text,
      sessionId: truncatedSessionId.text,
      kind: description.kind,
      title: title.text,
      ...(summary === undefined || summary.text === '' ? {} : { summary: summary.text }),
      ...(toolName === undefined || toolName.text === '' ? {} : { toolName: toolName.text }),
      createdAt,
      ...(truncated ? { truncated: true } : {}),
    },
    truncated,
  }
}

/** 一条 `session/title` 会话事件映射出的 §8.5 观察。 */
export interface SessionChangedNotice {
  /** 标题变化的会话 id。 */
  readonly sessionId: string
  /** 新的会话标题（会话事件里的原始标题）。 */
  readonly title: string
  /** 本连接上该会话的下一个 §8.5 `revision`（从 0 起单调递增）。 */
  readonly revision: number
  /** 该 `session/title` 事件的追加时间（Unix 毫秒）。 */
  readonly updatedAt: number
}

/**
 * 构造 §8.5 `remote.sessionChanged` 的协议参数（尚未做帧上限裁剪）。
 *
 * 只带标题变化能确定的字段：`sessionId` / `revision` / `title` / `updatedAt`；
 * `workspaceId`、`archived`、`removed` 是可选字段，本映射不知道（归档/删除不产生 `session/title`
 * 事件），因此不写。§8.5 的字段表没有 `truncated`，发生截断时仍按 §8.1 通则附加该标记，
 * 未知字段由 App 忽略。
 * @param notice - 从 `session/title` 事件读出的观察。
 * @returns 协议参数与字段截断标记。
 */
export function buildSessionChangedNotification(
  notice: SessionChangedNotice,
): { readonly params: Record<string, unknown>; readonly truncated: boolean } {
  const sessionId = truncateText(notice.sessionId, NOTIFICATION_FIELD_LIMITS.id)
  const title = truncateText(cleanInlineText(notice.title), NOTIFICATION_FIELD_LIMITS.title)
  const truncated = sessionId.truncated || title.truncated
  return {
    params: {
      sessionId: sessionId.text,
      revision: notice.revision,
      title: title.text,
      updatedAt: notice.updatedAt,
      ...(truncated ? { truncated: true } : {}),
    },
    truncated,
  }
}

/** 一条 pending 交互映射出的通知描述。 */
interface InteractionDescription {
  /** 协议 §8.3 的 `kind` 枚举值。 */
  readonly kind: 'approval' | 'question' | 'plan'
  /** 协议 §8.3 的 `title`（必填）。 */
  readonly title: string
  /** 协议 §8.3 的 `summary`（可选，一行纯文本）。 */
  readonly summary?: string
  /** 触发审批的工具名（仅审批有）。 */
  readonly toolName?: string
}

/**
 * 描述一条 pending 审批。
 * @param request - `interactions.changed` 里的审批记录（参数取自 `approval/request` 事件）。
 * @returns 通知描述；`toolName` 缺失时用通用标题。
 */
function describeApproval(request: Record<string, unknown>): InteractionDescription {
  const toolName = typeof request['toolName'] === 'string' ? request['toolName'] : undefined
  const reason = typeof request['reason'] === 'string' ? cleanParagraph(request['reason']) : ''
  return {
    kind: 'approval',
    title: cleanInlineText(toolName ?? '') || '需要授权',
    ...(reason === '' ? {} : { summary: reason }),
    ...(toolName === undefined ? {} : { toolName }),
  }
}

/**
 * 描述一条 pending 提问（含计划审核）。
 *
 * 摘要规则：普通提问只有在一次问了多道题时才给 `summary`（标题已经是第一题原文）；计划审核的
 * 正文可能含 Markdown 代码块，而 §8.3 要求 `summary` 是一行纯文本且不含代码块，因此不给摘要。
 * @param request - `interactions.changed` 里的提问记录。
 * @returns 通知描述；缺 `questions` 时用通用标题。
 */
function describeQuestion(request: Record<string, unknown>): InteractionDescription {
  const questions = Array.isArray(request['questions']) ? request['questions'] : []
  const first = questions.find(isRecord)
  const questionText = first === undefined ? '' : cleanInlineText(stringField(first, 'question') ?? '')
  const plan = isPlanReview(questions)
  return {
    kind: plan ? 'plan' : 'question',
    title: questionText || (plan ? '计划待确认' : '待回答的问题'),
    ...(!plan && questions.length > 1 ? { summary: `${questions.length} 个问题待回答` } : {}),
  }
}

/**
 * 判定一次提问是不是 App 侧的计划审核卡片。
 * @param questions - `user-questions/request` 的题目数组。
 * @returns 是否为计划审核。
 */
function isPlanReview(questions: readonly unknown[]): boolean {
  if (questions.length !== 1) return false
  const question = questions[0]
  if (!isRecord(question)) return false
  const intent = question['intent']
  if (!isRecord(intent) || intent['kind'] !== 'plan-review') return false
  if (question['detail'] === undefined || question['multiSelect'] === true) return false
  const options = Array.isArray(question['options']) ? question['options'] : []
  if (options.length > 2) return false
  const approve = intent['approve']
  return options.some(option => isRecord(option) && option['label'] === approve)
}

/**
 * 从门面 `library.catalog` 的返回值里取会话标题与所属项目。
 *
 * `library.catalog` 的形状（`apps/android/runtime/library.mjs`）：`sessions` 是 `session.list`
 * 的行，标题在 `row.projections.values.title`（`sessions.list` 的 sidebar 行也在 `row.title`
 * 兜底）；`workspaces` 是 `WorkspaceView`，`sessionIds` 给出会话归属。形状不符时返回
 * `undefined`，调用方用 sessionId 兜底。
 * @param catalog - 门面 `library.catalog` 的返回值。
 * @param sessionId - 目标会话 id。
 * @returns 找到的标题/所属项目；都找不到时返回 `undefined`。
 */
export function sessionFactsFromCatalog(
  catalog: unknown,
  sessionId: string,
): RemoteSessionFacts | undefined {
  if (!isRecord(catalog)) return undefined
  const title = catalogSessionTitle(catalog['sessions'], sessionId)
  const workspaceId = catalogWorkspaceId(catalog['workspaces'], sessionId)
  if (title === undefined && workspaceId === undefined) return undefined
  return {
    ...(title === undefined ? {} : { title }),
    ...(workspaceId === undefined ? {} : { workspaceId }),
  }
}

/**
 * 在 `library.catalog.sessions` 里找一条会话的标题。
 * @param sessions - `session.list` 行数组。
 * @param sessionId - 目标会话 id。
 * @returns 非空标题；找不到时为 `undefined`。
 */
function catalogSessionTitle(sessions: unknown, sessionId: string): string | undefined {
  if (!Array.isArray(sessions)) return undefined
  for (const row of sessions) {
    if (!isRecord(row)) continue
    if (row['sessionId'] !== sessionId && row['id'] !== sessionId) continue
    const direct = stringField(row, 'title')
    if (direct !== undefined) return direct
    const projections = row['projections']
    if (!isRecord(projections)) continue
    const values = projections['values']
    if (!isRecord(values)) continue
    const title = stringField(values, 'title')
    if (title !== undefined) return title
  }
  return undefined
}

/**
 * 在 `library.catalog.workspaces` 里找一条会话的所属项目。
 * @param workspaces - `WorkspaceView` 数组。
 * @param sessionId - 目标会话 id。
 * @returns 非空 workspace id；找不到时为 `undefined`。
 */
function catalogWorkspaceId(workspaces: unknown, sessionId: string): string | undefined {
  if (!Array.isArray(workspaces)) return undefined
  for (const workspace of workspaces) {
    if (!isRecord(workspace)) continue
    const sessionIds = workspace['sessionIds']
    if (!Array.isArray(sessionIds) || !sessionIds.includes(sessionId)) continue
    const workspaceId = stringField(workspace, 'workspaceId')
    if (workspaceId !== undefined) return workspaceId
  }
  return undefined
}

/**
 * 把一帧通知裁进字节上限：超限时按 `droppableFields` 顺序整体丢弃可选字段，仍超限则逐级缩短
 * 必填的 `title`；连必填字段都装不下时返回 `params: undefined`，调用方必须丢弃整条通知。
 *
 * 字节数按协议 §1.3 的口径计算：`Buffer.byteLength(JSON.stringify(frame), 'utf8')`，包含
 * `jsonrpc`、`method` 与 `params` 全部字段。
 * @param method - 通知方法名（`remote.taskCompleted` 等）。
 * @param params - 未裁剪的协议参数。
 * @param limitBytes - 该通知的帧上限（§8.2 为 8 KiB，§8.3 为 16 KiB）。
 * @param droppableFields - 可选字段的丢弃顺序。
 * @returns 可发送参数与是否裁剪；装不下时 `params` 为 `undefined`。
 */
export function fitNotificationFrame(
  method: string,
  params: Record<string, unknown>,
  limitBytes: number,
  droppableFields: readonly string[],
): FittedNotificationFrame {
  const byteLength = (candidate: Record<string, unknown>): number =>
    Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method, params: candidate }), 'utf8')
  if (byteLength(params) <= limitBytes) return { params, dropped: false }
  let pruned: Record<string, unknown> = { ...params }
  for (const field of droppableFields) {
    if (!(field in pruned)) continue
    pruned = Object.fromEntries(Object.entries(pruned).filter(([key]) => key !== field))
    if (byteLength(pruned) <= limitBytes) return { params: pruned, dropped: true }
  }
  const originalTitle = typeof pruned['title'] === 'string' ? pruned['title'] : ''
  for (const maxChars of TITLE_SHRINK_STEPS) {
    pruned = { ...pruned, title: truncateText(originalTitle, maxChars).text }
    if (byteLength(pruned) <= limitBytes) return { params: pruned, dropped: true }
  }
  return { dropped: true }
}

/**
 * 按字符（Unicode 码点）截断。
 * @param text - 原文本。
 * @param maxChars - 最大字符数。
 * @returns 截断后的文本与是否真的截断。
 */
function truncateText(text: string, maxChars: number): { readonly text: string; readonly truncated: boolean } {
  // 按码点切，避免把代理对拆成半个字符。
  const characters = Array.from(text)
  if (characters.length <= maxChars) return { text, truncated: false }
  return { text: characters.slice(0, maxChars).join(''), truncated: true }
}

/**
 * 把文本压成一行：控制字符换成空格、连续空白折叠、去首尾空白。
 * @param text - 原文本。
 * @returns 单行文本；输入全空白时为空字符串。
 */
function cleanInlineText(text: string): string {
  return text.replace(/[\u0000-\u001f\u007f]+/gu, ' ').replace(/\s+/gu, ' ').trim()
}

/**
 * 把结果摘要压成一段纯文本（§8.2 `summary` 的「单段纯文本」要求）。
 * @param text - 原文本。
 * @returns 单段文本；输入全空白时为空字符串。
 */
function cleanParagraph(text: string): string {
  return cleanInlineText(text)
}

/**
 * 读取对象里的非空字符串字段。
 * @param record - 源对象。
 * @param key - 字段名。
 * @returns 去掉空白的字符串；字段不存在、不是字符串或全空白时返回 `undefined`。
 */
function stringField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key]
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  return trimmed === '' ? undefined : trimmed
}

/**
 * 判断一个值是不是非数组对象。
 * @param value - 候选值。
 * @returns 是否为普通对象。
 */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * 判断一个值是不是非负安全整数。
 * @param value - 候选值。
 * @returns 是否为非负安全整数。
 */
function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}
