/**
 * Configuration defaults, first-run runner inference, validation, and the
 * atomic configuration file.
 */

import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  CONFIG_FILE_NAME, ConfigStore, ConfigValidationError, DEFAULT_PAIRING_TTL_MS, MAXIMUM_PAIRING_TTL_MS,
  dataDirectory, defaultConfig, defaultDshHome, inferRunner, isDeviceId, isPairingOrigin, normalizeConfig,
  readConfigFile, writeConfigFile, type InferenceEnvironment,
} from '../src/host/config.ts'
import type { DeviceInterconnectConfig } from '../src/types.ts'

/** Paths the fake environment reports as present. */
class FakeFileSystem {
  readonly files = new Set<string>()
  readonly directories = new Map<string, string[]>()

  /** @param paths - absolute paths that exist. */
  constructor(paths: readonly string[] = []) {
    for (const path of paths) this.files.add(path)
  }

  readonly exists = (path: string): boolean => this.files.has(path)

  readonly readDirectory = (path: string): readonly string[] => this.directories.get(path) ?? []
}

/** One inference environment over a fake filesystem. */
function environment(paths: readonly string[] = [], overrides: Partial<InferenceEnvironment> = {}): InferenceEnvironment {
  const fileSystem = new FakeFileSystem(paths)
  return {
    env: {},
    platform: 'win32',
    execPath: 'C:\\nodejs\\node.exe',
    isElectron: false,
    homeDir: 'C:\\Users\\tester',
    exists: fileSystem.exists,
    readDirectory: fileSystem.readDirectory,
    ...overrides,
  }
}

/** The managed DSH runtime layout the official desktop install uses. */
const RUNTIME_HOME = 'C:\\Users\\tester\\.dsh'
const RUNTIME_NODE = join(RUNTIME_HOME, 'dsh-runtimes', 'dsh-primary-runtime', 'dependencies', 'node', 'bin', 'node.exe')
const RUNTIME_PNPM = join(RUNTIME_HOME, 'dsh-runtimes', 'dsh-primary-runtime', 'dependencies', 'pnpm', 'bin', 'pnpm.mjs')

/** One complete valid configuration document. */
function validDocument(): Record<string, unknown> {
  return {
    enabled: true,
    runner: {
      nodePath: 'C:\\node\\node.exe',
      pnpmPath: 'C:\\pnpm\\pnpm.mjs',
      repoDir: 'D:\\repo',
      profile: 'remote-host',
      patchPath: '',
      dshHome: 'C:\\home',
    },
    host: {
      port: 5_001,
      host: '0.0.0.0',
      publicHost: '192.168.1.20',
      publicOrigin: 'wss://example.test:443',
      discoveryEnabled: false,
      discoveryPort: 5_002,
      pagesEnabled: true,
      pagesPort: 5_003,
    },
    pairing: { longTerm: false, pairingTtlMs: 60_000 },
    tunnel: {
      provider: 'sakurafrp',
      frpcPath: 'C:\\frpc\\frpc.exe',
      token: 'sakura-access-key',
      tunnelIds: '114514,114516',
      publicAddress: 'cn-xx.natfrp.cloud:12345',
      iniPath: '',
      extraArgs: '--log_level debug',
    },
  }
}

const temporaryDirectories: string[] = []

/** Create one temporary directory for file-backed cases. */
async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-device-interconnect-'))
  temporaryDirectories.push(directory)
  return directory
}

afterEach(async () => {
  vi.restoreAllMocks()
  await Promise.all(temporaryDirectories.splice(0).map(directory => rm(directory, { recursive: true, force: true })))
})

