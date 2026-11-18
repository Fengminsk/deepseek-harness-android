/**
 * 桌面实时会话事件中继的宿主侧：把控制 API 校验过的批次广播成页面线通知，并把桌面
 * 运行状态合并进只读列表响应。
 *
 * 两条路径都只在「桌面插件经本机回环控制 API 主动投递」时工作，不读 Session、不写
 * Session，也不经过 §8 的 `remote.*` 通知线（那条线由 `desktop-notifications.ts` 的
 * 中继负责）；因此同一事件不会产生两条系统通知，页面线也保持与运行时自己发送时同形。
 *
 * 广播语义：
 * - `session.event` 的 `event` 用运行时同一个 {@link presentSessionEvent} 生成，
 *   App 按 `seq` 去重，所以与 `session.follow` 增量同时到达也不会重复；
 * - `session.status` 只在桌面 Agent 状态变化时到达，App 用它即时更新运行状态条；
 * - `sessions.changed` 是触发器型通知，让首页重新拉 `sessions.list` 点亮/熄灭运行标记，
 *   并按 {@link SESSIONS_CHANGED_THROTTLE_MS} 合并，避免子 Agent 抖动造成刷新风暴；
 * - 没有 ready 连接时整批安全丢弃；单条广播失败只记日志，不影响连接与宿主。
 *
 * 列表合并语义：只读响应照旧来自子进程门面，桌面进程的 `running` 状态作为补充字段合并；
 * 中继不可用、超时或响应形态不符时原样返回，App 仍可用 `readWindow`/`session.follow`
 * 校正，页面线事件不会绕过这些权威读。
 * @module @deepseek-ai/dsh-remote-host/session-events-relay
 */

import { presentSessionEvent } from '@minnnng/dsh-android-runtime/live-state.mjs'
import type { DesktopRelaySessionStatus } from './desktop-relay-client.ts'
import type { SessionEventsRelayInput, SessionStatusRelayEntry } from './pairing-page.ts'
import type { RemoteLogger } from './server.ts'

/** 列表合并读取桌面状态的等待上限；超时按「没有桌面状态」处理。 */
export const DESKTOP_FACTS_TIMEOUT_MS = 800

/** `sessions.changed` 的最短间隔，避免子 Agent 状态抖动引发首页刷新风暴。 */
export const SESSIONS_CHANGED_THROTTLE_MS = 500

/** 一条 ready 连接的广播出口；只有 `notify` 与生命周期状态。 */
export interface SessionEventBroadcastTarget {
  /** 连接生命周期状态；只有 `ready` 才允许写页面线通知。 */
  readonly state: string
  /**
   * 写一条页面线通知。
   * @param method - 通知方法名，例如 `session.event`。
   * @param params - 通知参数。
   */
  notify(method: string, params?: Record<string, unknown>): void
}

/** 一次广播的接受条数；用于自检与日志。 */
export interface SessionEventBroadcastCounts {
  /** 实际写出的 `session.event` 条数。 */
  readonly events: number
  /** 实际写出的 `session.status` 条数。 */
  readonly statuses: number
  /** 本批是否触发了 `sessions.changed`（1 表示已触发或已排队）。 */
  readonly sessionsChanged: number
}

/** {@link SessionEventBroadcaster} 的构造参数。 */
export interface SessionEventBroadcasterOptions {
  /** 宿主日志出口；广播失败按它记录，不含事件正文。 */
  readonly log?: RemoteLogger
  /** 宿主时钟（Unix 毫秒），默认 `Date.now`；自检注入固定时钟。 */
  readonly now?: () => number
  /** `sessions.changed` 合并窗口；默认 {@link SESSIONS_CHANGED_THROTTLE_MS}。 */
  readonly sessionsChangedThrottleMs?: number
  /** 事件 presentation；默认使用运行时同一个实现，自检可注入替身。 */
  readonly present?: (event: Record<string, unknown>) => unknown
}

