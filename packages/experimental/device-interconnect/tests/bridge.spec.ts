/**
 * The bridge between the Settings page and the supervised remote host:
 * snapshot assembly, control-plane caching and failure reporting, runner
 * readiness, child start/stop/restart, and the page actions.
 */

import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Bridge } from '../src/host/bridge.ts'
import { ConfigStore, ConfigValidationError, defaultConfig, processInferenceEnvironment } from '../src/host/config.ts'
import { ControlPlaneError, type ControlPlane } from '../src/host/control-plane.ts'
import { OVERLAY_FILE_NAME } from '../src/host/config.ts'
import type { ChildState, ControlPlaneState, DeviceInterconnectConfig } from '../src/types.ts'
import type { LaunchCommand, SupervisorApi } from '../src/host/supervisor.ts'

/** One configuration document with every runner path present. */
function configuration(overrides: Partial<DeviceInterconnectConfig> = {}): DeviceInterconnectConfig {
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
function supervisor() {
  let status = child()
  const start = vi.fn((_command: LaunchCommand) => { status = child({ running: true, pid: 9, startedAt: 5 }) })
  const stop = vi.fn(async () => { status = child() })
  const restart = vi.fn(async (command: LaunchCommand) => { start(command) })
  const dispose = vi.fn(async () => {})
  const api: SupervisorApi = {
    status: () => status,
    start,
    stop,
    restart,
    dispose,
  }
  return { api, start, stop, restart, dispose, setStatus: (next: ChildState) => { status = next } }
}

/** Control-plane double. */
function controlPlane(state = controlState()) {
  const cp: ControlPlane & {
    state: ReturnType<typeof vi.fn>
    pair: ReturnType<typeof vi.fn>
    revoke: ReturnType<typeof vi.fn>
    qrSvg: ReturnType<typeof vi.fn>
  } = {
    state: vi.fn(async () => state),
    pair: vi.fn(async () => state),
    revoke: vi.fn(async () => state),
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
  controlPlane?: ReturnType<typeof controlPlane>
  exists?: (path: string) => boolean
  now?: () => number
} = {}) {
  const directory = await dataDirectory()
  const fallback = overrides.config ?? configuration()
  const store = new ConfigStore({ file: join(directory, 'config.json'), fallback })
  const supervisorDouble = overrides.supervisor ?? supervisor()
  const controlPlaneDouble = overrides.controlPlane ?? controlPlane()
  const factory = vi.fn(() => controlPlaneDouble)
  const bridge = new Bridge({
    dataDir: directory,
    store,
    supervisor: supervisorDouble.api,
    controlPlane: factory,
    env: { PATH: 'C:\\bin', DSH_HOME: 'C:\\parent-home' },
    now: overrides.now ?? (() => 100),
    stateCacheMs: 10,
    exists: overrides.exists ?? (() => true),
    logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
  })
  return { bridge, store, directory, supervisor: supervisorDouble, controlPlane: controlPlaneDouble, factory }
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

  it('serves the child output tail and the proxied QR SVG', async () => {
    const { bridge, controlPlane: control, supervisor } = await bench()
    supervisor.setStatus(child({ logsTail: 'listening on 4777\n' }))
    expect(bridge.logs()).toBe('listening on 4777\n')
    expect(await bridge.qrSvg()).toBe('<svg/>')
    expect(control.qrSvg).toHaveBeenCalledOnce()
  })
})

describe('child lifecycle', () => {
  it('starts nothing while the switch is off', async () => {
    const { bridge, supervisor } = await bench()
    await bridge.initialize()
    expect(supervisor.start).not.toHaveBeenCalled()
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
      controlPlane: vi.fn(() => controlPlane()),
      env: {},
      exists: () => true,
      logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })
    await broken.initialize()
    expect((await broken.state()).problems.some(problem => problem.code === 'config-apply-failed')).toBe(true)
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

  it('rejects an invalid saved configuration without touching the stored one', async () => {
    const { bridge, store } = await bench()
    const before = store.current()
    await expect(bridge.saveConfig({ ...configuration(), host: { port: 0 } })).rejects.toBeInstanceOf(ConfigValidationError)
    expect(store.current()).toEqual(before)
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
      controlPlane: vi.fn(() => controlPlane()),
      env: {},
      exists: () => true,
      logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })
    const state = await bridge.state()
    expect(state.problems[0]).toMatchObject({ code: 'config-unreadable' })
  })

  it('stops the child on disposal', async () => {
    const { bridge, supervisor } = await bench()
    await bridge.dispose()
    expect(supervisor.dispose).toHaveBeenCalledOnce()
  })

  it('keeps the defaults of the fallback inference environment', () => {
    const environment = processInferenceEnvironment()
    expect(defaultConfig(environment).host.port).toBe(4_777)
  })
})
