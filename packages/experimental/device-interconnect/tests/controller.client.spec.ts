/**
 * The browser controller: snapshot parsing, the staged draft, and the bridge
 * bodies of the page actions — especially the write-only tunnel access key.
 */

import { describe, expect, it } from 'vitest'
import type { DeviceInterconnectView, RuntimeState, TunnelState } from '../src/types.ts'
import { TUNNEL_ROUTE } from '../src/api.ts'
import { DeviceInterconnectController, parseRuntimeState } from '../src/client/controller.ts'

/** One served configuration document. */
function config(overrides: Partial<DeviceInterconnectView> = {}): DeviceInterconnectView {
  return {
    enabled: true,
    runner: {
      mode: 'child',
      nodePath: 'C:\\node\\node.exe', pnpmPath: 'C:\\pnpm\\pnpm.mjs', repoDir: 'D:\\repo',
      profile: 'remote-host', patchPath: '', dshHome: '',
    },
    host: {
      port: 4_777, host: '0.0.0.0', publicHost: '', publicOrigin: '',
      discoveryEnabled: true, discoveryPort: 4_778, pagesEnabled: true, pagesPort: 4_780,
    },
    pairing: { longTerm: true, pairingTtlMs: 2_592_000_000 },
    tunnel: {
      provider: 'sakurafrp',
      frpcPath: 'C:\\frpc\\frpc.exe',
      tunnelIds: '114514',
      publicAddress: 'cn-xx.natfrp.cloud:12345',
      iniPath: '',
      extraArgs: '',
      tokenConfigured: true,
      autoProvision: false,
      frpcAutoDownload: true,
      nodeId: null,
      tunnelName: 'DSH 设备互联',
      tunnelId: null,
    },
    ...overrides,
  }
}

/** One tunnel runtime state. */
function tunnelState(overrides: Partial<TunnelState> = {}): TunnelState {
  return {
    provider: 'sakurafrp',
    running: false,
    ready: true,
    problems: [],
    derivedPublicOrigin: 'wss://cn-xx.natfrp.cloud:12345',
    logsTail: '',
    ...overrides,
  }
}

/** One configuration document whose stored frpc path is the given value. */
function configWithFrpcPath(frpcPath: string): DeviceInterconnectView {
  const base = config()
  return config({ tunnel: { ...base.tunnel, frpcPath } })
}

/** One runtime snapshot document. */
function state(overrides: Partial<RuntimeState> = {}): RuntimeState {
  return {
    config: config(),
    child: { running: true, pid: 42, startedAt: 1, logsTail: 'ready\n' },
    tunnel: tunnelState(),
    controlPlane: { reachable: true },
    pairing: { open: false, longTerm: true },
    devices: [],
    runner: { ready: true, problems: [] },
    problems: [],
    ...overrides,
  }
}

/** One recorded bridge request. */
interface RecordedRequest {
  readonly url: string
  readonly method: string
  readonly body?: unknown
}

/**
 * Build a controller over a fetch double that answers every call with one document.
 * @param answer - the document every call answers with, or a failure status.
 * @returns the controller and every recorded request.
 */
function bench(answer: { readonly state?: RuntimeState; readonly body?: unknown; readonly status?: number } = {}) {
  const requests: RecordedRequest[] = []
  const fetchImplementation: typeof fetch = async (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    const body = typeof init?.body === 'string' ? JSON.parse(init.body) as unknown : undefined
    requests.push({
      url,
      method: init?.method ?? 'GET',
      ...(body === undefined ? {} : { body }),
    })
    const status = answer.status ?? 200
    const payload = answer.body ?? answer.state ?? state()
    return new Response(JSON.stringify(payload), {
      status,
      headers: { 'content-type': 'application/json' },
    })
  }
  const controller = new DeviceInterconnectController({ fetch: fetchImplementation, intervalMs: 60_000 })
  return { controller, requests }
}

