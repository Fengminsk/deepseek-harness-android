/**
 * 桌面实时会话事件中继自检：证明控制端点、页面线广播、去重与列表合并成立。
 *
 * 运行：`node --import tsx/esm apps/remote-host/scripts/session-events-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本只监听 127.0.0.1 的临时端口，不写用户目录
 * （临时目录立即清理），不连接真实桌面进程、不接触设备令牌。
 *
 * 覆盖：
 * 1. 控制端点：控制头、Content-Type、非法 JSON、事件/状态条数上限、体积上限、
 *    未配置回调 503、合法批次原样交给宿主；
 * 2. 广播：`presentSessionEvent` presentation、`session.event` 参数形状、per-session
 *    seq 去重、无连接/未 ready 安全丢弃、`session.status` 与 `sessions.changed`
 *    触发器（含合并窗口）、广播异常不影响宿主；
 * 3. 列表合并：`sessions.list` 补 `running`、`tasks.session` 补 live、原样返回路径、
 *    超时与读取失败不改变响应；
 * 4. 端到端：真 `DesktopRelayClient` 读临时回环状态的 sessions.list 合并，以及
 *    没有描述文件时保持原响应。
 *
 * @module @deepseek-ai/dsh-remote-host/scripts/session-events-selfcheck
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DesktopRelayClient } from '../src/desktop-relay-client.ts'
import {
  PairingPageServer,
  type PairingPageSource,
  type SessionEventsRelayInput,
} from '../src/pairing-page.ts'
import {
  mergeDesktopRunningIntoSessionsList,
  mergeDesktopRunningIntoTasksSession,
  SessionEventBroadcaster,
  withDesktopSessionFacts,
  type DesktopStatusReader,
  type SessionEventBroadcastTarget,
} from '../src/session-events-relay.ts'

/** 一条自检断言失败。 */
class SelfCheckFailure extends Error {}

let checks = 0

/**
 * 断言为真。
 * @param condition - 条件。
 * @param message - 失败说明。
 */
function check(condition: unknown, message: string): asserts condition {
  checks += 1
  if (condition) return
  throw new SelfCheckFailure(message)
}

/**
 * 收敛任意抛出值为一行。
 * @param error - 抛出值。
 * @returns 文本。
 */
function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** 等待若干毫秒。 */
function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => { setTimeout(resolve, milliseconds) })
}

/** 一条自检用的配对页数据源。 */
function fakeSource(): PairingPageSource {
  const ticket = {
    pairUrl: 'wss://127.0.0.1:1/app#instance=x&token=y',
    usbPairUrl: 'wss://127.0.0.1:1/app#instance=x&token=y',
    expiresAt: Date.now() + 1_000,
  }
  return {
    currentPairing: () => undefined,
    pair: () => ticket,
    devices: () => [],
    revokeDevice: async () => ({ revoked: false, closed: 0 }),
    deleteDevice: async () => ({ deleted: false, wasActive: false, closedConnections: 0 }),
    host: () => ({
      name: 'selfcheck',
      instanceId: '0'.repeat(64),
      origin: 'wss://127.0.0.1:1',
      port: 1,
      discovery: { enabled: false, port: 4_778 },
      listening: true,
    }),
  }
}

/** POST 一帧控制 API 请求。 */
async function postRelay(
  url: string,
  body: string,
  headers: Record<string, string> = {},
): Promise<{ status: number; json?: unknown }> {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-dsh-pairing-control': '1', ...headers },
    body,
  })
  const text = await response.text()
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    json = undefined
  }
  return { status: response.status, ...(json === undefined ? {} : { json }) }
}

