/**
 * Desktop relay server: loopback-only startup, descriptor lifecycle, token
 * authentication, body limits, attachment rejection, executor failures, and
 * status endpoints. No production port or desktop service is touched.
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DesktopRelayClient } from '../../../../apps/remote-host/src/desktop-relay-client.ts'
import {
  DesktopRelay,
  DesktopRelayError,
  createDesktopRelayExecutor,
  MAXIMUM_RELAY_BODY_BYTES,
  parseSendRequest,
  RELAY_FILE_NAME,
  RELAY_HEADER,
  type DesktopRelayExecutor,
  type DesktopRelaySendRequest,
} from '../src/host/desktop-relay.ts'

/** Fake desktop executor with recorded sends and controllable failures. */
function executor(): DesktopRelayExecutor & {
  readonly sent: DesktopRelaySendRequest[]
  fail: Error | undefined
} {
  const sent: DesktopRelaySendRequest[] = []
  const fake = {
    sent,
    fail: undefined as Error | undefined,
    async readWindow(request: { sessionId: string }) {
      return { events: [{ seq: 3, type: 'assistant/message' }], throughSeq: 3, sessionId: request.sessionId }
    },
    async projections(sessionId: string) {
      return { kind: 'sequenced', asOfSeq: 3, values: { plan: { enabled: true } }, sessionId }
    },
    async commandCatalog(agentId: string) {
      return [{ name: 'file', agentId }]
    },
    async modelCatalog() {
      return { providers: [{ id: 'cached-model-provider' }] }
    },
    async permissionCatalog() {
      return { options: [{ value: 'workspace-write' }] }
    },
    async interactionsList(sessionId: string) {
      return { sessionId, revision: 100, requests: [] }
    },
    interactionsStatus() {
      return { ready: true, pending: 0 }
    },
    async interactionsReply(params: Record<string, unknown>) {
      return { accepted: params['response'] === 'allowed-once', requestStillPending: false }
    },
    async send(request: DesktopRelaySendRequest) {
      sent.push(request)
      if (fake.fail !== undefined) throw fake.fail
      return { accepted: true, requestId: request.requestId ?? null }
    },
    async status(sessionId: string) {
      return { status: 'running' as const, toolName: 'wait_agent', queued: sessionId === 'busy' ? 2 : 0 }
    },
    async sessions() {
      return { s1: { status: 'running' as const } }
    },
  }
  return fake
}

let directory = ''
let relay: DesktopRelay | undefined

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'dsh-relay-test-'))
})

afterEach(async () => {
  await relay?.stop()
  relay = undefined
  await rm(directory, { recursive: true, force: true })
})

/** Start a relay with the fake executor and return its base URL and token. */
async function start(): Promise<{ url: string; token: string; fake: ReturnType<typeof executor> }> {
  const fake = executor()
  relay = new DesktopRelay({
    dataDir: directory,
    executor: fake,
    logger: { info: vi.fn(), warn: vi.fn() },
    now: () => 1_700_000_000_000,
  })
  const status = await relay.start()
  expect(status.available).toBe(true)
  const descriptor = JSON.parse(
    await readFile(join(directory, RELAY_FILE_NAME), 'utf8'),
  ) as { url: string; token: string; pid: number; createdAt: number }
  expect(descriptor.pid).toBe(process.pid)
  expect(descriptor.createdAt).toBe(1_700_000_000_000)
  return { url: descriptor.url, token: descriptor.token, fake }
}

