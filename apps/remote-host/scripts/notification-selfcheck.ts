/**
 * 远程推送通知自检：证明 `../src/notifications.ts` 的字段映射、截断、帧上限、去重与降级成立。
 *
 * 运行：`node --import tsx/esm apps/remote-host/scripts/notification-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本零依赖、不写文件、不监听端口：假连接 + 假日志 +
 * 假会话查询，只驱动 `RemoteNotifications` 与它的纯函数。
 *
 * 覆盖：
 * 1. `task.completed` → `remote.taskCompleted` 的字段映射（标题/项目来自门面本地读，时间来自宿主时钟）；
 * 2. 查不到会话信息时标题退化成 sessionId；`taskId` 的确定性生成；
 * 3. 字段截断：标题 200、摘要 512、id 128，并置 `truncated: true`；
 * 4. 帧上限：真实字段上限下 8 KiB/16 KiB 帧内可达；`fitNotificationFrame` 先丢可选字段、再缩短
 *    `title`，装不下时返回 `undefined`（调用方必须丢弃，绝不发超限帧）；
 * 5. `interactions.changed` → `remote.approvalPending`：审批/提问/计划三种 kind、同一 interactionId
 *    只发一次、新增才发、重复快照不重发；
 * 6. `session.event` 里的 `session/title` → `remote.sessionChanged`（§8.5）：同一会话 revision 单调、
 *    跨会话独立计数、`updatedAt` 取事件时间、标题截断；
 * 7. 只有 ready 连接发送：未 ready 时丢弃且不消耗去重集合；
 * 8. 发送异常降级成一条 `remote-notify-failed` warn，不向页面线抛错；
 * 9. 无关页面线通知忽略、dispose 后不再发送、`library.catalog` 形状解析。
 *
 * @module @deepseek-ai/dsh-remote-host/scripts/notification-selfcheck
 */

import {
  APPROVAL_PENDING_FRAME_LIMIT_BYTES,
  buildApprovalPendingNotification,
  buildTaskCompletedNotification,
  fitNotificationFrame,
  NOTIFICATION_FIELD_LIMITS,
  RemoteNotifications,
  sessionFactsFromCatalog,
  SESSION_CHANGED_FRAME_LIMIT_BYTES,
  TASK_COMPLETED_FRAME_LIMIT_BYTES,
  type RemoteNotificationTarget,
  type RemoteSessionFacts,
  type RemoteSessionLookup,
} from '../src/notifications.ts'
import type { RemoteConnectionState, RemoteLogRecord } from '../src/server.ts'

/** 自检用的固定宿主时钟（Unix 毫秒）。 */
const SAMPLE_NOW = 1_700_000_000_000

/** 一条自检断言失败。 */
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

/** 一条落到假连接上的通知。 */
interface SentNotification {
  readonly method: string
  readonly params: Record<string, unknown>
}

/** 一条连接在自检里的替身：记录写出的通知，可注入写失败。 */
class FakeTarget implements RemoteNotificationTarget {
  readonly id = 'c-selfcheck'
  state: RemoteConnectionState = 'ready'
  readonly sent: SentNotification[] = []
  /** 接下来多少次 `notify` 抛错（模拟连接正在关闭）。 */
  failures = 0

  /**
   * 记录一条通知；注入失败时抛错。
   * @param method - 通知方法名。
   * @param params - 通知参数。
   */
  notify(method: string, params?: Record<string, unknown>): void {
    if (this.failures > 0) {
      this.failures -= 1
      throw new Error('socket 已关闭')
    }
    this.sent.push({ method, params: params ?? {} })
  }
}

/** 自检上下文：一条连接 + 日志 + 通知观察者。 */
interface Harness {
  readonly target: FakeTarget
  readonly logs: RemoteLogRecord[]
  readonly notifications: RemoteNotifications
}

/**
 * 建一套自检上下文。
 * @param options - 假会话查询与初始连接状态。
 * @returns 连接、日志与通知观察者。
 */
function harness(options: {
  readonly lookupSession?: RemoteSessionLookup
  readonly state?: RemoteConnectionState
} = {}): Harness {
  const target = new FakeTarget()
  if (options.state !== undefined) target.state = options.state
  const logs: RemoteLogRecord[] = []
  const notifications = new RemoteNotifications({
    target,
    log: (record) => {
      logs.push(record)
    },
    ...(options.lookupSession === undefined ? {} : { lookupSession: options.lookupSession }),
    now: () => SAMPLE_NOW,
  })
  return { target, logs, notifications }
}

