/**
 * The bridge between the Settings page and the supervised children: snapshot
 * assembly, control-plane caching and failure reporting, runner and tunnel
 * readiness, child start/stop/restart order, and the page actions.
 */

import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Bridge } from '../src/host/bridge.ts'
import { ConfigStore, ConfigValidationError, defaultConfig, processInferenceEnvironment } from '../src/host/config.ts'
import { ControlPlaneError, type ControlPlane } from '../src/host/control-plane.ts'
import { OVERLAY_FILE_NAME } from '../src/host/config.ts'
import { TunnelError } from '../src/host/tunnel.ts'
import {
  SakuraFrpApiError, type CreateTunnelRequest, type EditTunnelRequest, type SakuraFrpApi, type SakuraFrpCreatedTunnel,
  type SakuraFrpNode, type SakuraFrpTunnel, type SakuraFrpUserInfo,
} from '../src/host/sakurafrp-api.ts'
import type { ChildState, ControlPlaneState, DeviceInterconnectConfig, TunnelSettings } from '../src/types.ts'
import type { LaunchCommand, SupervisorApi } from '../src/host/supervisor.ts'

/** One complete SakuraFrp tunnel configuration. */
function tunnel(overrides: Partial<TunnelSettings> = {}): TunnelSettings {
  return {
    provider: 'sakurafrp',
    frpcPath: 'C:\\frpc\\frpc.exe',
    token: 'sakura-access-key',
    tunnelIds: '114514',
    publicAddress: 'cn-xx.natfrp.cloud:12345',
    iniPath: '',
    extraArgs: '',
    autoProvision: false,
    frpcAutoDownload: true,
    nodeId: null,
    tunnelName: 'DSH 设备互联',
    tunnelId: null,
    ...overrides,
  }
}

/** One configuration document with every runner path present. */
function configuration(overrides: Partial<DeviceInterconnectConfig> = {}): DeviceInterconnectConfig {
  const defaults = defaultConfig(processInferenceEnvironment())
  return {
    enabled: false,
    runner: {
      nodePath: 'C:\\node\\node.exe',
      pnpmPath: 'C:\\pnpm\\pnpm.mjs',
      repoDir: 'D:\\repo',
      profile: 'remote-host',
      patchPath: '',
      dshHome: '',
    },
    host: {
      port: 4_777,
      host: '0.0.0.0',
      publicHost: '',
      publicOrigin: '',
      discoveryEnabled: true,
      discoveryPort: 4_778,
      pagesEnabled: true,
      pagesPort: 4_780,
    },
    pairing: { longTerm: true, pairingTtlMs: 2_592_000_000 },
    tunnel: defaults.tunnel,
    ...overrides,
  }
}

/** One child status double. */
function child(overrides: Partial<ChildState> = {}): ChildState {
  return { running: false, logsTail: 'ready\n', ...overrides }
}

/** One control-plane state double with an open window and one device. */
function controlState(overrides: Partial<ControlPlaneState> = {}): ControlPlaneState {
  return {
    host: {
      name: 'PC',
      instanceId: 'a'.repeat(64),
      origin: 'wss://192.168.1.20:4777',
      port: 4_777,
      discovery: { enabled: true, port: 4_778 },
      listening: true,
    },
    pairing: { open: true, expiresAt: 2_000, pairUrl: 'wss://192.168.1.20:4777#token=t', usbPairUrl: 'wss://127.0.0.1:4777#token=t' },
    devices: [
      { id: '0123456789abcdef0123456789abcdef', label: 'Phone', createdAt: 1, lastSeenAt: 2, expiresAt: 3 },
    ],
    ...overrides,
  }
}

/** Supervisor double recording every command. */
function supervisor(options: { readonly name?: string; readonly calls?: string[] } = {}) {
  const name = options.name ?? 'host'
  const calls = options.calls ?? []
  const pid = name === 'tunnel' ? 11 : 9
  let status = child()
  const start = vi.fn((_command: LaunchCommand) => {
    calls.push(`${name}.start`)
    status = child({ running: true, pid, startedAt: 5 })
  })
  const stop = vi.fn(async () => {
    calls.push(`${name}.stop`)
    status = child()
  })
  const restart = vi.fn(async (command: LaunchCommand) => {
    calls.push(`${name}.restart`)
    start(command)
  })
  const dispose = vi.fn(async () => {
    calls.push(`${name}.dispose`)
    status = child()
  })
  const api: SupervisorApi = { status: () => status, start, stop, restart, dispose }
  return { api, start, stop, restart, dispose, calls, status: () => status, setStatus: (next: ChildState) => { status = next } }
}

