/**
 * Desktop notification observer for the Plan-B relay.
 *
 * It watches desktop-process events that the remote-host child cannot see
 * (sessions owned by the desktop DSH) and posts the same page-line notifications
 * the child would have observed (`task.completed`). The answerable approval
 * stream is handled by desktop-interactions.ts. The remote-host child maps
 * notifications through its existing §8 pipeline,
 * so payload shaping, limits, and per-connection dedupe stay in one owner.
 *
 * Observer failures are contained: every callback is wrapped, and a failing
 * post only logs a warning. No token, message text, or session content is
 * logged.
 * @module @deepseek-ai/dsh-device-interconnect/host/desktop-notifications
 */

import type { Context } from '@deepseek-ai/cordis'
import { onDesktopEvent } from './desktop-events.ts'

/** One page-line notification posted to the remote host's control API. */
export interface RelayNotification {
  /** Page-line method name, e.g. `task.completed`. */
  readonly method: string
  /** Page-line params; shapes match the runtime facade notifications. */
  readonly params: Record<string, unknown>
}

/** Options of one desktop notification observer. */
export interface DesktopNotificationsOptions {
  /** Plugin context in the desktop Host process; events are observed globally. */
  readonly ctx: Context
  /** Posts one batch to the remote-host control API; failures are logged only. */
  readonly post: (notifications: readonly RelayNotification[]) => Promise<void>
  /** Lifecycle log sink. */
  readonly logger: {
    info(message: string, ...rest: unknown[]): void
    warn(message: string, ...rest: unknown[]): void
  }
  /** Clock; defaults to `Date.now`. */
  readonly now?: () => number
}

/** Agent status event shape observed from the desktop Host. */
interface AgentStatusEvent {
  readonly agent: DesktopAgent
  readonly status: string
}

/** The subset of a desktop Agent this observer reads. */
interface DesktopAgent {
  readonly id: unknown
  readonly session: { readonly id: unknown; readonly header?: { readonly origin?: string } }
  readonly inbox?: { readonly nextTurn?: readonly unknown[]; readonly nextStep?: readonly unknown[] }
}

/** One running completion candidate. */
interface RunningTask {
  readonly agent: DesktopAgent
  turn: number | undefined
  startSeq: number | undefined
  hasStep: boolean
  preview: string | undefined
  completedEndSeq: number | undefined
}

/** The subset of one session event this observer reads. */
interface DesktopSessionEvent {
  readonly seq: number
  readonly time?: number
  readonly type: string
  readonly data?: Record<string, unknown>
}

/** Session-like value on `session/event`. */
interface DesktopSession {
  readonly id: unknown
}

