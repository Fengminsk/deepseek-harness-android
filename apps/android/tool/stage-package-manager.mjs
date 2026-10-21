/** Stage the locked original pnpm and the built installation's local core tarballs. */
import { createHash } from 'node:crypto'
import { cp, lstat, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { basename, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { c as createTar, x as extractTar } from 'tar'

const packageName = /^@[a-z0-9._~-]+\/[a-z0-9._~-]+$/
const excludedDirectories = new Set(['node_modules', 'src', 'test', 'tests', 'fixtures', 'coverage', '.git', '.cache', '.bin'])
const excludedFile = /\.(?:exe|dll|dylib|node|a|pdb|map|ts|tsbuildinfo)$/
const hash = (algorithm, bytes, encoding = 'hex') => createHash(algorithm).update(bytes).digest(encoding)

function contained(parent, child) {
  const path = relative(resolve(parent), resolve(child))
  if (!path || isAbsolute(path) || path === '..' || path.startsWith(`..${sep}`) || resolve(parent, path) !== resolve(child)) {
    throw new Error('Android package staging target must be inside its output directory')
  }
}

async function optionalFile(file) {
  try { return await readFile(file) } catch (error) {
    if (error.code === 'ENOENT') return undefined
    throw error
  }
}

/** Download only the locked archive; cached bytes undergo the same integrity checks. */
export async function lockedPnpmArchive(lock, cacheDirectory) {
  if (lock.name !== 'pnpm' || !/^\d+\.\d+\.\d+$/.test(lock.version)
    || lock.url !== `https://registry.npmjs.org/pnpm/-/pnpm-${lock.version}.tgz`
    || !/^[a-f0-9]{64}$/.test(lock.sha256) || !/^sha512-[A-Za-z0-9+/]+=*$/.test(lock.integrity)) {
    throw new Error('Invalid Android pnpm archive lock')
  }
  await mkdir(cacheDirectory, { recursive: true })
  const archive = join(cacheDirectory, `pnpm-${lock.version}.tgz`)
  let bytes = await optionalFile(archive)
  const cached = bytes !== undefined
  if (!cached) {
    const response = await fetch(lock.url, { signal: AbortSignal.timeout(120_000) })
    if (!response.ok) throw new Error(`pnpm archive download failed: HTTP ${response.status}`)
    bytes = Buffer.from(await response.arrayBuffer())
  }
  if (hash('sha256', bytes) !== lock.sha256 || `sha512-${hash('sha512', bytes, 'base64')}` !== lock.integrity) {
    throw new Error('Android pnpm archive checksum mismatch; remove the damaged cached archive and retry staging')
  }
  if (!cached) {
    const temporary = `${archive}.partial`
    await writeFile(temporary, bytes)
    await rename(temporary, archive)
  }
  return archive
}

/** Replace workspace protocols with versions from the exact packaged core set. */
export function publishableCoreManifest(metadata, versions, unsupportedOptional = new Set()) {
  const packed = structuredClone(metadata)
  delete packed.devDependencies
  for (const section of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const [name, spec] of Object.entries(packed[section] ?? {})) {
      if (typeof spec !== 'string' || !spec.startsWith('workspace:')) continue
      const version = versions.get(name)
      if (version === undefined) {
        if (section === 'optionalDependencies' && unsupportedOptional.has(name)) {
          delete packed[section][name]
          continue
        }
        throw new Error(`Android core package ${metadata.name} requires unpackaged workspace dependency ${name}`)
      }
      const range = spec.slice('workspace:'.length)
      packed[section][name] = range === '~' || range === '^' ? `${range}${version}` : version
    }
  }
  return packed
}

async function unsupportedNativePackages(repositoryRoot) {
  const directory = join(repositoryRoot, 'native/system/packages')
  const unsupported = new Set()
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    const raw = await optionalFile(join(directory, entry.name, 'package.json'))
    if (!raw) continue
    const metadata = JSON.parse(raw)
    const permits = (values, target) => values === undefined ||
      (!values.includes(`!${target}`) && (!values.some(value => !value.startsWith('!')) || values.includes(target)))
    if (!permits(metadata.os, 'android') || !permits(metadata.cpu, 'arm64')) unsupported.add(metadata.name)
  }
  return unsupported
}

async function stagedCorePackages(modules) {
  const packages = []
  for (const scope of ['@deepseek-ai', '@minnnng']) {
    let entries
    try { entries = await readdir(join(modules, scope), { withFileTypes: true }) } catch (error) {
      if (error.code === 'ENOENT') continue
      throw error
    }
    for (const entry of entries) {
      const source = join(modules, scope, entry.name)
      const raw = await optionalFile(join(source, 'package.json'))
      if (raw === undefined) continue
      const metadata = JSON.parse(raw)
      if (metadata.name !== `${scope}/${entry.name}` || !packageName.test(metadata.name)
        || typeof metadata.version !== 'string' || !/^[0-9A-Za-z][0-9A-Za-z.+_-]*$/.test(metadata.version)) {
        throw new Error(`Invalid staged core package identity at ${source}`)
      }
      packages.push({ source, metadata })
    }
  }
  for (const name of ['@deepseek-ai/cordis', '@deepseek-ai/dsh']) {
    if (!packages.some(item => item.metadata.name === name)) throw new Error(`Android package set is missing ${name}`)
  }
  return packages.sort((left, right) => left.metadata.name.localeCompare(right.metadata.name))
}

