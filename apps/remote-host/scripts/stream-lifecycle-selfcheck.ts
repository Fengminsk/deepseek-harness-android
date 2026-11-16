/**
 * 远程连接流生命周期自检：证明「每条远程连接一个独立 owner、解除绑定时释放该 owner 的全部
 * 资源」成立，并回归真机发现的 `App stream limit reached`（订阅记录跨 App 重启/重连累积）。
 *
 * 运行：`node --import tsx/esm apps/remote-host/scripts/stream-lifecycle-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本零依赖、不写文件、不开端口、不启动 DSH 进程，
 * 只驱动真实的 `apps/android/runtime/index.mjs`（`RemoteConnectionOwners`、
 * `createRemoteFacadeService`）与 `streams.mjs`（`AppStreams`），其余资源是内存假实现。
 *
 * 覆盖：
 * 1. 门面接线：每条连接一个独立 owner，`api.*` / `workspaceChanges.*` /
 *    `session.attachmentFile.*` 等按 owner 管理的方法参数被注入该 owner，其它方法不改参数；
 * 2. 订阅上限按 owner 独立：同一门面上 A 触顶不影响 B，记录数与 owner 一一对应；
 * 3. 回执按 owner 隔离：A 的流不会被 B 的 owner 确认；
 * 4. 解除绑定释放该 owner 的流、按 owner 管理的资源与会话历史租约，另一条连接不受影响；
 *    共享资源的释放副作用同步发生，赶在下一条连接开始工作之前；
 * 5. 同一个 sink 换 owner 时先释放旧 owner；重复 unbind 幂等；
 * 6. 客户端自带 owner（App 的「本次变更」页面）保留，连接关闭不代页面释放——否则页面
 *    重连后同一个 owner 会被资源的已关闭集合永久拒绝；
 * 7. 清理失败只记 warn，不把连接关闭流程变成失败；
 * 8. 回归：40 次 连接→订阅→关闭 后仍能订阅（旧实现共享固定 owner 且从不清理，
 *    第 33 次订阅触顶 32 被拒）。
 *
 * 为什么不启动 wss 宿主：连接分配 owner 与解除绑定是 `index.ts` 里的三行接线，真正的
 * 生命周期语义在运行时门面；用真实门面 + 假连接复刻这三次调用，比重新造一套 TLS 传输更
 * 直接。宿主侧的真实升级/关闭由 `smoke-remote-host.ts` 覆盖。
 * @module @deepseek-ai/dsh-remote-host/scripts/stream-lifecycle-selfcheck
 */

import { randomUUID } from 'node:crypto'

/** 运行时门面里用到的流对象表面（源文件是 .mjs，没有可导入的类型声明）。 */
interface AppStreamsLike {
  /** 当前订阅记录，键是 `[owner, streamId]` 的 JSON 序列化。 */
  readonly records: Map<string, unknown>
  /**
   * 建立一条订阅。
   * @param params - `api.subscribe` 参数。
   * @returns `{streamId, subscriptionId, generation}`。
   */
  subscribe(params: Record<string, unknown>): Promise<Record<string, unknown>>
  /**
   * 确认已送达的帧。
   * @param params - `api.ack` 参数。
   * @returns 确认结论。
   */
  ack(params: Record<string, unknown>): Record<string, unknown>
  /**
   * 释放一条流。
   * @param params - `api.unsubscribe` 参数。
   * @returns 关闭结论。
   */
  unsubscribe(params: Record<string, unknown>): Promise<Record<string, unknown>>
  /**
   * 释放一个 owner 的全部流。
   * @param owner - 连接 owner。
   * @returns 全部流关闭后兑现。
   */
  closeOwner(owner: string): Promise<void>
  /** 释放全部流。 */
  close(): Promise<void>
}

/** 一个按 owner 释放的资源（与 `index.mjs` 里传给 `RemoteConnectionOwners` 的对象一致）。 */
interface OwnerResource {
  readonly label: string
  closeOwner(owner: string): Promise<unknown> | unknown
}