/** Control-plane double. */
function controlPlane(state = controlState(), stateImplementation?: () => Promise<ControlPlaneState>) {
  const cp: ControlPlane & {
    state: ReturnType<typeof vi.fn>
    pair: ReturnType<typeof vi.fn>
    revoke: ReturnType<typeof vi.fn>
    deleteDevice: ReturnType<typeof vi.fn>
    qrSvg: ReturnType<typeof vi.fn>
  } = {
    state: stateImplementation === undefined ? vi.fn(async () => state) : vi.fn(stateImplementation),
    pair: vi.fn(async () => state),
    revoke: vi.fn(async () => state),
    deleteDevice: vi.fn(async () => state),
    qrSvg: vi.fn(async () => '<svg/>'),
  }
  return cp
}

const directories: string[] = []

/** Create one temporary data directory. */
async function dataDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-device-interconnect-bridge-'))
  directories.push(directory)
  return directory
}

afterEach(async () => {
  await Promise.all(directories.splice(0).map(directory => rm(directory, { recursive: true, force: true })))
})

/**
 * Build one bridge over doubles.
 * @param overrides - values replacing the defaults.
 * @returns the bridge, its store, and every double.
 */
async function bench(overrides: {
  config?: DeviceInterconnectConfig
  supervisor?: ReturnType<typeof supervisor>
  tunnelSupervisor?: ReturnType<typeof supervisor>
  controlPlane?: ReturnType<typeof controlPlane>
  exists?: (path: string) => boolean
  now?: () => number
  readinessPollMs?: number
  readinessTimeoutMs?: number
  sakurafrpApi?: (token: string) => SakuraFrpApi
  downloadFrpc?: (dataDir: string) => Promise<{ readonly path: string; readonly version: string }>
} = {}) {
  const directory = await dataDirectory()
  const fallback = overrides.config ?? configuration()
  const store = new ConfigStore({ file: join(directory, 'config.json'), fallback })
  const calls: string[] = []
  const supervisorDouble = overrides.supervisor ?? supervisor({ calls })
  const tunnelSupervisorDouble = overrides.tunnelSupervisor ?? supervisor({ name: 'tunnel', calls })
  const controlPlaneDouble = overrides.controlPlane ?? controlPlane()
  const factory = vi.fn(() => controlPlaneDouble)
  const logger = { info: vi.fn(), warn: vi.fn(), error: vi.fn() }
  const bridge = new Bridge({
    dataDir: directory,
    store,
    supervisor: supervisorDouble.api,
    tunnelSupervisor: tunnelSupervisorDouble.api,
    controlPlane: factory,
    env: { PATH: 'C:\\bin', DSH_HOME: 'C:\\parent-home' },
    now: overrides.now ?? (() => 100),
    stateCacheMs: 10,
    exists: overrides.exists ?? (() => true),
    readinessPollMs: overrides.readinessPollMs ?? 1,
    readinessTimeoutMs: overrides.readinessTimeoutMs ?? 100,
    sakurafrpApi: overrides.sakurafrpApi ?? (() => fakeSakuraApi()),
    downloadFrpc: overrides.downloadFrpc ?? (async () => ({ path: 'C:\\managed\\frpc.exe', version: '0.51' })),
    logger,
  })
  return {
    bridge,
    store,
    directory,
    supervisor: supervisorDouble,
    tunnelSupervisor: tunnelSupervisorDouble,
    controlPlane: controlPlaneDouble,
    factory,
    calls,
    logger,
  }
}

