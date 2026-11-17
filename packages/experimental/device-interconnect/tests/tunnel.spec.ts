/**
 * The managed NAT-traversal tunnel: address and argument validation, the
 * derived public origin, readiness checks, the frpc launch command, and the
 * real child lifecycle over a fake frpc script.
 */

import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { defaultConfig, processInferenceEnvironment } from '../src/host/config.ts'
import { ChildSupervisor, type LaunchCommand } from '../src/host/supervisor.ts'
import {
  TunnelError, derivePublicOrigin, isSafeTunnelExtraArgs, isTunnelPublicAddress, splitExtraArgs,
  tunnelLaunchCommand, tunnelReadiness, withTunnelOrigin,
} from '../src/host/tunnel.ts'
import type { DeviceInterconnectConfig, TunnelSettings } from '../src/types.ts'

/** One complete tunnel configuration. */
function tunnel(overrides: Partial<TunnelSettings> = {}): TunnelSettings {
  return {
    provider: 'sakurafrp',
    frpcPath: 'C:\\frpc\\frpc.exe',
    token: 'sakura-access-key',
    tunnelIds: '114514',
    publicAddress: 'cn-xx.natfrp.cloud:12345',
    iniPath: '',
    extraArgs: '',
    ...overrides,
  }
}

/** One complete Device Interconnect configuration over the given tunnel. */
function configuration(overrides: Partial<TunnelSettings> = {}): DeviceInterconnectConfig {
  return { ...defaultConfig(processInferenceEnvironment()), enabled: true, tunnel: tunnel(overrides) }
}

describe('public address', () => {
  it('accepts node-domain:port and IPv4:port with ports 1 to 65535', () => {
    expect(isTunnelPublicAddress('cn-xx.natfrp.cloud:12345')).toBe(true)
    expect(isTunnelPublicAddress('node.example.test:443')).toBe(true)
    expect(isTunnelPublicAddress('192.0.2.7:1')).toBe(true)
    expect(isTunnelPublicAddress('host:65535')).toBe(true)
  })

  it('rejects schemes, missing ports, and out-of-range ports', () => {
    expect(isTunnelPublicAddress('https://cn-xx.natfrp.cloud:12345')).toBe(false)
    expect(isTunnelPublicAddress('cn-xx.natfrp.cloud')).toBe(false)
    expect(isTunnelPublicAddress('cn-xx.natfrp.cloud:0')).toBe(false)
    expect(isTunnelPublicAddress('cn-xx.natfrp.cloud:65536')).toBe(false)
    expect(isTunnelPublicAddress('cn-xx.natfrp.cloud:12345/path')).toBe(false)
    expect(isTunnelPublicAddress('')).toBe(false)
  })

  it('rejects a host with an empty label or a doubled dot', () => {
    expect(isTunnelPublicAddress('cn..natfrp.cloud:12345')).toBe(false)
    expect(isTunnelPublicAddress('.natfrp.cloud:12345')).toBe(false)
    expect(isTunnelPublicAddress(`${'a'.repeat(64)}.cloud:12345`)).toBe(false)
  })
})

describe('derived public origin', () => {
  it('derives wss from a SakuraFrp TCP tunnel and keeps the explicit port', () => {
    expect(derivePublicOrigin(tunnel())).toBe('wss://cn-xx.natfrp.cloud:12345')
    expect(derivePublicOrigin(tunnel({ publicAddress: 'node.example.test:443' }))).toBe('wss://node.example.test:443')
  })

  it('derives nothing when the provider is off or the address is unusable', () => {
    expect(derivePublicOrigin(tunnel({ provider: 'none' }))).toBe('')
    expect(derivePublicOrigin(tunnel({ publicAddress: '' }))).toBe('')
    expect(derivePublicOrigin(tunnel({ publicAddress: 'https://cn-xx.natfrp.cloud:12345' }))).toBe('')
  })

  it('overrides the manual origin of the remote host overlay', () => {
    const config = configuration()
    const effective = withTunnelOrigin({ ...config, host: { ...config.host, publicOrigin: 'wss://manual.test:443' } })
    expect(effective.host.publicOrigin).toBe('wss://cn-xx.natfrp.cloud:12345')
    expect(effective.tunnel).toEqual(config.tunnel)
  })

  it('keeps the manual origin when no tunnel origin applies', () => {
    const config = configuration({ provider: 'none' })
    const manual = { ...config, host: { ...config.host, publicOrigin: 'wss://manual.test:443' } }
    expect(withTunnelOrigin(manual)).toBe(manual)
  })
})