/**
 * 把桌面中继批次广播到一条已认证连接。
 *
 * 去重按 session 维护：`seq` 不递增的事件丢弃；状态按 session 记忆运行态，只有运行
 * 态发生变化才触发 `sessions.changed`。实例随宿主启动创建、随宿主停止释放。
 */
export class SessionEventBroadcaster {
  private readonly log: RemoteLogger | undefined
  private readonly now: () => number
  private readonly throttleMs: number
  private readonly present: (event: Record<string, unknown>) => unknown
  private readonly lastSeq = new Map<string, number>()
  private readonly running = new Map<string, boolean>()
  private changedTarget: SessionEventBroadcastTarget | undefined
  private changedTimer: NodeJS.Timeout | undefined
  private lastChangedAt = Number.NEGATIVE_INFINITY
  private failureReported = false
  private closed = false

  /** @param options - 日志、时钟、合并窗口与 presentation 缝。 */
  constructor(options: SessionEventBroadcasterOptions = {}) {
    this.log = options.log
    this.now = options.now ?? Date.now
    this.throttleMs = options.sessionsChangedThrottleMs ?? SESSIONS_CHANGED_THROTTLE_MS
    this.present = options.present ?? presentSessionEvent
  }

  /**
   * 广播一批桌面中继数据；没有 ready 连接时整批丢弃。
   * @param input - 控制 API 校验过的批次。
   * @param target - 当前绑定连接；没有连接或未 ready 时为 undefined。
   * @returns 实际写出的条数。
   */
  broadcast(
    input: SessionEventsRelayInput,
    target: SessionEventBroadcastTarget | undefined,
  ): SessionEventBroadcastCounts {
    if (this.closed || target === undefined || target.state !== 'ready') {
      return { events: 0, statuses: 0, sessionsChanged: 0 }
    }
    let events = 0
    let statuses = 0
    let changed = false
    for (const group of input.sessions) {
      for (const event of group.events) {
        const seq = event['seq']
        if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 0) continue
        const previous = this.lastSeq.get(group.sessionId)
        if (previous !== undefined && seq <= previous) continue
        this.lastSeq.set(group.sessionId, seq)
        const presented = this.presentEvent(event)
        if (this.send(target, 'session.event', { sessionId: group.sessionId, event: presented })) events += 1
      }
    }
    for (const entry of input.statuses) {
      if (this.send(target, 'session.status', { sessionId: entry.sessionId, status: entry.status })) statuses += 1
      const runningNow = entry.status === 'running'
      if (this.running.get(entry.sessionId) !== runningNow) {
        this.running.set(entry.sessionId, runningNow)
        changed = true
      }
    }
    if (changed) {
      this.triggerSessionsChanged(target)
      return { events, statuses, sessionsChanged: 1 }
    }
    return { events, statuses, sessionsChanged: 0 }
  }

  /**
   * 停止合并计时器并拒绝后续广播；幂等。宿主停止时先调它再断开连接。
   * @returns 无返回值。
   */
  dispose(): void {
    this.closed = true
    if (this.changedTimer !== undefined) {
      clearTimeout(this.changedTimer)
      this.changedTimer = undefined
    }
    this.changedTarget = undefined
  }

  /** 生成 presentation；运行时实现自己会兜底，这里再兜一层防止替身实现抛错。 */
  private presentEvent(event: Record<string, unknown>): unknown {
    try {
      return this.present(event)
    } catch {
      return event
    }
  }

  /** 写一条通知；失败只记一次日志，绝不向调用方抛出。 */
  private send(target: SessionEventBroadcastTarget, method: string, params: Record<string, unknown>): boolean {
    try {
      target.notify(method, params)
      this.failureReported = false
      return true
    } catch (error) {
      if (!this.failureReported) {
        this.failureReported = true
        this.log?.({
          level: 'warn',
          event: 'session-events-relay-broadcast-failed',
          message: '页面线广播没有写到连接上（连接可能正在关闭）；事件已丢弃。',
          fields: { method, error: describeFailure(error) },
        })
      }
      return false
    }
  }

  /** 合并 `sessions.changed` 触发器；窗口内多次运行态变化只发一次。 */
  private triggerSessionsChanged(target: SessionEventBroadcastTarget): void {
    if (this.closed) return
    this.changedTarget = target
    const wait = Math.max(0, this.throttleMs - (this.now() - this.lastChangedAt))
    if (wait === 0) {
      this.flushSessionsChanged()
      return
    }
    if (this.changedTimer !== undefined) return
    this.changedTimer = setTimeout(() => {
      this.changedTimer = undefined
      this.flushSessionsChanged()
    }, wait)
    this.changedTimer.unref()
  }

  /** 写出一次 `sessions.changed`；目标已不可用时安全丢弃。 */
  private flushSessionsChanged(): void {
    const target = this.changedTarget
    this.changedTarget = undefined
    if (target === undefined || this.closed || target.state !== 'ready') return
    this.lastChangedAt = this.now()
    this.send(target, 'sessions.changed', {})
  }
}