describe('defaults and inference', () => {
  it('starts disabled with product listener defaults and long-term pairing', () => {
    const config = defaultConfig(environment())
    expect(config.enabled).toBe(false)
    expect(config.host).toEqual({
      port: 4_777,
      host: '0.0.0.0',
      publicHost: '',
      publicOrigin: '',
      discoveryEnabled: true,
      discoveryPort: 4_778,
      pagesEnabled: true,
      pagesPort: 4_780,
    })
    expect(config.pairing).toEqual({ longTerm: true, pairingTtlMs: DEFAULT_PAIRING_TTL_MS })
    expect(config.tunnel).toEqual({
      provider: 'none',
      frpcPath: '',
      token: '',
      tunnelIds: '',
      publicAddress: '',
      iniPath: '',
      extraArgs: '',
    })
    expect(config.runner).toEqual({
      nodePath: 'C:\\nodejs\\node.exe',
      pnpmPath: '',
      repoDir: '',
      profile: 'remote-host',
      patchPath: '',
      dshHome: '',
    })
  })

  it('finds the Node.js and pnpm executables of the managed DSH runtime', () => {
    const fileSystem = new FakeFileSystem([RUNTIME_NODE, RUNTIME_PNPM])
    fileSystem.directories.set(join(RUNTIME_HOME, 'dsh-runtimes'), ['dsh-primary-runtime'])
    const runner = inferRunner(environment([], {
      env: { DSH_HOME: RUNTIME_HOME },
      exists: fileSystem.exists,
      readDirectory: fileSystem.readDirectory,
    }))
    expect(runner.nodePath).toBe(RUNTIME_NODE)
    expect(runner.pnpmPath).toBe(RUNTIME_PNPM)
  })

  it('leaves the Node.js path empty inside Electron when no managed runtime exists', () => {
    const runner = inferRunner(environment([], {
      env: { DSH_HOME: RUNTIME_HOME },
      isElectron: true,
      execPath: 'C:\\Program Files\\DSH\\DSH.exe',
    }))
    expect(runner.nodePath).toBe('')
    expect(runner.pnpmPath).toBe('')
  })

  it('prefers the explicit environment overrides', () => {
    const runner = inferRunner(environment([], {
      env: {
        DSH_DEVICE_INTERCONNECT_NODE: 'C:\\custom\\node.exe',
        DSH_DEVICE_INTERCONNECT_PNPM: 'C:\\custom\\pnpm.mjs',
        DSH_DEVICE_INTERCONNECT_REPO: 'E:\\checkout',
      },
    }))
    expect(runner).toMatchObject({
      nodePath: 'C:\\custom\\node.exe',
      pnpmPath: 'C:\\custom\\pnpm.mjs',
      repoDir: 'E:\\checkout',
    })
  })

  it('derives DSH_HOME and the bundle data directory from the environment', () => {
    expect(defaultDshHome({ DSH_HOME: 'D:\\dsh' })).toBe('D:\\dsh')
    expect(defaultDshHome({ USERPROFILE: 'C:\\Users\\u' })).toBe(join('C:\\Users\\u', '.dsh'))
    expect(dataDirectory({ DSH_HOME: 'D:\\dsh' })).toBe(join('D:\\dsh', 'device-interconnect'))
  })
})

