import { randomUUID } from 'node:crypto'
import { isRemoteJsonValue } from '@deepseek-ai/dsh-typert-protocol'

/**
 * 未确认窗口的协议常量（`docs/remote-dsh/protocol.md` §6.2）：单流最多 64 条、
 * 1 MiB。两者都是线上协议的一部分，不随配置变化。
 */
const WINDOW_FRAMES = 64
const WINDOW_BYTES = 1048576

/** 回退或跳跃确认序号的流内错误码（协议 §6.2/§6.3）。 */
const ACK_VIOLATION = 'app-stream/ack-violation'

/**
 * 远程连接的流归属。协议 §6.4 规定一条连接只有一个 owner，`owner` 维度不上线：
 * Android 本地链路由原生 Binder 注入，远程连接上由远端宿主为每条连接注入一个独立值
 * （`index.mjs` 的 `RemoteConnectionOwners`），连接关闭时按该 owner 释放流。这里的
 * 固定值只作兼容兜底：宿主没有注入 owner 时仍按旧行为把连接归到同一个 owner。
 */
const REMOTE_OWNER = 'remote'

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

  /**
   * 流归属。本地 loopback 由原生注入 `owner`；远程连接上由远端宿主在 dispatch 前注入
   * 每条连接自己的 owner（同样不上线），只有宿主没有注入时才退回固定值。
   * @param {{ owner?: unknown }} params 订阅/回执/退订的参数
   * @returns {string} 归属标识
   */
  owner(params) {
    return params.owner ?? REMOTE_OWNER
  }

  /**
   * 流的线上标识。远程连接按协议发 `streamId`，本地 loopback 与既有原生
   * 文档预览仍按 `subscriptionId` 发；两种名字指同一件事，别名只在此处定义。
   */
  streamId(params) {
    const { streamId, subscriptionId } = params
    if (streamId !== undefined && subscriptionId !== undefined && streamId !== subscriptionId) {
      throw new TypeError('Conflicting App stream identity')
    }
    return streamId ?? subscriptionId
  }

  async subscribe(params) {
    const id = this.streamId(params)
    const owner = this.owner(params)
    const key = this.key(owner, id)
    if (this.records.has(key)) throw new Error('Subscription is already active')
    if ([...this.records.values()].filter(record => record.owner === owner).length >= this.maxSubscriptions()) {
      throw new Error('App stream limit reached; close an unused page before subscribing')
    }
    if (typeof params.namespace !== 'string' || typeof params.method !== 'string') {
      throw new TypeError('Stream namespace and method are required')
    }
    const record = { key, owner, id, generation: randomUUID(),
      lifetime: new AbortController(), sequence: 0, acked: 0, window: 1,
      entries: [], unconfirmedFrames: 0, unconfirmedBytes: 0, waiter: undefined,
      terminating: false }
    this.records.set(key, record)
    try {
      const iterable = await this.ctx.typertGateway.stream({ namespace: params.namespace, method: params.method,
        args: params.args ?? {}, peer: this.peer(), signal: record.lifetime.signal })
      record.done = this.consume(record, iterable)
      return { streamId: record.id, subscriptionId: record.id, generation: record.generation }
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
        if (!await this.pushItem(record, value)) return
      }
      if (!record.lifetime.signal.aborted) this.pushTerminal(record, { type: 'end' })
    } catch (error) {
      if (!record.lifetime.signal.aborted) this.pushTerminal(record, { type: 'error', error: {
        code: typeof error.code === 'string' ? error.code : 'app-stream/failed',
        message: String(error.message ?? error).slice(0, 1024),
      } })
    } finally {
      if (this.records.get(record.key) === record) this.records.delete(record.key)
    }
  }

  /**
   * 在未确认窗口内推送一条 item 并累计占用；窗口放不下时挂起生产者，
   * 直到 `api.ack` 推进 `ackedUpTo`。返回 false 表示流已终止。
   */
  async pushItem(record, value) {
    for (;;) {
      if (record.lifetime.signal.aborted) return false
      const frame = this.frame(record, { type: 'item', value })
      const bytes = this.frameBytes(frame)
      if (bytes > this.maxFrameBytes()) {
        throw new Error('Stream frame exceeds the App IPC limit; narrow the requested range')
      }
      if (record.unconfirmedFrames + 1 <= record.window && this.withinByteBudget(record, bytes)) {
        this.push(record, frame, bytes)
        record.entries.push({ sequence: frame.sequence, bytes })
        record.unconfirmedFrames++
        record.unconfirmedBytes += bytes
        // 只发逐条确认的旧客户端停在 W=1：推一条、等一条，上游节流与改造前一致。
        if (record.window === 1) await this.settle(record)
        return !record.lifetime.signal.aborted
      }
      await this.waitForAck(record)
    }
  }

  /**
   * 字节预算。单帧自身超过 1 MiB 时只有在窗口为空时才放行：本地单帧上限是
   * 16 MiB（`appStreamMaxFrameBytes`），严格按 1 MiB 拒绝会把改造前可送达的
   * 大帧变成回归，而等待一个永远放不下的窗口会死锁。
   */
  withinByteBudget(record, bytes) {
    return record.unconfirmedBytes === 0 || record.unconfirmedBytes + bytes <= WINDOW_BYTES
  }

  async waitForAck(record) {
    const waiter = record.waiter ??= Promise.withResolvers()
    await waiter.promise
  }

  /** 逐条模式下等到窗口清空；唤醒后重查状态，避免漏掉已到达的确认。 */
  async settle(record) {
    while (!record.lifetime.signal.aborted && record.window === 1 && record.unconfirmedFrames > 0) {
      await this.waitForAck(record)
    }
  }

  wake(record) {
    const waiter = record.waiter
    record.waiter = undefined
    waiter?.resolve()
  }

  /** 组装一帧。终止帧同样占用一个序号，但不计入窗口。 */
  frame(record, data) {
    return { owner: record.owner, subscriptionId: record.id, streamId: record.id,
      generation: record.generation, sequence: record.sequence + 1, ...data }
  }

  frameBytes(frame) {
    return Buffer.byteLength(JSON.stringify(frame), 'utf8')
  }

  push(record, frame, bytes = this.frameBytes(frame)) {
    if (bytes > this.maxFrameBytes()) {
      throw new Error('Stream frame exceeds the App IPC limit; narrow the requested range')
    }
    record.sequence = frame.sequence
    this.transport.notify('api.stream', frame)
  }

  pushTerminal(record, data) {
    this.push(record, this.frame(record, data))
  }

  ack(params) {
    const record = this.records.get(this.key(this.owner(params), this.streamId(params)))
    if (!record) return { accepted: false }
    if (params.generation !== undefined && params.generation !== record.generation) return { accepted: false }
    if (params.upTo !== undefined) return this.advanceWindow(record, params.upTo)
    return this.advanceLegacy(record, params.sequence)
  }

  /**
   * 累计确认。只接受单调递增的 `upTo`：回退或越过 `sentUpTo` 都是协议错误，
   * 按 §6.3 终止该流（不关闭连接）。
   */
  advanceWindow(record, upTo) {
    if (!Number.isSafeInteger(upTo) || upTo < 1) throw new TypeError('Invalid stream acknowledgement')
    const violation = upTo < record.acked ? '流确认序号回退，已终止该流。'
      : upTo > record.sequence ? '流确认序号跳跃，已终止该流。' : null
    if (violation !== null) {
      this.terminate(record, ACK_VIOLATION, violation)
      throw Object.assign(new Error(violation), { code: ACK_VIOLATION })
    }
    // 首个累计确认证明客户端按窗口节奏回执；旧客户端只发 `sequence`，
    // 永远停在逐条语义（W=1），行为与改造前一致。
    record.window = WINDOW_FRAMES
    this.advance(record, upTo)
    return { accepted: true, upTo: record.acked }
  }

  /** 逐条确认（旧客户端）。保留改造前的判定，不做协议终止。 */
  advanceLegacy(record, sequence) {
    if (!Number.isSafeInteger(sequence) || sequence < 1 || sequence > record.sequence) {
      throw new TypeError('Invalid stream acknowledgement')
    }
    this.advance(record, sequence)
    return { accepted: true }
  }

  advance(record, upTo) {
    if (upTo <= record.acked) return
    record.acked = upTo
    while (record.entries.length > 0 && record.entries[0].sequence <= upTo) {
      record.unconfirmedFrames--
      record.unconfirmedBytes -= record.entries.shift().bytes
    }
    this.wake(record)
  }

  /** 按 §6.3 终止一条流：推流内错误帧、abort 生产者、立即失效该订阅。 */
  terminate(record, code, message) {
    if (record.terminating) return
    record.terminating = true
    if (this.records.get(record.key) === record) this.records.delete(record.key)
    try {
      this.pushTerminal(record, { type: 'error', error: { code, message } })
    } catch {
      // 终止帧本身超限：流照常终止，只是没有可送达的错误帧。
    }
    record.lifetime.abort()
    this.wake(record)
  }

  async unsubscribe(params) {
    const record = this.records.get(this.key(this.owner(params), this.streamId(params)))
    if (!record || (params.generation !== undefined && params.generation !== record.generation)) return { closed: true }
    record.lifetime.abort()
    this.wake(record)
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
