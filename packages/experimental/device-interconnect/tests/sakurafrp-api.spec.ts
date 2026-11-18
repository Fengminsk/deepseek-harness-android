/**
 * The SakuraFrp API v4 client: request shape, response parsing, and the error
 * mapping the provision turns into user-visible messages.
 */

import { describe, expect, it, vi } from 'vitest'
import {
  SakuraFrpApiError, createSakuraFrpApi, parseCreatedTunnel, parseNodes, parseTunnels, parseUserInfo,
} from '../src/host/sakurafrp-api.ts'

/** One recorded API request. */
interface Recorded {
  readonly url: string
  readonly method: string
  readonly token: string | undefined
  readonly body: unknown
}

/**
 * Build one API client over a fake fetch.
 * @param answer - per-call response factory: status plus body text.
 * @returns the client and every recorded request.
 */
function bench(answer: (call: number) => { readonly status?: number; readonly body?: unknown; readonly text?: string }) {
  const requests: Recorded[] = []
  let call = 0
  const fetchImplementation: typeof fetch = async (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    const headers = new Headers(init?.headers)
    requests.push({
      url,
      method: init?.method ?? 'GET',
      token: headers.get('authorization') ?? undefined,
      body: typeof init?.body === 'string' ? JSON.parse(init.body) as unknown : undefined,
    })
    const response = answer(call)
    call += 1
    const body = response.text ?? JSON.stringify(response.body ?? {})
    return new Response(body, { status: response.status ?? 200, headers: { 'content-type': 'application/json' } })
  }
  const api = createSakuraFrpApi({ token: 'secret-key', fetch: fetchImplementation, baseUrl: 'https://api.test/v4' })
  return { api, requests }
}