describe('extra arguments', () => {
  it('splits on whitespace and accepts plain flags', () => {
    expect(splitExtraArgs('')).toEqual([])
    expect(splitExtraArgs('   ')).toEqual([])
    expect(splitExtraArgs('--log_level debug  --other')).toEqual(['--log_level', 'debug', '--other'])
    expect(isSafeTunnelExtraArgs('--log_level debug')).toBe(true)
  })

  it('rejects shell metacharacters and control characters', () => {
    for (const value of ['a;b', 'a|b', 'a&b', 'a>b', 'a`b`', 'a"b', "a'b", 'a*b', 'a?b', 'a\nb', 'a\u0000b']) {
      expect(isSafeTunnelExtraArgs(value)).toBe(false)
    }
  })
})

describe('readiness', () => {
  const existing = (path: string): boolean => path !== 'C:\\missing\\frpc.exe' && path !== 'C:\\missing\\frpc.ini'

  it('is never ready while the provider is off', () => {
    expect(tunnelReadiness(tunnel({ provider: 'none' }), () => true)).toEqual({ ready: false, problems: [] })
  })

  it('reports a missing or absent frpc executable', () => {
    const missing = tunnelReadiness(tunnel({ frpcPath: '' }), () => true)
    expect(missing.ready).toBe(false)
    expect(missing.problems.map(problem => problem.code)).toEqual(['tunnel-frpc-missing'])
    const absent = tunnelReadiness(tunnel({ frpcPath: 'C:\\missing\\frpc.exe' }), existing)
    expect(absent.problems[0]?.message).toContain('frpc 可执行文件不存在')
    const blank = tunnelReadiness(tunnel({ token: '', tunnelIds: '' }), () => true)
    expect(blank.problems.map(problem => problem.code)).toEqual(['tunnel-token-missing', 'tunnel-ids-missing'])
  })

  it('accepts a complete access-key configuration', () => {
    const readiness = tunnelReadiness(tunnel(), () => true)
    expect(readiness).toEqual({ ready: true, problems: [] })
  })

  it('accepts a custom frpc.ini without an access key or tunnel ids', () => {
    const ini = tunnel({ iniPath: 'C:\\frpc\\frpc.ini', token: '', tunnelIds: '' })
    expect(tunnelReadiness(ini, existing)).toEqual({ ready: true, problems: [] })
    const absent = tunnelReadiness({ ...ini, iniPath: 'C:\\missing\\frpc.ini' }, existing)
    expect(absent.problems.map(problem => problem.code)).toContain('tunnel-ini-missing')
  })

  it('reports a missing or invalid public address', () => {
    const missing = tunnelReadiness(tunnel({ publicAddress: '' }), () => true)
    expect(missing.problems.map(problem => problem.code)).toEqual(['tunnel-public-address-missing'])
    const invalid = tunnelReadiness(tunnel({ publicAddress: 'cn-xx.natfrp.cloud' }), () => true)
    expect(invalid.problems.map(problem => problem.code)).toEqual(['tunnel-public-address-invalid'])
  })
})

describe('launch command', () => {
  it('pulls the configuration with the access key and tunnel ids', () => {
    const command = tunnelLaunchCommand(tunnel(), 'C:\\data', { PATH: 'C:\\bin' })
    expect(command).toEqual({
      file: 'C:\\frpc\\frpc.exe',
      args: ['-f', 'sakura-access-key:114514', '-n', '--disable_log_color'],
      cwd: 'C:\\data',
      env: { PATH: 'C:\\bin' },
    })
  })

  it('uses the custom ini instead of the access key', () => {
    const command = tunnelLaunchCommand(tunnel({ iniPath: 'C:\\frpc\\frpc.ini' }), 'C:\\data', {})
    expect(command.args).toEqual(['-c', 'C:\\frpc\\frpc.ini', '-n'])
  })

  it('appends the extra arguments', () => {
    const command = tunnelLaunchCommand(tunnel({ extraArgs: '--log_level debug' }), 'C:\\data', {})
    expect(command.args.slice(-2)).toEqual(['--log_level', 'debug'])
  })
})

describe('tunnel errors', () => {
  it('carries a stable code, an HTTP status, and a displayable message', () => {
    const error = new TunnelError('tunnel-not-ready', 400, '设置不完整。')
    expect(error).toMatchObject({ code: 'tunnel-not-ready', status: 400, message: '设置不完整。' })
    expect(error).toBeInstanceOf(Error)
  })
})

/** Fake frpc script: prints one line, then runs until killed. */
const RUNNING_FRPC = [
  "process.stdout.write('fake-frpc-ready\\n')",
  'setInterval(() => {}, 1000)',
  '',
].join('\n')

/** Fake frpc script: prints an error, then exits with code 3. */
const FAILING_FRPC = [
  "process.stderr.write('fake-frpc-failed\\n')",
  'process.exit(3)',
  '',
].join('\n')

const temporaryDirectories: string[] = []
const spawnedPids: number[] = []

/**
 * Whether one process id still exists.
 * @param pid - process id to probe.
 * @returns true while the process exists.
 */