describe('snapshot parsing', () => {
  it('accepts a complete document and rejects a missing or malformed tunnel block', () => {
    const complete = state()
    expect(parseRuntimeState(complete)).toMatchObject({
      tunnel: { provider: 'sakurafrp', ready: true, derivedPublicOrigin: 'wss://cn-xx.natfrp.cloud:12345' },
      config: { tunnel: { tokenConfigured: true } },
    })
    const withoutTunnel: { -readonly [K in keyof RuntimeState]?: RuntimeState[K] } = { ...complete }
    delete withoutTunnel.tunnel
    expect(parseRuntimeState(withoutTunnel)).toBeUndefined()
    expect(parseRuntimeState({ ...complete, tunnel: { ...tunnelState(), provider: 'other' } })).toBeUndefined()
    expect(parseRuntimeState({ ...complete, config: { ...complete.config, tunnel: { provider: 'sakurafrp' } } }))
      .toBeUndefined()
  })

  it('fills the draft from the served configuration', async () => {
    const { controller } = bench()
    await controller.refresh()
    const snapshot = controller.store.getSnapshot()
    expect(snapshot.phase).toBe('ready')
    expect(snapshot.draft).toMatchObject({
      tunnelProvider: 'sakurafrp',
      frpcPath: 'C:\\frpc\\frpc.exe',
      tunnelToken: '',
      tunnelIds: '114514',
      publicAddress: 'cn-xx.natfrp.cloud:12345',
    })
  })

  it('reports an unreadable snapshot as the page error', async () => {
    const { controller } = bench({ body: { ...state(), tunnel: undefined } })
    await controller.refresh()
    expect(controller.store.getSnapshot()).toMatchObject({ phase: 'error' })
  })
})

