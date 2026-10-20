const modes = new Set(['one-shot', 'continuable', 'unknown'])

function badRequest(message) {
  return Object.assign(new TypeError(message), { code: 'gateway/bad-request' })
}

function identity(value, label) {
  if (typeof value !== 'string' || !value.trim() || value.length > 512) {
    throw badRequest(`${label} must be a non-empty string of at most 512 characters`)
  }
  return value
}

function addressOf(value) {
  if (!value || !modes.has(value.mode)) throw badRequest('A session-backed subagent address is required')
  return {
    parentSessionId: identity(value.parentSessionId, 'parentSessionId'),
    childSessionId: identity(value.childSessionId, 'childSessionId'),
    mode: value.mode,
  }
}

function pageSize(value = 50) {
  if (!Number.isSafeInteger(value) || value < 1 || value > 100) throw badRequest('Page size must be between 1 and 100')
  return value
}

/** Navigation only: original addressed history validates lineage and the child's own descriptor. */
export function subagentAddressFromHeader(header) {
  if (header?.origin !== 'subagent' || typeof header.id !== 'string' || !header.id
    || typeof header.parentSession !== 'string' || !header.parentSession) return null
  return { parentSessionId: header.parentSession, childSessionId: header.id, mode: 'unknown' }
}

function observedSubmission(snapshot, requestId) {
  const messages = Object.values(snapshot.projections?.values?.inbox ?? {}).flat()
  for (const record of snapshot.records) {
    if (record.type !== 'event') continue
    if (record.event.type === 'user/message') messages.push(record.event.data)
    if (record.event.type === 'agent/inbox/spliced') messages.push(...record.event.data.inserted)
  }
  const message = messages.find(item => item.source?.kind === 'user' && item.source.rpcId === requestId)
  // A bounded opening can prove acceptance, never prove that an absent request was rejected.
  return { requestId, state: message ? 'observed' : 'not-observed',
    ...(message ? { messageId: message.id } : {}) }
}

/** App carrier over original discovery, addressed history, prompt, and parent interruption. */
export class AppSubagents {
  constructor(ctx, { invoke, follow, taskSession, presentEvent = event => event }) {
    this.ctx = ctx
    this.invoke = invoke
    this.follow = follow
    this.taskSession = taskSession
    this.presentEvent = presentEvent
    this.reads = new Map()
    this.closed = false
  }

  /** Preserve domain failure codes through Android's JSON MethodChannel boundary. */
  async call(method, params = {}) {
    try {
      if (this.closed) throw Object.assign(new Error('Subagent service has closed'), { code: 'gateway/cancelled' })
      switch (method) {
        case 'catalog': return await this.catalog(params)
        case 'inspect': return await this.inspect(params)
        case 'page': return await this.page(params)
        case 'send': return await this.send(params)
        case 'interrupt': return await this.interrupt(params)
        default: throw badRequest('Unknown subagent operation')
      }
    } catch (error) {
      return { _pocket_error: {
        code: typeof error.code === 'string' ? error.code : 'gateway/internal',
        message: String(error.message ?? error),
        ...(error.details !== undefined ? { details: error.details } : {}),
      } }
    }
  }

  async read(operation) {
    const lifetime = new AbortController()
    const done = Promise.withResolvers()
    this.reads.set(lifetime, done.promise)
    try {
      return await operation(lifetime.signal)
    } finally {
      lifetime.abort()
      this.reads.delete(lifetime)
      done.resolve()
    }
  }

  flags(address) {
    const parentAvailable = !!this.ctx.agents.get(address.parentSessionId)
    const child = this.ctx.agents.get(address.childSessionId)
    const running = child?.status === 'running'
    const continuable = address.mode === 'continuable'
    return {
      parentAvailable, attached: !!child, running,
      canPrompt: continuable && parentAvailable,
      canInterrupt: continuable && running,
      readOnlyReason: !continuable ? address.mode : !parentAvailable ? 'parent-unavailable' : null,
    }
  }

