/**
 * Plan-B 桌面中继自检：证明 remote-host 侧的中继判定、回退与客户端协议成立。
 *
 * 运行：`node --import tsx/esm apps/remote-host/scripts/relay-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本只监听 127.0.0.1 的临时端口，不写用户目录
 * （临时目录立即清理），不接触真实桌面中继或设备令牌。
 *
 * 覆盖：
 * 1. 写句柄冲突识别；附件/空文本不中继；
 * 2. 本地成功不调用中继；无关错误原样抛出；
 * 3. 写冲突才中继并返回同形结果；中继失败保留原错误（不重复发送）；
 * 4. DesktopRelayClient：无 descriptor / 错误 token / 超时 / 正常发送 / 状态读取；
 * 5. 中继请求头使用 descriptor token，且响应结构按 facade 结果透传。
 *
 * @module @deepseek-ai/dsh-remote-host/scripts/relay-selfcheck
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DesktopRelayClient, DesktopRelayUnavailableError } from '../src/desktop-relay-client.ts'
import { PairingPageServer, type PairingPageSource } from '../src/pairing-page.ts'
import {
  dispatchWithSessionRelay,
  isWriteHandleConflict,
  relaySendRequest,
} from '../src/session-relay.ts'

/** 一条自检断言失败。 */
class SelfCheckFailure extends Error {}

/**
 * 断言为真。
 * @param condition - 条件。
 * @param message - 失败说明。
 */