/** 一个连接切换时整体释放的共享资源。 */
interface SharedResource {
  readonly label: string
  release(): unknown
}

/** `RemoteConnectionOwners` 用到的表面。 */
interface ConnectionOwnersLike {
  scopedParams(method: string, params: unknown, owner?: string): unknown
  bind(sink: object, owner: string): void
  unbind(sink: object): Promise<boolean>
  release(owner: string): Promise<void>
}

/** `createRemoteFacadeService` 用到的表面。 */
interface FacadeServiceLike {
  dispatch(method: string, params: unknown, owner?: string): unknown
  bind(sink: object, owner: string): void
  unbind(sink: object): Promise<boolean>
}

/** 运行时 `index.mjs` 的门面表面。 */
interface RuntimeModule {
  readonly RemoteConnectionOwners: new (options: {
    readonly ownerResources: readonly OwnerResource[]
    readonly sharedResources?: readonly SharedResource[]
    readonly warn: (message: string) => void
  }) => ConnectionOwnersLike
  readonly createRemoteFacadeService: (options: {
    readonly dispatch: (method: string, params: unknown) => unknown
    readonly owners: ConnectionOwnersLike
    readonly transport: { bind?(sink: object): void; unbind?(sink: object): boolean }
    readonly detachConnection?: () => void
  }) => FacadeServiceLike
}

/** 运行时 `streams.mjs` 的流表面。 */
interface StreamsModule {
  readonly AppStreams: new (
    ctx: unknown,
    transport: unknown,
    peer: () => unknown,
    limits: { maxSubscriptions(): number; maxFrameBytes(): number },
  ) => AppStreamsLike
}

/** 一条上游流请求（`typertGateway.stream` 的参数）。 */
interface StreamRequest {
  readonly namespace: string
  readonly method: string
  readonly args: Record<string, unknown>
  readonly signal: AbortSignal
}

/** 假 Gateway：记录打开/中止，并让每条流挂起直到连接关闭。 */
interface StreamFixture {
  readonly requests: StreamRequest[]
  readonly opened: string[]
  readonly aborted: string[]
  readonly gateway: { stream(request: StreamRequest): AsyncGenerator<Record<string, unknown>> }
}

/** 一条模拟连接的 sink。 */
interface Sink {
  readonly id: string
}

/** 一条模拟连接：宿主为它分配的 sink 与 owner。 */
interface Connection {
  readonly sink: Sink
  readonly owner: string
}

/** 一条 `api.stream` 通知。 */
interface Frame {
  readonly method: string
  readonly params: Record<string, unknown>
}

/** 自检夹具。 */
interface Harness {
  readonly maxSubscriptions: number
  readonly streams: AppStreamsLike
  readonly fixture: StreamFixture
  readonly frames: Frame[]
  readonly owners: ConnectionOwnersLike
  readonly facade: FacadeServiceLike
  readonly transport: FakeFacadeTransport
  readonly observed: { method: string; params: unknown }[]
  readonly closed: Map<string, string[]>
  readonly historyReleases: number[]
  readonly warnings: string[]
  readonly detaches: number[]
}

/** 运行时门面源文件的绝对 URL：从本脚本所在目录解析，不依赖仓库工作目录。 */
const RUNTIME_INDEX_URL = new URL('../../android/runtime/index.mjs', import.meta.url).href

/** 运行时流源文件的绝对 URL。 */
const RUNTIME_STREAMS_URL = new URL('../../android/runtime/streams.mjs', import.meta.url).href

// 源文件是 .mjs，没有可导入的类型；这里按消费方用到的表面声明一次。
const runtime = await import(RUNTIME_INDEX_URL) as RuntimeModule
const streamsModule = await import(RUNTIME_STREAMS_URL) as StreamsModule

/** 一条断言失败。 */
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

/**
 * 断言一个值是非数组对象并返回它。
 * @param value - 任意值。
 * @param label - 失败说明里的字段名。
 * @returns 对象本身。
 * @throws 不是非数组对象时抛出。
 */