/** 断言控制端点的鉴权、上限与合法批次。 */
async function endpointChecks(): Promise<void> {
  const received: SessionEventsRelayInput[] = []
  const pages = new PairingPageServer({
    port: 0,
    source: fakeSource(),
    log: () => {},
    onSessionEventsRelay: (input) => { received.push(input) },
  })
  const start = await pages.start()
  check(start.listening, '配对页应启动成功')
  if (!start.listening) return
  const url = `${start.url}api/session/events/relay`
  try {
    const missingHeader = await postRelay(url, '{}', { 'x-dsh-pairing-control': '' })
    check(missingHeader.status === 403, `缺少控制头必须 403，收到 ${String(missingHeader.status)}`)

    const wrongType = await fetch(url, {
      method: 'POST', headers: { 'x-dsh-pairing-control': '1', 'content-type': 'text/plain' }, body: '{}',
    })
    check(wrongType.status === 415, `非 JSON Content-Type 必须 415，收到 ${String(wrongType.status)}`)

    const malformed = await postRelay(url, '{not-json')
    check(malformed.status === 400, `非法 JSON 必须 400，收到 ${String(malformed.status)}`)

    const empty = await postRelay(url, JSON.stringify({}))
    check(empty.status === 400, `空批次必须 400，收到 ${String(empty.status)}`)

    const tooMany = await postRelay(url, JSON.stringify({
      sessions: [{
        sessionId: 's-1',
        events: Array.from({ length: 33 }, (_value, index) => ({ seq: index + 1, type: 'step/start' })),
      }],
    }))
    check(tooMany.status === 400, `超过 32 条事件必须 400，收到 ${String(tooMany.status)}`)

    const badStatus = await postRelay(url, JSON.stringify({
      statuses: [{ sessionId: 's-1', status: 'paused' }],
    }))
    check(badStatus.status === 400, `非法状态必须 400，收到 ${String(badStatus.status)}`)

    const oversized = await postRelay(url, JSON.stringify({
      sessions: [{
        sessionId: 's-1',
        events: Array.from({ length: 20 }, (_value, index) => ({
          seq: index + 1,
          type: 'tool/result',
          data: { text: 'x'.repeat(8 * 1024) },
        })),
      }],
    }))
    check(oversized.status === 413, `超过体积上限必须 413，收到 ${String(oversized.status)}`)

    const accepted = await postRelay(url, JSON.stringify({
      sessions: [{
        sessionId: 's-1',
        events: [
          { seq: 1, type: 'assistant/message', data: { message: { content: [] } } },
          { seq: 2, type: 'tool/call', data: { name: 'shell' } },
        ],
      }],
      statuses: [{ sessionId: 's-1', status: 'running' }],
    }))
    check(accepted.status === 200, `合法批次必须 200，收到 ${String(accepted.status)}`)
    const acceptedBody = accepted.json as { accepted?: { events?: number; statuses?: number } } | undefined
    check(acceptedBody?.accepted?.events === 2 && acceptedBody.accepted.statuses === 1,
      '响应应回本批接受条数')
    check(received.length > 0, '宿主回调应收到一批')
    const firstBatch = received[0]
    check(firstBatch?.sessions[0]?.events[1]?.['seq'] === 2, '事件应原样交给宿主')
    check(firstBatch?.statuses[0]?.status === 'running', '状态应原样交给宿主')

    const statusOnly = await postRelay(url, JSON.stringify({
      statuses: [{ sessionId: 's-2', status: 'idle' }],
    }))
    check(statusOnly.status === 200, `只有状态也应接受，收到 ${String(statusOnly.status)}`)
    check(received.length === 2 && received.at(-1)?.statuses.length === 1, '状态批次应交给宿主')
  } finally {
    await pages.stop()
  }

  const disabled = new PairingPageServer({ port: 0, source: fakeSource(), log: () => {} })
  const disabledStart = await disabled.start()
  check(disabledStart.listening, '未配置回调的配对页也应启动')
  if (disabledStart.listening) {
    try {
      const response = await postRelay(
        `${disabledStart.url}api/session/events/relay`,
        JSON.stringify({ statuses: [{ sessionId: 's-1', status: 'running' }] }),
      )
      check(response.status === 503, `未配置回调必须 503，收到 ${String(response.status)}`)
    } finally {
      await disabled.stop()
    }
  }
}

/** 一个记录通知的广播目标。 */
interface RecordedTarget extends SessionEventBroadcastTarget {
  readonly calls: { method: string; params?: Record<string, unknown> }[]
}

/** 造一个记录通知的 ready 连接目标。 */
function recordingTarget(state = 'ready'): RecordedTarget {
  const calls: { method: string; params?: Record<string, unknown> }[] = []
  return {
    state,
    calls,
    notify(method, params) { calls.push({ method, ...(params === undefined ? {} : { params }) }) },
  }
}