function check(condition: unknown, message: string): asserts condition {
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

/** 一条用于断言的写句柄冲突错误。 */
function writeConflict(): Error {
  return new Error('session "s-1" is already owned by an active write handle')
}

/** 本地/中继调用记录。 */
interface Calls {
  local: number
  relay: number
}

/** 跑中继判定场景。 */
async function sessionRelayChecks(): Promise<void> {
  check(isWriteHandleConflict(writeConflict()), '写句柄冲突必须识别')
  check(isWriteHandleConflict(new Error('session/write-conflict')), '冲突 code 必须识别')
  check(!isWriteHandleConflict(new Error('boom')), '无关错误不能识别为冲突')
  const textParams = { sessionId: 's-1', requestId: 'r-1', text: 'hello', provider: 'p', model: 'm', selectModel: true }
  check(relaySendRequest(textParams)?.text === 'hello', '文本发送应可中继')
  check(relaySendRequest({ ...textParams, attachmentIds: ['a'] }) === undefined, '附件发送不中继')
  check(relaySendRequest({ sessionId: 's-1', text: '' }) === undefined, '空文本不中继')

  const calls: Calls = { local: 0, relay: 0 }
  /** Read the relay counter through a call so assertion narrowing cannot over-narrow it. */
  const relayCalls = (): number => calls.relay
  const relay = {
    async send() {
      calls.relay += 1
      return { accepted: true, relayed: true }
    },
  }
  // 本地成功：绝不再调中继。
  const localOk = await dispatchWithSessionRelay({
    method: 'session.send', params: textParams,
    local: () => { calls.local += 1; return { accepted: true, local: true } },
    relay: relay as never,
  })
  check((localOk as { local?: boolean }).local === true && relayCalls() === 0, '本地成功不中继')

  // 写冲突：relay 一次并返回同形结果。
  const relayed = await dispatchWithSessionRelay({
    method: 'session.send', params: textParams,
    local: () => { throw writeConflict() },
    relay: relay as never,
  })
  check(relayCalls() === 1 && (relayed as { relayed?: boolean }).relayed === true, '写冲突应中继一次')

  // 附件冲突：不中继，保留原错误。
  calls.relay = 0
  let attachmentError: unknown
  try {
    await dispatchWithSessionRelay({
      method: 'session.send', params: { ...textParams, attachmentIds: ['a'] },
      local: () => { throw writeConflict() },
      relay: relay as never,
    })
  } catch (error) {
    attachmentError = error
  }
  check(relayCalls() === 0 && attachmentError === undefined ? false : attachmentError instanceof Error,
    '附件冲突应保留原错误')
  check(describe(attachmentError).includes('active write handle'), '附件冲突错误文本保留')

  // 非 session.send 或无关错误：原样抛出。
  const relaysBefore = calls.relay
  let otherError: unknown
  try {
    await dispatchWithSessionRelay({
      method: 'session.command', params: textParams,
      local: () => { throw writeConflict() },
      relay: relay as never,
    })
  } catch (error) {
    otherError = error
  }
  check(otherError instanceof Error && relayCalls() === relaysBefore, '非发送方法不中继')

  // 中继失败：保留原错误并附上可读原因。
  let relayFailure: unknown
  try {
    await dispatchWithSessionRelay({
      method: 'session.send', params: textParams,
      local: () => { throw writeConflict() },
      relay: { async send() { throw new DesktopRelayUnavailableError('timeout', '桌面中继请求超时。') } } as never,
    })
  } catch (error) {
    relayFailure = error
  }
  check(relayFailure instanceof Error && describe(relayFailure).includes('active write handle'),
    '中继失败保留原错误')
  check(describe(relayFailure).includes('桌面中继请求超时'), '中继失败附上原因')

  // 无中继客户端：保持原错误。
  let noRelay: unknown
  try {
    await dispatchWithSessionRelay({
      method: 'session.send', params: textParams,
      local: () => { throw writeConflict() },
      relay: undefined,
    })
  } catch (error) {
    noRelay = error
  }
  check(noRelay instanceof Error && describe(noRelay).includes('active write handle'), '无 descriptor 保持原行为')
}

/** 启动一个假桌面中继；返回 base URL 与收到的请求数。 */
async function fakeRelay(options: { token: string; delayMs?: number }): Promise<{
  server: Server
  url: string
  requests: number
  stop(): Promise<void>
}> {
  const state = { requests: 0 }
  const server = createServer((request: IncomingMessage, response: ServerResponse) => {
    state.requests += 1
    const authorized = request.headers['x-dsh-desktop-relay'] === options.token
    if (!authorized) {
      response.writeHead(403, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ ok: false, error: { code: 'relay/unauthorized', message: 'bad token' } }))
      return
    }
    const chunks: Buffer[] = []
    request.on('data', (chunk: Buffer) => chunks.push(chunk))
    request.on('end', () => {
      const reply = (): void => {
        response.writeHead(200, { 'content-type': 'application/json' })
        if (request.url?.startsWith('/relay/session/send') === true) {
          const body = JSON.parse(Buffer.concat(chunks).toString('utf8')) as { text?: string }
          response.end(JSON.stringify({ ok: true, result: { accepted: true, echoed: body.text } }))
        } else if (request.url?.startsWith('/relay/session/status') === true) {
          response.end(JSON.stringify({ ok: true, status: 'running', toolName: 'wait_agent' }))
        } else {
          response.end(JSON.stringify({ ok: true, sessions: { 's-1': { status: 'running' } } }))
        }
      }
      if (options.delayMs === undefined) reply()
      else setTimeout(reply, options.delayMs)
    })
  })
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => resolve())
  })
  const address = server.address()
  if (address === null || typeof address === 'string') throw new SelfCheckFailure('假中继没有端口')
  const url = `http://127.0.0.1:${String(address.port)}`
  return {
    server,
    url,
    get requests() { return state.requests },
    async stop() { await new Promise<void>(resolve => server.close(() => resolve())) },
  }
}