/**
 * 等异步构造（会话查询 + race 的微任务）落帧。
 * @returns 下一轮事件循环后兑现。
 */
async function settle(): Promise<void> {
  await new Promise<void>((resolve) => {
    setImmediate(resolve)
  })
}

/**
 * 按协议 §1.3 的口径算一帧的字节数。
 * @param method - 通知方法名。
 * @param params - 通知参数。
 * @returns UTF-8 字节数（含 `jsonrpc`/`method`/`params`）。
 */
function frameBytes(method: string, params: Record<string, unknown>): number {
  return Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method, params }), 'utf8')
}

/**
 * 取最近一条指定方法的通知。
 * @param harnessed - 自检上下文。
 * @param method - 通知方法名。
 * @returns 通知，不存在时为 `undefined`。
 */
function lastOf(harnessed: Harness, method: string): SentNotification | undefined {
  return harnessed.target.sent.findLast(notification => notification.method === method)
}

let total = 0
let passed = 0
const failures: string[] = []

/**
 * 跑一项断言并打印结果。失败不中断后续项，但会计入退出码。
 * @param label - 中文说明。
 * @param run - 断言本体，返回通过时展示的细节。
 */
async function step(label: string, run: () => Promise<string> | string): Promise<void> {
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
 * 自检主体。
 * @returns 进程退出码：全过 0，有失败 1。
 */
async function main(): Promise<number> {
  await step('task.completed → remote.taskCompleted 字段映射', async () => {
    const context = harness({ lookupSession: () => ({ title: '生成标题', workspaceId: 'ws-1' }) })
    context.notifications.observe('task.completed', {
      sessionId: 's-1',
      turn: 3,
      endSeq: 42,
      preview: '已完成：收到\n第二行',
    })
    await settle()
    check(context.target.sent.length === 1, `期望 1 条 remote.* 帧，实际 ${context.target.sent.length} 条`)
    const notification = lastOf(context, 'remote.taskCompleted')
    check(notification !== undefined, '没有写出 remote.taskCompleted')
    const params = notification.params
    check(params['taskId'] === 'turn:s-1:3', `taskId 期望 turn:s-1:3，实际 ${String(params['taskId'])}`)
    check(params['sessionId'] === 's-1', `sessionId 不符：${String(params['sessionId'])}`)
    check(params['workspaceId'] === 'ws-1', `workspaceId 不符：${String(params['workspaceId'])}`)
    check(params['title'] === '生成标题', `title 不符：${String(params['title'])}`)
    check(params['status'] === 'completed', `status 不符：${String(params['status'])}`)
    check(params['turn'] === 3, `turn 不符：${String(params['turn'])}`)
    check(params['completedAt'] === SAMPLE_NOW, `completedAt 期望宿主时钟，实际 ${String(params['completedAt'])}`)
    check(params['summary'] === '已完成：收到 第二行', `summary 未压成单段纯文本：${String(params['summary'])}`)
    check(params['truncated'] === undefined, '没有截断时不应写 truncated')
    const bytes = frameBytes('remote.taskCompleted', params)
    check(bytes <= TASK_COMPLETED_FRAME_LIMIT_BYTES, `帧 ${bytes} 字节超过 §8.2 的 ${TASK_COMPLETED_FRAME_LIMIT_BYTES} 字节上限`)
    const sentLog = context.logs.find(record => record.event === 'remote-notify-sent')
    check(sentLog !== undefined, '没有记录 remote-notify-sent')
    check(sentLog.level === 'info', `remote-notify-sent 的级别期望 info，实际 ${sentLog.level}`)
    check(sentLog.fields?.method === 'remote.taskCompleted', 'remote-notify-sent 的 fields.method 不符')
    check(sentLog.fields?.bytes === bytes, `remote-notify-sent 的 fields.bytes 期望 ${bytes}，实际 ${String(sentLog.fields?.bytes)}`)
    return `taskId/turn/completedAt/title/workspaceId/summary 映射正确，${bytes} 字节（≤ ${TASK_COMPLETED_FRAME_LIMIT_BYTES}）`
  })

  await step('查不到会话信息时标题退化成 sessionId', async () => {
    const context = harness()
    context.notifications.observe('task.completed', { sessionId: 'session-xyz', endSeq: 7 })
    await settle()
    const notification = lastOf(context, 'remote.taskCompleted')
    check(notification !== undefined, '没有写出 remote.taskCompleted')
    check(notification.params['title'] === 'session-xyz', `title 期望 sessionId 兜底，实际 ${String(notification.params['title'])}`)
    check(notification.params['workspaceId'] === undefined, 'workspaceId 查不到时不应带该字段')
    check(notification.params['taskId'] === 'turn:session-xyz:end-7', `taskId 期望按 endSeq 生成，实际 ${String(notification.params['taskId'])}`)
    check(notification.params['turn'] === undefined, '页面线没有 turn 时不应伪造 turn')
    check(notification.params['summary'] === undefined, '页面线没有 preview 时不应带 summary')
    return 'title=sessionId、taskId=end-7、无 workspaceId/turn/summary 虚构字段'
  })

  await step('字段截断：标题 200、摘要 512、id 128 并置 truncated', async () => {
    const longSessionId = 's'.repeat(300)
    const context = harness({ lookupSession: () => ({ title: '标'.repeat(260), workspaceId: 'w'.repeat(300) }) })
    context.notifications.observe('task.completed', { sessionId: longSessionId, turn: 9, preview: '摘'.repeat(600) })
    await settle()
    const notification = lastOf(context, 'remote.taskCompleted')
    check(notification !== undefined, '没有写出 remote.taskCompleted')
    const params = notification.params
    check(params['truncated'] === true, '发生字段截断时必须置 truncated: true')
    const title = params['title']
    check(typeof title === 'string' && [...title].length === NOTIFICATION_FIELD_LIMITS.title, `title 期望 ${NOTIFICATION_FIELD_LIMITS.title} 字符，实际 ${String(title)}`)
    const summary = params['summary']
    check(typeof summary === 'string' && [...summary].length === NOTIFICATION_FIELD_LIMITS.taskSummary, `summary 期望 ${NOTIFICATION_FIELD_LIMITS.taskSummary} 字符`)
    const sessionId = params['sessionId']
    check(typeof sessionId === 'string' && [...sessionId].length === NOTIFICATION_FIELD_LIMITS.id, `sessionId 期望 ${NOTIFICATION_FIELD_LIMITS.id} 字符`)
    const workspaceId = params['workspaceId']
    check(typeof workspaceId === 'string' && [...workspaceId].length === NOTIFICATION_FIELD_LIMITS.id, `workspaceId 期望 ${NOTIFICATION_FIELD_LIMITS.id} 字符`)
    const taskId = params['taskId']
    check(typeof taskId === 'string' && [...taskId].length === NOTIFICATION_FIELD_LIMITS.id, `taskId 期望 ${NOTIFICATION_FIELD_LIMITS.id} 字符`)
    const bytes = frameBytes('remote.taskCompleted', params)
    check(bytes <= TASK_COMPLETED_FRAME_LIMIT_BYTES, `截断后帧仍有 ${bytes} 字节`)
    return `5 个字符串字段按 §8.2 截断，truncated=true，${bytes} 字节`
  })

  await step('帧上限：超限先丢可选字段、再缩短 title、装不下则丢弃', async () => {
    const notice = { sessionId: 's-1', turn: 1, preview: '摘'.repeat(NOTIFICATION_FIELD_LIMITS.taskSummary) }
    const facts: RemoteSessionFacts = { title: '标'.repeat(NOTIFICATION_FIELD_LIMITS.title), workspaceId: 'ws-1' }
    const built = buildTaskCompletedNotification(notice, facts, SAMPLE_NOW)
    const fullBytes = frameBytes('remote.taskCompleted', built.params)
    check(fullBytes <= TASK_COMPLETED_FRAME_LIMIT_BYTES, `各字段顶到上限时帧 ${fullBytes} 字节已超过 §8.2 上限`)
    const fitsFull = fitNotificationFrame('remote.taskCompleted', built.params, TASK_COMPLETED_FRAME_LIMIT_BYTES, ['summary', 'workspaceId'])
    check(fitsFull.dropped === false, '帧本身不超限时不应裁剪')
    check(fitsFull.params !== undefined, '帧本身不超限时参数不应被丢弃')
    // 人为把上限压到刚好装不下摘要：必须整体丢弃 summary，把 truncated 留给调用方置位。
    const squeezed = fitNotificationFrame('remote.taskCompleted', built.params, fullBytes - 1, ['summary', 'workspaceId'])
    check(squeezed.dropped === true, '超过上限时 dropped 应为 true')
    check(squeezed.params !== undefined, '只差 1 字节时应丢可选字段而不是丢整条通知')
    check(squeezed.params['summary'] === undefined, '超限裁剪没有按顺序先丢 summary')
    check(frameBytes('remote.taskCompleted', squeezed.params) <= fullBytes - 1, '裁剪后仍超过人为上限')
    // 连必填字段都装不下：返回 undefined，调用方必须丢弃（绝不发超限帧）。
    const impossible = fitNotificationFrame('remote.taskCompleted', built.params, 60, ['summary', 'workspaceId'])
    check(impossible.dropped === true, '装不下时 dropped 应为 true')
    check(impossible.params === undefined, '装不下时必须返回 undefined，不能返回超限参数')
    // §8.3 的 16 KiB 上限同样成立。
    const approval = buildApprovalPendingNotification({
      id: 'i'.repeat(NOTIFICATION_FIELD_LIMITS.id),
      sessionId: 's-1',
      kind: 'approval',
      toolName: 't'.repeat(NOTIFICATION_FIELD_LIMITS.id),
      reason: 'r'.repeat(NOTIFICATION_FIELD_LIMITS.approvalSummary),
    }, SAMPLE_NOW)
    check(approval !== undefined, '审批参数构造失败')
    const approvalFits = fitNotificationFrame('remote.approvalPending', approval.params, APPROVAL_PENDING_FRAME_LIMIT_BYTES, ['summary', 'toolName'])
    check(approvalFits.params !== undefined, '字段顶到上限的审批帧装不进 §8.3 上限')
    check(frameBytes('remote.approvalPending', approvalFits.params) <= APPROVAL_PENDING_FRAME_LIMIT_BYTES, '审批帧超过 §8.3 上限')
    return `顶格帧 ${fullBytes} 字节（≤ 8 KiB）；丢 summary 后 ${frameBytes('remote.taskCompleted', squeezed.params)} 字节；60 字节假上限返回 undefined`
  })

  await step('interactions.changed → remote.approvalPending（审批/提问/计划三种 kind）', async () => {
    const context = harness()
    context.notifications.observe('interactions.changed', {
      revision: 1,
      requests: [
        { id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh', reason: '越界写文件' },
        {
          id: 'question-1',
          sessionId: 's-2',
          kind: 'question',
          questions: [{ id: 'q1', question: '选哪个？' }, { id: 'q2', question: '第二个问题？' }],
        },
        {
          id: 'plan-1',
          sessionId: 's-3',
          kind: 'question',
          questions: [{
            id: 'p1',
            question: '是否批准这个计划？',
            detail: '第一步\n```\ncode\n```',
            intent: { kind: 'plan-review', approve: '批准' },
            options: [{ id: 'o1', label: '批准' }, { id: 'o2', label: '继续修改' }],
          }],
        },
      ],
    })
    check(context.target.sent.length === 3, `期望 3 条 remote.approvalPending，实际 ${context.target.sent.length} 条`)
    const byId = new Map(context.target.sent.map(notification => [notification.params['interactionId'], notification.params]))
    const approval = byId.get('approval-1')
    check(approval !== undefined, '缺少审批通知')
    check(approval['kind'] === 'approval', `审批 kind 不符：${String(approval['kind'])}`)
    check(approval['title'] === 'pwsh', `审批 title 期望工具名，实际 ${String(approval['title'])}`)
    check(approval['toolName'] === 'pwsh', `审批 toolName 不符：${String(approval['toolName'])}`)
    check(approval['summary'] === '越界写文件', `审批 summary 不符：${String(approval['summary'])}`)
    check(approval['createdAt'] === SAMPLE_NOW, `createdAt 期望宿主时钟，实际 ${String(approval['createdAt'])}`)
    check(approval['truncated'] === undefined, '未截断时不应写 truncated')
    const question = byId.get('question-1')
    check(question !== undefined, '缺少提问通知')
    check(question['kind'] === 'question', `提问 kind 不符：${String(question['kind'])}`)
    check(question['title'] === '选哪个？', `提问 title 期望第一题原文，实际 ${String(question['title'])}`)
    check(question['summary'] === '2 个问题待回答', `多题 summary 不符：${String(question['summary'])}`)
    const plan = byId.get('plan-1')
    check(plan !== undefined, '缺少计划审核通知')
    check(plan['kind'] === 'plan', `计划审核 kind 期望 plan，实际 ${String(plan['kind'])}`)
    check(plan['title'] === '是否批准这个计划？', `计划审核 title 不符：${String(plan['title'])}`)
    check(plan['summary'] === undefined, '计划审核正文可能含代码块，不应塞进 summary')
    for (const notification of context.target.sent) {
      const bytes = frameBytes('remote.approvalPending', notification.params)
      check(bytes <= APPROVAL_PENDING_FRAME_LIMIT_BYTES, `${String(notification.params['interactionId'])} 帧 ${bytes} 字节超过 §8.3 上限`)
    }
    return '审批=approval(title=toolName)、多题=question(title=首题)、计划审核=plan(无 summary)'
  })

  await step('interactions.changed 去重：同一 interactionId 只发一次、新增才发', async () => {
    const context = harness()
    const snapshot = (requests: readonly Record<string, unknown>[]): Record<string, unknown> => ({ revision: 1, requests })
    context.notifications.observe('interactions.changed', snapshot([
      { id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh' },
    ]))
    const afterFirst = context.target.sent.length
    check(afterFirst === 1, `首个快照应发 1 条，实际 ${afterFirst} 条`)
    // 同一交互的 version 变了（例如发送中状态刷新）也不重发。
    context.notifications.observe('interactions.changed', snapshot([
      { id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh', version: 2 },
    ]))
    const afterRepeat = context.target.sent.length
    check(afterRepeat === 1, `同一 interactionId 被重复通知：${afterRepeat} 条`)
    // 已处理（快照里消失）后再出现同样的 id：按 §8.1 不在本连接上重放，不重发。
    context.notifications.observe('interactions.changed', snapshot([]))
    context.notifications.observe('interactions.changed', snapshot([
      { id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh' },
    ]))
    const afterReappear = context.target.sent.length
    check(afterReappear === 1, '同一 interactionId 消失后重现又被通知了一次')
    // 新交互才发。
    context.notifications.observe('interactions.changed', snapshot([
      { id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh' },
      { id: 'question-2', sessionId: 's-2', kind: 'question', questions: [{ id: 'q', question: '新问题' }] },
    ]))
    const afterNew = context.target.sent.length
    check(afterNew === 2, `新增交互应再发 1 条，实际累计 ${afterNew} 条`)
    check(lastOf(context, 'remote.approvalPending')?.params['interactionId'] === 'question-2', '新增的交互 id 不符')
    return '1 → 重复(1) → 消失后重现(1) → 新增(2)，只对新增发送'
  })

  await step('只有 ready 连接发送，未 ready 的观察不消耗去重集合', async () => {
    const context = harness({ state: 'awaiting-hello' })
    context.notifications.observe('task.completed', { sessionId: 's-1', turn: 1 })
    context.notifications.observe('interactions.changed', {
      revision: 1,
      requests: [{ id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh' }],
    })
    await settle()
    const beforeReady = context.target.sent.length
    check(beforeReady === 0, `未 ready 的连接写入了 ${beforeReady} 条通知`)
    // ready 之后同一交互的快照仍应发送（未 ready 期间没有记进去重集合）。
    context.target.state = 'ready'
    context.notifications.observe('interactions.changed', {
      revision: 1,
      requests: [{ id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh' }],
    })
    const afterReady = context.target.sent.length
    check(afterReady === 1, `ready 后没有补发：${afterReady} 条`)
    return 'awaiting-hello 期间 0 条；ready 后同一 interactionId 正常发送 1 条'
  })

  await step('发送异常降级成一条 remote-notify-failed warn，不抛出', async () => {
    const context = harness()
    context.target.failures = 2
    context.notifications.observe('interactions.changed', {
      revision: 1,
      requests: [{ id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh' }],
    })
    context.notifications.observe('interactions.changed', {
      revision: 2,
      requests: [{ id: 'question-1', sessionId: 's-2', kind: 'question', questions: [{ id: 'q', question: '问题' }] }],
    })
    check(context.target.sent.length === 0, '注入写失败后仍记录到了通知')
    const warnings = context.logs.filter(record => record.event === 'remote-notify-failed' && record.level === 'warn')
    check(warnings.length === 1, `连续写失败应只记 1 条 warn，实际 ${warnings.length} 条`)
    check(warnings[0]?.fields?.method === 'remote.approvalPending', `warn 的 fields.method 不符：${String(warnings[0]?.fields?.method)}`)
    check(context.target.state === 'ready', '写失败不应改变连接状态')
    return '两次写失败只记 1 条 remote-notify-failed，observe 未抛错'
  })

  await step('无关页面线通知忽略、dispose 后不再发送', async () => {
    const context = harness()
    context.notifications.observe('session.event', { sessionId: 's-1', event: { type: 'turn/start' } })
    context.notifications.observe('sessions.changed', {})
    context.notifications.observe('notifications.error', { message: 'x' })
    await settle()
    check(context.target.sent.length === 0, `无关通知写出了 ${context.target.sent.length} 条 remote.* 帧`)
    context.notifications.dispose()
    context.notifications.observe('task.completed', { sessionId: 's-1', turn: 1 })
    context.notifications.observe('interactions.changed', {
      revision: 1,
      requests: [{ id: 'approval-1', sessionId: 's-1', kind: 'approval', toolName: 'pwsh' }],
    })
    context.notifications.observe('session.event', {
      sessionId: 's-1',
      event: { type: 'session/title', seq: 1, time: 1_700_000_100_000, data: { title: 'dispose 后' } },
    })
    await settle()
    check(context.target.sent.length === 0, `dispose 之后仍写出了 ${context.target.sent.length} 条通知`)
    return 'session.event/sessions.changed/notifications.error 均忽略；dispose 幂等且停止发送'
  })

  await step('session/title → remote.sessionChanged（§8.5 标题线）', async () => {
    const context = harness()
    const titleEvent = (sessionId: string, title: string, time: number): Record<string, unknown> => ({
      sessionId,
      event: { type: 'session/title', seq: 1, time, data: { title } },
    })
    context.notifications.observe('session.event', titleEvent('s-1', '第一个标题', 1_700_000_100_000))
    const firstCount = context.target.sent.length
    check(firstCount === 1, `首个标题事件应发 1 条，实际 ${firstCount} 条`)
    const first = lastOf(context, 'remote.sessionChanged')
    check(first !== undefined, '没有写出 remote.sessionChanged')
    check(first.params['sessionId'] === 's-1', `sessionId 不符：${String(first.params['sessionId'])}`)
    check(first.params['title'] === '第一个标题', `title 不符：${String(first.params['title'])}`)
    check(first.params['revision'] === 0, `首个标题的 revision 期望 0，实际 ${String(first.params['revision'])}`)
    check(first.params['updatedAt'] === 1_700_000_100_000, `updatedAt 期望事件时间，实际 ${String(first.params['updatedAt'])}`)
    check(first.params['workspaceId'] === undefined, '标题线不知道所属项目，不应伪造 workspaceId')
    check(first.params['archived'] === undefined && first.params['removed'] === undefined, '标题线不应伪造归档/删除状态')
    check(first.params['truncated'] === undefined, '未截断时不应写 truncated')
    // 同一会话第二次标题 revision 单调 +1；另一个会话的 revision 独立从 0 开始。
    context.notifications.observe('session.event', titleEvent('s-1', '第二个标题', 1_700_000_200_000))
    context.notifications.observe('session.event', titleEvent('s-2', '别的会话', 1_700_000_300_000))
    const changes = context.target.sent.filter(notification => notification.method === 'remote.sessionChanged')
    check(changes.length === 3, `三次标题事件应发 3 条，实际 ${changes.length} 条`)
    check(changes[1]?.params['revision'] === 1, `s-1 第二个标题 revision 期望 1，实际 ${String(changes[1]?.params['revision'])}`)
    check(changes[2]?.params['revision'] === 0, `s-2 首个标题 revision 期望 0，实际 ${String(changes[2]?.params['revision'])}`)
    // 非 title 的会话事件不产生 §8.5 帧。
    context.notifications.observe('session.event', {
      sessionId: 's-1',
      event: { type: 'turn/start', seq: 3, time: 1_700_000_400_000, data: { turn: 2 } },
    })
    const afterOtherEvent = context.target.sent.length
    check(afterOtherEvent === 3, `非标题会话事件写出了 ${afterOtherEvent - 3} 条帧`)
    // 超长标题按 §8.5 的 200 字符上限截断并置 truncated。
    context.notifications.observe('session.event', titleEvent('s-1', '标'.repeat(300), 1_700_000_500_000))
    const truncated = context.target.sent.at(-1)
    check(truncated !== undefined && truncated.method === 'remote.sessionChanged', '超长标题没有写出 remote.sessionChanged')
    const truncatedTitle = truncated.params['title']
    check(typeof truncatedTitle === 'string' && [...truncatedTitle].length === NOTIFICATION_FIELD_LIMITS.title, `超长标题期望截到 ${NOTIFICATION_FIELD_LIMITS.title} 字符`)
    check(truncated.params['truncated'] === true, '标题被截断时应按 §8.1 通则置 truncated')
    const bytes = frameBytes('remote.sessionChanged', truncated.params)
    check(bytes <= SESSION_CHANGED_FRAME_LIMIT_BYTES, `帧 ${bytes} 字节超过 §8.5 的 ${SESSION_CHANGED_FRAME_LIMIT_BYTES} 字节上限`)
    return `标题线字段正确（revision 0→1 单调、跨会话独立、updatedAt=事件时间），${bytes} 字节（≤ 4 KiB）`
  })

  await step('library.catalog 形状解析：标题/workspaceId/坏形状', async () => {
    const catalog = {
      workspaces: [
        { workspaceId: 'ws-1', path: 'D:\\x', title: '项目', sessionIds: ['s-1'], createdAt: '', updatedAt: '' },
        { workspaceId: 'ws-2', path: 'D:\\y', title: '别的项目', sessionIds: ['s-2'], createdAt: '', updatedAt: '' },
      ],
      sessions: [
        { sessionId: 's-1', updatedAt: 1, projections: { kind: 'cached', asOfSeq: 3, values: { title: '缓存标题' } } },
        { sessionId: 's-2', updatedAt: 2, title: '列表行标题' },
        { sessionId: 's-3', updatedAt: 3 },
      ],
      archivedSessionIds: [],
      pinnedSessionIds: [],
    }
    const first = sessionFactsFromCatalog(catalog, 's-1')
    check(first?.title === '缓存标题', `缓存投影标题不符：${String(first?.title)}`)
    check(first?.workspaceId === 'ws-1', `workspaceId 不符：${String(first?.workspaceId)}`)
    const second = sessionFactsFromCatalog(catalog, 's-2')
    check(second?.title === '列表行标题', `列表行标题兜底不符：${String(second?.title)}`)
    check(second?.workspaceId === 'ws-2', `第二个会话的 workspaceId 不符：${String(second?.workspaceId)}`)
    check(sessionFactsFromCatalog(catalog, 's-3') === undefined, '没有标题与项目的会话不应返回事实')
    check(sessionFactsFromCatalog(catalog, 'missing') === undefined, '不存在的会话不应返回事实')
    check(sessionFactsFromCatalog(undefined, 's-1') === undefined, '非对象 catalog 不应抛错')
    check(sessionFactsFromCatalog({ sessions: 'x', workspaces: 3 }, 's-1') === undefined, '坏字段形状不应抛错')
    return '缓存投影标题 + workspace.sessionIds 归属正确；缺字段/坏形状返回 undefined'
  })

  console.log('')
  if (failures.length > 0) {
    console.log(`FAIL  ${passed}/${total} 项通过，${failures.length} 项失败`)
    for (const failure of failures) console.log(`  - ${failure}`)
    return 1
  }
  console.log(`PASS  ${passed}/${passed} 项全部通过（字段映射 + 截断 + 帧上限 + 去重 + ready + 降级）`)
  return 0
}

// 兜底看门狗：任何一步把句柄留在事件循环里时，不能让自检一直挂着。
const watchdog = setTimeout(() => {
  console.error('FAIL  远程推送通知自检在 60 s 内没有结束，判定有定时器或 Promise 未收尾。')
  process.exit(1)
}, 60_000)
watchdog.unref()

process.exitCode = await main().catch((error: unknown) => {
  console.error(`FAIL  自检主体抛出：${describeError(error)}`)
  return 1
})
