import { randomUUID } from 'node:crypto'
import { z } from 'zod'
import { SessionId } from '@deepseek-ai/dsh-session'

const reasonSchema = z.object({ kind: z.string() }).passthrough()
const turnSchema = z.object({
  turn: z.number().int().nonnegative(), seq: z.number().int().nonnegative(),
  time: z.number(), endSeq: z.number().int().nonnegative().optional(),
  endTime: z.number().optional(), reason: reasonSchema.optional(),
})
const droppedSchema = z.object({
  seq: z.number().int().nonnegative(), time: z.number(),
  count: z.number().int().positive(), target: z.enum(['next-turn', 'next-step']),
})
const jobSchema = z.object({
  seq: z.number().int().nonnegative(), time: z.number(), jobId: z.string(), owner: z.string(),
  kind: z.string(), label: z.string(), startedAt: z.number(), finishedAt: z.number().optional(),
  status: z.string().optional(), detail: z.string().optional(),
})
const stateSchema = z.object({ turns: z.array(turnSchema), dropped: z.array(droppedSchema), jobs: z.array(jobSchema) })

/** Durable turn outcomes and canceled input counts, folded only by the Session projection registry. */
export const taskProjectionDefinition = {
  key: 'pocketTasks',
  stateVersion: 1,
  stateSchema,
  init: () => ({ turns: [], dropped: [], jobs: [] }),
  apply(state, event) {
    switch (event.type) {
      case 'turn/start':
        if (state.turns.at(-1)?.turn >= event.data.turn) return state
        return { ...state, turns: [...state.turns, {
          turn: event.data.turn, seq: event.seq, time: event.time,
        }] }
      case 'turn/end': {
        const last = state.turns.at(-1)
        if (!last || last.turn !== event.data.turn || last.reason) return state
        return { ...state, turns: [...state.turns.slice(0, -1), {
          ...last, endSeq: event.seq, endTime: event.time, reason: event.data.reason,
        }] }
      }
      case 'agent/inbox/spliced': {
        const { outcome, removedCount, inserted, target } = event.data
        if (outcome !== 'canceled' || !(removedCount > 0) || inserted.length > 0) return state
        return { ...state, dropped: [...state.dropped, {
          seq: event.seq, time: event.time, count: removedCount, target,
        }] }
      }
      case 'job/registered':
        if (state.jobs.some(job => job.jobId === event.data.jobId)) return state
        return { ...state, jobs: [...state.jobs, {
          seq: event.seq, time: event.time, jobId: event.data.jobId, owner: event.data.owner,
          kind: event.data.kind, label: event.data.label, startedAt: event.data.startedAt,
        }] }
      case 'job/settled': {
        const index = state.jobs.findIndex(job => job.jobId === event.data.jobId)
        const job = { seq: index < 0 ? event.seq : state.jobs[index].seq, time: event.data.startedAt,
          jobId: event.data.jobId, owner: event.data.owner, kind: event.data.kind,
          label: event.data.label, startedAt: event.data.startedAt, finishedAt: event.data.finishedAt,
          status: event.data.status, ...(event.data.detail === undefined ? {} : { detail: event.data.detail }) }
        return { ...state, jobs: index < 0 ? [...state.jobs, job] : state.jobs.with(index, job) }
      }
      default: return state
    }
  },
  wire: { viewSchema: stateSchema, view: state => state },
}

function identity(value) {
  if (typeof value !== 'string' || !value.trim()) throw new TypeError('sessionId must be a non-empty string')
  return SessionId(value)
}

function preview(content) {
  let text = ''
  for (const part of content ?? []) {
    if (part.type === 'text') text += `${text ? ' ' : ''}${part.text.slice(0, 160)}`
    if (text.length >= 160) break
  }
  return text.replace(/\s+/g, ' ').trim().slice(0, 160)
}

function ending(reason) {
  switch (reason?.kind) {
    case 'completed': return 'completed'
    case 'error': return 'failed'
    case 'aborted': return reason.reason?.kind === 'user' ? 'cancelled' : 'interrupted'
    case 'interrupted': return 'interrupted'
    case 'blocked': return 'blocked'
    case 'max-tokens': return 'limited'
    case 'forked': return 'forked'
    default: return 'unknown'
  }
}