/** 验证 DesktopRelayClient 的 descriptor、鉴权、超时与形状。 */
async function clientChecks(): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-relay-selfcheck-'))
  try {
    const descriptorFile = join(directory, 'relay.json')
    const client = new DesktopRelayClient({ file: descriptorFile, timeoutMs: 500 })
    check(!(await client.available()), '缺少 descriptor 时不可用')
    let missing: unknown
    try {
      await client.send({ sessionId: 's-1', text: 'x' })
    } catch (error) {
      missing = error
    }
    check(missing instanceof DesktopRelayUnavailableError && missing.code === 'no-descriptor',
      '缺少 descriptor 的发送应抛 no-descriptor')

    const token = 'a'.repeat(64)
    const relay = await fakeRelay({ token })
    try {
      await writeFile(descriptorFile, JSON.stringify({ url: relay.url, token, pid: 1, createdAt: 1 }), 'utf8')
      check(await client.available(), 'descriptor 存在时可用')
      const result = await client.send({ sessionId: 's-1', requestId: 'r-1', text: 'hello' })
      check((result as { accepted?: boolean; echoed?: string }).accepted === true
        && (result as { echoed?: string }).echoed === 'hello', '发送结果按 facade 形状透传')
      const status = await client.sessionStatus('s-1')
      check(status.status === 'running' && status.toolName === 'wait_agent', '状态端点读取')
      const all = await client.sessionsStatus()
      check(all['s-1']?.status === 'running', '批量状态读取')

      await writeFile(descriptorFile, JSON.stringify({ url: relay.url, token: 'b'.repeat(64) }), 'utf8')
      let unauthorized: unknown
      try {
        await client.send({ sessionId: 's-1', text: 'x' })
      } catch (error) {
        unauthorized = error
      }
      check(unauthorized instanceof DesktopRelayUnavailableError && unauthorized.code === 'unauthorized',
        '错误 token 应抛 unauthorized')
    } finally {
      await relay.stop()
    }

    const slow = await fakeRelay({ token, delayMs: 1_500 })
    try {
      await writeFile(descriptorFile, JSON.stringify({ url: slow.url, token }), 'utf8')
      let timeout: unknown
      try {
        await client.send({ sessionId: 's-1', text: 'x' })
      } catch (error) {
        timeout = error
      }
      check(timeout instanceof DesktopRelayUnavailableError && timeout.code === 'timeout',
        '超时应抛 timeout')
    } finally {
      await slow.stop()
    }

    await writeFile(descriptorFile, JSON.stringify({ url: 'http://example.test:1', token: 'c'.repeat(64) }), 'utf8')
    check(!(await client.available()), '非回环 URL 的 descriptor 不可用')
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

/** 验证控制 API 的通知中继端点：鉴权、形状、回调与安全丢弃。 */
async function notificationRelayChecks(): Promise<void> {
  const received: { method: string; params: Record<string, unknown> }[][] = []
  const source: PairingPageSource = {
    currentPairing: () => undefined,
    pair: () => ({ pairUrl: 'wss://127.0.0.1:1/app#instance=x&token=y', usbPairUrl: 'wss://127.0.0.1:1/app#instance=x&token=y', expiresAt: Date.now() + 1_000 }),
    devices: () => [],
    revokeDevice: async () => ({ revoked: false, closed: 0 }),
    deleteDevice: async () => ({ deleted: false, wasActive: false, closedConnections: 0 }),
    host: () => ({ name: 'selfcheck', instanceId: '0'.repeat(64), origin: 'wss://127.0.0.1:1', port: 1, discovery: { enabled: false, port: 4_778 }, listening: true }),
  }
  const pages = new PairingPageServer({
    port: 0,
    source,
    log: () => {},
    onNotificationsRelay: notifications => { received.push([...notifications]) },
  })
  const start = await pages.start()
  check(start.listening, '配对页应启动成功')
  if (!start.listening) return
  try {
    const url = `${start.url}api/notifications/relay`
    const unauthorized = await fetch(url, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}',
    })
    check(unauthorized.status === 403, '通知中继缺少控制头必须 403，收到 ' + String(unauthorized.status))

    const bad = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-dsh-pairing-control': '1' },
      body: JSON.stringify({ notifications: [{ method: 'unknown.method', params: {} }] }),
    })
    check(bad.status === 400, '非白名单方法必须 400')

    const ok = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-dsh-pairing-control': '1' },
      body: JSON.stringify({ notifications: [{ method: 'task.completed', params: { sessionId: 's-1', turn: 1 } }] }),
    })
    check(ok.status === 200 && ((await ok.json()) as { accepted?: number }).accepted === 1, '通知批应被接受')
    check(received.length === 1 && received[0]?.[0]?.method === 'task.completed', '宿主回调应收到页面线通知')
  } finally {
    await pages.stop()
  }

  const disabled = new PairingPageServer({ port: 0, source, log: () => {} })
  const disabledStart = await disabled.start()
  check(disabledStart.listening, '未配置回调的配对页也应启动')
  if (disabledStart.listening) {
    try {
      const response = await fetch(`${disabledStart.url}api/notifications/relay`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-dsh-pairing-control': '1' },
        body: JSON.stringify({ notifications: [{ method: 'task.completed', params: { sessionId: 's-1' } }] }),
      })
      check(response.status === 503, '未配置通知中继时应返回 503 并安全丢弃')
    } finally {
      await disabled.stop()
    }
  }
}

/** 运行全部自检。 */
async function main(): Promise<void> {
  await sessionRelayChecks()
  await clientChecks()
  await notificationRelayChecks()
  console.log('relay-selfcheck: 全部通过')
}

main().catch((error: unknown) => {
  console.error(`relay-selfcheck 失败：${describe(error)}`)
  process.exitCode = 1
})