/** 只读桌面状态的读取面；生产实现是 `DesktopRelayClient`，自检可注入替身。 */
export interface DesktopStatusReader {
  /**
   * 读取所有桌面会话的粗粒度状态。
   * @returns sessionId 到状态的映射；中继不可用时为空对象。
   */
  sessionsStatus(): Promise<Readonly<Record<string, DesktopRelaySessionStatus>>>
}

/** {@link withDesktopSessionFacts} 的选项。 */
export interface DesktopSessionFactsOptions {
  /** 读取桌面状态的等待上限，默认 {@link DESKTOP_FACTS_TIMEOUT_MS}。 */
  readonly timeoutMs?: number
  /** 读取失败时的日志出口；省略时不记日志。 */
  readonly log?: RemoteLogger
}

/**
 * 把桌面运行状态合并进 `sessions.list` / `tasks.session` 的响应。
 *
 * 只改补充字段：`sessions.list` 的行加 `running: true`；`tasks.session` 在缺少运行中
 * live 记录时补 `live`。其它方法、非数组/非对象响应、中继缺席、读取失败或超时都原样
 * 返回，绝不把一次补充读取变成请求失败。
 * @param method - 入站门面方法名。
 * @param params - 入站门面参数。
 * @param result - 子进程门面已经返回的结果。
 * @param reader - 桌面状态读取面；没有桌面中继描述文件时为 undefined。
 * @param options - 等待上限与失败日志出口。
 * @returns 合并后的结果，或原结果。
 */
export async function withDesktopSessionFacts(
  method: string,
  params: Record<string, unknown>,
  result: unknown,
  reader: DesktopStatusReader | undefined,
  options: DesktopSessionFactsOptions = {},
): Promise<unknown> {
  if (reader === undefined) return result
  const sessionId = method === 'tasks.session' ? sessionIdParam(params) : undefined
  if (method !== 'sessions.list' && sessionId === undefined) return result
  try {
    const statuses = await withDeadline(
      reader.sessionsStatus(),
      options.timeoutMs ?? DESKTOP_FACTS_TIMEOUT_MS,
    )
    if (method === 'sessions.list') return mergeDesktopRunningIntoSessionsList(result, statuses)
    if (sessionId === undefined) return result
    return mergeDesktopRunningIntoTasksSession(result, sessionId, statuses[sessionId])
  } catch (error) {
    options.log?.({
      level: 'warn',
      event: 'desktop-session-status-merge-failed',
      message: '读取桌面会话运行状态失败，列表按子进程自己的结果返回。',
      fields: { method, error: describeFailure(error) },
    })
    return result
  }
}

