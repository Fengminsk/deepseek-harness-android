/**
 * The Settings page's HTTP surface: the loopback guard, the custom-header
 * requirement, JSON body rules, dispatch onto the bridge, and the error mapping.
 */

import { createServer, request as httpRequest, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  API_PREFIX, BRIDGE_HEADER, BRIDGE_HEADER_VALUE, CONFIG_ROUTE, ENABLED_ROUTE, LOGS_ROUTE, PAIR_ROUTE,
  QR_ROUTE, REVOKE_ROUTE, STATE_ROUTE,
} from '../src/api.ts'
import { ConfigValidationError } from '../src/host/config.ts'
import { ControlPlaneError } from '../src/host/control-plane.ts'
import {
  MAXIMUM_BODY_BYTES, createApiHandler, hasBridgeHeader, isLoopbackHostHeader, isSameOrigin, type BridgeApi,
} from '../src/host/routes.ts'
import type { DeviceInterconnectConfig, RuntimeState } from '../src/types.ts'

/** One runtime snapshot double. */
function snapshot(overrides: Partial<RuntimeState> = {}): RuntimeState {
  const config: DeviceInterconnectConfig = {
    enabled: true,
    runner: { nodePath: 'n', pnpmPath: 'p', repoDir: 'r', profile: 'remote-host', patchPath: '', dshHome: '' },
    host: {
      port: 4_777, host: '0.0.0.0', publicHost: '', publicOrigin: '',
      discoveryEnabled: true, discoveryPort: 4_778, pagesEnabled: true, pagesPort: 4_780,
    },
    pairing: { longTerm: true, pairingTtlMs: 2_592_000_000 },
  }
  return {
    config,
    child: { running: true, pid: 12, startedAt: 1, logsTail: 'ready\n' },
    controlPlane: { reachable: true },
    pairing: { open: false, longTerm: true },
    devices: [],
    runner: { ready: true, problems: [] },
    problems: [],
    ...overrides,
  }
}

/** A bridge double recording every call. */
function bridge(): {
  api: BridgeApi
  state: ReturnType<typeof vi.fn>
  setEnabled: ReturnType<typeof vi.fn>
  saveConfig: ReturnType<typeof vi.fn>
  pair: ReturnType<typeof vi.fn>
  revoke: ReturnType<typeof vi.fn>
  logs: ReturnType<typeof vi.fn>
  qrSvg: ReturnType<typeof vi.fn>
} {
  const state = vi.fn(async () => snapshot())
  const setEnabled = vi.fn(async () => snapshot())
  const saveConfig = vi.fn(async () => snapshot())
  const pair = vi.fn(async () => snapshot())
  const revoke = vi.fn(async () => snapshot())
  const logs = vi.fn(() => 'child output')
  const qrSvg = vi.fn(async () => '<svg xmlns="http://www.w3.org/2000/svg"></svg>')
  return {
    api: { state, setEnabled, saveConfig, pair, revoke, logs, qrSvg },
    state,
    setEnabled,
    saveConfig,
    pair,
    revoke,
    logs,
    qrSvg,
  }
}

const openServers: { readonly server: Server; readonly url: string }[] = []

/** Start one loopback server over the bridge handler. */
async function serve(api: BridgeApi): Promise<string> {
  const logger = { warn: vi.fn(), error: vi.fn() }
  const server = createServer(createApiHandler(api, logger))
  await new Promise<void>(resolve => { server.listen(0, '127.0.0.1', resolve) })
  const address = server.address() as AddressInfo
  const url = `http://127.0.0.1:${String(address.port)}`
  openServers.push({ server, url })
  return url
}

afterEach(async () => {
  await Promise.all(openServers.splice(0).map(async ({ server }) => {
    await new Promise<void>((resolve) => {
      server.close(() => { resolve() })
      server.closeAllConnections()
    })
  }))
})

/** One request the bridge accepts. */
async function call(
  url: string,
  path: string,
  init: RequestInit & { readonly bridgeHeader?: boolean } = {},
): Promise<Response> {
  const { bridgeHeader = true, ...rest } = init
  const headers = new Headers(rest.headers)
  if (bridgeHeader) headers.set(BRIDGE_HEADER, BRIDGE_HEADER_VALUE)
  return fetch(`${url}${path}`, { ...rest, headers })
}