function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    // ESRCH is the ordinary already-exited answer this probe reports as gone.
    return false
  }
}

afterEach(async () => {
  const pids = spawnedPids.splice(0)
  for (const pid of pids) {
    try {
      process.kill(pid)
    } catch {
      // A child that already exited needs no signal.
    }
  }
  // Windows keeps a child's working directory locked until the killed process
  // is fully gone, so both the exit and the removal need a bounded retry.
  const deadline = Date.now() + 5_000
  while (pids.some(processAlive) && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 20))
  }
  await Promise.all(temporaryDirectories.splice(0).map(directory => rm(directory, {
    recursive: true, force: true, maxRetries: 10, retryDelay: 50,
  })))
})

/**
 * Write one fake frpc script into a temporary directory.
 * @param source - script source.
 * @returns the directory and the script path.
 */
async function script(source: string): Promise<{ directory: string; file: string }> {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-device-interconnect-frpc-'))
  temporaryDirectories.push(directory)
  const file = join(directory, 'fake-frpc.mjs')
  await writeFile(file, source, 'utf8')
  return { directory, file }
}

/**
 * Build a launch command that runs the fake frpc with the current Node.js.
 * @param scriptPath - script to run.
 * @param directory - child working directory.
 * @returns the launch command.
 */
function fakeFrpcCommand(scriptPath: string, directory: string): LaunchCommand {
  return { file: process.execPath, args: [scriptPath], cwd: directory, env: { ...process.env } }
}

/**
 * Wait until one predicate holds, or fail the test.
 * @param predicate - the fact to observe.
 * @param description - failure description.
 */
async function waitFor(predicate: () => boolean, description: string): Promise<void> {
  const deadline = Date.now() + 15_000
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${description}`)
    await new Promise(resolve => setTimeout(resolve, 20))
  }
}

/**
 * Build one tunnel supervisor over real child processes.
 * @returns the supervisor.
 */
function supervisor(): ChildSupervisor {
  return new ChildSupervisor({
    label: 'frpc 隧道',
    killTree: async (pid) => {
      try {
        process.kill(pid)
      } catch {
        // A child that already exited needs no signal.
      }
    },
    stopTimeoutMs: 5_000,
    logger: { info: () => {}, warn: () => {} },
  })
}

describe('fake frpc lifecycle', () => {
  it('runs the child, retains its output, and stops it', async () => {
    const { directory, file } = await script(RUNNING_FRPC)
    const running = supervisor()
    running.start(fakeFrpcCommand(file, directory))
    const pid = running.status().pid
    if (pid !== undefined) spawnedPids.push(pid)
    await waitFor(() => running.status().logsTail.includes('fake-frpc-ready'), 'frpc output')
    expect(running.status()).toMatchObject({ running: true, startedAt: expect.any(Number) as number })
    await running.stop()
    expect(running.status().running).toBe(false)
    expect(running.status().logsTail).toContain('fake-frpc-ready')
  })

  it('records a crashed child and keeps its log', async () => {
    const { directory, file } = await script(FAILING_FRPC)
    const failed = supervisor()
    failed.start(fakeFrpcCommand(file, directory))
    await waitFor(() => !failed.status().running && failed.status().exitCode !== undefined, 'frpc exit')
    expect(failed.status().exitCode).toBe(3)
    expect(failed.status().error).toContain('frpc 隧道子进程退出（代码 3）')
    expect(failed.status().logsTail).toContain('fake-frpc-failed')
  })

  it('restarts the child on request', async () => {
    const { directory, file } = await script(RUNNING_FRPC)
    const restarting = supervisor()
    const command = fakeFrpcCommand(file, directory)
    restarting.start(command)
    const first = restarting.status().pid
    if (first !== undefined) spawnedPids.push(first)
    await waitFor(() => restarting.status().logsTail.includes('fake-frpc-ready'), 'first child output')
    await restarting.restart(command)
    const second = restarting.status().pid
    if (second !== undefined) spawnedPids.push(second)
    await waitFor(() => restarting.status().logsTail.split('fake-frpc-ready').length > 2, 'second child output')
    expect(restarting.status().running).toBe(true)
    await restarting.dispose()
    expect(restarting.status().running).toBe(false)
  })

  it('stops supervising a child that ignores the stop grace period', async () => {
    const { directory, file } = await script(RUNNING_FRPC)
    const stubborn = new ChildSupervisor({
      killTree: async () => {},
      stopTimeoutMs: 50,
      logger: { info: () => {}, warn: vi.fn() },
    })
    stubborn.start(fakeFrpcCommand(file, directory))
    const pid = stubborn.status().pid
    if (pid !== undefined) spawnedPids.push(pid)
    await stubborn.stop()
    expect(stubborn.status().running).toBe(false)
    expect(stubborn.status().error).toContain('未在停止等待时间内退出')
  })
})