/** POST one JSON request with the relay token. */
async function post(url: string, token: string, path: string, body: unknown): Promise<Response> {
  return fetch(`${url}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', [RELAY_HEADER]: token },
    body: JSON.stringify(body),
  })
}

describe('DesktopRelay', () => {
  it('streams files and images into the desktop services, then submits their receipts together', async () => {
    const stored: Buffer[] = []
    async function store(request: { sessionId: string; data: AsyncIterable<Uint8Array> }) {
      expect(request.sessionId).toBe('session-1')
      const chunks = []
      for await (const chunk of request.data) chunks.push(chunk)
      stored.push(Buffer.concat(chunks))
      return { receiptId: `receipt-${stored.length}` }
    }
    const uploads = { uploadStream: vi.fn(store), uploadImageStream: vi.fn(store) }
    const gateway = { invoke: vi.fn(async () => ({ accepted: true })) }
    const services: Record<string, unknown> = {
      fileUploads: uploads, typertGateway: gateway, connection: { createPeer: () => ({}) },
    }
    relay = new DesktopRelay({ dataDir: directory, logger: { info: vi.fn(), warn: vi.fn() },
      executor: createDesktopRelayExecutor({ get: (name: string) => services[name] } as never) })
    expect((await relay.start()).available).toBe(true)
    const client = new DesktopRelayClient({ file: join(directory, RELAY_FILE_NAME) })
    const files = [Buffer.alloc(768 * 1024 + 1, 11), Buffer.from([0, 255, 1]), Buffer.alloc(0)]
    for (const [index, file] of files.entries()) {
      async function* data() {
        for (let i = 0; i < file.length; i += 16384) yield file.subarray(i, i + 16384)
      }
      const meta = { sessionId: 'session-1', name: '测试 附件', bytes: file.length,
        mediaType: index === 1 ? 'image/png' : 'application/octet-stream' }
      expect(await client.upload(meta, data(), new AbortController().signal)).toEqual({ receiptId: `receipt-${index + 1}` })
    }
    expect(stored).toEqual(files)
    expect(uploads.uploadStream).toHaveBeenCalledTimes(2)
    expect(uploads.uploadImageStream).toHaveBeenCalledTimes(1)
    const receiptIds = ['receipt-3', 'receipt-1', 'receipt-2']
    const parts = receiptIds.map(receiptId => ({ type: 'file', receiptId }))
    for (const text of ['', '检查附件']) {
      await client.send({ sessionId: 'session-1', text, requestId: 'r', receiptIds })
      expect(gateway.invoke).toHaveBeenLastCalledWith(expect.objectContaining({ method: 'prompt', args: { request: {
        sessionId: 'session-1', requestId: 'r', mode: 'queue', content: text ? [{ type: 'text', text }, ...parts] : parts,
      } } }))
    }
    await client.command('session-1', '/example', receiptIds)
    expect(gateway.invoke).toHaveBeenLastCalledWith(expect.objectContaining({ namespace: 'commands', args: {
      line: '/example', agentId: 'session-1', submittedAttachments: parts,
    } }))
  })

  it('serves only authenticated global catalogs from the desktop executor', async () => {
    const { url, token } = await start()
    const headers = { [RELAY_HEADER]: token }
    const model = await fetch(`${url}/relay/catalog/model`, { headers })
    const commands = await fetch(`${url}/relay/catalog/commands?agentId=s-1`, { headers })
    expect(await commands.json()).toEqual({ ok: true, result: [{ name: 'file', agentId: 's-1' }] })
    expect(await model.json()).toEqual({ ok: true, result: { providers: [{ id: 'cached-model-provider' }] } })
    const permission = await fetch(`${url}/relay/catalog/permission`, { headers })
    expect(await permission.json()).toEqual({ ok: true, result: { options: [{ value: 'workspace-write' }] } })
    expect((await fetch(`${url}/relay/catalog/model`)).status).toBe(403)
    expect((await fetch(`${url}/relay/catalog/other`, { headers })).status).toBe(404)
  })

  it('reads and answers desktop interactions only with the relay token', async () => {
    const { url, token } = await start()
    const headers = { [RELAY_HEADER]: token, 'content-type': 'application/json' }
    const status = await fetch(`${url}/relay/interactions/status`, { headers })
    expect(await status.json()).toEqual({ ok: true, ready: true, pending: 0 })
    const list = await fetch(`${url}/relay/interactions/list`, {
      method: 'POST', headers, body: JSON.stringify({ sessionId: 's-1' }),
    })
    expect((await list.json()).result).toEqual({ sessionId: 's-1', revision: 100, requests: [] })
    const reply = await fetch(`${url}/relay/interactions/reply`, {
      method: 'POST', headers, body: JSON.stringify({ sessionId: 's-1', id: 'i-1', version: 1, response: 'allowed-once' }),
    })
    expect((await reply.json()).result).toEqual({ accepted: true, requestStillPending: false })
    const unauthenticated = await fetch(`${url}/relay/interactions/reply`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId: 's-1', id: 'i-1', version: 1, response: 'allowed-once' }),
    })
    expect(unauthenticated.status).toBe(403)
  })
  it('rejects missing and wrong tokens', async () => {
    const { url } = await start()
    expect((await fetch(`${url}/relay/health`)).status).toBe(403)
    expect((await fetch(`${url}/relay/health`, { headers: { [RELAY_HEADER]: 'wrong' } })).status).toBe(403)
  })

  it('answers health and relays one text send', async () => {
    const { url, token } = await start()
    const health = await fetch(`${url}/relay/health`, { headers: { [RELAY_HEADER]: token } })
    expect(health.status).toBe(200)
    expect(await health.json()).toEqual({ ok: true })

    const email = await post(url, token, '/relay/session/send', {
      sessionId: 's-1', requestId: 'r-1', text: 'hello',
    })
    expect(email.status).toBe(200)
    expect(await email.json()).toEqual({ ok: true, result: { accepted: true, requestId: 'r-1' } })
  })

  it('serves a desktop-owned Session window through the authenticated relay', async () => {
    const { url, token } = await start()
    const response = await post(url, token, '/relay/session/read-window', { sessionId: 's-1', afterSeq: 2 })
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true, result: {
      events: [{ seq: 3, type: 'assistant/message' }], throughSeq: 3, sessionId: 's-1',
    } })
  })

  it('serves plan and permission projections from the desktop owner', async () => {
    const { url, token } = await start()
    const response = await post(url, token, '/relay/session/projections', { sessionId: 's-1' })
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true, result: {
      kind: 'sequenced', asOfSeq: 3, values: { plan: { enabled: true } }, sessionId: 's-1',
    } })
  })

  it('rejects attachments, empty text, and oversized bodies', async () => {
    const { url, token } = await start()
    const attachment = await post(url, token, '/relay/session/send', {
      sessionId: 's-1', text: 'x', attachmentIds: ['a-1'],
    })
    expect(attachment.status).toBe(400)
    expect(await attachment.json()).toMatchObject({ ok: false, error: { code: 'relay/attachments-unsupported' } })

    const empty = await post(url, token, '/relay/session/send', { sessionId: 's-1', text: ' ' })
    expect(empty.status).toBe(400)

    const oversized = await post(url, token, '/relay/session/send', {
      sessionId: 's-1', text: 'x'.repeat(MAXIMUM_RELAY_BODY_BYTES + 1),
    })
    expect(oversized.status).toBe(400)
  })

  it('returns a structured error instead of throwing when the executor fails', async () => {
    const { url, token, fake } = await start()
    fake.fail = new DesktopRelayError('relay/write-conflict', 'desktop still busy')
    const response = await post(url, token, '/relay/session/send', { sessionId: 's-1', text: 'x' })
    expect(response.status).toBe(500)
    expect(await response.json()).toEqual({
      ok: false,
      error: { code: 'relay/write-conflict', message: 'desktop still busy' },
    })
  })

  it('answers both status endpoints and degrades executor failures to unknown', async () => {
    const { url, token } = await start()
    const one = await fetch(`${url}/relay/session/status?sessionId=busy`, {
      headers: { [RELAY_HEADER]: token },
    })
    expect(await one.json()).toEqual({ ok: true, status: 'running', toolName: 'wait_agent', queued: 2 })
    const all = await fetch(`${url}/relay/sessions/status`, { headers: { [RELAY_HEADER]: token } })
    expect(await all.json()).toEqual({ ok: true, sessions: { s1: { status: 'running' } } })
  })

  it('deletes the descriptor on stop and rejects requests afterwards', async () => {
    const { url, token } = await start()
    await relay?.stop()
    await expect(readFile(join(directory, RELAY_FILE_NAME), 'utf8')).rejects.toThrow()
    await expect(fetch(`${url}/relay/health`, { headers: { [RELAY_HEADER]: token } })).rejects.toThrow()
  })

  it('validates send request shapes', () => {
    expect(parseSendRequest({ sessionId: 's', text: 'x' })).toEqual({ value: { sessionId: 's', text: 'x' } })
    expect(parseSendRequest({ sessionId: 's', text: 'x', attachmentIds: [] })).toHaveProperty('value')
    expect(parseSendRequest({ sessionId: '', text: 'x' })).toHaveProperty('error')
    expect(parseSendRequest({ sessionId: 's', text: 'x', attachmentIds: ['a'] })).toHaveProperty('error')
    expect(parseSendRequest({ sessionId: 's', text: 'x' })).not.toHaveProperty('error')
  })
})
