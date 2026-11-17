/**
 * Host plugin activation: the bridge route registration and its disposal, the
 * served state over a real loopback server, the enable action's persistence,
 * and the invalid-configuration refusal.
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import type { WebRoute, WebServer } from '@deepseek-ai/dsh-host-webserver'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { BRIDGE_HEADER, BRIDGE_HEADER_VALUE, API_PREFIX, QR_ROUTE, STATE_ROUTE } from '../src/api.ts'
import { apply, name, type Config } from '../src/host/plugin.ts'
import type { RuntimeState } from '../src/types.ts'

/** A web-server double that records the one route the plugin registers. */
function webServer(): {
  readonly service: WebServer
  readonly routes: WebRoute[]
  readonly dispose: ReturnType<typeof vi.fn>
} {
  const routes: WebRoute[] = []
  const dispose = vi.fn()
  const service = {
    register(route: WebRoute) {
      routes.push(route)
      return dispose
    },
  }
  // The plugin calls only `register`; the assertion keeps the production
  // service type while the double stays a two-line fake.
  return { service: service as never, routes, dispose }
}

const directories: string[] = []
const servers: Server[] = []

/** Create one temporary DSH home. */
async function temporaryDshHome(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-device-interconnect-plugin-'))
  directories.push(directory)
  return directory
}

afterEach(async () => {
  vi.unstubAllEnvs()
  await Promise.all(servers.splice(0).map(async (server) => {
    await new Promise<void>((resolve) => {
      server.close(() => { resolve() })
      server.closeAllConnections()
    })
  }))
  await Promise.all(directories.splice(0).map(directory => rm(directory, { recursive: true, force: true })))
})

/**
 * Activate the plugin against a temporary DSH home and one recorded route.
 *
 * The listener ports are seeded away from the product defaults so an unrelated
 * remote host running on this machine cannot answer this fixture's control
 * plane reads.
 * @param bundleConfig - first-run seed from the bundle row.
 * @returns the context, the fiber, the recorded routes, the route disposer, and the bridge URL.
 */
async function activate(bundleConfig: Config = {}) {
  const dshHome = await temporaryDshHome()
  vi.stubEnv('DSH_HOME', dshHome)
  const server = webServer()
  const ctx = new Context()
  ctx.provide('webServer', server.service)
  const seed: Config = {
    host: {
      port: 4_777,
      host: '0.0.0.0',
      publicHost: '',
      publicOrigin: '',
      discoveryEnabled: false,
      discoveryPort: 1,
      pagesEnabled: true,
      pagesPort: 1,
    },
    ...bundleConfig,
  }
  const fiber = ctx.plugin({
    name,
    inject: [],
    apply: (pluginContext: Context) => apply(pluginContext, seed),
  })
  await fiber.await()
  const route = server.routes[0]
  if (route === undefined) throw new Error('the plugin did not register its bridge route')
  const httpServer = createServer((request, response) => { void route.handler(request, response) })
  await new Promise<void>(resolve => { httpServer.listen(0, '127.0.0.1', resolve) })
  servers.push(httpServer)
  const address = httpServer.address() as AddressInfo
  return {
    ctx,
    fiber,
    dshHome,
    routes: server.routes,
    disposeRoute: server.dispose,
    url: `http://127.0.0.1:${String(address.port)}`,
  }
}

