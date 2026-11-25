/** Answerable desktop interactions exposed to the paired phone.
 *
 * The desktop process owns the Agent and its Gateway waterfall. A child-process
 * `interactions.list/reply` sees a different Agent set, so it cannot answer a
 * desktop approval. This observer holds a second owner event client; the first
 * valid answer from the desktop UI or phone settles the same original request.
 */
import { randomUUID } from 'node:crypto'
import type { Context } from '@deepseek-ai/cordis'
import type { RelayNotification } from './desktop-notifications.ts'

type RecordValue = Record<string, unknown>
interface PendingInteraction {
  readonly id: string
  readonly eventId: string
  readonly sessionId: string
  readonly version: number
  readonly kind: 'approval' | 'question'
  readonly request: RecordValue
  sending: boolean
}

/**
 * Approval and question requests the paired phone may answer.
 *
 * Pending requests live in memory only: a restart drops them, and the desktop
 * UI remains an equal answerer for every request. The first accepted answer
 * settles the request; stale and in-flight answers are refused.
 */
export class DesktopInteractions {
  private readonly records = new Map<string, PendingInteraction>()
  private readonly lifetime = new AbortController()
  private readonly ctx: Context
  private readonly post: (notifications: readonly RelayNotification[]) => Promise<void>
  private readonly warn: (message: string, error: unknown) => void
  private peer: { dispose(): Promise<unknown> } | undefined
  private clientId: string | undefined
  private revision = Date.now()
  private version = 0
  private started = false
  private ready = false
  private lastError: string | undefined

  /** @param options - desktop context, notification sink, and warning sink. */
  constructor(options: {
    ctx: Context
    post: (notifications: readonly RelayNotification[]) => Promise<void>
    warn: (message: string, error: unknown) => void
  }) {
    this.ctx = options.ctx
    this.post = options.post
    this.warn = options.warn
  }

  /** Open the stream of answerable desktop requests, retrying after a broken stream; idempotent. */
  start(): void {
    if (this.started) return
    this.started = true
    void this.run()
  }

  /**
   * Observer availability for the Settings page and the phone.
   * @returns readiness, the recorded stream failure when one exists, and the
   * pending request count.
   */
  diagnostics(): { ready: boolean; error?: string; pending: number } {
    return {
      ready: this.ready,
      ...(this.lastError === undefined ? {} : { error: this.lastError }),
      pending: this.records.size,
    }
  }

  /**
   * Close the stream and drop every pending request; idempotent. Dropped
   * requests stay answerable only from the desktop UI.
   */
  async stop(): Promise<void> {
    this.lifetime.abort()
    this.ready = false
    this.records.clear()
    await this.peer?.dispose()
  }

  private async run(): Promise<void> {
    while (!this.lifetime.signal.aborted) {
      try {
        await this.consume()
        if (!this.lifetime.signal.aborted) throw new Error('桌面审批事件流已结束')
      } catch (error) {
        if (this.lifetime.signal.aborted) break
        this.lastError = error instanceof Error ? error.message : String(error)
        this.warn('desktop interaction stream failed', error)
      } finally {
        this.ready = false
        this.clientId = undefined
        const peer = this.peer
        this.peer = undefined
        if (peer !== undefined) await peer.dispose().catch(() => {})
      }
      if (!this.lifetime.signal.aborted) {
        await new Promise(resolve => setTimeout(resolve, 1_000))
      }
    }
  }

  /**
   * Pending requests of one session, as `interactions.list` and
   * `interactions.changed` publish them.
   * @param sessionId - desktop session whose pending requests are read.
   * @returns the session id, the snapshot revision, and that session's pending
   * requests.
   */
  snapshot(sessionId: string): RecordValue {
    return {
      sessionId,
      revision: this.revision,
      requests: [...this.records.values()]
        .filter(record => record.sessionId === sessionId)
        .map(record => this.project(record)),
    }
  }

  /**
   * Submit one answer for a pending request.
   * @param params - `id`, `version`, `sessionId`, and `response`: an approval
   * `'allowed-once'`/`'rejected'` or a question `{ answers }` value.
   * @returns `accepted`, plus `requestStillPending` and a readable `message`
   * on refusal; it throws when the desktop channel cannot deliver the answer.
   */
  async reply(params: RecordValue): Promise<RecordValue> {
    const id = params['id']
    const version = params['version']
    const sessionId = params['sessionId']
    const record = typeof id === 'string' ? this.records.get(id) : undefined
    if (record === undefined || record.version !== version || record.sessionId !== sessionId) {
      return { accepted: false, requestStillPending: false, message: '该请求已处理或失效' }
    }
    if (record.sending) return { accepted: false, requestStillPending: true, message: '答复正在提交' }
    let value: unknown
    if (record.kind === 'approval') {
      if (params['response'] !== 'allowed-once' && params['response'] !== 'rejected') {
        return { accepted: false, requestStillPending: true, message: '请选择允许一次或拒绝' }
      }
      value = params['response']
    } else {
      const response = params['response']
      if (!isRecord(response) || !Array.isArray(response['answers'])) {
        return { accepted: false, requestStillPending: true, message: '请回答每个问题' }
      }
      value = response
    }
    record.sending = true
    try {
      await this.outcome(record.eventId, { kind: 'result', value })
      if (this.records.get(record.id) === record) {
        this.records.delete(record.id)
        this.publish(record.sessionId)
      }
      return { accepted: true, requestStillPending: false }
    } catch (error) {
      record.sending = false
      throw error
    }
  }