/** Issue one raw GET, which can carry a Host head fetch refuses to override. */
async function rawGet(url: string, headers: Readonly<Record<string, string>>): Promise<{ status: number; body: string }> {
  const target = new URL(url)
  return new Promise((resolve, reject) => {
    const request = httpRequest({
      hostname: target.hostname,
      port: target.port,
      path: STATE_ROUTE,
      method: 'GET',
      headers,
    }, (response) => {
      const chunks: Buffer[] = []
      response.on('data', (chunk: Buffer) => { chunks.push(chunk) })
      response.on('end', () => {
        resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') })
      })
    })
    request.on('error', reject)
    request.end()
  })
}

/** POST one JSON body. */
function post(url: string, path: string, body: unknown): Promise<Response> {
  return call(url, path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

describe('security guards', () => {
  it('accepts only loopback Host heads', () => {
    expect(isLoopbackHostHeader('127.0.0.1:20410')).toBe(true)
    expect(isLoopbackHostHeader('localhost:20410')).toBe(true)
    expect(isLoopbackHostHeader('[::1]:20410')).toBe(true)
    expect(isLoopbackHostHeader('127.0.0.1')).toBe(true)
    expect(isLoopbackHostHeader(undefined)).toBe(false)
    expect(isLoopbackHostHeader('evil.example:20410')).toBe(false)
    expect(isLoopbackHostHeader('127.0.0.1.evil.example:20410')).toBe(false)
  })

  it('accepts an absent or same-origin Origin head', () => {
    expect(isSameOrigin(undefined, '127.0.0.1:20410')).toBe(true)
    expect(isSameOrigin('http://127.0.0.1:20410', '127.0.0.1:20410')).toBe(true)
    expect(isSameOrigin('http://localhost:20410', 'localhost:20410')).toBe(true)
    expect(isSameOrigin('http://evil.example', '127.0.0.1:20410')).toBe(false)
    expect(isSameOrigin('http://127.0.0.1:9999', '127.0.0.1:20410')).toBe(false)
    expect(isSameOrigin('null', '127.0.0.1:20410')).toBe(false)
    expect(isSameOrigin('http://127.0.0.1:20410', undefined)).toBe(false)
  })

  it('requires the exact custom header value', () => {
    expect(hasBridgeHeader({ headers: { [BRIDGE_HEADER]: '1' } })).toBe(true)
    expect(hasBridgeHeader({ headers: { [BRIDGE_HEADER]: '0' } })).toBe(false)
    expect(hasBridgeHeader({ headers: {} })).toBe(false)
  })
})

describe('bridge routes', () => {
  it('serves the runtime snapshot', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, STATE_ROUTE)
    expect(response.status).toBe(200)
    expect(response.headers.get('cache-control')).toBe('no-store')
    expect(response.headers.get('x-content-type-options')).toBe('nosniff')
    expect(response.headers.get('access-control-allow-origin')).toBeNull()
    expect(await response.json()).toMatchObject({ config: { enabled: true }, child: { running: true } })
    expect(fake.state).toHaveBeenCalledOnce()
  })

  it('serves the child output tail', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, LOGS_ROUTE)
    expect(await response.json()).toEqual({ logsTail: 'child output' })
  })

  it('switches the child and passes the parsed boolean', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await post(url, ENABLED_ROUTE, { enabled: false })
    expect(response.status).toBe(200)
    expect(fake.setEnabled).toHaveBeenCalledWith(false)
  })

  it('saves the submitted configuration', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const config = snapshot().config
    const response = await post(url, CONFIG_ROUTE, { config })
    expect(response.status).toBe(200)
    expect(fake.saveConfig).toHaveBeenCalledWith(config)
  })

  it('reopens the pairing window without reading a body', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, PAIR_ROUTE, { method: 'POST' })
    expect(response.status).toBe(200)
    expect(fake.pair).toHaveBeenCalledOnce()
  })

  it('revokes one device', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await post(url, REVOKE_ROUTE, { deviceId: 'abc' })
    expect(response.status).toBe(200)
    expect(fake.revoke).toHaveBeenCalledWith('abc')
  })

  it('proxies the QR SVG for an image request without the custom header', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, `${QR_ROUTE}?v=1`, { bridgeHeader: false })
    expect(response.status).toBe(200)
    expect(response.headers.get('content-type')).toContain('image/svg+xml')
    expect(await response.text()).toContain('<svg')
    expect(fake.qrSvg).toHaveBeenCalledOnce()
  })

  it('answers 404 when no pairing window is open', async () => {
    const fake = bridge()
    fake.qrSvg.mockRejectedValue(new ControlPlaneError('qr-unavailable', '没有窗口。'))
    const url = await serve(fake.api)
    const response = await call(url, QR_ROUTE, { bridgeHeader: false })
    expect(response.status).toBe(404)
    expect(await response.text()).toContain('没有窗口')
  })

  it('rejects a non-loopback Host head', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await rawGet(url, { host: 'evil.example', [BRIDGE_HEADER]: '1' })
    expect(response.status).toBe(403)
    expect(JSON.parse(response.body)).toMatchObject({ error: { code: 'host-not-allowed' } })
  })

  it('rejects a cross-origin request', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await fetch(`${url}${STATE_ROUTE}`, {
      headers: { [BRIDGE_HEADER]: '1', origin: 'http://evil.example' },
    })
    expect(response.status).toBe(403)
    expect((await response.json() as { error: { code: string } }).error.code).toBe('origin-not-allowed')
  })

  it('rejects a request without the bridge header', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, STATE_ROUTE, { bridgeHeader: false })
    expect(response.status).toBe(403)
    expect((await response.json() as { error: { code: string } }).error.code).toBe('header-required')
  })

  it('rejects an unsupported method and names the allowed one', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, STATE_ROUTE, { method: 'POST' })
    expect(response.status).toBe(405)
    expect(response.headers.get('allow')).toBe('GET')
    expect((await response.json() as { error: { code: string } }).error.code).toBe('method-not-allowed')
  })

  it('requires a JSON content type for writes', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, ENABLED_ROUTE, { method: 'POST' })
    expect(response.status).toBe(415)
    expect((await response.json() as { error: { code: string } }).error.code).toBe('content-type-required')
  })

  it('rejects malformed JSON', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, ENABLED_ROUTE, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{oops',
    })
    expect(response.status).toBe(400)
    expect((await response.json() as { error: { code: string } }).error.code).toBe('invalid-json')
  })

  it('rejects a non-object JSON body', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await post(url, ENABLED_ROUTE, [true])
    expect(response.status).toBe(400)
  })

  it('rejects a body over the size ceiling', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, CONFIG_ROUTE, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ padding: 'x'.repeat(MAXIMUM_BODY_BYTES + 1) }),
    })
    expect(response.status).toBe(413)
    expect((await response.json() as { error: { code: string } }).error.code).toBe('body-too-large')
  })

  it('answers 404 outside the bridge prefix and for unknown bridge paths', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    expect((await call(url, '/api/settings')).status).toBe(404)
    expect((await call(url, `${API_PREFIX}/unknown`)).status).toBe(404)
  })

  it('maps a rejected configuration onto 400', async () => {
    const fake = bridge()
    fake.saveConfig.mockRejectedValue(new ConfigValidationError(['host.port 必须是 1–65535 的整数。']))
    const url = await serve(fake.api)
    const response = await post(url, CONFIG_ROUTE, { config: {} })
    expect(response.status).toBe(400)
    const body = await response.json() as { error: { code: string; message: string } }
    expect(body.error.code).toBe('invalid-config')
    expect(body.error.message).toContain('host.port')
  })

  it('maps a control-plane refusal onto 502', async () => {
    const fake = bridge()
    fake.pair.mockRejectedValue(new ControlPlaneError('pair-failed', '打开配对窗口失败。'))
    const url = await serve(fake.api)
    const response = await call(url, PAIR_ROUTE, { method: 'POST' })
    expect(response.status).toBe(502)
    expect((await response.json() as { error: { code: string } }).error.code).toBe('pair-failed')
  })

  it('maps an unexpected failure onto 500', async () => {
    const fake = bridge()
    fake.state.mockRejectedValue(new Error('boom'))
    const url = await serve(fake.api)
    const response = await call(url, STATE_ROUTE)
    expect(response.status).toBe(500)
    expect((await response.json() as { error: { code: string } }).error.code).toBe('internal')
  })

  it('answers HEAD on the QR route without a body', async () => {
    const fake = bridge()
    const url = await serve(fake.api)
    const response = await call(url, QR_ROUTE, { method: 'HEAD', bridgeHeader: false })
    expect(response.status).toBe(200)
    expect(await response.text()).toBe('')
  })
})
