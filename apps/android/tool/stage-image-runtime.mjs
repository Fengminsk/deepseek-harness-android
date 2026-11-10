/** Package Sharp's official WASM fallback from the repository's exact dependency lock. */
import { createHash } from 'node:crypto'
import { lstat, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { load } from 'js-yaml'
import { satisfies } from 'semver'
import { x as extractTar } from 'tar'

const packageName = /^(?:@[a-z0-9._~-]+\/)?[a-z0-9._~-]+$/
const versionPattern = /^\d+\.\d+\.\d+(?:-[a-z0-9.-]+)?$/
const integrityOf = bytes => `sha512-${createHash('sha512').update(bytes).digest('base64')}`
const renameRetryDelays = [25, 50, 100, 200, 400, 800]

function contained(parent, child) {
  const path = relative(resolve(parent), resolve(child))
  if (!path || isAbsolute(path) || path === '..' || path.startsWith(`..${sep}`)) {
    throw new Error('Image runtime staging target escapes its output directory')
  }
}

/** Resolve the official WASM package and its entire dependency closure without choosing new versions. */
export function imageRuntimePackages(lock, sharpVersion) {
  if (!versionPattern.test(sharpVersion)) throw new Error('Invalid staged Sharp version')
  const result = new Map()
  const visit = (name, version) => {
    if (!packageName.test(name) || !versionPattern.test(version)) throw new Error('Invalid locked image package identity')
    const existing = result.get(name)
    if (existing) {
      if (existing.version !== version) throw new Error(`Conflicting image dependency versions: ${name}`)
      return
    }
    const key = `${name}@${version}`
    const integrity = lock.packages?.[key]?.resolution?.integrity
    const snapshot = lock.snapshots?.[key]
    if (!/^sha512-[A-Za-z0-9+/]{86}==$/.test(integrity ?? '') || !snapshot) {
      throw new Error(`Image dependency is not pinned in pnpm-lock.yaml: ${key}`)
    }
    if (snapshot.optionalDependencies || snapshot.transitivePeerDependencies) {
      throw new Error(`Image dependency needs an explicit Android compatibility review: ${key}`)
    }
    const item = { name, version, integrity, dependencies: snapshot.dependencies ?? {},
      url: `https://registry.npmjs.org/${name}/-/${name.split('/').at(-1)}-${version}.tgz` }
    result.set(name, item)
    for (const [dependency, resolved] of Object.entries(item.dependencies)) visit(dependency, resolved)
  }
  visit('@img/sharp-wasm32', sharpVersion)
  return [...result.values()]
}

/** Revalidate cached archives and publish newly downloaded bytes only after SHA-512 verification. */
export async function imageRuntimeArchive(item, cacheDirectory) {
  await mkdir(cacheDirectory, { recursive: true })
  const file = join(cacheDirectory, `${item.name.replaceAll('/', '-').replace('@', '')}-${item.version}.tgz`)
  contained(cacheDirectory, file)
  let bytes
  try { bytes = await readFile(file) } catch (error) { if (error.code !== 'ENOENT') throw error }
  const cached = bytes !== undefined
  if (!cached) {
    const response = await fetch(item.url, { signal: AbortSignal.timeout(120_000) })
    if (!response.ok) throw new Error(`Image runtime download failed: ${item.name}, HTTP ${response.status}`)
    bytes = Buffer.from(await response.arrayBuffer())
  }
  if (integrityOf(bytes) !== item.integrity) throw new Error(`Image runtime archive checksum mismatch: ${item.name}`)
  if (!cached) {
    const scratch = await mkdtemp(join(cacheDirectory, '.image-download-'))
    contained(cacheDirectory, scratch)
    try {
      const temporary = join(scratch, 'package.tgz')
      await writeFile(temporary, bytes)
      await rename(temporary, file)
    } finally { await rm(scratch, { recursive: true, force: true }) }
  }
  return file
}

/**
 * Publish a verified package into an absent target in exclusively owned staging.
 * Windows may briefly retain directory handles after removal. Retry only those
 * rename errors, with at most 1,575 ms of backoff; never remove a reappearing target.
 * Return the retry count so an actual recovery is visible in the staging log.
 * @param {string} temporary - Verified package directory owned by this staging run.
 * @param {string} destination - Absent package target within the same private staging directory.
 * @param {object} options - Instance-local platform and filesystem adapters for deterministic tests.
 * @param {string} [options.platform] - Host platform; retry applies only to Windows.
 * @param {Function} [options.move] - Directory rename operation.
 * @param {Function} [options.inspect] - Target lstat operation, including dangling links.
 * @param {Function} [options.pause] - Awaited backoff in milliseconds.
 * @returns {Promise<number>} Number of retries before a successful publication.
 */
export async function publishImageRuntimePackage(temporary, destination, {
  platform = process.platform, move = rename, inspect = lstat, pause = delay,
} = {}) {
  for (let attempt = 0; ; attempt++) {
    let absent = false
    try { await inspect(destination) } catch (error) {
      if (error.code !== 'ENOENT') throw error
      absent = true
    }
    if (!absent) {
      throw Object.assign(new Error('Image runtime staging target already exists'), { code: 'EEXIST' })
    }
    try {
      await move(temporary, destination)
      return attempt
    } catch (error) {
      if (platform !== 'win32' || !['EPERM', 'EBUSY', 'EACCES'].includes(error.code)
        || attempt >= renameRetryDelays.length) throw error
      await pause(renameRetryDelays[attempt])
    }
  }
}

/** Stage original packages, including licenses and worker/WASM files; no install scripts or source patches. */
export async function stageImageRuntime({ repositoryRoot, staging,
  cacheDirectory = join(repositoryRoot, '.cache/android/image-archives') }) {
  const modules = resolve(staging, 'node_modules')
  const sharp = JSON.parse(await readFile(join(modules, 'sharp/package.json'), 'utf8'))
  if (sharp.name !== 'sharp') throw new Error('Staged Sharp package identity mismatch')
  const lock = load(await readFile(join(repositoryRoot, 'pnpm-lock.yaml'), 'utf8'))
  const packages = imageRuntimePackages(lock, sharp.version)
  for (const item of packages) {
    const archive = await imageRuntimeArchive(item, cacheDirectory)
    const destination = join(modules, item.name)
    contained(modules, destination)
    const temporary = await mkdtemp(join(modules, '.image-package-'))
    contained(modules, temporary)
    try {
      await extractTar({ file: archive, cwd: temporary, strip: 1,
        filter: (_path, entry) => entry.type !== 'SymbolicLink' && entry.type !== 'Link' })
      const metadata = JSON.parse(await readFile(join(temporary, 'package.json'), 'utf8'))
      if (metadata.name !== item.name || metadata.version !== item.version
        || Object.keys(metadata.dependencies ?? {}).length !== Object.keys(item.dependencies).length
        || Object.entries(metadata.dependencies ?? {}).some(([name, range]) => !item.dependencies[name] || !satisfies(item.dependencies[name], range))) {
        throw new Error(`Image runtime archive dependencies differ from lock: ${item.name}`)
      }
      // Both targets are resolved children of the private staging node_modules.
      await mkdir(resolve(destination, '..'), { recursive: true })
      await rm(destination, { recursive: true, force: true })
      const retries = await publishImageRuntimePackage(temporary, destination)
      if (retries) console.warn(`Image runtime directory rename recovered after ${retries} retries: ${item.name}`)
    } finally { await rm(temporary, { recursive: true, force: true }) }
  }
  const android = join(resolve(staging), 'android')
  await mkdir(android, { recursive: true })
  await writeFile(join(android, 'image-runtime.json'), `${JSON.stringify({ sharp: sharp.version, packages }, null, 2)}\n`)
  return packages
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('Usage: node stage-image-runtime.mjs <private-staging-directory>')
  const packages = await stageImageRuntime({ repositoryRoot: resolve(import.meta.dirname, '../../..'), staging: resolve(process.argv[2]) })
  console.log(`Staged official Sharp WASM runtime: ${packages.map(item => `${item.name}@${item.version}`).join(', ')}`)
}