  async catalog(params) {
    const parentSessionId = identity(params.parentSessionId, 'parentSessionId')
    const offset = params.offset ?? 0
    if (!Number.isSafeInteger(offset) || offset < 0) throw badRequest('offset must be a non-negative safe integer')
    const limit = pageSize(params.limit ?? 30)
    return this.read(async signal => {
      const catalog = await this.ctx.subagents.listChildren(parentSessionId, signal)
      return {
        parentSessionId, parentAvailable: !!this.ctx.agents.get(parentSessionId),
        entries: catalog.slice(offset, offset + limit).map(entry => {
          const address = entry.mode === 'external' ? null
            : { parentSessionId, childSessionId: entry.id, mode: entry.mode }
          const child = address ? this.ctx.agents.get(entry.id) : undefined
          return { ...entry, address, attached: !!child, running: child?.status === 'running' }
        }),
        nextOffset: offset + limit < catalog.length ? offset + limit : null,
      }
    })
  }

  present(history) {
    return { ...history, records: history.records.map(record => record.type === 'event'
      ? { ...record, event: this.presentEvent(record.event) } : record) }
  }

  async inspect(params) {
    const address = addressOf(params.address)
    const maxMessages = pageSize(params.maxMessages)
    const requestId = params.requestId === undefined ? undefined : identity(params.requestId, 'requestId')
    return this.read(async signal => {
      const iterable = await this.follow({ address: { kind: 'subagent', ...address }, maxMessages }, signal)
      const iterator = iterable[Symbol.asyncIterator]()
      let snapshot
      try {
        const first = await iterator.next()
        if (first.done || first.value?.type !== 'snapshot') throw new Error('Subagent history did not provide an opening snapshot')
        snapshot = first.value
      } finally {
        await iterator.return?.()
      }
      // The original follow has already validated that this descriptor belongs to the child's own suffix.
      const resolved = { ...address, mode: snapshot.projections.values.subagent.mode }
      const task = await this.taskSession({ sessionId: address.childSessionId })
      return {
        address: resolved, snapshot: this.present(snapshot), capabilities: this.flags(resolved), task,
        submission: requestId === undefined ? null : observedSubmission(snapshot, requestId),
      }
    })
  }

  async page(params) {
    const address = addressOf(params.address)
    const maxMessages = pageSize(params.maxMessages)
    if (!Number.isSafeInteger(params.throughSeq) || params.throughSeq < -1
      || params.beforeSeq !== undefined && (!Number.isSafeInteger(params.beforeSeq) || params.beforeSeq < 0)) {
      throw badRequest('History cursors must be safe sequence numbers')
    }
    return this.read(async signal => this.present(await this.invoke('session', 'page', { request: {
      address: { kind: 'subagent', ...address }, throughSeq: params.throughSeq,
      ...(params.beforeSeq === undefined ? {} : { beforeSeq: params.beforeSeq }), maxMessages,
    } }, signal)))
  }

  send(params) {
    const address = addressOf(params.address)
    if (address.mode !== 'continuable') throw badRequest('Only a continuable subagent can receive a prompt')
    const requestId = identity(params.requestId, 'requestId')
    if (typeof params.text !== 'string' || !params.text.trim()) throw badRequest('A non-empty text prompt is required')
    if (params.delivery !== 'queue' && params.delivery !== 'steer') throw badRequest('delivery must be queue or steer')
    // requestId is original attribution, not an idempotency key. Never retry an uncertain submission.
    return this.invoke('subagents', 'prompt', { request: {
      ...address, requestId, delivery: params.delivery, content: [{ type: 'text', text: params.text }],
    } })
  }

  interrupt(params) {
    const address = addressOf(params.address)
    if (address.mode !== 'continuable') throw badRequest('Only a continuable subagent can be interrupted')
    // Original authority permits stopping a live child even after its parent has detached.
    return this.invoke('subagents', 'interruptByParent', address)
  }

  async close() {
    this.closed = true
    const reads = [...this.reads]
    for (const [lifetime] of reads) lifetime.abort()
    await Promise.all(reads.map(([, done]) => done))
  }
}