  private async consume(): Promise<void> {
    const connection = this.ctx.get('connection', false) as unknown as {
      createPeer(input: { principal: { kind: 'owner' }; interactions: 'answer' }): { dispose(): Promise<unknown> }
      createSharedFetchHandler(path: string): { fetch(request: Request, peer: unknown): Promise<Response> }
    } | undefined
    const gateway = this.ctx.get('typertGateway', false) as unknown as {
      wireStream: { open(method: string, params: RecordValue, uplink: AsyncIterable<never>, peer: unknown, signal: AbortSignal): Promise<AsyncIterable<RecordValue>> }
    } | undefined
    if (connection === undefined || gateway === undefined) throw new Error('desktop Gateway services unavailable')
    const peer = this.peer = connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' })
    const uplink: AsyncIterable<never> = { async *[Symbol.asyncIterator]() { /* read-only event stream */ } }
    const stream = await gateway.wireStream.open('$events', { args: {} }, uplink, peer, this.lifetime.signal)
    for await (const frame of stream) {
      if (this.lifetime.signal.aborted) break
      if (frame['type'] === 'ready' && typeof frame['clientId'] === 'string') {
        this.clientId = frame['clientId']
        this.ready = true
        this.lastError = undefined
      } else if (frame['type'] === 'waterfall') {
        this.receive(frame)
      } else if (frame['type'] === 'cancel' && typeof frame['eventId'] === 'string') {
        this.remove(frame['eventId'])
      }
    }
  }

  private receive(frame: RecordValue): void {
    const event = frame['event']
    if (event !== 'approval/request' && event !== 'user-questions/request') return
    const eventId = frame['eventId']
    const sessionId = frame['agentId']
    const request = frame['request']
    if (typeof eventId !== 'string' || typeof sessionId !== 'string' || !isRecord(request)) return
    const record: PendingInteraction = {
      id: eventId, eventId, sessionId, version: ++this.version,
      kind: event === 'approval/request' ? 'approval' : 'question',
      request, sending: false,
    }
    this.records.set(eventId, record)
    this.publish(sessionId)
  }

  private remove(eventId: string): void {
    const record = this.records.get(eventId)
    if (record === undefined) return
    this.records.delete(eventId)
    this.publish(record.sessionId)
  }

  private project(record: PendingInteraction): RecordValue {
    const base: RecordValue = {
      id: record.id,
      version: record.version,
      sessionId: record.sessionId,
      kind: record.kind,
      ...(typeof record.request['callId'] === 'string' ? { callId: record.request['callId'] } : {}),
    }
    if (record.kind === 'question') {
      return { ...base, questions: record.request['questions'] ?? [] }
    }
    const toolCall = this.toolCall(record.sessionId, record.request['callId'])
    return {
      ...base,
      ...(typeof record.request['toolName'] === 'string' ? { toolName: record.request['toolName'] } : {}),
      ...(typeof record.request['reason'] === 'string' ? { reason: record.request['reason'] } : {}),
      ...(toolCall === undefined ? {} : { toolCall }),
    }
  }

  private toolCall(sessionId: string, callId: unknown): RecordValue | undefined {
    if (typeof callId !== 'string') return undefined
    const agents = this.ctx.get('agents', false) as unknown as {
      get(id: string): { session?: { seq: number; eventAt(seq: number): { type?: string; data?: RecordValue } | undefined } } | undefined
    } | undefined
    const session = agents?.get(sessionId)?.session
    if (session === undefined) return undefined
    for (let seq = session.seq - 1; seq >= Math.max(0, session.seq - 500); seq--) {
      const event = session.eventAt(seq)
      if (event?.type !== 'tool/call' || event.data?.['callId'] !== callId) continue
      try {
        if (JSON.stringify(event.data).length <= 16_000) return event.data
      } catch { /* only serializable tool calls can cross the relay */ }
      return undefined
    }
    return undefined
  }

  private publish(sessionId: string): void {
    this.revision = Math.max(Date.now(), this.revision + 1)
    void this.post([{ method: 'interactions.changed', params: this.snapshot(sessionId) }])
      .catch(error => this.warn('desktop interaction notification failed', error))
  }

  private async outcome(eventId: string, outcome: RecordValue): Promise<void> {
    const clientId = this.clientId
    const peer = this.peer
    if (clientId === undefined || peer === undefined) throw new Error('桌面审批连接尚未就绪')
    const connection = this.ctx.get('connection', false) as unknown as {
      createSharedFetchHandler(path: string): { fetch(request: Request, peer: unknown): Promise<Response> }
    }
    const handler = connection.createSharedFetchHandler('/api')
    const response = await handler.fetch(new Request('http://desktop.internal/api/$events/result', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: 'client-request', rpcId: randomUUID(), method: '$events/result',
        payload: { args: { clientId, eventId, outcome } },
      }),
      signal: this.lifetime.signal,
    }), peer)
    if (!response.ok) throw new Error(`桌面审批通道返回 ${response.status}`)
    const envelope = await response.json() as { result?: { ok?: boolean; error?: { message?: string } } }
    if (envelope.result?.ok !== true) throw new Error(envelope.result?.error?.message ?? '桌面未确认这次答复')
  }
}

function isRecord(value: unknown): value is RecordValue {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