/** A scripted SakuraFrp API double. */
function fakeSakuraApi(overrides: {
  readonly user?: SakuraFrpUserInfo
  readonly nodes?: readonly SakuraFrpNode[]
  readonly tunnels?: readonly SakuraFrpTunnel[]
  readonly created?: SakuraFrpCreatedTunnel
  readonly failWith?: SakuraFrpApiError
} = {}): SakuraFrpApi {
  const user = overrides.user ?? { id: 7, name: 'alice', frozen: false, tunnels: 2, traffic: [0, 100] }
  const nodes = overrides.nodes ?? [{ id: 11, name: '节点 A', host: 'a.natfrp.cloud', vip: 0, flag: 4 }]
  const created = overrides.created ?? { id: 99, name: 'DSH 设备互联', remote: '23456' }
  const fail = (): never => { throw overrides.failWith ?? new SakuraFrpApiError('sakura-api-error', 'API 失败。') }
  let tunnels: readonly SakuraFrpTunnel[] = overrides.tunnels ?? []
  return {
    userInfo: async () => (overrides.failWith === undefined ? user : fail()),
    listNodes: async () => nodes,
    listTunnels: async () => tunnels,
    createTunnel: async (request: CreateTunnelRequest) => {
      tunnels = [...tunnels, {
        id: created.id,
        name: request.name,
        type: 'tcp',
        node: request.nodeId,
        localIp: request.localIp,
        localPort: request.localPort,
        remote: created.remote ?? '',
      }]
      return created
    },
    editTunnel: async (_request: EditTunnelRequest) => {},
  }
}

/** Wait until a deferred tunnel start reached the tunnel supervisor. */
async function waitForTunnelStart(tunnelSupervisor: ReturnType<typeof supervisor>): Promise<void> {
  await vi.waitFor(() => { expect(tunnelSupervisor.start).toHaveBeenCalled() }, { timeout: 5_000 })
}

describe('snapshot assembly', () => {
  it('reports a running child, reachable control plane, and the pairing view', async () => {
    const { bridge, supervisor } = await bench()
    supervisor.setStatus(child({ running: true, pid: 9, startedAt: 5 }))
    const state = await bridge.state()
    expect(state.child).toMatchObject({ running: true, pid: 9 })
    expect(state.controlPlane).toMatchObject({ reachable: true, host: { name: 'PC' } })
    expect(state.pairing).toMatchObject({
      open: true,
      longTerm: true,
      pairUrl: 'wss://192.168.1.20:4777#token=t',
      qrSvgUrl: '/device-interconnect/api/qr.svg?v=2000',
    })
    expect(state.devices).toHaveLength(1)
    expect(state.runner.ready).toBe(true)
  })

  it('reports a closed pairing window when the control plane is unreachable', async () => {
    const control = controlPlane()
    control.state.mockRejectedValue(new ControlPlaneError('control-unreachable', '连不上。'))
    const { bridge } = await bench({ controlPlane: control })
    const state = await bridge.state()
    expect(state.controlPlane).toMatchObject({ reachable: false, error: { code: 'control-unreachable' } })
    expect(state.pairing).toEqual({ open: false, longTerm: true })
    expect(state.devices).toEqual([])
  })

  it('skips the control plane when the pairing page is disabled', async () => {
    const config = configuration()
    const { bridge, controlPlane } = await bench({ config: { ...config, host: { ...config.host, pagesEnabled: false } } })
    const state = await bridge.state()
    expect(state.controlPlane).toMatchObject({ reachable: false, error: { code: 'pages-disabled' } })
    expect(controlPlane.state).not.toHaveBeenCalled()
  })

  it('caches control-plane reads for the configured lifetime', async () => {
    let now = 100
    const control = controlPlane()
    const { bridge } = await bench({ controlPlane: control, now: () => now })
    await bridge.state()
    await bridge.state()
    expect(control.state).toHaveBeenCalledTimes(1)
    now = 200
    await bridge.state()
    expect(control.state).toHaveBeenCalledTimes(2)
  })

  it('reports incomplete runner paths and a missing extra patch', async () => {
    const config = configuration()
    const { bridge } = await bench({
      config: { ...config, runner: { ...config.runner, nodePath: '', pnpmPath: 'C:\\missing\\pnpm.mjs', patchPath: 'C:\\missing\\patch.yml' } },
      exists: path => path === 'D:\\repo',
    })
    const state = await bridge.state()
    expect(state.runner.ready).toBe(false)
    expect(state.runner.problems.map(problem => problem.code)).toEqual([
      'runner-node-missing', 'runner-pnpm-missing', 'runner-patch-missing',
    ])
  })

  it('serves the child output tails and the proxied QR SVG', async () => {
    const { bridge, controlPlane: control, supervisor, tunnelSupervisor } = await bench()
    supervisor.setStatus(child({ logsTail: 'listening on 4777\n' }))
    tunnelSupervisor.setStatus(child({ logsTail: 'start proxy success\n' }))
    expect(bridge.logs()).toBe('listening on 4777\n')
    expect(bridge.tunnelLogs()).toBe('start proxy success\n')
    expect(await bridge.qrSvg()).toBe('<svg/>')
    expect(control.qrSvg).toHaveBeenCalledOnce()
  })
})