/**
 * 把桌面 `running` 状态合并进 `sessions.list` 的会话行。
 *
 * 行保持原顺序与全部原字段，只补顶层 `running: true`（App 的既有读法）；桌面中继没有
 * 报告该会话或状态不是 `running` 时不改这一行。没有任何行变化时返回原数组。
 * @param result - 门的 `sessions.list` 结果。
 * @param statuses - 桌面状态映射。
 * @returns 合并后的数组，或原值。
 */
export function mergeDesktopRunningIntoSessionsList(
  result: unknown,
  statuses: Readonly<Record<string, DesktopRelaySessionStatus>>,
): unknown {
  if (!Array.isArray(result)) return result
  let changed = false
  const rows: unknown[] = []
  for (const row of result) {
    if (!isRecord(row) || row['running'] === true) {
      rows.push(row)
      continue
    }
    const sessionId = sessionIdOfRow(row)
    if (sessionId === undefined || statuses[sessionId]?.status !== 'running') {
      rows.push(row)
      continue
    }
    changed = true
    rows.push({ ...row, running: true })
  }
  return changed ? rows : result
}

/**
 * 把桌面 `running` 状态合并进 `tasks.session` 应答的运行快照。
 *
 * 子进程没有该桌面 Agent 时 `live` 缺失或不是 running；此时按桌面状态补一条与
 * `apps/android/runtime/tasks.mjs` 同形的 live 记录，让会话页进入即显示运行状态。
 * @param result - 门的 `tasks.session` 结果。
 * @param sessionId - 该应答对应的会话 id。
 * @param status - 桌面报告的该会话状态。
 * @returns 合并后的对象，或原值。
 */
export function mergeDesktopRunningIntoTasksSession(
  result: unknown,
  sessionId: string,
  status: DesktopRelaySessionStatus | undefined,
): unknown {
  if (!isRecord(result) || status?.status !== 'running') return result
  const live = result['live']
  if (isRecord(live) && live['status'] === 'running') return result
  return {
    ...result,
    live: {
      sessionId,
      status: 'running',
      queued: status.queued ?? 0,
      blockingRequests: 0,
    },
  }
}

/**
 * 把桌面状态映射转换成控制 API 的状态条目，供连接建立后补发一次运行状态。
 * @param statuses - 桌面状态映射。
 * @returns 只包含 `running` / `idle` 的状态条目。
 */
export function desktopStatusEntries(
  statuses: Readonly<Record<string, DesktopRelaySessionStatus>>,
): readonly SessionStatusRelayEntry[] {
  const entries: SessionStatusRelayEntry[] = []
  for (const [sessionId, status] of Object.entries(statuses)) {
    if (status.status === 'running' || status.status === 'idle') entries.push({ sessionId, status: status.status })
  }
  return entries
}

/** 从 `tasks.session` 参数里取会话 id。 */
function sessionIdParam(params: Record<string, unknown>): string | undefined {
  const value = params['sessionId']
  return typeof value === 'string' && value !== '' ? value : undefined
}

/** 从 `sessions.list` 行里取会话 id（顶层 `sessionId` 优先，兼容 `header.id`）。 */
function sessionIdOfRow(row: Record<string, unknown>): string | undefined {
  const direct = row['sessionId']
  if (typeof direct === 'string' && direct !== '') return direct
  const header = row['header']
  if (!isRecord(header)) return undefined
  const id = header['id']
  return typeof id === 'string' && id !== '' ? id : undefined
}

/** 给一次补充读取加上限时，避免慢宿主拖住列表响应。 */
async function withDeadline<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_resolve, reject) => {
        // 不能 unref：进程没有其它任务时，上限计时器必须活到触发，否则会静默退出。
        timer = setTimeout(() => { reject(new Error('desktop session status read timed out')) }, timeoutMs)
      }),
    ])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

/** 记录守卫：门面结果是进程边界上的 JSON。 */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** 渲染宿主侧捕获值，不依赖 `Object#toString`。 */
function describeFailure(error: unknown): string {
  if (error instanceof Error) return error.message
  return typeof error === 'string' ? error : 'non-Error failure'
}