function asRecord(value: unknown, label: string): Record<string, unknown> {
  check(typeof value === 'object' && value !== null && !Array.isArray(value), `${label} 不是对象：${String(value)}`)
  return value as Record<string, unknown>
}

/**
 * 等待一个条件成立。
 * @param predicate - 条件。
 * @param label - 超时时的中文说明。
 * @param timeoutMs - 等待上限。
 * @returns 无返回值；超时抛 {@link SelfCheckFailure}。
 */
async function waitFor(predicate: () => boolean, label: string, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() > deadline) throw new SelfCheckFailure(`${label}：等待超时（${timeoutMs} ms）`)
    await new Promise<void>((resolve) => { setTimeout(resolve, 0) })
  }
}

/**
 * 断言一次调用以指定信息失败。
 * @param run - 期望失败的调用。
 * @param pattern - 错误信息必须匹配的模式。
 * @param label - 中文说明。
 * @returns 无返回值；调用成功或信息不匹配时抛 {@link SelfCheckFailure}。
 */
async function expectFailure(run: () => Promise<unknown>, pattern: RegExp, label: string): Promise<void> {
  try {
    await run()
  } catch (error) {
    const message = describeError(error)
    check(pattern.test(message), `${label}：错误信息不符：${message}`)
    return
  }
  throw new SelfCheckFailure(`${label}：期望失败但调用成功了`)
}

/**
 * 构造假 Gateway。每条流先吐一条 opening 快照，然后挂起直到订阅被释放（模拟
 * `session.follow` 这类不会自然结束的上游）。
 * @returns 流夹具。
 */
function createStreamFixture(): StreamFixture {
  const requests: StreamRequest[] = []
  const opened: string[] = []
  const aborted: string[] = []
  return {
    requests,
    opened,
    aborted,
    gateway: {
      async *stream(request: StreamRequest): AsyncGenerator<Record<string, unknown>> {
        requests.push(request)
        const tag = String(request.args.tag)
        opened.push(tag)
        try {
          yield { opened: tag }
          await new Promise<void>((resolve) => {
            if (request.signal.aborted) resolve()
            else request.signal.addEventListener('abort', () => { resolve() }, { once: true })
          })
        } finally {
          aborted.push(tag)
        }
      },
    },
  }
}

/** 假晚绑定传输：只保存当前 sink，与 `createLateBoundTransport` 的单绑定语义一致。 */
class FakeFacadeTransport {
  sink: object | undefined
  readonly bindCalls: object[] = []
  readonly unbindCalls: object[] = []

  /**
   * 绑定一条连接的转发端。
   * @param sink - 连接的转发端。
   * @returns 无返回值。
   */
  bind(sink: object): void {
    this.sink = sink
    this.bindCalls.push(sink)
  }

  /**
   * 解除绑定；只有当前绑定的就是它时才生效。
   * @param sink - 之前交给 {@link FakeFacadeTransport.bind} 的对象。
   * @returns 是否真的解除了当前绑定。
   */
  unbind(sink: object): boolean {
    if (this.sink !== sink) return false
    this.sink = undefined
    this.unbindCalls.push(sink)
    return true
  }
}

/**
 * 门面分发表的替身：`api.*` 交给真实 `AppStreams`，其它方法原样返回参数供断言。
 * @param streams - 真实流对象。
 * @param observed - 记录分发表实际收到的参数。
 * @returns 分发表函数。
 */
function createDispatch(
  streams: AppStreamsLike,
  observed: { method: string; params: unknown }[],
): (method: string, params: unknown) => unknown {
  return (method, params) => {
    observed.push({ method, params })
    if (typeof params !== 'object' || params === null || Array.isArray(params)) return undefined
    const record = params as Record<string, unknown>
    switch (method) {
      case 'api.subscribe': return streams.subscribe(record)
      case 'api.ack': return streams.ack(record)
      case 'api.unsubscribe': return streams.unsubscribe(record)
      default: return { echo: record }
    }
  }
}