/**
 * Publish package assets only after the original pnpm and every core archive are ready.
 * Reads built packages; never builds, downloads core packages or runs lifecycle scripts.
 * @param {{repositoryRoot: string, staging: string, cacheDirectory?: string, modulesDirectory?: string}} options Output and built-input locations.
 */
export async function stagePackageManager({ repositoryRoot, staging,
  cacheDirectory = join(repositoryRoot, '.cache/android'), modulesDirectory = join(staging, 'node_modules') }) {
  const lock = JSON.parse(await readFile(join(repositoryRoot, 'apps/android/tool/runtime-lock.json'), 'utf8')).pnpm
  const rootManifest = JSON.parse(await readFile(join(repositoryRoot, 'package.json'), 'utf8'))
  if (rootManifest.packageManager !== `pnpm@${lock.version}`) throw new Error('Android pnpm differs from the repository packageManager')
  const archive = await lockedPnpmArchive(lock, cacheDirectory)
  const packages = await stagedCorePackages(modulesDirectory)
  const versions = new Map(packages.map(item => [item.metadata.name, item.metadata.version]))
  const unsupportedOptional = await unsupportedNativePackages(repositoryRoot)
  const android = join(resolve(staging), 'android')
  await mkdir(android, { recursive: true })
  const temporary = await mkdtemp(join(android, '.package-manager-'))
  const target = join(android, 'package-manager')
  contained(android, temporary)
  contained(android, target)
  try {
    const pnpm = join(temporary, 'pnpm')
    await mkdir(pnpm)
    await extractTar({ file: archive, cwd: pnpm, strip: 1 })
    const identity = JSON.parse(await readFile(join(pnpm, 'package.json'), 'utf8'))
    if (identity.name !== lock.name || identity.version !== lock.version) throw new Error('Android pnpm archive identity mismatch')
    const pnpmEntry = 'pnpm/bin/pnpm.mjs'
    if (!(await lstat(join(temporary, pnpmEntry))).isFile()) throw new Error('Original pnpm entry is missing')
    await mkdir(join(temporary, 'core'))
    const records = []
    const scratch = join(temporary, '.pack')
    await mkdir(scratch)
    for (const { source, metadata } of packages) {
      const directory = join(scratch, 'package')
      await cp(source, directory, { recursive: true, dereference: true, filter: path => {
        const local = relative(source, path)
        return !local.split(sep).some(part => excludedDirectories.has(part)) && !excludedFile.test(local)
      } })
      const packed = publishableCoreManifest(metadata, versions, unsupportedOptional)
      await writeFile(join(directory, 'package.json'), `${JSON.stringify(packed, null, 2)}\n`)
      if (typeof packed.main === 'string') {
        const entry = join(directory, packed.main)
        contained(directory, entry)
        if (!(await lstat(entry)).isFile()) throw new Error(`Android core package build output is missing: ${metadata.name}/${packed.main}`)
      }
      const pending = join(temporary, 'core', 'pending.tgz')
      await createTar({ cwd: scratch, file: pending, gzip: true, portable: true, mtime: new Date(0) }, ['package'])
      const bytes = await readFile(pending)
      const sha256 = hash('sha256', bytes)
      const file = `${metadata.name.slice(1).replace('/', '-')}-${metadata.version}-${sha256.slice(0, 16)}.tgz`
      await rename(pending, join(temporary, 'core', file))
      records.push({ name: metadata.name, version: metadata.version, file, bytes: bytes.length, sha256 })
      contained(temporary, directory)
      await rm(directory, { recursive: true })
    }
    await rm(scratch, { recursive: true })
    const descriptor = { schemaVersion: 1, pnpm: { ...lock, entry: pnpmEntry }, packages: records }
    await writeFile(join(temporary, 'packages.json'), `${JSON.stringify(descriptor, null, 2)}\n`)
    // This is a disposable build output, never the device's active profile.
    await rm(target, { recursive: true, force: true })
    await rename(temporary, target)
    console.log(`Android package manager: pnpm ${lock.version}, ${records.length} local core packages, ${records.reduce((sum, item) => sum + item.bytes, 0)} core archive bytes`)
    return descriptor
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error(`Usage: node ${basename(process.argv[1])} <private-staging-directory>`)
  await stagePackageManager({ repositoryRoot: resolve(import.meta.dirname, '../../..'), staging: resolve(process.argv[2]) })
}