describe('page actions', () => {
  it('stages the tunnel provider and editable fields', async () => {
    const { controller } = bench()
    await controller.refresh()
    controller.actions.selectTunnelProvider('none')
    expect(controller.store.getSnapshot().draft?.tunnelProvider).toBe('none')
    controller.actions.edit('frpcPath', 'C:\\other\\frpc.exe')
    expect(controller.store.getSnapshot().draft?.frpcPath).toBe('C:\\other\\frpc.exe')
    controller.actions.edit('tunnelToken', 'new-key')
    expect(controller.store.getSnapshot().draft?.tunnelToken).toBe('new-key')
  })

  it('submits the staged access key when the user typed one', async () => {
    const { controller, requests } = bench()
    await controller.refresh()
    controller.actions.edit('tunnelToken', 'new-key')
    await controller.save()
    const save = requests.find(request => request.url.endsWith('/config'))
    const body = save?.body as { config: { tunnel: Record<string, unknown> } } | undefined
    expect(body?.config.tunnel).toMatchObject({ provider: 'sakurafrp', token: 'new-key' })
    expect(controller.store.getSnapshot().notice).toEqual({ kind: 'success', text: { key: 'saved' } })
  })

  it('omits the access key when the staged field is empty so the Host keeps it', async () => {
    const { controller, requests } = bench()
    await controller.refresh()
    await controller.save()
    const save = requests.find(request => request.url.endsWith('/config'))
    const body = save?.body as { config: { tunnel: Record<string, unknown> } } | undefined
    expect(body?.config.tunnel).not.toHaveProperty('token')
    expect(body?.config.tunnel).toMatchObject({ provider: 'sakurafrp', tunnelIds: '114514' })
  })

  it('keeps the staged frpc path across toggles and polling', async () => {
    const { controller } = bench()
    await controller.refresh()
    controller.actions.edit('frpcPath', 'C:\\tools\\frpc.exe')
    controller.actions.toggle('autoProvision', false)
    controller.actions.toggle('frpcAutoDownload', false)
    await controller.refresh()
    expect(controller.store.getSnapshot().draft?.frpcPath).toBe('C:\\tools\\frpc.exe')
  })

  it('keeps the staged frpc path through the one-click provision refresh', async () => {
    const { controller, requests } = bench()
    await controller.refresh()
    controller.actions.edit('frpcPath', 'C:\\tools\\frpc.exe')
    controller.actions.edit('tunnelToken', 'new-key')
    await controller.actions.provision()
    const provision = requests.find(request => request.url.endsWith('/tunnel/provision'))
    expect(provision?.body).toMatchObject({ token: 'new-key', frpcPath: 'C:\\tools\\frpc.exe' })
    const draft = controller.store.getSnapshot().draft
    expect(draft?.frpcPath).toBe('C:\\tools\\frpc.exe')
    expect(draft?.tunnelToken).toBe('')
  })

  it('sends the staged frpc path on save and echoes the saved one', async () => {
    const { controller, requests } = bench()
    await controller.refresh()
    controller.actions.edit('frpcPath', 'C:\\tools\\frpc.exe')
    await controller.save()
    const save = requests.find(request => request.url.endsWith('/config'))
    const body = save?.body as { config: { tunnel: Record<string, unknown> } } | undefined
    expect(body?.config.tunnel.frpcPath).toBe('C:\\tools\\frpc.exe')
    const echoing = bench({ state: state({ config: configWithFrpcPath('C:\\tools\\frpc.exe') }) })
    await echoing.controller.refresh()
    expect(echoing.controller.store.getSnapshot().draft?.frpcPath).toBe('C:\\tools\\frpc.exe')
  })

  it('posts the one-click provision request with the staged access key', async () => {
    const { controller, requests } = bench()
    await controller.refresh()
    controller.actions.edit('tunnelToken', 'new-key')
    controller.actions.toggle('frpcAutoDownload', false)
    controller.actions.edit('tunnelName', 'My tunnel')
    await controller.actions.provision()
    const provision = requests.find(request => request.url.endsWith('/tunnel/provision'))
    expect(provision).toMatchObject({
      method: 'POST',
      body: { token: 'new-key', frpcAutoDownload: false, tunnelName: 'My tunnel' },
    })
    expect(controller.store.getSnapshot().notice).toEqual({ kind: 'success', text: { key: 'tunnelProvisioned' } })
  })

  it('permanently deletes a device record through the delete route', async () => {
    const { controller, requests } = bench()
    await controller.refresh()
    await controller.actions.deleteDevice('0123456789abcdef0123456789abcdef')
    const deletion = requests.find(request => request.url.endsWith('/devices/delete'))
    expect(deletion).toMatchObject({
      method: 'POST',
      body: { deviceId: '0123456789abcdef0123456789abcdef' },
    })
    expect(controller.store.getSnapshot().notice).toEqual({ kind: 'success', text: { key: 'deleted' } })
  })

  it('starts and stops the tunnel through the tunnel route', async () => {
    const { controller, requests } = bench()
    await controller.refresh()
    await controller.actions.setTunnelEnabled(false)
    const stop = requests.find(request => request.url.endsWith(TUNNEL_ROUTE))
    expect(stop).toMatchObject({ method: 'POST', body: { enabled: false } })
    expect(controller.store.getSnapshot().notice).toEqual({ kind: 'success', text: { key: 'tunnelStopped' } })
    await controller.actions.setTunnelEnabled(true)
    expect(controller.store.getSnapshot().notice).toEqual({ kind: 'success', text: { key: 'tunnelStarted' } })
  })

  it('reports a refused tunnel start as an error notice', async () => {
    const failure = { status: 409, body: { error: { code: 'tunnel-host-not-running', message: '远程宿主未运行。' } } }
    const { controller } = bench(failure)
    await controller.refresh()
    await controller.actions.setTunnelEnabled(true)
    expect(controller.store.getSnapshot().notice).toEqual({
      kind: 'error',
      text: { diagnostic: { code: 'tunnel-host-not-running', message: '远程宿主未运行。' } },
    })
  })
})
