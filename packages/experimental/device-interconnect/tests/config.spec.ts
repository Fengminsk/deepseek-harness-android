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