describe('validation', () => {
  const fallback = defaultConfig(environment())

  it('accepts a complete document', () => {
    const read = normalizeConfig(validDocument(), fallback)
    expect(read.ok).toBe(true)
    if (!read.ok) return
    expect(read.config.host.publicOrigin).toBe('wss://example.test:443')
    expect(read.config.pairing).toEqual({ longTerm: false, pairingTtlMs: 60_000 })
    expect(read.config.tunnel).toEqual({
      provider: 'sakurafrp',
      frpcPath: 'C:\\frpc\\frpc.exe',
      token: 'sakura-access-key',
      tunnelIds: '114514,114516',
      publicAddress: 'cn-xx.natfrp.cloud:12345',
      iniPath: '',
      extraArgs: '--log_level debug',
    })
  })

  it('fills absent fields from the fallback so a bundle row can seed only enabled', () => {
    const read = normalizeConfig({ enabled: true }, fallback)
    expect(read.ok).toBe(true)
    if (!read.ok) return
    expect(read.config.enabled).toBe(true)
    expect(read.config.host.port).toBe(fallback.host.port)
    expect(read.config.runner.profile).toBe('remote-host')
  })

  it('reports every invalid value instead of accepting part of the document', () => {
    const document = validDocument()
    const read = normalizeConfig({
      ...document,
      enabled: 1,
      runner: { ...document['runner'] as object, profile: '../escape' },
      host: {
        ...document['host'] as object,
        port: 70_000,
        host: '   ',
        publicOrigin: 'https://example.test',
        discoveryEnabled: 'yes',
      },
      pairing: { longTerm: 'no', pairingTtlMs: MAXIMUM_PAIRING_TTL_MS + 1 },
      tunnel: {
        provider: 'frp',
        frpcPath: 'C:\\frpc\\frpc.exe\n',
        token: 'key with space',
        tunnelIds: '114514,abc',
        publicAddress: 'https://cn-xx.natfrp.cloud:12345',
        iniPath: 'C:\\frpc\\frpc.ini\r',
        extraArgs: '--flag;rm -rf',
      },
    }, fallback)
    expect(read.ok).toBe(false)
    if (read.ok) return
    expect(read.problems).toEqual(expect.arrayContaining([
      'enabled 必须是 true 或 false。',
      'runner.profile 只能包含字母、数字、点、下划线和连字符。',
      'host.port 必须是 1–65535 的整数。',
      'host.host 必须是一个非空、不含首尾空白的地址。',
      'host.publicOrigin 必须是 wss://主机名[:端口] 形式的地址，可留空。',
      'host.discoveryEnabled 必须是 true 或 false。',
      'pairing.longTerm 必须是 true 或 false。',
      'pairing.pairingTtlMs 必须是 1000–7776000000 的整数。',
      'tunnel.provider 必须是 none 或 sakurafrp。',
      'tunnel.frpcPath 不能包含换行或控制字符。',
      'tunnel.token（访问密钥）不能包含空白或控制字符。',
      'tunnel.tunnelIds 必须是数字隧道 ID，用英文逗号分隔（如 114514 或 114514,114516）。',
      'tunnel.publicAddress 只填写「节点域名:远程端口」。HTTPS 隧道会在服务端终止 TLS，无法配合远程宿主的固定证书，必须使用 TCP 隧道。',
      'tunnel.iniPath 不能包含换行或控制字符。',
      'tunnel.extraArgs 只能包含空白分隔的 frpc 参数，不能包含 shell 元字符或换行。',
    ]))
  })

  it('ignores unknown keys', () => {
    const read = normalizeConfig({ ...validDocument(), extra: { nested: true } }, fallback)
    expect(read.ok).toBe(true)
  })

  it('rejects a non-object document', () => {
    expect(normalizeConfig(undefined, fallback).ok).toBe(false)
    expect(normalizeConfig([], fallback).ok).toBe(false)
  })

  it('accepts only wss origins without a path, query, fragment, or account', () => {
    expect(isPairingOrigin('wss://ddsshh.example.test:443')).toBe(true)
    expect(isPairingOrigin('wss://example.test')).toBe(true)
    expect(isPairingOrigin('https://example.test')).toBe(false)
    expect(isPairingOrigin('wss://example.test/path')).toBe(false)
    expect(isPairingOrigin('wss://user:pass@example.test')).toBe(false)
    expect(isPairingOrigin('wss://example.test?query=1')).toBe(false)
    expect(isPairingOrigin('not a url')).toBe(false)
  })

  it('recognizes device ids', () => {
    expect(isDeviceId('0123456789abcdef0123456789abcdef')).toBe(true)
    expect(isDeviceId('0123456789ABCDEF0123456789ABCDEF')).toBe(false)
    expect(isDeviceId('short')).toBe(false)
    expect(isDeviceId(42)).toBe(false)
  })
})