/** Strip markup/control characters from a short completion preview. */
export function completionPreview(content: unknown): string | undefined {
  if (!Array.isArray(content)) return undefined
  const first = content
    .filter(part => typeof part === 'object' && part !== null
      && (part as { type?: unknown }).type === 'text'
      && typeof (part as { text?: unknown }).text === 'string')
    .map(part => (part as { text: string }).text)
    .join(' ')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/^(?:[#>*-]+\s*)+/, '')
    .trim()
  if (first === '') return undefined
  const sentence = /^.{1,100}?[。！？!?]/u.exec(first)?.[0] ?? first.slice(0, 100)
  return sentence.trim() || undefined
}

/** Observe desktop task completions, posting page-line notifications. */
export class DesktopNotifications {
  private readonly options: DesktopNotificationsOptions
  private readonly running = new Map<string, RunningTask>()
  private readonly disposers: (() => void)[] = []
  private started = false
  private closed = false

  /** @param options - context, post callback, and logging. */
  constructor(options: DesktopNotificationsOptions) {
    this.options = options
  }

  /** Subscribe to desktop events; idempotent. */
  start(): void {
    if (this.started || this.closed) return
    this.started = true
    const ctx = this.options.ctx
    this.disposers.push(
      onDesktopEvent(ctx, 'agent/status', value => { this.onAgentStatus(value as AgentStatusEvent) }),
      onDesktopEvent(ctx, 'session/event', (session, event) => {
        this.onSessionEvent(session as DesktopSession, event as DesktopSessionEvent)
      }),
      onDesktopEvent(ctx, 'agent/disposed', value => { this.forget((value as { agent?: unknown }).agent) }),
      onDesktopEvent(ctx, 'agent/error', value => { this.forget((value as { agent?: unknown }).agent) }),
    )
  }

  /** Stop observing; idempotent. */
  stop(): void {
    this.closed = true
    for (const dispose of this.disposers.splice(0).reverse()) {
      try {
        dispose()
      } catch {
        // Observer disposal must not escape into the desktop Host.
      }
    }
    this.running.clear()
  }

  /** Drop one agent's running record. */
  private forget(agent: unknown): void {
    if (agent === undefined || agent === null) return
    const id = agentId(agent as DesktopAgent)
    if (id !== undefined && this.running.get(id)?.agent === agent) this.running.delete(id)
  }

  /** Track whole-driver completion like the runtime's AppTaskCompletion. */
  private onAgentStatus(value: AgentStatusEvent): void {
    if (this.closed) return
    try {
      const agent = value.agent
      if (agent === undefined || agent.session.header?.origin === 'subagent') return
      const sessionId = agentId(agent)
      if (sessionId === undefined) return
      if (value.status === 'running') {
        if (this.running.get(sessionId)?.agent !== agent) {
          this.running.set(sessionId, { agent, hasStep: false, turn: undefined, startSeq: undefined, preview: undefined, completedEndSeq: undefined })
        }
        return
      }
      if (value.status !== 'idle') return
      const record = this.running.get(sessionId)
      if (record === undefined || record.agent !== agent) return
      this.running.delete(sessionId)
      if (!record.hasStep) return
      if ((agent.inbox?.nextTurn?.length ?? 0) > 0 || (agent.inbox?.nextStep?.length ?? 0) > 0) return
      void this.deliverCompletion(record)
    } catch (error) {
      this.warn('agent status observer failed', error)
    }
  }

  /** Read the registered projection and post a completion only for a completed turn. */
  private async deliverCompletion(record: RunningTask): Promise<void> {
    try {
      const projections = getOptional<{
        snapshot(session: unknown, keys: readonly string[]): { values?: { pocketTasks?: { turns?: readonly ProjectedTurn[] } } }
      }>(this.options.ctx, 'sessionProjections')
      // The durable turn/end event is already observed on this desktop owner.
      // A missing or late pocketTasks projection must not suppress the notice.
      let endSeq = record.completedEndSeq
      if (endSeq === undefined && projections !== undefined) {
        try {
          const snapshot = projections.snapshot(record.agent.session, ['pocketTasks'])
          const turn = snapshot.values?.pocketTasks?.turns?.at(-1)
          if (turn !== undefined && turn.turn === record.turn && turn.seq === record.startSeq
            && turn.reason?.kind === 'completed' && Number.isSafeInteger(turn.endSeq)) {
            endSeq = turn.endSeq
          }
        } catch {
          // The observed completed event remains authoritative.
        }
      }
      if (!Number.isSafeInteger(endSeq)) return
      const goals = getOptional<{ get(agent: unknown): { phase?: string } | undefined }>(this.options.ctx, 'goals')
      const goal = goals?.get(record.agent)
      if (goal !== undefined && goal.phase !== 'complete') return
      await this.publish([{
        method: 'task.completed',
        params: {
          sessionId: agentId(record.agent),
          turn: record.turn,
          endSeq,
          ...(record.preview === undefined ? {} : { preview: record.preview }),
        },
      }])
    } catch (error) {
      this.warn('task completion relay failed', error)
    }
  }

  /** Track turn/step/assistant events and surface desktop approvals. */
  private onSessionEvent(session: DesktopSession, event: DesktopSessionEvent): void {
    if (this.closed) return
    try {
      const sessionId = typeof session.id === 'string' ? session.id : String(session.id)
      const data = event.data
      // Gateway waterfall owns answerable approval snapshots. Session events
      // lack the version and event id required to answer the original request.
      if (event.type === 'approval/asked') return
      const record = this.running.get(sessionId)
      if (record === undefined || agentId(record.agent) !== sessionId) return
      if (event.type === 'turn/start') {
        record.turn = typeof data?.['turn'] === 'number' ? data['turn'] : undefined
        record.startSeq = event.seq
        record.hasStep = false
        record.preview = undefined
        record.completedEndSeq = undefined
      } else if (event.type === 'step/start' && record.turn === data?.['turn']) {
        record.hasStep = true
      } else if (event.type === 'assistant/message' && record.turn === data?.['turn']) {
        const message = data?.['message']
        const content = typeof message === 'object' && message !== null
          ? (message as { content?: unknown }).content
          : undefined
        record.preview = completionPreview(content) ?? record.preview
      } else if (event.type === 'turn/end' && record.turn === data?.['turn']
        && data?.['reason'] !== undefined
        && typeof data['reason'] === 'object'
        && (data['reason'] as { kind?: unknown }).kind === 'completed') {
        record.completedEndSeq = event.seq
      }
    } catch (error) {
      this.warn('session event observer failed', error)
    }
  }

  /** Post a batch; a missing control plane or no ready connection only logs. */
  private async publish(notifications: readonly RelayNotification[]): Promise<void> {
    try {
      await this.options.post(notifications)
    } catch (error) {
      this.warn('notification relay post failed', error)
    }
  }

  /** Log a warning with no event content. */
  private warn(message: string, error: unknown): void {
    this.options.logger.warn(
      'device-interconnect: %s: %s',
      message,
      error instanceof Error ? error.message : String(error),
    )
  }
}

/** Projected turn row read by completion delivery. */
interface ProjectedTurn {
  readonly turn: number
  readonly seq: number
  readonly endSeq?: number
  readonly reason?: { readonly kind?: string }
}

/** Agent/session id as a string. */
function agentId(agent: DesktopAgent): string | undefined {
  const id = agent.session.id
  if (typeof id === 'string') return id
  if (typeof id === 'number') return String(id)
  return undefined
}

/** Optional service read that never throws when the service is absent. */
function getOptional<T>(ctx: Context, name: string): T | undefined {
  try {
    return ctx.get(name, false) as T | undefined
  } catch {
    return undefined
  }
}
