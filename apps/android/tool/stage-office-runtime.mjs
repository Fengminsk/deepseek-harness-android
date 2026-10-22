/** Stage the original Office provider's pinned portable engine for Android Node. */
import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { cp, lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, stat, writeFile } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { load } from 'js-yaml'
import { x as extractTar } from 'tar'

const names = ['@deepseek-ai/libreoffice-kit', '@deepseek-ai/libreoffice-kit-wasm']
const hash = (algorithm, bytes) => createHash(algorithm).update(bytes).digest('hex')
const integrity = bytes => `sha512-${createHash('sha512').update(bytes).digest('base64')}`

function child(parent, target) {
  const path = relative(resolve(parent), resolve(target))
  if (!path || isAbsolute(path) || path === '..' || path.startsWith(`..${sep}`)) {
    throw new Error('Office staging target escapes its private output directory')
  }
}

export function officeRuntimePackages(lock, version) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Invalid Office runtime version')
  const adapter = lock.snapshots?.[`${names[0]}@${version}`]
  if (adapter?.optionalDependencies?.[names[1]] !== version) {
    throw new Error('Locked Office adapter does not select the matching WASM engine')
  }
  for (const [name, dependency] of Object.entries(adapter.dependencies ?? {})) {
    if (!lock.packages?.[`${name}@${dependency}`]) throw new Error(`Office dependency is not locked: ${name}`)
  }
  return names.map(name => {
    const locked = lock.packages?.[`${name}@${version}`]
    const checksum = locked?.resolution?.integrity
    if (!/^sha512-[A-Za-z0-9+/]{86}==$/.test(checksum ?? '')) {
      throw new Error(`Office package is not pinned: ${name}@${version}`)
    }
    if (locked.os || locked.cpu) throw new Error(`Office package is not portable: ${name}`)
    return { name, version, integrity: checksum,
      url: `https://registry.npmjs.org/${name}/-/${name.split('/').at(-1)}-${version}.tgz` }
  })
}

export async function officeRuntimeArchive(item, cacheDirectory) {
  await mkdir(cacheDirectory, { recursive: true })
  const archive = join(cacheDirectory, `${item.name.split('/').at(-1)}-${item.version}.tgz`)
  child(cacheDirectory, archive)
  let bytes
  try { bytes = await readFile(archive) } catch (error) { if (error.code !== 'ENOENT') throw error }
  if (!bytes) {
    const response = await fetch(item.url, { signal: AbortSignal.timeout(120_000) })
    if (!response.ok) throw new Error(`Office runtime download failed: ${item.name}, HTTP ${response.status}`)
    bytes = Buffer.from(await response.arrayBuffer())
  }
  if (integrity(bytes) !== item.integrity) throw new Error(`Office runtime archive checksum mismatch: ${item.name}`)
  if (!existsSync(archive)) {
    const temporary = await mkdtemp(join(cacheDirectory, '.office-download-'))
    child(cacheDirectory, temporary)
    try {
      await writeFile(join(temporary, 'package.tgz'), bytes)
      await rename(join(temporary, 'package.tgz'), archive)
    } finally { await rm(temporary, { recursive: true, force: true }) }
  }
  return archive
}

export async function verifyOfficeEngine(directory, version) {
  const manifest = JSON.parse(await readFile(join(directory, 'prebuilds.json'), 'utf8'))
  if (manifest.version !== version || manifest.platform !== 'wasm' || manifest.status !== 'built'
    || manifest.engine?.kind !== 'wasm') throw new Error('Office WASM engine identity mismatch')
  const expected = [manifest.engine.loader, manifest.engine.wasm, manifest.engine.data,
    manifest.engine.metadata, 'assets/manifest.json']
  if (expected.some(path => !/^assets\/[a-zA-Z0-9._-]+$/.test(path))) {
    throw new Error('Office WASM engine has an invalid asset path')
  }
  for (const path of expected) {
    const target = join(directory, path)
    child(directory, target)
    const checksum = manifest.files?.[path]
    if (!/^[a-f0-9]{64}$/.test(checksum ?? '') || hash('sha256', await readFile(target)) !== checksum) {
      throw new Error(`Office WASM engine asset checksum mismatch: ${path}`)
    }
  }
  return { version, backend: 'wasm', assets: expected.map(path => ({ path, sha256: manifest.files[path] })) }
}

