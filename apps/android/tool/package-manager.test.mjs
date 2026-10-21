// Artifact tests use the prepared private package set and never change the shared runtime bundle.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { copyFile, cp, mkdir, mkdtemp, readFile, readdir, stat, utimes, writeFile } from 'node:fs/promises'
import fsPromises from 'node:fs/promises'
import { createRequire, registerHooks, syncBuiltinESMExports } from 'node:module'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import test from 'node:test'
import { load, dump } from 'js-yaml'
import { c as createTar } from 'tar'
import { lockedPnpmArchive, publishableCoreManifest } from './stage-package-manager.mjs'

const root = resolve(import.meta.dirname, '../../..')
const built = join(root, '.cache/android/runtime-bundle')
const staged = join(root, '.cache/android/package-manager-check')
const assets = join(staged, 'android/package-manager')
const atomic = pathToFileURL(join(built, 'node_modules/@deepseek-ai/dsh-atomic-write/lib/index.js')).href
const resolver = registerHooks({ resolve(specifier, context, next) {
  return next(specifier === '@deepseek-ai/dsh-atomic-write' ? atomic : specifier, context)
} })
const { readAndroidPackageSet, prepareAndroidPackageManager } =
  await import('../runtime/package-manager.mjs')
resolver.deregister()
const descriptor = JSON.parse(await readFile(join(assets, 'packages.json'), 'utf8'))

async function withHostLauncher(run) {
  if (process.platform !== 'win32') return run()
  // Windows denies unprivileged file symlinks. Only the Android launcher link is
  // simulated; profile reads, writer locks, atomic writes and pnpm stay real.
  const original = { symlink: fsPromises.symlink, lstat: fsPromises.lstat, readlink: fsPromises.readlink }
  const links = new Map()
  fsPromises.symlink = async (target, path) => {
    assert.ok(path.startsWith(join(root, '.cache/android/package-manager-test-')))
    assert.equal(links.has(path), false)
    links.set(path, target)
  }
  fsPromises.lstat = async (path, ...args) => links.has(path)
    ? { isSymbolicLink: () => true } : original.lstat(path, ...args)
  fsPromises.readlink = async (path, ...args) => links.has(path) ? links.get(path) : original.readlink(path, ...args)
  syncBuiltinESMExports()
  try { return await run() } finally { Object.assign(fsPromises, original); syncBuiltinESMExports() }
}

async function fixture() {
  const directory = await mkdtemp(join(root, '.cache/android/package-manager-test-'))
  const home = join(directory, 'home'), profile = join(home, 'profiles/android')
  const nativeLibraryDirectory = join(directory, 'native')
  await mkdir(profile, { recursive: true })
  await mkdir(nativeLibraryDirectory)
  // Preparation checks permissions only. Host tests never execute this placeholder as the Android helper.
  await writeFile(join(nativeLibraryDirectory, 'libpocket_node_cli.so'), '', { mode: 0o700 })
  return { directory, home, profile, nativeLibraryDirectory, runtimeDirectory: staged }
}

async function run(command, args, { cwd, env }) {
  const child = spawn(command, args, { cwd, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
  let output = ''
  child.stdout.on('data', value => { output += value })
  child.stderr.on('data', value => { output += value })
  const closed = once(child, 'close')
  const timer = setTimeout(() => child.kill(), 45_000)
  try {
    const [code, signal] = await closed
    assert.equal(signal, null, output)
    assert.equal(code, 0, output)
    return output
  } finally { clearTimeout(timer) }
}

async function packFixture(directory, archive) {
  createTar({ file: archive, cwd: directory, prefix: 'package', portable: true, gzip: true, sync: true }, ['.'])
}

function offlineEnvironment(home, extra = {}) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) =>
    !/proxy|^(?:npm_config_|pnpm_|node_options$)|key|secret|token|password/i.test(name)))
  return { ...env, HOME: home, USERPROFILE: home, CI: 'true', ...extra,
    pnpm_config_registry: 'http://127.0.0.1:1', pnpm_config_manage_package_manager_versions: 'false' }
}