/**
 * 构造一套自检夹具：真实 `AppStreams` + 真实 owner 生命周期/门面接线，其余资源是假实现。
 * @param options - 订阅上限与故意失败的清理标签。
 * @returns 自检夹具。
 */
function createHarness(options: { maxSubscriptions?: number; failingLabels?: readonly string[] } = {}): Harness {
  const maxSubscriptions = options.maxSubscriptions ?? 32
  const fixture = createStreamFixture()
  const frames: Frame[] = []
  const streams = new streamsModule.AppStreams(
    { typertGateway: { stream: fixture.gateway.stream } },
    {
      notify: (method: string, params: Record<string, unknown>) => {
        frames.push({ method, params })
      },
    },
    () => ({ principal: { kind: 'owner' } }),
    { maxSubscriptions: () => maxSubscriptions, maxFrameBytes: () => 1024 * 1024 },
  )
  const closed = new Map<string, string[]>()
  const historyReleases: number[] = []
  const warnings: string[] = []
  const detaches: number[] = []
  const failing = new Set(options.failingLabels ?? [])
  const labels = [
    'App reference cleanup failed',
    'App change comparison cleanup failed',
    'App stream cleanup failed',
    'App file read cleanup failed',
    'App file search cleanup failed',
    'App document preview cleanup failed',
    'App attachment file cleanup failed',
  ]
  const ownerResources: OwnerResource[] = labels.map((label) => {
    if (label === 'App stream cleanup failed') return { label, closeOwner: (owner: string) => streams.closeOwner(owner) }
    if (failing.has(label)) return { label, closeOwner: () => Promise.reject(new Error('injected cleanup failure')) }
    return {
      label,
      closeOwner: (owner: string) => {
        const owners = closed.get(label) ?? []
        owners.push(owner)
        closed.set(label, owners)
      },
    }
  })
  const owners = new runtime.RemoteConnectionOwners({
    ownerResources,
    sharedResources: [{ label: 'App session history cleanup failed', release: () => { historyReleases.push(Date.now()) } }],
    warn: (message: string) => { warnings.push(message) },
  })
  const transport = new FakeFacadeTransport()
  const observed: { method: string; params: unknown }[] = []
  const facade = runtime.createRemoteFacadeService({
    dispatch: createDispatch(streams, observed),
    owners,
    transport,
    detachConnection: () => { detaches.push(Date.now()) },
  })
  return { maxSubscriptions, streams, fixture, frames, owners, facade, transport, observed, closed, historyReleases, warnings, detaches }
}

/**
 * 复刻宿主 `onConnection` 的三步：分配 owner、把 sink 交给门面 bind、入站请求带上 owner。
 * @param facade - 门面服务表面。
 * @param id - 连接标识，只用于自检断言。
 * @returns 模拟连接。
 */
function connect(facade: FacadeServiceLike, id: string): Connection {
  const sink: Sink = Object.freeze({ id })
  const owner = randomUUID()
  facade.bind(sink, owner)
  return { sink, owner }
}

/**
 * 经门面分发表发起一次调用。
 * @param facade - 门面服务表面。
 * @param connection - 模拟连接。
 * @param method - 方法名。
 * @param params - 参数。
 * @returns 分发表结果的 Promise（分发表可能同步返回，这里统一成 Promise）。
 */
async function call(
  facade: FacadeServiceLike,
  connection: Connection,
  method: string,
  params: unknown,
): Promise<unknown> {
  return await facade.dispatch(method, params, connection.owner)
}

/**
 * 发起一次调用并断言结果是对象。
 * @param facade - 门面服务表面。
 * @param connection - 模拟连接。
 * @param method - 方法名。
 * @param params - 参数。
 * @param label - 失败说明里的方法名。
 * @returns 结果对象。
 */
async function callObject(
  facade: FacadeServiceLike,
  connection: Connection,
  method: string,
  params: unknown,
  label: string,
): Promise<Record<string, unknown>> {
  return asRecord(await call(facade, connection, method, params), `${label} 结果`)
}