describe('tunnel snapshot', () => {
  it('serves the tunnel state with the derived origin and readiness', async () => {
    const { bridge } = await bench({ config: configuration({ tunnel: tunnel() }) })
    const state = await bridge.state()
    expect(state.tunnel).toMatchObject({
      provider: 'sakurafrp',
      running: false,
      ready: true,
      derivedPublicOrigin: 'wss://cn-xx.natfrp.cloud:12345',
      problems: [],
      logsTail: 'ready\n',
    })
  })

  it('never serves the access key back to the page', async () => {
    const { bridge } = await bench({ config: configuration({ tunnel: tunnel() }) })
    const state = await bridge.state()
    expect(state.config.tunnel).toMatchObject({ provider: 'sakurafrp', tokenConfigured: true })
    expect(JSON.stringify(state)).not.toContain('sakura-access-key')
  })

  it('reports an incomplete tunnel configuration without spawning it', async () => {
    const { bridge, tunnelSupervisor } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel({ frpcPath: '' }) }),
    })
    await bridge.initialize()
    const state = await bridge.state()
    expect(state.tunnel.ready).toBe(false)
    expect(state.tunnel.problems.map(problem => problem.code)).toEqual(['tunnel-frpc-missing'])
    expect(tunnelSupervisor.start).not.toHaveBeenCalled()
  })

  it('reports a tunnel child failure without touching the remote host', async () => {
    const { bridge, supervisor, tunnelSupervisor } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel() }),
    })
    await bridge.initialize()
    await waitForTunnelStart(tunnelSupervisor)
    tunnelSupervisor.setStatus(child({ running: false, exitCode: 1, error: 'frpc 隧道子进程退出（代码 1）' }))
    const state = await bridge.state()
    expect(state.tunnel).toMatchObject({ running: false, exitCode: 1, error: 'frpc 隧道子进程退出（代码 1）' })
    expect(supervisor.stop).not.toHaveBeenCalled()
    expect(supervisor.status().running).toBe(true)
  })
})