test('all staged core archives match their descriptor and pnpm matches its locked identity', async () => {
  const checked = await readAndroidPackageSet(assets)
  assert.equal(checked.pnpm.version, '11.28.5')
  assert.ok(checked.packages.length > 2)
  const lock = JSON.parse(await readFile(join(root, 'apps/android/tool/runtime-lock.json'), 'utf8')).pnpm
  assert.equal(checked.pnpm.sha256, lock.sha256)
  await lockedPnpmArchive(lock, join(root, '.cache/android'))
})

test('damaged core archives reject preparation before modifying existing profile files', async () => {
  const f = await fixture()
  f.runtimeDirectory = join(f.directory, 'damaged-runtime')
  const damaged = join(f.runtimeDirectory, 'android/package-manager')
  await mkdir(join(damaged, 'core'), { recursive: true })
  await mkdir(join(damaged, 'pnpm/bin'), { recursive: true })
  const subset = { ...descriptor, packages: descriptor.packages.filter(item =>
    ['@deepseek-ai/cordis', '@deepseek-ai/dsh'].includes(item.name)) }
  for (const item of subset.packages) await copyFile(join(assets, 'core', item.file), join(damaged, 'core', item.file))
  await writeFile(join(damaged, 'packages.json'), JSON.stringify(subset))
  await copyFile(join(assets, 'pnpm/package.json'), join(damaged, 'pnpm/package.json'))
  await copyFile(join(assets, descriptor.pnpm.entry), join(damaged, descriptor.pnpm.entry))
  const archive = join(damaged, 'core', subset.packages[0].file)
  const bytes = await readFile(archive)
  bytes[bytes.length - 1] ^= 1
  await writeFile(archive, bytes)
  const manifest = '{"name":"existing-profile","private":true}\n'
  const workspace = '# retained user configuration\nonlyBuiltDependencies: []\n'
  await writeFile(join(f.profile, 'package.json'), manifest)
  await writeFile(join(f.profile, 'pnpm-workspace.yaml'), workspace)
  await assert.rejects(prepareAndroidPackageManager(f), /core archive integrity failed/)
  assert.equal(await readFile(join(f.profile, 'package.json'), 'utf8'), manifest)
  assert.equal(await readFile(join(f.profile, 'pnpm-workspace.yaml'), 'utf8'), workspace)
  assert.deepEqual((await readdir(f.profile)).sort(), ['package.json', 'pnpm-workspace.yaml'])
})

test('conflicting core overrides and linker settings preserve both profile documents exactly', async () => {
  for (const settings of [
    { overrides: { '@deepseek-ai/cordis': '4.0.0' } },
    { overrides: { '@deepseek-ai/cordis@>=4': '4.0.0' } },
    { overrides: { 'third-party>@deepseek-ai/cordis@>=4': '4.0.0' } },
    { overrides: { ' @deepseek-ai/cordis ': '4.0.0' } },
    { overrides: { 'third-party> @deepseek-ai/cordis@>3': '4.0.0' } },
    { nodeLinker: 'isolated' },
    { autoInstallPeers: true },
  ]) {
    const f = await fixture()
    const workspace = `# user content must survive rejection\n${dump(settings)}`
    const state = `${JSON.stringify({ schemaVersion: 1, overrides: {} })}\n`
    await writeFile(join(f.profile, 'pnpm-workspace.yaml'), workspace)
    await writeFile(join(f.profile, 'android-package-manager.json'), state)
    await assert.rejects(prepareAndroidPackageManager(f), /conflicts with/)
    assert.equal(await readFile(join(f.profile, 'pnpm-workspace.yaml'), 'utf8'), workspace)
    assert.equal(await readFile(join(f.profile, 'android-package-manager.json'), 'utf8'), state)
    assert.deepEqual((await readdir(f.profile)).sort(), ['android-package-manager.json', 'pnpm-workspace.yaml'])
  }
})