/**
 * 分发表实际收到的参数（断言非对象参数时用 undefined 分支单独处理）。
 * @param harness - 自检夹具。
 * @param method - 方法名。
 * @returns 参数对象。
 */
function observedParams(harness: Harness, method: string): Record<string, unknown> {
  const entry = harness.observed.find(item => item.method === method)
  check(entry !== undefined, `分发表没有收到 ${method}`)
  return asRecord(entry.params, `${method} 参数`)
}

/**
 * 订阅一条假的长流。
 * @param harness - 自检夹具。
 * @param connection - 模拟连接。
 * @param tag - 上游流标识；同一 owner 内唯一。
 * @returns 订阅结果。
 */
async function subscribe(
  harness: Harness,
  connection: Connection,
  tag: string,
): Promise<Record<string, unknown>> {
  return await callObject(harness.facade, connection, 'api.subscribe', {
    streamId: tag,
    subscriptionId: tag,
    namespace: 'session',
    method: 'follow',
    args: { tag },
  }, `api.subscribe(${tag})`)
}

/**
 * 当前订阅记录条数。
 * @param harness - 自检夹具。
 * @returns 订阅记录条数。
 */
function recordCount(harness: Harness): number {
  return harness.streams.records.size
}

/**
 * 某个 owner 名下的订阅记录条数。
 * @param harness - 自检夹具。
 * @param owner - 连接 owner。
 * @returns 记录条数。
 */
function ownerRecordCount(harness: Harness, owner: string): number {
  const prefix = `[${JSON.stringify(owner)},`
  return [...harness.streams.records.keys()].filter(key => key.startsWith(prefix)).length
}

let total = 0
let passed = 0
const failures: string[] = []

/**
 * 跑一项断言并打印结果。失败不中断后续项，但会计入退出码。
 * @param label - 中文说明。
 * @param run - 断言本体，返回通过时展示的细节。
 * @returns 无返回值。
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
 * @returns 进程退出码：全部通过 0，有失败项 1。
 */