/** One accepted bridge request. */
function call(url: string, path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${url}${path}`, {
    ...init,
    headers: { [BRIDGE_HEADER]: BRIDGE_HEADER_VALUE, ...(init.headers ?? {}) },
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

describe('device-interconnect host plugin', () => {
  it('registers the bridge prefix route and removes it with the fiber', async () => {
    const plugin = await activate()
    expect(plugin.routes).toHaveLength(1)
    expect(plugin.routes[0]).toMatchObject({ kind: 'prefix', path: API_PREFIX })
    await plugin.fiber.dispose()
    expect(plugin.disposeRoute).toHaveBeenCalledOnce()
  })

  it('serves the state of an untouched installation', async () => {
    const plugin = await activate()
    const response = await call(plugin.url, STATE_ROUTE)
    expect(response.status).toBe(200)
    const state = await response.json() as RuntimeState
    expect(state.config.enabled).toBe(false)
    expect(state.config.tunnel).toMatchObject({ provider: 'none', tokenConfigured: false })
    expect(state.child.running).toBe(false)
    expect(state.tunnel).toMatchObject({ provider: 'none', running: false, ready: false })
    expect(state.controlPlane.reachable).toBe(false)
    expect(state.runner.ready).toBe(false)
    expect(state.runner.problems.map(problem => problem.code)).toContain('runner-pnpm-missing')
    expect(state.pairing.longTerm).toBe(true)
  })

  it('persists the switch and reports the runner problem instead of spawning', async () => {
    const plugin = await activate()
    const response = await post(plugin.url, `${API_PREFIX}/enabled`, { enabled: true })
    expect(response.status).toBe(200)
    const state = await response.json() as RuntimeState
    expect(state.config.enabled).toBe(true)
    expect(state.child.running).toBe(false)
    const file = join(plugin.dshHome, 'device-interconnect', 'config.json')
    const persisted = JSON.parse(await readFile(file, 'utf8')) as RuntimeState['config']
    expect(persisted.enabled).toBe(true)
    expect(persisted.runner.profile).toBe('remote-host')
  })

  it('applies a validated configuration document', async () => {
    const plugin = await activate()
    const first = await (await call(plugin.url, STATE_ROUTE)).json() as RuntimeState
    const response = await post(plugin.url, `${API_PREFIX}/config`, {
      config: { ...first.config, host: { ...first.config.host, port: 5_100 } },
    })
    expect(response.status).toBe(200)
    const state = await response.json() as RuntimeState
    expect(state.config.host.port).toBe(5_100)
  })

  it('persists the tunnel access key and only reports that it is configured', async () => {
    const plugin = await activate()
    const first = await (await call(plugin.url, STATE_ROUTE)).json() as RuntimeState
    const response = await post(plugin.url, `${API_PREFIX}/config`, {
      config: {
        ...first.config,
        tunnel: {
          provider: 'sakurafrp',
          frpcPath: 'C:\\frpc\\frpc.exe',
          token: 'sakura-access-key',
          tunnelIds: '114514',
          publicAddress: 'cn-xx.natfrp.cloud:12345',
          iniPath: '',
          extraArgs: '',
        },
      },
    })
    expect(response.status).toBe(200)
    const state = await response.json() as RuntimeState
    expect(state.config.tunnel).toMatchObject({ provider: 'sakurafrp', tokenConfigured: true, tunnelIds: '114514' })
    expect(state.tunnel).toMatchObject({
      provider: 'sakurafrp',
      ready: false,
      derivedPublicOrigin: 'wss://cn-xx.natfrp.cloud:12345',
    })
    // The access key is stored in the configuration file but never served back.
    const file = join(plugin.dshHome, 'device-interconnect', 'config.json')
    const persisted = JSON.parse(await readFile(file, 'utf8')) as RuntimeState['config'] & {
      tunnel: { token: string }
    }
    expect(persisted.tunnel.token).toBe('sakura-access-key')
    expect(JSON.stringify(state)).not.toContain('sakura-access-key')
  })

  it('refuses a tunnel start while the provider is off', async () => {
    const plugin = await activate()
    const response = await post(plugin.url, `${API_PREFIX}/tunnel`, { enabled: true })
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: 'tunnel-provider-off' } })
  })

  it('refuses an invalid configuration document', async () => {
    const plugin = await activate()
    const response = await post(plugin.url, `${API_PREFIX}/config`, { config: { host: { port: -1 } } })
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: 'invalid-config' } })
  })

  it('answers the QR route as an image request without the bridge header', async () => {
    const plugin = await activate()
    const response = await fetch(`${plugin.url}${QR_ROUTE}`, { headers: { cache: 'no-store' } })
    // No remote host runs in this fixture, so the proxied read fails cleanly.
    expect([404, 502]).toContain(response.status)
  })

  it('loads without a web server service', async () => {
    const dshHome = await temporaryDshHome()
    vi.stubEnv('DSH_HOME', dshHome)
    const ctx = new Context()
    const fiber = ctx.plugin({ name, inject: [], apply: (pluginContext: Context) => apply(pluginContext, {}) })
    await expect(fiber.await()).resolves.toBeDefined()
    await fiber.dispose()
  })

  it('fails loudly on an invalid bundle configuration', async () => {
    const ctx = new Context()
    const invalid: Config = JSON.parse('{"enabled":"yes"}')
    const fiber = ctx.plugin({ name, inject: [], apply: (pluginContext: Context) => apply(pluginContext, invalid) })
    await expect(fiber.await()).rejects.toThrow('invalid bundle configuration')
  })
})