test('profile migration updates only owned overrides and repeating preparation writes nothing', async () => withHostLauncher(async () => {
  const f = await fixture()
  const workspace = join(f.profile, 'pnpm-workspace.yaml')
  const ownership = join(f.profile, 'android-package-manager.json')
  const original = { onlyBuiltDependencies: ['approved-dependency'], registry: 'https://registry.npmjs.org',
    overrides: { '@deepseek-ai/cordis': 'file:/old/core.tgz', '@deepseek-ai/retired': 'file:/old/retired.tgz',
      'third-party': '^2', '@deepseek-ai/cordis@>=4>third-party': '^3' } }
  await writeFile(workspace, dump(original))
  await writeFile(ownership, JSON.stringify({ schemaVersion: 1,
    overrides: { '@deepseek-ai/cordis': 'file:/old/core.tgz', '@deepseek-ai/retired': 'file:/old/retired.tgz' } }))
  const invocation = await prepareAndroidPackageManager(f)
  const settings = load(await readFile(workspace, 'utf8'))
  assert.deepEqual(settings.onlyBuiltDependencies, original.onlyBuiltDependencies)
  assert.equal(settings.registry, original.registry)
  assert.equal(settings.overrides['third-party'], '^2')
  assert.equal(settings.overrides['@deepseek-ai/cordis@>=4>third-party'], '^3')
  assert.equal(settings.overrides['@deepseek-ai/retired'], undefined)
  assert.ok(settings.overrides['@deepseek-ai/cordis'].startsWith('file:'))
  assert.equal(settings.nodeLinker, 'hoisted')
  assert.equal(settings.autoInstallPeers, false)
  const timestamp = new Date('2020-01-01T00:00:00Z')
  await utimes(workspace, timestamp, timestamp)
  await utimes(ownership, timestamp, timestamp)
  assert.deepEqual(await prepareAndroidPackageManager(f), invocation)
  assert.equal((await stat(workspace)).mtimeMs, timestamp.getTime())
  assert.equal((await stat(ownership)).mtimeMs, timestamp.getTime())
  assert.equal(invocation.command, join(f.nativeLibraryDirectory, 'libpocket_node_cli.so'))
  assert.deepEqual(invocation.args, [join(assets, descriptor.pnpm.entry)])
  assert.equal(invocation.env.pnpm_config_script_shell, '/system/bin/sh')
  assert.equal(Object.keys(invocation.env).some(name => /proxy/i.test(name)), false)
}))

test('workspace manifest conversion retains supported ranges and removes only unavailable optional native packages', () => {
  const source = { name: '@deepseek-ai/example', dependencies: { '@deepseek-ai/core': 'workspace:*' },
    peerDependencies: { '@deepseek-ai/cordis': 'workspace:~' },
    optionalDependencies: { '@deepseek-ai/node-native-other': 'workspace:~' }, devDependencies: { test: '1' } }
  const packed = publishableCoreManifest(source, new Map([
    ['@deepseek-ai/core', '1.2.3'], ['@deepseek-ai/cordis', '4.0.5'],
  ]), new Set(['@deepseek-ai/node-native-other']))
  assert.deepEqual(packed.dependencies, { '@deepseek-ai/core': '1.2.3' })
  assert.deepEqual(packed.peerDependencies, { '@deepseek-ai/cordis': '~4.0.5' })
  assert.deepEqual(packed.optionalDependencies, {})
  assert.equal(packed.devDependencies, undefined)
  assert.equal(source.dependencies['@deepseek-ai/core'], 'workspace:*')
  assert.throws(() => publishableCoreManifest(source, new Map()), /unpackaged workspace dependency/)
})