async function main(): Promise<number> {
  console.log('远程连接流生命周期自检（真实运行时门面 + 假连接）')

  await step('门面接线：每条连接一个独立 owner，按 owner 管理的方法被注入 owner', async () => {
    const harness = createHarness()
    const first = connect(harness.facade, 'first')
    const second = connect(harness.facade, 'second')
    check(first.owner !== second.owner, '两条连接拿到了同一个 owner')
    check(harness.transport.bindCalls.length === 2, `bind 应被调用 2 次，实际 ${harness.transport.bindCalls.length} 次`)
    await subscribe(harness, first, 'probe')
    check(observedParams(harness, 'api.subscribe').owner === first.owner, 'api.subscribe 没有被注入连接 owner')
    await call(harness.facade, second, 'workspaceChanges.summary', { requestId: randomUUID(), sessionId: 's', seq: 1 })
    check(observedParams(harness, 'workspaceChanges.summary').owner === second.owner, 'workspaceChanges.* 没有被注入连接 owner')
    await harness.streams.close()
    return `owner 逐连接唯一（${first.owner.slice(0, 8)}… ≠ ${second.owner.slice(0, 8)}…），api.* 与 workspaceChanges.* 均已注入`
  })

  await step('非 owner 方法不进 owner 维度', async () => {
    const harness = createHarness()
    const connection = connect(harness.facade, 'first')
    await call(harness.facade, connection, 'session.send', { sessionId: 's-1', requestId: randomUUID(), text: '你好' })
    const observed = observedParams(harness, 'session.send')
    check(observed.owner === undefined, 'session.send 参数被塞入了 owner')
    check(observed.text === '你好', 'session.send 参数被改写')
    await call(harness.facade, connection, 'runtime.info', undefined)
    const described = harness.observed.find(entry => entry.method === 'runtime.info')?.params
    check(described === undefined, '非对象参数被改写')
    return 'session.send 原样转交；undefined 参数原样转交'
  })

  await step('订阅上限按 owner 独立', async () => {
    const harness = createHarness({ maxSubscriptions: 2 })
    const first = connect(harness.facade, 'first')
    const second = connect(harness.facade, 'second')
    await subscribe(harness, first, 'a-1')
    await subscribe(harness, first, 'a-2')
    await expectFailure(() => subscribe(harness, first, 'a-3'), /App stream limit reached/, 'A 第三条订阅应触顶')
    await subscribe(harness, second, 'b-1')
    await subscribe(harness, second, 'b-2')
    check(ownerRecordCount(harness, first.owner) === 2, `A 的记录数不符：${ownerRecordCount(harness, first.owner)}`)
    check(ownerRecordCount(harness, second.owner) === 2, `B 的记录数不符：${ownerRecordCount(harness, second.owner)}`)
    check(recordCount(harness) === 4, `总记录数应为 4，实际 ${recordCount(harness)}`)
    check(ownerRecordCount(harness, 'remote') === 0, '仍有记录落到固定兜底 owner 上')
    await harness.streams.close()
    return `A=2、B=2，A 触顶后 B 仍可订阅（上限 ${harness.maxSubscriptions} 按 owner 计数）`
  })

  await step('回执按 owner 隔离', async () => {
    const harness = createHarness()
    const first = connect(harness.facade, 'first')
    const second = connect(harness.facade, 'second')
    const admitted = await subscribe(harness, first, 'a-ack')
    await waitFor(
      () => harness.frames.some(entry => entry.params.streamId === 'a-ack' && entry.params.sequence === 1),
      'A 的流没有推出第一帧',
    )
    const ack = { streamId: 'a-ack', subscriptionId: 'a-ack', generation: admitted.generation, sequence: 1 }
    const denied = await callObject(harness.facade, second, 'api.ack', ack, 'api.ack(B 的 owner)')
    check(denied.accepted === false, `B 的 owner 不应确认 A 的流：${JSON.stringify(denied)}`)
    const accepted = await callObject(harness.facade, first, 'api.ack', ack, 'api.ack(A 的 owner)')
    check(accepted.accepted === true, `A 的 owner 应能确认自己的流：${JSON.stringify(accepted)}`)
    const frameOwners = new Set(harness.frames.map(entry => entry.params.owner))
    check(frameOwners.size === 1 && frameOwners.has(first.owner), `帧 owner 不符：${[...frameOwners].join(',')}`)
    await harness.streams.close()
    return 'B 的 owner 回执 accepted:false，A 的 owner 回执 accepted:true'
  })

  await step('解除绑定释放该 owner 的流与其它资源，另一条连接不受影响', async () => {
    const harness = createHarness()
    const first = connect(harness.facade, 'first')
    await subscribe(harness, first, 'a-1')
    await subscribe(harness, first, 'a-2')
    // 宿主替换设备时先在旧连接关闭前 bind 新连接；这里复刻「旧 sink 已不是当前绑定、
    // 但它的解绑仍必须释放旧 owner」的窗口。
    const second = connect(harness.facade, 'second')
    await subscribe(harness, second, 'b-1')
    await subscribe(harness, second, 'b-2')
    check(recordCount(harness) === 4, `解除绑定前应有 4 条记录，实际 ${recordCount(harness)}`)
    const releasedFirst = await harness.facade.unbind(first.sink)
    check(releasedFirst === true, '解除 A 的绑定应报告已解除')
    const detachAfterFirstUnbind = harness.detaches.length
    check(detachAfterFirstUnbind === 0, `非当前绑定的 detach 不应调用，实际 ${detachAfterFirstUnbind} 次`)
    check(recordCount(harness) === 2, `A 的记录应被清空，剩余 ${recordCount(harness)} 条`)
    check(ownerRecordCount(harness, second.owner) === 2, 'B 的记录被误清')
    check(harness.fixture.aborted.includes('a-1') && harness.fixture.aborted.includes('a-2'), 'A 的上游流没有被中止')
    check(!harness.fixture.aborted.includes('b-1') && !harness.fixture.aborted.includes('b-2'), 'B 的上游流被误中止')
    for (const label of [
      'App reference cleanup failed',
      'App change comparison cleanup failed',
      'App file read cleanup failed',
      'App file search cleanup failed',
      'App document preview cleanup failed',
      'App attachment file cleanup failed',
    ]) {
      check(harness.closed.get(label)?.includes(first.owner) === true, `${label} 没有收到 A 的 owner`)
      check(harness.closed.get(label)?.includes(second.owner) !== true, `${label} 误释放了 B 的 owner`)
    }
    check(harness.historyReleases.length === 1, `会话历史租约应释放 1 次，实际 ${harness.historyReleases.length} 次`)
    const repeated = await harness.facade.unbind(first.sink)
    check(repeated === false, '重复解除绑定应返回 false')
    check(
      harness.closed.get('App reference cleanup failed')?.filter(owner => owner === first.owner).length === 1,
      '重复解除绑定重复释放了资源',
    )
    // B 仍可正常工作：被中止的 A 的流在 B 上退订是幂等空操作。
    const stale = await callObject(harness.facade, second, 'api.unsubscribe', { streamId: 'a-1', subscriptionId: 'a-1' }, 'api.unsubscribe(a-1)')
    check(stale.closed === true, 'B 上的幂等退订应返回 closed:true')
    const releasedSecond = await harness.facade.unbind(second.sink)
    check(releasedSecond === true, '解除 B 的绑定应报告已解除')
    check(harness.detaches.length === 1, `当前绑定的 detach 应调用 1 次，实际 ${harness.detaches.length} 次`)
    check(recordCount(harness) === 0, `B 的记录应被清空，剩余 ${recordCount(harness)} 条`)
    await harness.streams.close()
    return 'A 的 2 条流与 6 类资源 + 历史租约已释放、B 的 2 条流不受影响；当前绑定解绑触发 detach；重复 unbind 幂等'
  })

  await step('共享资源的释放副作用同步发生（赶在下一条连接开始工作之前）', async () => {
    const harness = createHarness()
    const first = connect(harness.facade, 'first')
    await subscribe(harness, first, 'a-1')
    const pending = harness.facade.unbind(first.sink)
    check(harness.historyReleases.length === 1, '解除绑定返回前没有同步释放共享资源')
    await pending
    return 'facade.unbind 返回时 history.releaseAll() 已执行'
  })

  await step('同一个 sink 换 owner 时先释放旧 owner', async () => {
    const harness = createHarness()
    const first = connect(harness.facade, 'first')
    await subscribe(harness, first, 'a-1')
    harness.facade.bind(first.sink, randomUUID())
    await waitFor(() => recordCount(harness) === 0, '换 owner 后旧 owner 的记录没有被释放')
    check(harness.fixture.aborted.includes('a-1'), '换 owner 后旧 owner 的上游流没有被中止')
    return '同一个 sink 重新 bind 会释放旧 owner 的流'
  })

  await step('客户端自带 owner 保留，连接关闭不代页面释放', async () => {
    const harness = createHarness()
    const first = connect(harness.facade, 'first')
    const pageOwner = `remote-${randomUUID()}`
    await call(harness.facade, first, 'workspaceChanges.summary', { owner: pageOwner, requestId: randomUUID(), sessionId: 's', seq: 3 })
    check(observedParams(harness, 'workspaceChanges.summary').owner === pageOwner, '客户端自带的页面 owner 被连接 owner 覆盖')
    await call(harness.facade, first, 'session.attachmentFile.prepare', { id: randomUUID() })
    check(observedParams(harness, 'session.attachmentFile.prepare').owner === first.owner, '未带 owner 的 session.attachmentFile.* 没有注入连接 owner')
    await harness.facade.unbind(first.sink)
    check(harness.closed.get('App change comparison cleanup failed')?.includes(pageOwner) !== true, '连接关闭释放了客户端页面 owner')
    return 'workspaceChanges.* 保留页面 owner，session.attachmentFile.* 注入连接 owner；连接关闭只释放连接 owner'
  })

  await step('清理失败只记 warn，不打断释放', async () => {
    const harness = createHarness({ failingLabels: ['App document preview cleanup failed'] })
    const first = connect(harness.facade, 'first')
    await subscribe(harness, first, 'a-1')
    const released = await harness.facade.unbind(first.sink)
    check(released === true, '清理失败不应改变解除绑定的结论')
    check(recordCount(harness) === 0, '清理失败不应阻止流释放')
    check(harness.warnings.some(message => message.includes('App document preview cleanup failed')), '清理失败没有记录 warn')
    check(harness.closed.get('App reference cleanup failed')?.includes(first.owner) === true, '其它资源没有被继续释放')
    return `warn=${JSON.stringify(harness.warnings[0] ?? '')}，其它资源照常释放`
  })

  await step('回归：40 次 连接→订阅→关闭 后仍能订阅', async () => {
    const harness = createHarness({ maxSubscriptions: 32 })
    const ownersSeen = new Set<string>()
    for (let cycle = 1; cycle <= 40; cycle += 1) {
      const connection = connect(harness.facade, `cycle-${cycle}`)
      ownersSeen.add(connection.owner)
      await subscribe(harness, connection, `cycle-${cycle}-follow`)
      await subscribe(harness, connection, `cycle-${cycle}-control`)
      check(recordCount(harness) === 2, `第 ${cycle} 轮连接存续期间应有 2 条记录，实际 ${recordCount(harness)}`)
      await harness.facade.unbind(connection.sink)
      check(recordCount(harness) === 0, `第 ${cycle} 轮关闭后仍有 ${recordCount(harness)} 条记录`)
    }
    check(ownersSeen.size === 40, `40 轮应产生 40 个不同 owner，实际 ${ownersSeen.size}`)
    await harness.streams.close()
    return '40 轮共 80 次订阅全部成功，每轮关闭后记录数 0（未经清理时会在第 33 次触顶）'
  })

  await step('旧行为夹具：共享固定 owner 且从不 closeOwner 时第 33 次订阅被拒', async () => {
    const harness = createHarness({ maxSubscriptions: 32 })
    for (let index = 1; index <= 32; index += 1) {
      const admitted = await harness.streams.subscribe({
        owner: 'remote',
        streamId: `legacy-${index}`,
        subscriptionId: `legacy-${index}`,
        namespace: 'session',
        method: 'follow',
        args: { tag: `legacy-${index}` },
      })
      check(typeof admitted.generation === 'string', `第 ${index} 次订阅没有返回 generation`)
    }
    await expectFailure(
      () => harness.streams.subscribe({
        owner: 'remote',
        streamId: 'legacy-33',
        subscriptionId: 'legacy-33',
        namespace: 'session',
        method: 'follow',
        args: { tag: 'legacy-33' },
      }),
      /App stream limit reached/,
      '共享 owner 的第 33 次订阅应触顶',
    )
    await harness.streams.closeOwner('remote')
    check(recordCount(harness) === 0, 'closeOwner 没有清空共享 owner 的记录')
    return '旧实现（固定 owner、关闭不清理）第 33 次订阅复现 App stream limit reached；closeOwner 后恢复'
  })

  console.log('')
  if (failures.length > 0) {
    console.log(`FAIL  ${passed}/${total} 项通过，${failures.length} 项失败`)
    for (const failure of failures) console.log(`  - ${failure}`)
    return 1
  }
  console.log(`PASS  ${passed}/${passed} 项全部通过（owner 隔离 + 连接关闭释放 + 40 轮回归）`)
  return 0
}

// 兜底看门狗：任何一步把定时器或迭代器留在事件循环里时，不能让自检一直挂着。
const watchdog = setTimeout(() => {
  console.error('FAIL  流生命周期自检在 60 s 内没有结束，判定有流或定时器未收尾。')
  process.exit(1)
}, 60_000)
watchdog.unref()

process.exitCode = await main().catch((error: unknown) => {
  console.error(`FAIL  自检主体抛出：${describeError(error)}`)
  return 1
})