describe('child lifecycle', () => {
  it('starts nothing while the switch is off', async () => {
    const { bridge, supervisor, tunnelSupervisor } = await bench()
    await bridge.initialize()
    expect(supervisor.start).not.toHaveBeenCalled()
    expect(tunnelSupervisor.start).not.toHaveBeenCalled()
  })

  it('writes the overlay and starts the child when enabled with a ready runner', async () => {
    const { bridge, supervisor, directory } = await bench({ config: configuration({ enabled: true }) })
    await bridge.initialize()
    expect(supervisor.start).toHaveBeenCalledOnce()
    const command = supervisor.start.mock.calls[0]?.[0]
    expect(command?.file).toBe('C:\\node\\node.exe')
    expect(command?.args.slice(0, 5)).toEqual(['C:\\pnpm\\pnpm.mjs', 'dsh', '--profile', 'remote-host', '--patch'])
    expect(command?.args).toContain('--no-open')
    expect(command?.cwd).toBe('D:\\repo')
    const overlay = await readFile(join(directory, OVERLAY_FILE_NAME), 'utf8')
    expect(overlay).toContain('- id: remote-host')
    expect(overlay).toContain('pairingLongTerm: true')
    expect(overlay).toContain('pairingTtlMs: 2592000000')
    expect(overlay).toContain('pagesPort: 4780')
    // The inherited DSH_HOME stays when the runner does not override it.
    expect(command?.env['DSH_HOME']).toBe('C:\\parent-home')
    expect(command?.env['PATH']?.startsWith('C:\\node')).toBe(true)
  })

  it('writes the tunnel public origin into the remote-host overlay', async () => {
    const { bridge, directory } = await bench({
      config: configuration({ enabled: true, host: { ...configuration().host, publicOrigin: 'wss://manual.test:443' }, tunnel: tunnel() }),
    })
    await bridge.initialize()
    const overlay = await readFile(join(directory, OVERLAY_FILE_NAME), 'utf8')
    expect(overlay).toContain('publicOrigin: "wss://cn-xx.natfrp.cloud:12345"')
    expect(overlay).not.toContain('manual.test')
  })

  it('passes an extra patch and a runner DSH_HOME through', async () => {
    const config = configuration({ enabled: true })
    const { bridge, supervisor } = await bench({
      config: { ...config, runner: { ...config.runner, patchPath: 'D:\\repo\\extra.yml', dshHome: 'D:\\remote-home' } },
    })
    await bridge.initialize()
    const command = supervisor.start.mock.calls[0]?.[0]
    expect(command?.args.filter(arg => arg === '--patch')).toHaveLength(2)
    expect(command?.args).toContain('D:\\repo\\extra.yml')
    expect(command?.env['DSH_HOME']).toBe('D:\\remote-home')
  })

  it('does not start an unstartable runner', async () => {
    const config = configuration({ enabled: true })
    const { bridge, supervisor } = await bench({
      config: { ...config, runner: { ...config.runner, pnpmPath: '' } },
    })
    await bridge.initialize()
    expect(supervisor.start).not.toHaveBeenCalled()
  })

  it('records an apply failure as a page problem instead of throwing', async () => {
    const directory = await dataDirectory()
    const blocked = join(directory, 'blocked')
    await writeFile(blocked, 'not a directory', 'utf8')
    const broken = new Bridge({
      dataDir: blocked,
      store: new ConfigStore({
        file: join(directory, 'config.json'),
        fallback: configuration({ enabled: true }),
      }),
      supervisor: supervisor().api,
      tunnelSupervisor: supervisor({ name: 'tunnel' }).api,
      controlPlane: vi.fn(() => controlPlane()),
      env: {},
      exists: () => true,
      logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })
    await broken.initialize()
    expect((await broken.state()).problems.some(problem => problem.code === 'config-apply-failed')).toBe(true)
  })
})