/** Read models only: Agent, inbox and Session owners retain all execution and cancellation. */
export class AppTasks {
  constructor(ctx, transport, { interactions = () => ({ requests: [] }) } = {}) {
    this.ctx = ctx
    this.transport = transport
    this.interactions = interactions
    this.epoch = randomUUID()
    this.revision = 0
    this.last = undefined
    this.closed = false
    this.errors = new Map()
    this.disposers = [
      ctx.sessionProjections.register(taskProjectionDefinition),
      ctx.sessionProjections.onChanged((_session, key) => {
        if (['pocketTasks', 'inbox', 'title'].includes(key)) this.publish()
      }),
      ctx.on('agent/status', ({ agent, status }) => {
        if (status === 'running') this.errors.delete(String(agent.id))
        this.publish()
      }),
      ctx.on('agent/disposed', () => this.publish()),
      ctx.on('api-session/error', (id, error) => {
        this.errors.set(String(id), error)
        this.publish()
      }),
    ]
    this.jobs = ctx.get('jobs')
    if (this.jobs) this.disposers.push(this.jobs.events.subscribe({ owners: 'all' }, event => {
      if (event.type !== 'output') this.publish()
    }))
  }

  interactionsChanged() { this.publish() }

  blocking(sessionId) {
    return this.interactions().requests.filter(request => request.sessionId === sessionId
      && (request.kind === 'approval' || request.kind === 'question' && request.state === 'open'))
  }

  liveRecord(agent) {
    const sessionId = String(agent.id)
    const blockingRequests = this.blocking(sessionId).length
    const queued = agent.inbox.nextTurn.length + agent.inbox.nextStep.length
    const failed = this.errors.has(sessionId)
    const status = agent.status === 'running'
      ? blockingRequests > 0 ? 'waiting' : 'running'
      : queued > 0 ? 'queued' : failed ? 'failed' : 'idle'
    return { sessionId, status, queued, blockingRequests,
      ...(failed ? { error: this.errors.get(sessionId) } : {}) }
  }

  /** Synchronous current-process baseline; a missing job provider stays explicitly unknown. */
  summary() {
    const active = this.ctx.agents.list().map(agent => this.liveRecord(agent)).filter(row => row.status !== 'idle')
    const jobs = this.jobs?.snapshot()
    const summary = {
      running: active.filter(row => row.status === 'running').length,
      queued: active.reduce((count, row) => count + row.queued, 0),
      waiting: active.reduce((count, row) => count + row.blockingRequests, 0),
      failed: active.filter(row => row.status === 'failed').length,
      backgroundJobs: jobs === undefined ? null
        : jobs.filter(job => job.status === 'running' || job.status === 'stopping').length,
    }
    const value = { summary, active }
    const fingerprint = JSON.stringify(value)
    if (fingerprint !== this.last) { this.last = fingerprint; this.revision++ }
    return { epoch: this.epoch, revision: this.revision, ...value }
  }

  publish() {
    if (!this.closed) {
      const snapshot = this.summary()
      this.transport.notify('runtime.tasks.changed', { ...snapshot, revision: ++this.revision })
    }
  }