test('original pnpm installs core tarballs offline and bootstrap shares the main Cordis instance with a profile plugin',
  { timeout: 60_000 }, async () => withHostLauncher(async () => {
    const f = await fixture()
    const invocation = await prepareAndroidPackageManager(f)
    // File overrides make Cordis's optional core peers dependencies as well. Their
    // three third-party dependencies are test fixtures, outside the shipped core set.
    const workspace = join(f.profile, 'pnpm-workspace.yaml')
    const settings = load(await readFile(workspace, 'utf8'))
    for (const name of ['@standard-schema/spec', 'js-yaml', 'argparse']) {
      const archive = join(f.directory, `${name.replaceAll('/', '-')}.tgz`)
      await packFixture(join(built, 'node_modules', name), archive)
      settings.overrides[name] = `file:${archive.replaceAll('\\', '/')}`
    }
    await writeFile(workspace, dump(settings, { lineWidth: -1 }))
    const plugin = join(f.directory, 'plugin')
    await mkdir(plugin)
    await writeFile(join(plugin, 'package.json'), JSON.stringify({ name: 'pocket-offline-test-plugin', version: '1.0.0',
      type: 'module', main: 'index.mjs', dependencies: { '@deepseek-ai/cordis': '^4.0.0', '@deepseek-ai/cosmokit': '^1.8.0' } }))
    await writeFile(join(plugin, 'index.mjs'), "export { Context, Service } from '@deepseek-ai/cordis'\n")
    const pluginArchive = join(f.directory, 'plugin.tgz')
    await packFixture(plugin, pluginArchive)
    await writeFile(join(f.profile, 'package.json'), JSON.stringify({ name: 'offline-profile', private: true, type: 'module',
      dependencies: { 'pocket-offline-test-plugin': `file:${pluginArchive.replaceAll('\\', '/')}` } }))
    const env = offlineEnvironment(f.home, { ...invocation.env })
    for (const [key, expected] of [
      ['store-dir', join(f.home, 'package-manager/store')],
      ['cache-dir', join(f.home, 'package-manager/cache')],
      ['state-dir', join(f.home, 'package-manager/state')],
      ['script-shell', '/system/bin/sh'],
    ]) {
      assert.equal((await run(process.execPath, [...invocation.args, 'config', 'get', key], { cwd: f.profile, env })).trim(), expected)
    }
    const output = await run(process.execPath, [...invocation.args, 'install', '--offline', '--ignore-scripts',
      '--no-frozen-lockfile', '--reporter=append-only'], { cwd: f.profile, env })
    assert.match(output, /Done|Already up to date/)
    const installed = createRequire(join(f.profile, 'package.json'))
    for (const name of ['@deepseek-ai/cordis', '@deepseek-ai/cosmokit']) {
      const local = descriptor.packages.find(item => item.name === name)
      assert.equal(installed(`${name}/package.json`).version, local.version)
    }
    const lockfile = await readFile(join(f.profile, 'pnpm-lock.yaml'), 'utf8')
    assert.match(lockfile, new RegExp(descriptor.packages.find(item => item.name === '@deepseek-ai/cordis').file))
    assert.equal((await readdir(join(f.home, 'package-manager/store'))).length > 0, true)

    const runtime = join(f.directory, 'runtime')
    const modules = join(runtime, 'node_modules')
    for (const name of ['@deepseek-ai/cordis', '@deepseek-ai/cosmokit']) {
      await cp(join(built, 'node_modules', name), join(modules, name), { recursive: true,
        filter: path => !path.includes(`${join(name, 'node_modules')}`) })
    }
    await mkdir(join(modules, '@deepseek-ai/dsh/lib'), { recursive: true })
    await mkdir(join(modules, '@minnnng/dsh-android-runtime'), { recursive: true })
    await copyFile(join(root, 'apps/android/runtime/bootstrap.mjs'), join(runtime, 'bootstrap.mjs'))
    await writeFile(join(modules, '@minnnng/dsh-android-runtime/host-guard.mjs'),
      'export const ANDROID_BUNDLES = []\nexport function assertAndroidHostConfiguration() {}\n')
    await writeFile(join(modules, '@deepseek-ai/dsh/package.json'), '{"name":"@deepseek-ai/dsh","type":"module"}')
    await writeFile(join(modules, '@deepseek-ai/dsh/lib/bin.js'), `
import assert from 'node:assert/strict'
import { Context, Service } from '@deepseek-ai/cordis'
export async function runCli() {
  const plugin = await import(${JSON.stringify(pathToFileURL(installed.resolve('pocket-offline-test-plugin')).href)})
  assert.equal(plugin.Context, Context)
  assert.equal(plugin.Service, Service)
  const ctx = new Context()
  assert.ok(ctx instanceof plugin.Context)
  await ctx.fiber.dispose()
  console.log('Cordis instance shared with main runtime')
}
`)
    const result = await run(process.execPath, [join(runtime, 'bootstrap.mjs')], {
      cwd: f.home, env: offlineEnvironment(f.home, { DSH_HOME: f.home }),
    })
    assert.match(result, /Cordis instance shared with main runtime/)
  }))