describe('tunnel lifecycle', () => {
  it('starts the tunnel after the remote host became ready', async () => {
    let calls = 0
    const control = controlPlane(controlState(), () => {
      calls += 1
      return calls < 3
        ? Promise.reject(new ControlPlaneError('control-unreachable', '还没起来。'))
        : Promise.resolve(controlState())
    })
    const { bridge, supervisor, tunnelSupervisor, calls: order } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel() }),
      controlPlane: control,
    })
    await bridge.initialize()
    await waitForTunnelStart(tunnelSupervisor)
    expect(order.indexOf('host.start')).toBeLessThan(order.indexOf('tunnel.start'))
    expect(supervisor.status().running).toBe(true)
    const command = tunnelSupervisor.start.mock.calls[0]?.[0]
    expect(command?.file).toBe('C:\\frpc\\frpc.exe')
    expect(command?.args).toEqual(['-f', 'sakura-access-key:114514', '-n', '--disable_log_color'])
  })

  it('does not start the tunnel when the remote host never becomes ready', async () => {
    const control = controlPlane()
    control.state.mockRejectedValue(new ControlPlaneError('control-unreachable', '还没起来。'))
    const { bridge, tunnelSupervisor, logger } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel() }),
      controlPlane: control,
      readinessPollMs: 1,
      readinessTimeoutMs: 3,
    })
    await bridge.initialize()
    await vi.waitFor(() => { expect(logger.warn).toHaveBeenCalledWith(expect.stringContaining('did not become ready')) }, { timeout: 5_000 })
    expect(tunnelSupervisor.start).not.toHaveBeenCalled()
  })

  it('stops the tunnel before the remote host when the switch turns off', async () => {
    const { bridge, tunnelSupervisor, calls } = await bench({ config: configuration({ enabled: true, tunnel: tunnel() }) })
    await bridge.initialize()
    await waitForTunnelStart(tunnelSupervisor)
    await bridge.setEnabled(false)
    const tunnelStop = calls.indexOf('tunnel.stop')
    const hostStop = calls.indexOf('host.stop')
    expect(tunnelStop).toBeGreaterThanOrEqual(0)
    expect(tunnelStop).toBeLessThan(hostStop)
    expect(tunnelSupervisor.status().running).toBe(false)
  })

  it('restarts the tunnel around a remote-host restart', async () => {
    const { bridge, supervisor, tunnelSupervisor, calls } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel() }),
    })
    await bridge.initialize()
    await waitForTunnelStart(tunnelSupervisor)
    const base = configuration({ enabled: true, tunnel: tunnel() })
    await bridge.saveConfig({ ...base, host: { ...base.host, port: 5_000 } })
    expect(supervisor.restart).toHaveBeenCalled()
    expect(calls.indexOf('tunnel.stop')).toBeGreaterThanOrEqual(0)
    expect(calls.indexOf('tunnel.stop')).toBeLessThan(calls.indexOf('host.restart'))
    await vi.waitFor(() => { expect(tunnelSupervisor.start.mock.calls.length).toBeGreaterThanOrEqual(2) }, { timeout: 5_000 })
  })

  it('starts and stops the tunnel without touching the remote host switch', async () => {
    const { bridge, supervisor, tunnelSupervisor } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel() }),
    })
    await bridge.initialize()
    await waitForTunnelStart(tunnelSupervisor)
    supervisor.start.mockClear()
    supervisor.stop.mockClear()
    await bridge.setTunnelEnabled(false)
    expect(tunnelSupervisor.stop).toHaveBeenCalled()
    expect(supervisor.stop).not.toHaveBeenCalled()
    await bridge.setTunnelEnabled(true)
    expect(tunnelSupervisor.start.mock.calls.length).toBeGreaterThanOrEqual(2)
    expect(supervisor.stop).not.toHaveBeenCalled()
  })

  it('refuses a manual start while the provider is off', async () => {
    const { bridge } = await bench()
    await expect(bridge.setTunnelEnabled(true)).rejects.toMatchObject({ code: 'tunnel-provider-off' })
  })

  it('refuses a manual start with an incomplete configuration', async () => {
    const { bridge } = await bench({ config: configuration({ enabled: true, tunnel: tunnel({ frpcPath: '' }) }) })
    await expect(bridge.setTunnelEnabled(true)).rejects.toMatchObject({ code: 'tunnel-not-ready' })
  })

  it('refuses a manual start while the remote host is stopped', async () => {
    const { bridge } = await bench({ config: configuration({ enabled: true, tunnel: tunnel() }) })
    await expect(bridge.setTunnelEnabled(true)).rejects.toMatchObject({ code: 'tunnel-host-not-running' })
  })

  it('refuses a manual start when the host does not confirm its listener', async () => {
    const control = controlPlane()
    control.state.mockRejectedValue(new ControlPlaneError('control-unreachable', '还没起来。'))
    const { bridge, supervisor } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel() }),
      controlPlane: control,
      readinessTimeoutMs: 3,
    })
    supervisor.setStatus(child({ running: true, pid: 9, startedAt: 5 }))
    await expect(bridge.setTunnelEnabled(true)).rejects.toMatchObject({ code: 'tunnel-host-not-ready' })
  })

  it('relaunches the remote host when the derived origin was not applied yet', async () => {
    const { bridge, supervisor, tunnelSupervisor } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel() }),
    })
    supervisor.setStatus(child({ running: true, pid: 9, startedAt: 5 }))
    await bridge.setTunnelEnabled(true)
    expect(supervisor.restart).toHaveBeenCalledOnce()
    expect(tunnelSupervisor.start).toHaveBeenCalledOnce()
  })

  it('rejects a non-boolean tunnel switch and refuses later starts after disposal', async () => {
    const { bridge, tunnelSupervisor } = await bench()
    await expect(bridge.setTunnelEnabled('yes')).rejects.toBeInstanceOf(ConfigValidationError)
    await bridge.dispose()
    await expect(bridge.setTunnelEnabled(true)).rejects.toBeInstanceOf(TunnelError)
    expect(tunnelSupervisor.start).not.toHaveBeenCalled()
  })

  it('stops the tunnel and then the remote host on disposal', async () => {
    const { bridge, tunnelSupervisor, calls } = await bench({ config: configuration({ enabled: true, tunnel: tunnel() }) })
    await bridge.initialize()
    await waitForTunnelStart(tunnelSupervisor)
    await bridge.dispose()
    const tunnelDispose = calls.indexOf('tunnel.dispose')
    const hostDispose = calls.indexOf('host.dispose')
    expect(tunnelDispose).toBeGreaterThanOrEqual(0)
    expect(tunnelDispose).toBeLessThan(hostDispose)
  })
})

