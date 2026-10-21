/** Installation-owned pnpm invocation for the original DSH profile package operations. */
import { createHash } from 'node:crypto'
import { access, lstat, mkdir, readFile, readlink, symlink, unlink } from 'node:fs/promises'
import { constants } from 'node:fs'
import { delimiter, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { load, dump } from 'js-yaml'
import { withFileLock, writeFileAtomic } from '@deepseek-ai/dsh-atomic-write'

const stateFile = 'android-package-manager.json'
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')

function failure(message, cause) {
  const error = new Error(`Pocket Harness package manager: ${message}`, cause === undefined ? undefined : { cause })
  error.code = 'ANDROID_PACKAGE_MANAGER_CONFIGURATION'
  return error
}

async function optionalText(file) {
  try { return await readFile(file, 'utf8') } catch (error) {
    if (error.code === 'ENOENT') return undefined
    throw error
  }
}

function childPath(directory, file) {
  const path = resolve(directory, file)
  const local = relative(resolve(directory), path)
  if (!local || isAbsolute(local) || local === '..' || local.startsWith(`..${sep}`)) {
    throw failure('the packaged asset path escapes its directory')
  }
  return path
}

/** Validate immutable package bytes before creating any device profile settings. */
export async function readAndroidPackageSet(directory) {
  const descriptor = JSON.parse(await readFile(join(directory, 'packages.json'), 'utf8'))
  if (!record(descriptor) || descriptor.schemaVersion !== 1 || !record(descriptor.pnpm)
    || descriptor.pnpm.name !== 'pnpm' || !/^\d+\.\d+\.\d+$/.test(descriptor.pnpm.version)
    || descriptor.pnpm.entry !== 'pnpm/bin/pnpm.mjs' || !Array.isArray(descriptor.packages)) {
    throw failure('invalid packaged pnpm/core descriptor; reinstall a complete application build')
  }
  const names = new Set(), files = new Set()
  for (const item of descriptor.packages) {
    if (!record(item) || !/^@(?:deepseek-ai|minnnng)\/[a-z0-9._~-]+$/.test(item.name)
      || !/^[0-9A-Za-z][0-9A-Za-z.+_-]*$/.test(item.version)
      || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*\.tgz$/.test(item.file)
      || !Number.isSafeInteger(item.bytes) || item.bytes <= 0 || !/^[a-f0-9]{64}$/.test(item.sha256)
      || names.has(item.name) || files.has(item.file)) throw failure('invalid or duplicate core package identity')
    names.add(item.name)
    files.add(item.file)
    const path = childPath(join(directory, 'core'), item.file)
    if (!(await lstat(path)).isFile()) throw failure(`core archive is not a regular file: ${item.name}`)
    const bytes = await readFile(path)
    if (bytes.length !== item.bytes || sha256(bytes) !== item.sha256) throw failure(`core archive integrity failed: ${item.name}`)
  }
  if (!names.has('@deepseek-ai/cordis') || !names.has('@deepseek-ai/dsh')) throw failure('packaged core is incomplete')
  const pnpm = JSON.parse(await readFile(join(directory, 'pnpm/package.json'), 'utf8'))
  if (pnpm.name !== descriptor.pnpm.name || pnpm.version !== descriptor.pnpm.version
    || !(await lstat(childPath(directory, descriptor.pnpm.entry))).isFile()) throw failure('bundled pnpm identity does not match the package descriptor')
  return descriptor
}

/**
 * Preserve all user settings. Only absent or previously application-owned core
 * overrides can be updated; an explicit competing override stops preparation.
 */
export function mergeAndroidPackageSettings(settings, previous, overrides) {
  if (!record(settings) || (settings.overrides !== undefined && !record(settings.overrides))) {
    throw failure('pnpm-workspace.yaml must contain a settings mapping and an overrides mapping')
  }
  if (previous !== undefined && (!record(previous) || previous.schemaVersion !== 1 || !record(previous.overrides))) {
    throw failure(`${stateFile} is unreadable; restore this profile's package settings before installing plugins`)
  }
  for (const [key, expected] of Object.entries({ nodeLinker: 'hoisted', autoInstallPeers: false })) {
    if (settings[key] !== undefined && settings[key] !== expected) {
      throw failure(`pnpm-workspace.yaml ${key} conflicts with the shared Android runtime; existing settings were not changed`)
    }
  }
  const merged = { ...settings.overrides }
  for (const [selector, value] of Object.entries(merged)) {
    // pnpm's parent separator excludes the > in a version range such as @>=4.
    const trimmed = selector.trim()
    const parent = trimmed.search(/[^ |@]>/)
    const target = (parent === -1 ? trimmed : trimmed.slice(parent + 2)).trim()
    const name = Object.keys(overrides).find(candidate => target === candidate || target.startsWith(`${candidate}@`))
    if (!name) continue
    if (selector !== name || (value !== overrides[name] && value !== previous?.overrides[name])) {
      throw failure(`core override ${selector} conflicts with the packaged runtime; existing settings were not changed`)
    }
  }
  // Previously managed packages removed by a newer APK lose only that managed
  // override. User-owned third-party overrides stay byte-for-byte as values.
  for (const [name, value] of Object.entries(previous?.overrides ?? {})) {
    if (!Object.hasOwn(overrides, name) && merged[name] === value) delete merged[name]
  }
  return { ...settings, packages: settings.packages ?? ['.'],
    nodeLinker: 'hoisted', autoInstallPeers: false, overrides: { ...merged, ...overrides } }
}

async function nodeLauncher(home, executable) {
  const directory = join(home, 'package-manager', 'bin')
  await mkdir(directory, { recursive: true, mode: 0o700 })
  const target = join(directory, 'node')
  let existing
  try { existing = await lstat(target) } catch (error) { if (error.code !== 'ENOENT') throw error }
  if (existing !== undefined) {
    if (!existing.isSymbolicLink()) throw failure('the application node launcher path is occupied by another file')
    const old = await readlink(target)
    if (old === executable) return directory
    if (!isAbsolute(old) || !old.endsWith('/libpocket_node_cli.so')) {
      throw failure('the application node launcher was changed; existing file was preserved')
    }
    await unlink(target)
  }
  await symlink(executable, target)
  return directory
}

/**
 * Prepare the Android-owned profile under the original package.json writer lock.
 * No package is installed here. Core archives are pinned with ordinary pnpm
 * overrides; DSH's existing bootstrap resolution retains the running service identities.
 * @param {{runtimeDirectory: string, home: string, nativeLibraryDirectory: string}} options Native-owned absolute locations.
 * @returns {Promise<{command: string, args: string[], env: Record<string, string>}>} Original runCli packageManager value.
 */
export async function prepareAndroidPackageManager({ runtimeDirectory, home, nativeLibraryDirectory }) {
  if (![runtimeDirectory, home, nativeLibraryDirectory].every(value => typeof value === 'string' && isAbsolute(value))) {
    throw failure('native runtime locations must be absolute paths')
  }
  const assets = join(runtimeDirectory, 'android/package-manager')
  const descriptor = await readAndroidPackageSet(assets)
  const executable = join(nativeLibraryDirectory, 'libpocket_node_cli.so')
  await access(executable, constants.X_OK)
  const directory = join(home, 'profiles/android')
  await mkdir(directory, { recursive: true, mode: 0o700 })
  const overrides = Object.fromEntries(descriptor.packages.map(item => [item.name,
    `file:${childPath(join(assets, 'core'), item.file).replaceAll('\\', '/')}`]))
  await withFileLock(join(directory, 'package.json'), async () => {
    const workspace = join(directory, 'pnpm-workspace.yaml')
    const saved = await optionalText(workspace)
    const savedState = await optionalText(join(directory, stateFile))
    const settings = saved === undefined ? {} : load(saved)
    const previous = savedState === undefined ? undefined : JSON.parse(savedState)
    const merged = mergeAndroidPackageSettings(settings, previous, overrides)
    // Write settings first: a crash before the ownership record is written is
    // retryable because the desired core overrides already match exactly.
    const next = dump(merged, { lineWidth: -1, noRefs: true, sortKeys: false })
    if (saved !== next) await writeFileAtomic(workspace, next, { mode: 0o600 })
    const nextState = `${JSON.stringify({ schemaVersion: 1, overrides }, null, 2)}\n`
    if (savedState !== nextState) await writeFileAtomic(join(directory, stateFile), nextState, { mode: 0o600 })
  }, { waitMs: 10_000 })
  const bin = await nodeLauncher(home, executable)
  return {
    command: executable,
    args: [childPath(assets, descriptor.pnpm.entry)],
    env: {
      HOME: home, PNPM_HOME: join(home, 'package-manager'),
      PATH: [bin, process.env.PATH].filter(Boolean).join(delimiter),
      LD_LIBRARY_PATH: [nativeLibraryDirectory, process.env.LD_LIBRARY_PATH].filter(Boolean).join(delimiter),
      NODE: executable, npm_node_execpath: executable,
      pnpm_config_manage_package_manager_versions: 'false',
      pnpm_config_store_dir: join(home, 'package-manager/store'),
      pnpm_config_cache_dir: join(home, 'package-manager/cache'),
      pnpm_config_state_dir: join(home, 'package-manager/state'),
      pnpm_config_script_shell: '/system/bin/sh',
    },
  }
}