describe('tunnel settings', () => {
  const fallback = defaultConfig(environment())

  /**
   * Normalize one document over a tunnel-configured fallback.
   * @param tunnel - the submitted tunnel block.
   * @param base - tunnel settings the fallback holds.
   * @returns the normalized read.
   */
  function read(tunnel: unknown, base = fallback) {
    const document = validDocument()
    return normalizeConfig({ ...document, tunnel }, base)
  }

  /** A fallback whose tunnel already holds an access key. */
  function configured(): DeviceInterconnectConfig {
    return {
      ...fallback,
      tunnel: {
        provider: 'sakurafrp',
        frpcPath: 'C:\\frpc\\frpc.exe',
        token: 'stored-key',
        tunnelIds: '114514',
        publicAddress: 'cn-xx.natfrp.cloud:12345',
        iniPath: '',
        extraArgs: '',
      },
    }
  }

  it('migrates an old document without a tunnel block to provider none', () => {
    const readOld = normalizeConfig({ enabled: true }, fallback)
    expect(readOld.ok).toBe(true)
    if (!readOld.ok) return
    expect(readOld.config.tunnel.provider).toBe('none')
    expect(readOld.config.tunnel.token).toBe('')
  })

  it('keeps the stored access key for an absent or empty value', () => {
    const base = configured()
    const absent = normalizeConfig({ ...validDocument(), tunnel: { provider: 'sakurafrp' } }, base)
    expect(absent.ok).toBe(true)
    if (!absent.ok) return
    expect(absent.config.tunnel.token).toBe('stored-key')
    const empty = normalizeConfig({ ...validDocument(), tunnel: { provider: 'sakurafrp', token: '' } }, base)
    expect(empty.ok).toBe(true)
    if (!empty.ok) return
    expect(empty.config.tunnel.token).toBe('stored-key')
  })

  it('replaces the access key with a non-empty value', () => {
    const result = normalizeConfig({ ...validDocument(), tunnel: { provider: 'sakurafrp', token: 'new-key' } }, configured())
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.config.tunnel.token).toBe('new-key')
  })

  it('clears the access key only through null or clearToken', () => {
    const base = configured()
    for (const tunnel of [
      { provider: 'sakurafrp', token: null },
      { provider: 'sakurafrp', clearToken: true },
    ]) {
      const result = normalizeConfig({ ...validDocument(), tunnel }, base)
      expect(result.ok).toBe(true)
      if (!result.ok) return
      expect(result.config.tunnel.token).toBe('')
    }
  })

  it('rejects a malformed access key without losing the stored one', () => {
    const result = read({ provider: 'sakurafrp', token: 42 }, configured())
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.problems).toContain('tunnel.token 必须是不超过 512 个字符的字符串或 null。')
  })

  it('accepts TCP tunnel addresses with an explicit port, including 443', () => {
    for (const publicAddress of ['cn-xx.natfrp.cloud:12345', 'node.example.test:443', '192.0.2.7:20000']) {
      const result = read({ provider: 'sakurafrp', publicAddress })
      expect(result.ok).toBe(true)
      if (!result.ok) return
      expect(result.config.tunnel.publicAddress).toBe(publicAddress)
    }
  })

  it('rejects a public address without a port or with a scheme', () => {
    const missingPort = read({ provider: 'sakurafrp', publicAddress: 'cn-xx.natfrp.cloud' })
    expect(missingPort.ok).toBe(false)
    const outOfRange = read({ provider: 'sakurafrp', publicAddress: 'cn-xx.natfrp.cloud:70000' })
    expect(outOfRange.ok).toBe(false)
    const scheme = read({ provider: 'sakurafrp', publicAddress: 'https://cn-xx.natfrp.cloud:12345' })
    expect(scheme.ok).toBe(false)
    if (scheme.ok) return
    expect(scheme.problems.some(problem => problem.includes('HTTPS 隧道'))).toBe(true)
  })

  it('accepts decimal tunnel id lists and rejects anything else', () => {
    expect(read({ provider: 'sakurafrp', tunnelIds: '114514' }).ok).toBe(true)
    expect(read({ provider: 'sakurafrp', tunnelIds: '114514,114516' }).ok).toBe(true)
    for (const tunnelIds of ['114514,', 'a,b', '114514 114516', '-1']) {
      expect(read({ provider: 'sakurafrp', tunnelIds }).ok).toBe(false)
    }
  })

  it('accepts plain frpc arguments and rejects shell metacharacters', () => {
    expect(read({ provider: 'sakurafrp', extraArgs: '--log_level debug --proxy_protocol_version v2' }).ok).toBe(true)
    for (const extraArgs of ['--flag;rm', '--flag|other', '--flag & other', '--flag\n--other', '--flag `x`']) {
      expect(read({ provider: 'sakurafrp', extraArgs }).ok).toBe(false)
    }
  })

  it('accepts an empty tunnel block when the provider is off', () => {
    const result = read({ provider: 'none' })
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.config.tunnel.provider).toBe('none')
  })

  it('rejects a non-object tunnel block', () => {
    const result = read('sakurafrp')
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.problems).toContain('tunnel 必须是一个 JSON 对象。')
  })
})

