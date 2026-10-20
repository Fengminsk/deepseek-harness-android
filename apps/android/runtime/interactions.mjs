import { randomUUID } from 'node:crypto'
import { PendingQuestion, createWaterfallRequest } from './question-carrier.mjs'

const emptyUplink = { async *[Symbol.asyncIterator]() {} }
const waitActions = new Set(['holdFocus', 'releaseFocus', 'engage', 'takeTime'])

/** Android is one authenticated owner client of the existing Gateway event stream. */
export class AppInteractions {
  constructor(ctx, transport) {
    this.ctx = ctx
    this.transport = transport
    this.peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' })
    this.fetchHandler = ctx.connection.createSharedFetchHandler('/api')
    this.lifetime = new AbortController()
    this.records = new Map()
    this.events = new Map()
    this.revision = 0
    this.version = 0
    this.error = null
    this.started = null
    for (const event of ['session/event', 'agent/created', 'agent/disposed', 'agent/inbox/claimed', 'agent/inbox/discarded']) {
      ctx.on(event, () => {
        queueMicrotask(() => {
          if (!this.lifetime.signal.aborted) this.reconcile()
        })
      })
    }
  }

  start() {
    if (this.started) return this.started
    const ready = Promise.withResolvers()
    this.started = ready.promise
    this.done = this.consume(ready).catch(error => {
      ready.reject(error)
      if (!this.lifetime.signal.aborted) {
        this.error = '审批连接中断，请重新启动 Agent 服务；未确认的请求不会自动通过。'
        for (const record of [...this.records.values()]) this.remove(record)
        this.publish()
        console.error('Android interaction carrier failed:', error)
      }
    })
    return this.started
  }

  async consume(ready) {
    const stream = await this.ctx.typertGateway.wireStream.open(
      '$events', { args: {} }, emptyUplink, this.peer, this.lifetime.signal)
    for await (const frame of stream) {
      if (frame.type === 'ready') {
        this.clientId = frame.clientId
        this.reconcile()
        ready.resolve()
      } else if (frame.type === 'cancel') {
        const record = this.events.get(frame.eventId)
        if (record) this.detach(record)
      } else if (frame.type === 'waterfall') {
        await this.receive(frame)
      }
    }
    if (!this.lifetime.signal.aborted) throw new Error('Android interaction stream ended')
  }