/** 断言页面线广播、去重与触发器。 */
async function broadcastChecks(): Promise<void> {
  const target = recordingTarget()
  const broadcaster = new SessionEventBroadcaster({ now: () => Date.now(), sessionsChangedThrottleMs: 0 })
  const counts = broadcaster.broadcast({
    sessions: [{
      sessionId: 's-1',
      events: [
        { seq: 5, type: 'assistant/attempt', data: { stream: [] } },
        { seq: 5, type: 'assistant/attempt', data: { stream: [] } },
        { seq: 4, type: 'step/start' },
        { seq: 6, type: 'tool/call', data: { name: 'shell' } },
      ],
    }],
    statuses: [{ sessionId: 's-1', status: 'running' }],
  }, target)
  check(counts.events === 2 && counts.statuses === 1, `去重后应接受 2 个事件/1 个状态，收到 ${JSON.stringify(counts)}`)
  check(target.calls.filter(call => call.method === 'session.event').length === 2, '重复/回退事件不应广播')
  const firstEvent = target.calls.find(call => call.method === 'session.event')
  check(firstEvent?.params?.['sessionId'] === 's-1', 'session.event 应带 sessionId')
  const presented = firstEvent?.params?.['event'] as Record<string, unknown> | undefined
  check(Array.isArray(presented?.['assistantContent']), 'assistant/attempt 应带运行时 presentation')
  check(presented?.['seq'] === 5, 'presentation 不应改写 seq')
  check(target.calls.some(call => call.method === 'session.status'
    && call.params?.['status'] === 'running'), '运行状态应广播 session.status')
  check(target.calls.filter(call => call.method === 'sessions.changed').length === 1,
    '运行态变化应触发一次 sessions.changed')

  // 同一状态重复到达：session.status 仍写，但不重复触发首页刷新；idle 再触发一次。
  const sameStatus = broadcaster.broadcast({
    sessions: [],
    statuses: [{ sessionId: 's-1', status: 'running' }],
  }, target)
  check(sameStatus.sessionsChanged === 0, '相同运行态不应重复触发 sessions.changed')
  const idle = broadcaster.broadcast({
    sessions: [],
    statuses: [{ sessionId: 's-1', status: 'idle' }],
  }, target)
  check(idle.sessionsChanged === 1, '运行态变为 idle 应触发 sessions.changed')
  check(target.calls.filter(call => call.method === 'sessions.changed').length === 2,
    '两次运行态变化应各触发一次 sessions.changed')
  broadcaster.dispose()

  // 合并窗口：第一次变化立即广播，窗口内的第二次变化等窗口结束后补发一次。
  const throttledTarget = recordingTarget()
  const throttled = new SessionEventBroadcaster({ sessionsChangedThrottleMs: 30 })
  throttled.broadcast({
    sessions: [], statuses: [{ sessionId: 's-2', status: 'running' }],
  }, throttledTarget)
  check(throttledTarget.calls.filter(call => call.method === 'sessions.changed').length === 1,
    '第一次运行态变化应立即广播 sessions.changed')
  throttled.broadcast({
    sessions: [], statuses: [{ sessionId: 's-2', status: 'idle' }],
  }, throttledTarget)
  check(throttledTarget.calls.filter(call => call.method === 'sessions.changed').length === 1,
    '合并窗口内的第二次变化不应立即广播')
  await wait(60)
  check(throttledTarget.calls.filter(call => call.method === 'sessions.changed').length === 2,
    '合并窗口结束后应补发一次 sessions.changed')
  throttled.dispose()

  // 无连接 / 未 ready：整批丢弃且不抛错。
  const noConnection = new SessionEventBroadcaster()
  const dropped = noConnection.broadcast({
    sessions: [{ sessionId: 's-1', events: [{ seq: 1, type: 'turn/start' }] }],
    statuses: [{ sessionId: 's-1', status: 'running' }],
  }, undefined)
  check(dropped.events === 0 && dropped.statuses === 0, '没有连接时应安全丢弃')
  noConnection.dispose()

  const closingTarget = recordingTarget('closing')
  const closing = new SessionEventBroadcaster()
  const closingCounts = closing.broadcast({
    sessions: [{ sessionId: 's-1', events: [{ seq: 1, type: 'turn/start' }] }],
    statuses: [],
  }, closingTarget)
  check(closingCounts.events === 0 && closingTarget.calls.length === 0, '未 ready 连接不应写帧')
  closing.dispose()

  // 广播失败（连接正在关闭）：只记日志，不抛给调用方。
  const logs: unknown[] = []
  const throwing = new SessionEventBroadcaster({
    log: entry => logs.push(entry),
  })
  const explodingTarget: SessionEventBroadcastTarget = {
    state: 'ready',
    notify() { throw new Error('socket closed') },
  }
  const failed = throwing.broadcast({
    sessions: [{ sessionId: 's-1', events: [{ seq: 1, type: 'turn/start' }] }],
    statuses: [{ sessionId: 's-1', status: 'running' }],
  }, explodingTarget)
  check(failed.events === 0 && failed.statuses === 0, '广播失败条数应为 0')
  check(logs.length === 1, '广播失败只记一条日志')
  throwing.dispose()
}