describe('page actions', () => {
  it('persists the switch and starts or stops the child', async () => {
    const { bridge, store, supervisor } = await bench({ controlPlane: controlPlane() })
    await bridge.setEnabled(true)
    expect(store.current().enabled).toBe(true)
    expect(supervisor.start).toHaveBeenCalledOnce()
    await bridge.setEnabled(false)
    expect(store.current().enabled).toBe(false)
    expect(supervisor.stop).toHaveBeenCalledOnce()
  })

  it('rejects a non-boolean switch value', async () => {
    const { bridge } = await bench()
    await expect(bridge.setEnabled('yes')).rejects.toBeInstanceOf(ConfigValidationError)
  })

  it('persists a saved configuration and restarts a running child with it', async () => {
    const { bridge, store, supervisor } = await bench({ config: configuration({ enabled: true }) })
    const next = configuration({ enabled: true })
    const saved = await bridge.saveConfig({ ...next, host: { ...next.host, port: 5_000 } })
    expect(store.current().host.port).toBe(5_000)
    expect(saved.config.host.port).toBe(5_000)
    expect(supervisor.restart).toHaveBeenCalledOnce()
  })

  it('keeps the stored access key when the page saves without one', async () => {
    const { bridge, store } = await bench({ config: configuration({ enabled: true, tunnel: tunnel() }) })
    const saved = configuration({ enabled: true, tunnel: tunnel() })
    const { token: _token, ...withoutToken } = saved.tunnel
    const result = await bridge.saveConfig({ ...saved, tunnel: withoutToken })
    expect(store.current().tunnel.token).toBe('sakura-access-key')
    expect(result.config.tunnel.tokenConfigured).toBe(true)
  })

  it('clears the stored access key on request', async () => {
    const { bridge, store } = await bench({ config: configuration({ enabled: true, tunnel: tunnel() }) })
    const saved = configuration({ enabled: true, tunnel: tunnel() })
    const result = await bridge.saveConfig({ ...saved, tunnel: { ...saved.tunnel, clearToken: true } })
    expect(store.current().tunnel.token).toBe('')
    expect(result.config.tunnel.tokenConfigured).toBe(false)
  })

  it('rejects an invalid saved configuration without touching the stored one', async () => {
    const { bridge, store } = await bench()
    const before = store.current()
    await expect(bridge.saveConfig({ ...configuration(), host: { port: 0 } })).rejects.toBeInstanceOf(ConfigValidationError)
    expect(store.current()).toEqual(before)
  })

  it('deletes a device record and rejects a malformed device id', async () => {
    const control = controlPlane()
    const { bridge } = await bench({ controlPlane: control })
    await expect(bridge.deleteDevice('nope')).rejects.toBeInstanceOf(ControlPlaneError)
    expect(control.deleteDevice).not.toHaveBeenCalled()
    await bridge.deleteDevice('0123456789abcdef0123456789abcdef')
    expect(control.deleteDevice).toHaveBeenCalledWith('0123456789abcdef0123456789abcdef')
  })

  it('reopens the pairing window through the control plane', async () => {
    const control = controlPlane()
    const { bridge } = await bench({ controlPlane: control })
    await bridge.pair()
    expect(control.pair).toHaveBeenCalledOnce()
  })

  it('revokes a device and rejects a malformed device id', async () => {
    const control = controlPlane()
    const { bridge } = await bench({ controlPlane: control })
    await expect(bridge.revoke('nope')).rejects.toBeInstanceOf(ControlPlaneError)
    expect(control.revoke).not.toHaveBeenCalled()
    await bridge.revoke('0123456789abcdef0123456789abcdef')
    expect(control.revoke).toHaveBeenCalledWith('0123456789abcdef0123456789abcdef')
  })

  it('reports activation problems from an unreadable configuration file', async () => {
    const directory = await dataDirectory()
    const file = join(directory, 'config.json')
    await writeFile(file, '{broken', 'utf8')
    const bridge = new Bridge({
      dataDir: directory,
      store: new ConfigStore({ file, fallback: configuration(), logger: { warn: vi.fn() } }),
      supervisor: supervisor().api,
      tunnelSupervisor: supervisor({ name: 'tunnel' }).api,
      controlPlane: vi.fn(() => controlPlane()),
      env: {},
      exists: () => true,
      logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })
    const state = await bridge.state()
    expect(state.problems[0]).toMatchObject({ code: 'config-unreadable' })
  })

  it('stops the children on disposal', async () => {
    const { bridge, supervisor, tunnelSupervisor } = await bench()
    await bridge.dispose()
    expect(tunnelSupervisor.dispose).toHaveBeenCalledOnce()
    expect(supervisor.dispose).toHaveBeenCalledOnce()
  })

  it('keeps the defaults of the fallback inference environment', () => {
    const environment = processInferenceEnvironment()
    expect(defaultConfig(environment).host.port).toBe(4_777)
  })
})