  async outcome(eventId, outcome) {
    const response = await this.fetchHandler.fetch(new Request('http://android.internal/api/$events/result', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: 'client-request', rpcId: randomUUID(), method: '$events/result',
        payload: { args: { clientId: this.clientId, eventId, outcome } } }),
      signal: this.lifetime.signal,
    }), this.peer)
    if (!response.ok) throw new Error(`Interaction carrier returned ${response.status}`)
    const envelope = await response.json()
    if (!envelope.result.ok) {
      const error = new Error(envelope.result.error.message)
      error.code = envelope.result.error.code
      throw error
    }
  }

  async receive(frame) {
    if (frame.event !== 'approval/request' && frame.event !== 'user-questions/request') {
      await this.outcome(frame.eventId, { kind: 'next' })
      return
    }
    const request = frame.request
    const sessionId = String(frame.agentId)
    const question = frame.event === 'user-questions/request'
    const callId = question ? request.wait?.callId : request.callId
    const id = question && callId ? PendingQuestion.keyOf(sessionId, callId) : frame.eventId
    const previous = this.records.get(id)
    if (previous) this.remove(previous)
    const record = { id, version: ++this.version, sessionId, kind: question ? 'question' : 'approval',
      callId, eventId: frame.eventId, request, life: new AbortController(), sending: false }
    this.records.set(id, record)
    this.events.set(frame.eventId, record)
    if (!question) {
      this.publish()
      return
    }
    record.card = new PendingQuestion(sessionId, request.questions, callId)
    record.unsubscribe = record.card.subscribe(() => this.publish())
    let deadline
    if (request.wait?.timed === true && callId) {
      const claim = await this.ctx.typertGateway.stream({ namespace: 'userQuestions', method: 'attachWait',
        args: { agentId: sessionId, callId }, peer: this.peer,
        signal: AbortSignal.any([this.lifetime.signal, record.life.signal]) })
      const iterator = claim[Symbol.asyncIterator]()
      const opening = await iterator.next()
      if (opening.done) {
        await this.outcome(frame.eventId, { kind: 'next' })
        this.detach(record)
        return
      }
      deadline = Date.now() + opening.value.remainingMs
      record.claimDone = iterator.next().catch(error => {
        if (!record.life.signal.aborted && !this.lifetime.signal.aborted) {
          this.error = `提问等待连接中断：${error.message}`
          this.publish()
        }
      })
    }
    const waterfall = createWaterfallRequest(deadline, record.life.signal,
      channel => record.card.detachWaterfall(channel))
    record.card.attachWaterfall(waterfall.channel)
    record.delivery = waterfall.result.then(
      value => this.complete(record, { kind: 'result', value }),
      error => {
        if (record.life.signal.aborted || this.lifetime.signal.aborted) return
        return this.complete(record, { kind: 'rejected', error: {
          name: error.name, message: error.message, code: error.code,
        } })
      },
    )
    // Submission observes this same promise; background countdown failures remain visible.
    record.delivery.catch(error => {
      this.error = `提问答复未确认：${error.message}`
      this.publish()
    })
    this.publish()
  }

  async complete(record, outcome) {
    if (!record.eventId) return false
    const eventId = record.eventId
    await this.outcome(eventId, outcome)
    const accepted = this.events.get(eventId) === record
    if (accepted) this.detach(record)
    return accepted
  }

  detach(record) {
    if (record.eventId) this.events.delete(record.eventId)
    record.eventId = undefined
    record.life.abort()
    if (record.kind === 'approval' || !record.callId) this.remove(record)
    else {
      this.reconcile()
    }
    this.publish()
  }

  remove(record) {
    if (record.eventId) this.events.delete(record.eventId)
    this.records.delete(record.id)
    record.life.abort()
    record.unsubscribe?.()
    record.card?.close()
  }

  reconcile() {
    const continued = new Map()
    const projections = this.ctx.get('sessionProjections')
    for (const agent of this.ctx.agents.roots()) {
      const rows = projections?.stateOf(agent.session, 'userQuestions')?.questions.active ?? []
      const queued = new Set([...agent.inbox.nextStep, ...agent.inbox.nextTurn]
        .filter(message => message.source.kind === 'user-question-reply').map(message => message.source.callId))
      for (const row of rows) {
        if (row.state !== 'continued' || queued.has(row.callId)) continue
        const id = PendingQuestion.keyOf(String(agent.id), row.callId)
        continued.set(id, row)
        let record = this.records.get(id)
        if (!record) {
          record = { id, version: ++this.version, sessionId: String(agent.id), kind: 'question',
            callId: row.callId, request: { questions: row.questions }, life: new AbortController(), sending: false,
            card: new PendingQuestion(String(agent.id), row.questions, row.callId) }
          record.unsubscribe = record.card.subscribe(() => this.publish())
          this.records.set(id, record)
        }
        if (!record.eventId) {
          record.card.attachRpc({ answer: answer => this.ctx.typertGateway.invoke({
            namespace: 'userQuestions', method: 'answer', args: { agentId: record.sessionId, callId: record.callId, answer },
            peer: this.peer,
          }) })
          record.card.setState('continued')
        }
      }
    }
    for (const record of [...this.records.values()]) {
      if (record.kind === 'question' && record.callId && !record.eventId && !continued.has(record.id)) this.remove(record)
    }
    this.publish()
  }

  project(record) {
    const { id, version, sessionId, kind, callId } = record
    if (kind === 'question') {
      const state = record.card?.snapshot()
      return { id, version, sessionId, kind, callId, questions: record.request.questions,
        state: state?.state ?? 'open', waitState: state?.waitState, countdown: state?.countdown }
    }
    let toolCall
    const agent = this.ctx.agents.list().find(agent => String(agent.id) === sessionId)
    if (agent && callId) {
      for (let seq = agent.session.seq - 1; seq >= 0; seq--) {
        const event = agent.session.eventAt(seq)
        if (event?.type === 'tool/call' && event.data.callId === callId) { toolCall = event.data; break }
      }
    }
    return { id, version, sessionId, kind, ...record.request, toolCall }
  }

  snapshot() {
    return { revision: this.revision, requests: [...this.records.values()].map(record => this.project(record)), error: this.error }
  }

  publish() {
    this.revision++
    this.transport.notify('interactions.changed', this.snapshot())
  }

  find(params) {
    const record = this.records.get(params.id)
    return record?.version === params.version ? record : undefined
  }

  async reply(params) {
    const record = this.find(params)
    if (!record) return { accepted: false, requestStillPending: false, message: '该请求已处理或失效' }
    if (record.sending) throw new Error('答复正在提交，请等待状态更新，勿重复提交')
    try {
      if (record.kind === 'approval') {
        if (!['allowed-once', 'rejected'].includes(params.response)) throw new TypeError('请选择原始批准或拒绝选项')
      } else validateAnswers(record.request.questions, params.response)
    } catch (error) {
      return { accepted: false, requestStillPending: true, message: error.message }
    }
    record.sending = true
    try {
      if (record.kind === 'approval') {
        const accepted = await this.complete(record, { kind: 'result', value: params.response })
        return { accepted, requestStillPending: false }
      }
      const delivery = record.delivery
      await record.card.answer(params.response)
      if (delivery && await delivery === false) return { accepted: false, requestStillPending: false }
      this.remove(record)
      this.publish()
      return { accepted: true, requestStillPending: false }
    } catch (error) {
      // A local carrier failure may follow submission. Do not automatically replay it.
      this.error = `答复结果未确认：${error.message}`
      this.publish()
      throw error
    }
  }

  wait(params) {
    const record = this.find(params)
    if (!record || record.kind !== 'question') return { accepted: false, requestStillPending: false }
    if (!waitActions.has(params.action)) throw new TypeError('Unknown question wait action')
    record.card[params.action]()
    return { accepted: true, requestStillPending: true }
  }

  async close() {
    this.lifetime.abort()
    for (const record of [...this.records.values()]) this.remove(record)
    await this.peer.dispose()
    await this.done
  }
}

/** Validate native wire answers against the exact labels and question ids displayed. */
function validateAnswers(questions, response) {
  if (!response || !Array.isArray(response.answers) || response.answers.length !== questions.length) {
    throw new TypeError('请为每个问题提交一个答复')
  }
  const ids = new Set()
  for (const answer of response.answers) {
    const question = questions.find(question => question.id === answer.id)
    if (!question || ids.has(answer.id) || !Array.isArray(answer.selected)) throw new TypeError('问题答复标识无效')
    ids.add(answer.id)
    const labels = new Set((question.options ?? []).map(option => option.label))
    if (answer.selected.some(label => typeof label !== 'string' || !labels.has(label))
      || new Set(answer.selected).size !== answer.selected.length
      || (answer.custom !== undefined && typeof answer.custom !== 'string')) throw new TypeError('答复包含未提供的选项')
    if (!question.multiSelect && (answer.selected.length > 1 || (answer.selected.length && answer.custom))) {
      throw new TypeError('单选问题请选择一个选项或填写自定义答复')
    }
  }
}
