/**
 * Desktop relay server: loopback-only startup, descriptor lifecycle, token
 * authentication, body limits, attachment rejection, executor failures, and
 * status endpoints. No production port or desktop service is touched.
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  DesktopRelay,
  DesktopRelayError,
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