describe('automatic tunnel provision', () => {
  /** One configuration in the one-click mode with a stored access key. */
  function provisionConfig(): DeviceInterconnectConfig {
    return configuration({
      enabled: true,
      tunnel: tunnel({
        autoProvision: true,
        tunnelIds: '',
        publicAddress: '',
        tunnelId: null,
      }),
    })
  }

  it('creates the tunnel, persists the ids, restarts the host, and starts frpc', async () => {
    const api = fakeSakuraApi()
    const { bridge, store, supervisor, tunnelSupervisor } = await bench({
      config: provisionConfig(),
      sakurafrpApi: () => api,
    })
    const state = await bridge.provisionTunnel({ frpcPath: 'C:\\frpc\\frpc.exe' })
    expect(store.current().tunnel).toMatchObject({
      token: 'sakura-access-key',
      tunnelId: 99,
      nodeId: 11,
      tunnelIds: '99',
      publicAddress: 'a.natfrp.cloud:23456',
      frpcPath: 'C:\\frpc\\frpc.exe',
    })
    expect(supervisor.restart).toHaveBeenCalled()
    expect(tunnelSupervisor.start).toHaveBeenCalledOnce()
    expect(tunnelSupervisor.start.mock.calls[0]?.[0].args).toEqual(['-f', 'sakura-access-key:99', '-n', '--disable_log_color'])
    expect(state.tunnel.provision?.lastSteps.map(step => step.status)).toEqual([
      'done', 'done', 'done', 'done', 'skipped', 'done',
    ])
    expect(state.tunnel.account).toMatchObject({ name: 'alice', tunnelCount: 1 })
    expect(state.tunnel.node).toMatchObject({ id: 11, host: 'a.natfrp.cloud' })
    expect(state.tunnel.tunnel).toMatchObject({ id: 99, remote: '23456' })
    expect(state.tunnel.frpc).toMatchObject({ path: 'C:\\frpc\\frpc.exe' })
    expect(state.config.tunnel.tokenConfigured).toBe(true)
    expect(JSON.stringify(state)).not.toContain('sakura-access-key')
  })

  it('records a failed attempt without touching the previous tunnel settings', async () => {
    const api = fakeSakuraApi({ failWith: new SakuraFrpApiError('sakura-unauthorized', 'SakuraFrp 访问密钥无效。', 401) })
    const { bridge, store, tunnelSupervisor } = await bench({ config: provisionConfig(), sakurafrpApi: () => api })
    const state = await bridge.provisionTunnel({})
    expect(state.tunnel.provision?.lastError).toMatchObject({ code: 'sakura-unauthorized' })
    expect(state.tunnel.provision?.lastSteps[0]).toMatchObject({ id: 'verify-token', status: 'failed' })
    expect(store.current().tunnel.tunnelId).toBeNull()
    expect(tunnelSupervisor.start).not.toHaveBeenCalled()
  })

  it('refuses to provision without an access key', async () => {
    const { bridge } = await bench({
      config: configuration({ enabled: true, tunnel: tunnel({ autoProvision: true, token: '' }) }),
    })
    const state = await bridge.provisionTunnel({})
    expect(state.tunnel.provision?.lastError).toMatchObject({ code: 'tunnel-token-missing' })
  })

  it('rejects a malformed provision request', async () => {
    const { bridge } = await bench()
    await expect(bridge.provisionTunnel({ frpcPath: 1 })).rejects.toBeInstanceOf(ConfigValidationError)
  })
})