describe('SakuraFrp API client', () => {
  it('sends the bearer token and reads the account', async () => {
    const { api, requests } = bench(() => ({
      body: { id: 7, name: 'alice', speed: 10, tunnels: 2, traffic: [1, 100], realname: 1 },
    }))
    const user = await api.userInfo()
    expect(user).toEqual({ id: 7, name: 'alice', speed: 10, tunnels: 2, traffic: [1, 100], realname: 1, frozen: false })
    expect(requests[0]).toMatchObject({ url: 'https://api.test/v4/user/info', method: 'GET', token: 'Bearer secret-key' })
  })

  it('reports a frozen account with its reason', () => {
    const user = parseUserInfo({ id: 7, name: 'alice', ban: { reason: '违规使用' } })
    expect(user).toMatchObject({ frozen: true, frozenReason: '账号已被冻结：违规使用' })
    expect(parseUserInfo({ id: 7, name: 'alice', ban: {} })).toMatchObject({ frozen: false })
  })

  it('reads the node map in service order', async () => {
    const { api } = bench(() => ({
      body: { '11': { name: 'A', host: 'a.natfrp.cloud', vip: 1, flag: 4 }, '12': { name: 'B', host: 'b.natfrp.cloud' } },
    }))
    await expect(api.listNodes()).resolves.toEqual([
      { id: 11, name: 'A', host: 'a.natfrp.cloud', vip: 1, flag: 4 },
      { id: 12, name: 'B', host: 'b.natfrp.cloud', vip: 0, flag: 0 },
    ])
    expect(parseNodes({ bad: { name: 'A' } })).toBeUndefined()
  })

  it('reads tunnels, including a numeric remote port', async () => {
    const { api } = bench(() => ({
      body: [{ id: 1, name: 't', type: 'tcp', node: 11, local_ip: '127.0.0.1', local_port: 4777, remote: 12345 }],
    }))
    await expect(api.listTunnels()).resolves.toEqual([
      { id: 1, name: 't', type: 'tcp', node: 11, localIp: '127.0.0.1', localPort: 4777, remote: '12345' },
    ])
    expect(parseTunnels([{ id: 1, name: 't', type: 'tcp' }])).toBeUndefined()
  })

  it('creates a TCP tunnel and surfaces the provider warning', async () => {
    const { api, requests } = bench(() => ({
      status: 201,
      body: { id: 9, name: 'DSH', remote: '23456', important_warning_for_ai: '仅供远程访问' },
    }))
    const created = await api.createTunnel({ name: 'DSH', nodeId: 11, localIp: '127.0.0.1', localPort: 4777 })
    expect(created).toEqual({ id: 9, name: 'DSH', remote: '23456', warning: '仅供远程访问' })
    expect(requests[0]?.body).toEqual({ name: 'DSH', type: 'tcp', node: 11, local_ip: '127.0.0.1', local_port: 4777 })
    expect(parseCreatedTunnel({ name: 'x' })).toBeUndefined()
  })

  it('edits a tunnel to the current local port', async () => {
    const { api, requests } = bench(() => ({ body: {} }))
    await api.editTunnel({ id: 9, localPort: 5_000 })
    expect(requests[0]).toMatchObject({ url: 'https://api.test/v4/tunnel/edit', method: 'POST' })
    expect(requests[0]?.body).toEqual({ id: 9, local_ip: '127.0.0.1', local_port: 5_000 })
  })

  it('maps HTTP failures onto stable codes', async () => {
    const unauthorized = bench(() => ({ status: 401, body: { message: 'bad key' } })).api
    await expect(unauthorized.userInfo()).rejects.toMatchObject({ code: 'sakura-unauthorized', status: 401 })
    const limited = bench(() => ({ status: 429 })).api
    await expect(limited.userInfo()).rejects.toMatchObject({ code: 'sakura-rate-limited' })
    const rejected = bench(() => ({ status: 400, body: { message: '隧道数量已达上限' } })).api
    await expect(rejected.listTunnels()).rejects.toMatchObject({ code: 'sakura-api-error', message: '隧道数量已达上限' })
  })

  it('maps transport failures and unparsable bodies', async () => {
    const network: typeof fetch = () => Promise.reject(new Error('offline'))
    await expect(createSakuraFrpApi({ token: 'k', fetch: network }).userInfo())
      .rejects.toMatchObject({ code: 'sakura-network' })
    const aborted: typeof fetch = () => Promise.reject(Object.assign(new Error('aborted'), { name: 'TimeoutError' }))
    await expect(createSakuraFrpApi({ token: 'k', fetch: aborted }).userInfo())
      .rejects.toMatchObject({ code: 'sakura-timeout' })
    const broken = bench(() => ({ text: '<html>' })).api
    await expect(broken.userInfo()).rejects.toMatchObject({ code: 'sakura-bad-response' })
    const notAnAccount = bench(() => ({ body: { id: 'x' } })).api
    await expect(notAnAccount.userInfo()).rejects.toMatchObject({ code: 'sakura-bad-response' })
  })

  it('keeps the access key out of every error message', async () => {
    const failing: typeof fetch = () => Promise.reject(new Error('boom'))
    try {
      await createSakuraFrpApi({ token: 'secret-key', fetch: failing }).userInfo()
      expect.unreachable('the call must fail')
    } catch (error) {
      expect(error).toBeInstanceOf(SakuraFrpApiError)
      expect((error as Error).message).not.toContain('secret-key')
    }
  })

  it('reads the account VIP group level', () => {
    expect(parseUserInfo({ id: 7, name: 'alice', group: { name: '青铜VIP', level: 3 } }))
      .toMatchObject({ group: { name: '青铜VIP', level: 3 } })
    expect(parseUserInfo({ id: 7, name: 'alice', group: {} })?.group).toBeUndefined()
    expect(parseUserInfo({ id: 7, name: 'alice', group: { level: 2 } }))
      .toMatchObject({ group: { level: 2 } })
  })

  it('does not log requests itself', () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    expect(log).not.toHaveBeenCalled()
    log.mockRestore()
  })
})