/** 断言只读响应合并。 */
function mergeChecks(): void {
  const rows: Record<string, unknown>[] = [
    { sessionId: 's-1', title: 'running on desktop' },
    { header: { id: 's-2' }, title: 'idle' },
    { sessionId: 's-3', title: 'unknown' },
  ]
  const merged = mergeDesktopRunningIntoSessionsList(rows, {
    's-1': { status: 'running' },
    's-2': { status: 'idle' },
  }) as Record<string, unknown>[]
  check(Array.isArray(merged) && merged.length === 3, '合并后行数不变')
  check(merged[0]?.['running'] === true && merged[0]?.['title'] === 'running on desktop',
    '运行中的桌面会话应补 running:true 且保留原字段')
  check(merged[1]?.['running'] === undefined, '非运行状态不应改行')
  check(merged[2]?.['running'] === undefined, '中继没有报告的会话不应改行')
  check(rows[0]?.['running'] === undefined, '合并不应改写子进程返回的数组')
  check(mergeDesktopRunningIntoSessionsList(rows, {}) === rows, '没有桌面状态时应返回原数组')
  const notAList = { sessions: [] }
  check(mergeDesktopRunningIntoSessionsList(notAList, {}) === notAList, '非数组应原样返回')

  const session = { sessionId: 's-1', title: 'task', history: [] }
  const running = mergeDesktopRunningIntoTasksSession(session, 's-1', { status: 'running', queued: 2 }) as Record<string, unknown>
  const live = running['live'] as Record<string, unknown> | undefined
  check(live?.['status'] === 'running' && live['queued'] === 2 && live['sessionId'] === 's-1',
    'tasks.session 应补与运行时同形的 live 记录')
  check(mergeDesktopRunningIntoTasksSession(session, 's-1', { status: 'idle' }) === session,
    '非运行状态不应改 tasks.session')
  const alreadyLive = { ...session, live: { sessionId: 's-1', status: 'running' } }
  check(mergeDesktopRunningIntoTasksSession(alreadyLive, 's-1', { status: 'running' }) === alreadyLive,
    '已有运行中 live 时不应覆盖')
}

/** 断言 {@link withDesktopSessionFacts} 的合并、失败与超时路径。 */
async function factsChecks(): Promise<void> {
  const rows = [{ sessionId: 's-1', title: 'a' }]
  const statuses = { 's-1': { status: 'running' as const } }
  const reader: DesktopStatusReader = { sessionsStatus: async () => statuses }
  const merged = await withDesktopSessionFacts('sessions.list', {}, rows, reader) as Record<string, unknown>[]
  check(merged[0]?.['running'] === true, 'sessions.list 应由桌面状态补 running')

  const tasks = await withDesktopSessionFacts(
    'tasks.session', { sessionId: 's-1' }, { sessionId: 's-1' }, reader,
  ) as Record<string, unknown>
  check((tasks['live'] as Record<string, unknown> | undefined)?.['status'] === 'running',
    'tasks.session 应由桌面状态补 live')

  const other = { unchanged: true }
  check(await withDesktopSessionFacts('session.readWindow', {}, other, reader) === other,
    '其它方法不应读取桌面状态')

  const failingReader: DesktopStatusReader = {
    sessionsStatus: async () => { throw new Error('desktop relay down') },
  }
  const logs: unknown[] = []
  check(await withDesktopSessionFacts('sessions.list', {}, rows, failingReader, {
    log: entry => logs.push(entry),
  }) === rows, '读取失败应原样返回响应')
  check(logs.length === 1, '读取失败应记一条日志')

  const hangingReader: DesktopStatusReader = {
    sessionsStatus: () => new Promise<Readonly<Record<string, { readonly status: 'running' }>>>(() => {
      // 永不兑现：验证补充读取的等待上限。
    }),
  }
  const startedAt = Date.now()
  check(await withDesktopSessionFacts('sessions.list', {}, rows, hangingReader, { timeoutMs: 20 }) === rows,
    '读取超时应原样返回响应')
  check(Date.now() - startedAt < 1_000, '超时上限应远小于一次请求超时')

  check(await withDesktopSessionFacts('sessions.list', {}, rows, undefined) === rows,
    '没有桌面中继时应原样返回响应')
}

