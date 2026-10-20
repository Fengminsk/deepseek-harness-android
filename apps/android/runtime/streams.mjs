import { randomUUID } from 'node:crypto'
import { isRemoteJsonValue } from '@deepseek-ai/dsh-typert-protocol'

/** Bounded App observations of the original Gateway streams; producers retain task ownership. */
export class AppStreams {
  constructor(ctx, transport, peer, { maxSubscriptions, maxFrameBytes }) {
    this.ctx = ctx
    this.transport = transport
    this.peer = peer
    this.maxSubscriptions = maxSubscriptions
    this.maxFrameBytes = maxFrameBytes
    this.records = new Map()
  }

  key(owner, id) {
    if (typeof owner !== 'string' || !owner || owner.length > 200
      || typeof id !== 'string' || !id || id.length > 200) throw new TypeError('Invalid App stream identity')
    return JSON.stringify([owner, id])
  }

  async subscribe(params) {
    const key = this.key(params.owner, params.subscriptionId)
    if (this.records.has(key)) throw new Error('Subscription is already active')
    if ([...this.records.values()].filter(record => record.owner === params.owner).length >= this.maxSubscriptions()) {
      throw new Error('App stream limit reached; close an unused page before subscribing')
    }
    if (typeof params.namespace !== 'string' || typeof params.method !== 'string') {
      throw new TypeError('Stream namespace and method are required')
    }
    const record = { key, owner: params.owner, id: params.subscriptionId, generation: randomUUID(),
      lifetime: new AbortController(), sequence: 0, acked: 0 }
    this.records.set(key, record)
    try {
      const iterable = await this.ctx.typertGateway.stream({ namespace: params.namespace, method: params.method,
        args: params.args ?? {}, peer: this.peer(), signal: record.lifetime.signal })
      record.done = this.consume(record, iterable)
      return { subscriptionId: record.id, generation: record.generation }
    } catch (error) {
      if (this.records.get(key) === record) this.records.delete(key)
      record.lifetime.abort()
      throw error
    }
  }

  async consume(record, iterable) {
    try {
      for await (const value of iterable) {
        if (record.lifetime.signal.aborted) return
        if (!isRemoteJsonValue(value)) throw new TypeError('This App stream requires a JSON result')
        const waiter = Promise.withResolvers()
        record.waiter = waiter
        this.emit(record, { type: 'item', value })
        await waiter.promise
        record.waiter = undefined
        if (record.lifetime.signal.aborted) return
      }
      if (!record.lifetime.signal.aborted) this.emit(record, { type: 'end' })
    } catch (error) {
      if (!record.lifetime.signal.aborted) {
        this.emit(record, { type: 'error', error: {
          code: typeof error.code === 'string' ? error.code : 'app-stream/failed',
          message: String(error.message ?? error).slice(0, 1024),
        } })
      }
    } finally {
      if (this.records.get(record.key) === record) this.records.delete(record.key)
    }
  }

  emit(record, data) {
    const frame = { owner: record.owner, subscriptionId: record.id, generation: record.generation,
      sequence: record.sequence + 1, ...data }
    if (Buffer.byteLength(JSON.stringify(frame), 'utf8') > this.maxFrameBytes()) {
      throw new Error('Stream frame exceeds the App IPC limit; narrow the requested range')
    }
    record.sequence = frame.sequence
    this.transport.notify('api.stream', frame)
  }

  ack(params) {
    const record = this.records.get(this.key(params.owner, params.subscriptionId))
    if (!record || params.generation !== record.generation) return { accepted: false }
    if (!Number.isSafeInteger(params.sequence) || params.sequence < 1 || params.sequence > record.sequence) {
      throw new TypeError('Invalid stream acknowledgement')
    }
    if (params.sequence <= record.acked) return { accepted: true }
    record.acked = params.sequence
    record.waiter?.resolve()
    return { accepted: true }
  }

  async unsubscribe(params) {
    const record = this.records.get(this.key(params.owner, params.subscriptionId))
    if (!record || (params.generation !== undefined && params.generation !== record.generation)) return { closed: true }
    record.lifetime.abort()
    record.waiter?.resolve()
    await record.done
    if (this.records.get(record.key) === record) this.records.delete(record.key)
    return { closed: true }
  }

  async closeOwner(owner) {
    await Promise.all([...this.records.values()].filter(record => record.owner === owner)
      .map(record => this.unsubscribe({ owner, subscriptionId: record.id })))
  }

  async close() {
    await Promise.all([...this.records.values()].map(record =>
      this.unsubscribe({ owner: record.owner, subscriptionId: record.id })))
  }
}