describe('configuration file', () => {
  it('returns the fallback for a missing file', async () => {
    const directory = await temporaryDirectory()
    const read = readConfigFile(join(directory, CONFIG_FILE_NAME), defaultConfig(environment()))
    expect(read.ok).toBe(true)
  })

  it('reports an unreadable JSON document', async () => {
    const directory = await temporaryDirectory()
    const file = join(directory, CONFIG_FILE_NAME)
    await writeFile(file, '{not json', 'utf8')
    const read = readConfigFile(file, defaultConfig(environment()))
    expect(read.ok).toBe(false)
    if (read.ok) return
    expect(read.problems[0]).toContain('不是合法 JSON')
  })

  it('round-trips through the atomic writer', async () => {
    const directory = await temporaryDirectory()
    const file = join(directory, 'nested', CONFIG_FILE_NAME)
    const read = normalizeConfig(validDocument(), defaultConfig(environment()))
    expect(read.ok).toBe(true)
    if (!read.ok) return
    await writeConfigFile(file, read.config)
    const text = await readFile(file, 'utf8')
    expect(JSON.parse(text)).toEqual(read.config)
    expect(text.endsWith('\n')).toBe(true)
  })

  it('persists validated saves and rejects invalid ones with every problem', async () => {
    const directory = await temporaryDirectory()
    const store = new ConfigStore({ file: join(directory, CONFIG_FILE_NAME), fallback: defaultConfig(environment()) })
    const saved = await store.save(validDocument())
    expect(store.current()).toEqual(saved)
    expect(JSON.parse(await readFile(store.file, 'utf8'))).toEqual(saved)
    await expect(store.save({ ...validDocument(), host: { port: -1 } })).rejects.toBeInstanceOf(ConfigValidationError)
    expect(store.current()).toEqual(saved)
  })

  it('falls back to the initial configuration for a corrupt file and reports it', async () => {
    const directory = await temporaryDirectory()
    const file = join(directory, CONFIG_FILE_NAME)
    await writeFile(file, '{broken', 'utf8')
    const warn = vi.fn()
    const store = new ConfigStore({ file, fallback: defaultConfig(environment()), logger: { warn } })
    expect(store.current().enabled).toBe(false)
    expect(store.problems()).toHaveLength(1)
    expect(warn).toHaveBeenCalledOnce()
  })
})

describe('types', () => {
  it('keeps the validated configuration assignable to the wire type', () => {
    const read: { config: DeviceInterconnectConfig } = { config: defaultConfig(environment()) }
    expect(read.config.pairing.longTerm).toBe(true)
  })
})