/** 启动一个假桌面中继；返回 base URL。 */
async function fakeDesktopRelay(): Promise<{ url: string; stop(): Promise<void>; server: Server }> {
  const server = createServer((_request: IncomingMessage, response: ServerResponse) => {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({
      ok: true,
      sessions: {
        's-1': { status: 'running', toolName: 'shell' },
        's-2': { status: 'idle' },
      },
    }))
  })
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => resolve())
  })
  const address = server.address()
  if (address === null || typeof address === 'string') throw new SelfCheckFailure('假桌面中继没有端口')
  return {
    url: `http://127.0.0.1:${String(address.port)}`,
    server,
    async stop() { await new Promise<void>(resolve => server.close(() => resolve())) },
  }
}

/** 端到端：真 DesktopRelayClient + 临时回环状态 → sessions.list 合并。 */
async function clientMergeChecks(): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-session-events-selfcheck-'))
  try {
    const descriptorFile = join(directory, 'relay.json')
    const client = new DesktopRelayClient({ file: descriptorFile, statusTimeoutMs: 500 })
    const rows = [{ sessionId: 's-1', title: 'a' }, { sessionId: 's-2', title: 'b' }]
    const withoutDescriptor = await withDesktopSessionFacts('sessions.list', {}, rows, client)
    check(withoutDescriptor === rows, '没有 descriptor 时列表保持原样')

    const relay = await fakeDesktopRelay()
    try {
      await writeFile(descriptorFile, JSON.stringify({ url: relay.url, token: 'a'.repeat(64) }), 'utf8')
      const merged = await withDesktopSessionFacts('sessions.list', {}, rows, client) as Record<string, unknown>[]
      check(merged[0]?.['running'] === true, '真中继应在 sessions.list 上补 desktop running')
      check(merged[1]?.['running'] === undefined, '非运行会话不应补 running')
    } finally {
      await relay.stop()
    }
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

/** 端到端：控制 API → 宿主广播 → 页面线通知（含宿主侧 seq 去重）。 */
async function endToEndChecks(): Promise<void> {
  const target = recordingTarget()
  const broadcaster = new SessionEventBroadcaster({ sessionsChangedThrottleMs: 0 })
  const pages = new PairingPageServer({
    port: 0,
    source: fakeSource(),
    log: () => {},
    onSessionEventsRelay: (input) => { broadcaster.broadcast(input, target) },
  })
  const start = await pages.start()
  check(start.listening, '端到端配对页应启动成功')
  if (!start.listening) return
  try {
    const url = `${start.url}api/session/events/relay`
    const first = await postRelay(url, JSON.stringify({
      sessions: [{ sessionId: 's-9', events: [{ seq: 7, type: 'step/start' }] }],
      statuses: [{ sessionId: 's-9', status: 'running' }],
    }))
    check(first.status === 200, `端到端批次应接受，收到 ${String(first.status)}`)
    const events = target.calls.filter(call => call.method === 'session.event')
    check(events.length === 1 && events[0]?.params?.['sessionId'] === 's-9', '控制 API 应广播 session.event')
    check(target.calls.some(call => call.method === 'session.status'
      && call.params?.['status'] === 'running'), '控制 API 应广播 session.status')
    check(target.calls.filter(call => call.method === 'sessions.changed').length === 1,
      '运行态变化应触发 sessions.changed')

    const repeated = await postRelay(url, JSON.stringify({
      sessions: [{ sessionId: 's-9', events: [{ seq: 7, type: 'step/start' }] }],
      statuses: [],
    }))
    check(repeated.status === 200, '重复事件批次仍应被接受')
    check(target.calls.filter(call => call.method === 'session.event').length === 1,
      '宿主侧应按 seq 丢弃重复事件')
  } finally {
    broadcaster.dispose()
    await pages.stop()
  }
}

/** 运行全部自检。 */
async function main(): Promise<void> {
  await endpointChecks()
  await broadcastChecks()
  mergeChecks()
  await factsChecks()
  await clientMergeChecks()
  await endToEndChecks()
  console.log(`session-events-selfcheck: PASS ${String(checks)}/${String(checks)}`)
}

main().catch((error: unknown) => {
  console.error(`session-events-selfcheck 失败：${describe(error)}`)
  process.exitCode = 1
})