/** Verify archives before extraction; publish only the runtime, engine assets, and licenses. */
export async function stageOfficeRuntime({ repositoryRoot, staging,
  cacheDirectory = join(repositoryRoot, '.cache/android/office-archives') }) {
  const modules = resolve(staging, 'node_modules')
  if ((await realpath(modules)) !== modules) throw new Error('Office modules directory must not be a link')
  const source = JSON.parse(await readFile(join(repositoryRoot, 'packages/document/office-to-pdf/package.json'), 'utf8'))
  const version = source.dependencies?.[names[0]]
  const lock = load(await readFile(join(repositoryRoot, 'pnpm-lock.yaml'), 'utf8'))
  const packages = officeRuntimePackages(lock, version)
  for (const item of packages) {
    const archive = await officeRuntimeArchive(item, cacheDirectory)
    const destination = join(modules, item.name)
    child(modules, destination)
    const temporary = await mkdtemp(join(modules, '.office-package-'))
    child(modules, temporary)
    try {
      const allowed = item.name === names[1]
        ? /^(?:package\/)?(?:package\.json|prebuilds\.json|assets(?:\/.*)?|licenses(?:\/.*)?|NOTICE|LICENSE)$/
        : /^(?:package\/)?(?:package\.json|lib(?:\/.*)?|NOTICE|LICENSE)$/
      await extractTar({ file: archive, cwd: temporary, strip: 1,
        filter: (path, entry) => entry.type !== 'SymbolicLink' && entry.type !== 'Link' && allowed.test(path) })
      const metadata = JSON.parse(await readFile(join(temporary, 'package.json'), 'utf8'))
      if (metadata.name !== item.name || metadata.version !== version) {
        throw new Error(`Office runtime package identity mismatch: ${item.name}`)
      }
      if (item.name === names[1]) await verifyOfficeEngine(temporary, version)
      if (existsSync(destination)) {
        if ((await lstat(destination)).isSymbolicLink()) throw new Error('Office target cannot be a link')
        child(modules, await realpath(destination))
        await rm(destination, { recursive: true, force: true })
      }
      await mkdir(resolve(destination, '..'), { recursive: true })
      await cp(temporary, destination, { recursive: true })
    } finally { await rm(temporary, { recursive: true, force: true }) }
  }
  for (const name of Object.keys(lock.snapshots?.[`${names[0]}@${version}`]?.dependencies ?? {})) {
    const path = join(modules, name, 'package.json')
    if (!(await stat(path).catch(() => null))?.isFile()) throw new Error(`Staged Office dependency is missing: ${name}`)
  }
  // The desktop deploy can carry a 190 MiB Win32 engine. It is never usable
  // by Android Node and would otherwise inflate every APK and extraction.
  for (const suffix of ['darwin-arm64', 'darwin-x64', 'win32-arm64', 'win32-x64']) {
    const obsolete = join(modules, `@deepseek-ai/libreoffice-kit-${suffix}`)
    child(modules, obsolete)
    if (!existsSync(obsolete)) continue
    if ((await lstat(obsolete)).isSymbolicLink()) throw new Error('Office native package cannot be a link')
    child(modules, await realpath(obsolete))
    await rm(obsolete, { recursive: true, force: true })
  }
  const engine = await verifyOfficeEngine(join(modules, names[1]), version)
  await mkdir(join(staging, 'android'), { recursive: true })
  await writeFile(join(staging, 'android/office-runtime.json'), `${JSON.stringify({ ...engine, packages }, null, 2)}\n`)
  return engine
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('Usage: node stage-office-runtime.mjs <private-staging-directory>')
  const engine = await stageOfficeRuntime({ repositoryRoot: resolve(import.meta.dirname, '../../..'), staging: resolve(process.argv[2]) })
  console.log(`Staged official Office ${engine.backend} runtime ${engine.version}`)
}