  project(sessionId, snapshot, observation) {
    const values = snapshot?.values ?? {}
    const tasks = values.pocketTasks
    const agent = this.ctx.agents.get(SessionId(sessionId))
    const live = agent ? this.liveRecord(agent) : undefined
    const open = tasks?.turns.at(-1)
    const turns = (tasks?.turns ?? []).map(turn => ({
      id: `turn:${turn.seq}`, kind: 'turn', ...turn,
      status: turn.reason ? ending(turn.reason)
        : live && agent.status === 'running' && turn === open ? live.status
        : observation === 'live' || observation === 'sequenced' ? 'interrupted' : 'unverified',
      cancellable: !turn.reason && turn === open && agent?.status === 'running',
    }))
    const dropped = (tasks?.dropped ?? []).map(item => ({
      id: `dropped:${item.seq}`, kind: 'discarded', ...item, status: 'cancelled', cancellable: false,
    }))
    const liveJobs = this.jobs?.snapshot()
    const jobs = (tasks?.jobs ?? []).map(job => {
      const activeJob = liveJobs?.find(item => item.id === job.jobId && item.owner === sessionId)
      return { ...job, jobKind: job.kind, kind: 'job', id: `job:${job.jobId}`,
        status: job.status === 'killed' ? 'cancelled' : job.status ?? activeJob?.status
          ?? (observation === 'cached' ? 'unverified' : 'unconfirmed'),
        error: job.detail, cancellable: false }
    })
    const pending = Object.entries(values.inbox ?? {}).flatMap(([target, messages]) => messages.map(message => ({
      id: `queued:${message.id}`, kind: 'queued', itemId: message.id, target,
      prompt: preview(message.content), status: agent ? 'queued' : 'suspended',
      // A stale cache never authorizes an inbox mutation.
      cancellable: !!agent && observation === 'live',
    })))
    return { sessionId, title: values.title?.title ?? sessionId, observation,
      asOfSeq: snapshot?.asOfSeq ?? null, historyAvailable: tasks !== undefined,
      pending, history: [...turns, ...dropped, ...jobs].sort((a, b) => b.seq - a.seq),
      ...(live ? { live } : {}) }
  }

  /** Listing uses current projections or checkpoint hints. It never activates an Agent or opens a cold log. */
  async list(params = {}) {
    const offset = params.offset ?? 0
    const limit = params.limit ?? 20
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 50) {
      throw new TypeError('Invalid task page')
    }
    const stored = await this.ctx.sessionPersistence.list()
    const headers = new Map(stored.map(row => [String(row.header.id), row.header]))
    for (const agent of this.ctx.agents.list()) headers.set(String(agent.id), agent.session.header)
    const ordered = [...headers].sort((a, b) => b[1].createdAt - a[1].createdAt || a[0].localeCompare(b[0]))
    const sessions = ordered.slice(offset, offset + limit).map(([id, header]) => {
      const session = this.ctx.sessions.get(SessionId(id))
      const snapshot = session ? this.ctx.sessionProjections.snapshot(session, ['pocketTasks', 'inbox', 'title'])
        : this.ctx.get('sessionProjectionCache')?.cachedSnapshot(header, ['pocketTasks', 'inbox', 'title'])
      const row = this.project(id, snapshot, session ? 'live' : snapshot ? 'cached' : 'unavailable')
      return { ...row, history: row.history.slice(0, 1) }
    })
    return { ...this.summary(), sessions, nextOffset: offset + limit < ordered.length ? offset + limit : null }
  }

  /** Explicit history read uses the original read-only Session observation and its crash-recovery projection. */
  async session(params) {
    const sessionId = identity(params.sessionId)
    const limit = params.limit ?? 50
    const beforeSeq = params.beforeSeq
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100
      || beforeSeq !== undefined && (!Number.isSafeInteger(beforeSeq) || beforeSeq < 0)) throw new TypeError('Invalid task history page')
    const snapshot = await this.ctx.sessionController.projections({ sessionId }, new AbortController().signal)
    if (snapshot === null) throw new Error('Session no longer exists')
    const row = this.project(String(sessionId), snapshot,
      this.ctx.sessions.get(sessionId) ? 'live' : snapshot.kind === 'sequenced' ? 'sequenced' : 'cached')
    const history = row.history.filter(item => beforeSeq === undefined || item.seq < beforeSeq)
    return { epoch: this.epoch, ...row, history: history.slice(0, limit),
      nextBeforeSeq: history.length > limit ? history[limit - 1].seq : null }
  }

  cancel(params) {
    return this.ctx.sessionController.cancel({ sessionId: identity(params.sessionId) })
  }

  removeQueued(params) {
    const sessionId = identity(params.sessionId)
    if (typeof params.itemId !== 'string' || !params.itemId) throw new TypeError('itemId must be a non-empty string')
    // Do not restore a dormant Agent as a side effect of a stale queue row.
    if (!this.ctx.agents.get(sessionId)) throw new Error('The queue is not attached; reopen the conversation before changing it')
    return this.ctx.sessionController.updateQueue({ sessionId, itemId: params.itemId, action: { kind: 'remove' } })
  }

  close() {
    if (this.closed) return
    this.closed = true
    for (const dispose of this.disposers.reverse()) dispose()
    this.errors.clear()
  }
}
