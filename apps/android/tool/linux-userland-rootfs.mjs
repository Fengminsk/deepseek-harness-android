import { createHash, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { link, lstat, mkdir, open, readFile, readdir, readlink, rename, rm, symlink, writeFile } from 'node:fs/promises'
import path from 'node:path'
import * as tar from 'tar'
import { requireVerifiedLinuxUserlandImage } from '../runtime/linux-userland-image.mjs'

const SHA256 = /^[0-9a-f]{64}$/
const MAX_ARCHIVE_BYTES = 96 * 1024 * 1024
const MAX_ENTRIES = 32_768
const MAX_TOTAL_BYTES = 256 * 1024 * 1024
const MAX_FILE_BYTES = 32 * 1024 * 1024
const MAX_PATH_BYTES = 512
const MAX_DEPTH = 32
const RELEASE_FORMAT = 'pocket-linux-rootfs-candidate-v1'

function rejected(message) {
  const error = new Error(message)
  error.code = 'LINUX_ROOTFS_REJECTED'
  return error
}

function requireAbsoluteDirectory(value, label) {
  if (typeof value !== 'string' || !path.isAbsolute(value)) {
    throw rejected(`${label} must be an absolute directory`)
  }
  return value
}

async function requireUnlinkedDirectory(directory, label) {
  const info = await lstat(directory).catch(() => null)
  if (!info?.isDirectory() || info.isSymbolicLink()) {
    throw rejected(`${label} is unavailable or linked`)
  }
}

function entryPath(raw) {
  if (typeof raw !== 'string' || /[\u0000-\u001f\\:]/.test(raw) ||
      raw.startsWith('/') || /^[a-zA-Z]:/.test(raw) || Buffer.byteLength(raw) > MAX_PATH_BYTES) {
    throw rejected('Rootfs contains an unsafe entry path')
  }
  let name = raw
  while (name.startsWith('./')) name = name.slice(2)
  name = name.replace(/\/+$/, '')
  if (name === '' || name === '.') return ''
  const parts = name.split('/')
  if (parts.length > MAX_DEPTH || parts.some(part => !part || part === '.' || part === '..')) {
    throw rejected('Rootfs contains traversal or excessive path depth')
  }
  return name
}

function linkedTarget(raw, parent, self) {
  if (typeof raw !== 'string' || !raw || /[\u0000-\u001f\\:]/.test(raw) ||
      Buffer.byteLength(raw) > MAX_PATH_BYTES) {
    throw rejected('Rootfs contains an unsafe link target')
  }
  // Absolute links in a Linux rootfs name guest-root paths. Convert them to
  // links relative to the staged root, never to host-root links.
  const resolved = path.posix.normalize(raw.startsWith('/')
    ? raw.replace(/^\/+/, '')
    : path.posix.join(parent, raw))
  if (resolved === '..' || resolved.startsWith('../') || resolved.startsWith('/') || resolved === self) {
    throw rejected('Rootfs link escapes or loops to itself')
  }
  return resolved
}

function scanEntry(state, archivePath, entry) {
  const name = entryPath(archivePath)
  const type = entry.type
  if (name === '') {
    if (type !== 'Directory') throw rejected('Rootfs root must be a directory')
    return null
  }
  if (!['File', 'Directory', 'SymbolicLink', 'Link'].includes(type)) {
    throw rejected(`Rootfs contains unsupported entry type ${type}`)
  }
  if (!Number.isSafeInteger(entry.size) || entry.size < 0 || entry.size > MAX_FILE_BYTES ||
      (type !== 'File' && entry.size !== 0)) {
    throw rejected('Rootfs contains an oversized or malformed entry')
  }
  if (++state.count > MAX_ENTRIES || (state.bytes += entry.size) > MAX_TOTAL_BYTES) {
    throw rejected('Rootfs exceeds its entry or expanded-byte budget')
  }
  const segments = name.split('/')
  for (let i = 1; i < segments.length; i++) {
    const parent = segments.slice(0, i).join('/')
    const key = parent.toLowerCase()
    const prior = state.paths.get(key)
    if (prior && (prior.path !== parent || prior.type !== 'Directory')) {
      throw rejected('Rootfs entry crosses a non-directory or case-colliding parent')
    }
    if (!prior) state.paths.set(key, { path: parent, type: 'Directory', explicit: false })
  }
  const key = name.toLowerCase()
  const prior = state.paths.get(key)
  if (prior && (prior.path !== name || prior.type !== 'Directory' || type !== 'Directory' || prior.explicit)) {
    throw rejected('Rootfs contains duplicate or case-colliding entries')
  }
  let target
  let expectedFileBytes = entry.size
  if (type === 'SymbolicLink') {
    target = linkedTarget(entry.linkpath, path.posix.dirname(name), name)
  } else if (type === 'Link') {
    target = linkedTarget(entry.linkpath, '.', name)
    const source = state.paths.get(target.toLowerCase())
    if (!source || source.path !== target || source.type !== 'File') {
      throw rejected('Rootfs hardlink must target an earlier regular file')
    }
    expectedFileBytes = source.size
  }
  state.paths.set(key, { path: name, type, explicit: true, size: expectedFileBytes })
  const hostLink = type === 'SymbolicLink'
    ? path.posix.relative(path.posix.dirname(name), target) || '.'
    : undefined
  const result = Object.freeze({ path: name, type, size: entry.size, expectedFileBytes, target, hostLink })
  state.entries.push(result)
  return result
}

/** Validate the complete tar stream before any filesystem extraction. */
export async function inspectPinnedRootfsArchive(archivePath) {
  const state = { count: 0, bytes: 0, paths: new Map(), entries: [] }
  const fileDigests = new Map()
  let rejectedEntry
  try {
    await tar.t({
      file: archivePath,
      strict: true,
      maxDecompressionRatio: 100,
      onReadEntry: entry => {
        if (entry.type !== 'File') return
        const name = entryPath(entry.path)
        const hash = createHash('sha256')
        entry.on('data', chunk => hash.update(chunk))
        entry.on('end', () => fileDigests.set(name, hash.digest('hex')))
      },
      filter: (archiveName, entry) => {
        if (rejectedEntry) return false
        try { scanEntry(state, archiveName, entry) }
        catch (error) { rejectedEntry = error; return false }
        return true
      },
    })
  } catch (error) {
    if (rejectedEntry) throw rejectedEntry
    throw rejected(`Rootfs tar validation failed: ${error.message}`)
  }
  if (rejectedEntry) throw rejectedEntry
  if (!state.entries.some(entry => entry.type === 'File')) {
    throw rejected('Rootfs has no regular files')
  }
  const entries = state.entries.map(entry => {
    if (entry.type !== 'File') return entry
    const sha256 = fileDigests.get(entry.path)
    if (!SHA256.test(sha256)) throw rejected('Rootfs file digest was not completed')
    return Object.freeze({ ...entry, sha256 })
  })
  return Object.freeze({
    entries: Object.freeze(entries),
    expandedBytes: state.bytes,
    entryCount: state.count,
  })
}

async function copyPinnedArchive(source, destination, expected) {
  const before = await lstat(source).catch(() => null)
  if (!before?.isFile() || before.isSymbolicLink() || before.size !== expected.bytes) {
    throw rejected('Pinned rootfs archive is unavailable or changed')
  }
  const input = await open(source, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  const output = await open(destination, 'wx', 0o600)
  try {
    const opened = await input.stat()
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size) {
      throw rejected('Pinned rootfs archive changed before copy')
    }
    const hash = createHash('sha256')
    const chunk = Buffer.allocUnsafe(64 * 1024)
    let copied = 0
    while (copied < expected.bytes) {
      const { bytesRead } = await input.read(chunk, 0, Math.min(chunk.length, expected.bytes - copied), copied)
      if (!bytesRead) throw rejected('Pinned rootfs archive ended during copy')
      let offset = 0
      while (offset < bytesRead) {
        const { bytesWritten } = await output.write(chunk, offset, bytesRead - offset, copied + offset)
        if (!bytesWritten) throw rejected('Could not copy pinned rootfs archive')
        offset += bytesWritten
      }
      hash.update(chunk.subarray(0, bytesRead))
      copied += bytesRead
    }
    const after = await input.stat()
    if (after.dev !== opened.dev || after.ino !== opened.ino ||
        after.size !== opened.size || after.mtimeMs !== opened.mtimeMs ||
        hash.digest('hex') !== expected.sha256) {
      throw rejected('Pinned rootfs archive failed its SHA-256 check')
    }
    await output.sync()
  } finally {
    await Promise.allSettled([input.close(), output.close()])
  }
}

async function verifyPinnedArchive(filename, expected) {
  const before = await lstat(filename).catch(() => null)
  if (!before?.isFile() || before.isSymbolicLink() || before.size !== expected.bytes) {
    throw rejected('Published rootfs archive is missing, linked, or changed in size')
  }
  const input = await open(filename, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = await input.stat()
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino ||
        opened.size !== before.size) throw rejected('Published rootfs archive changed before reading')
    const hash = createHash('sha256')
    const chunk = Buffer.allocUnsafe(64 * 1024)
    let offset = 0
    while (offset < opened.size) {
      const { bytesRead } = await input.read(chunk, 0, Math.min(chunk.length, opened.size - offset), offset)
      if (!bytesRead) throw rejected('Published rootfs archive ended during reading')
      hash.update(chunk.subarray(0, bytesRead))
      offset += bytesRead
    }
    const after = await input.stat()
    if (after.dev !== opened.dev || after.ino !== opened.ino || after.size !== opened.size ||
        after.mtimeMs !== opened.mtimeMs || hash.digest('hex') !== expected.sha256) {
      throw rejected('Published rootfs archive failed its pinned SHA-256 check')
    }
  } finally {
    await input.close()
  }
}

async function ensureExtractedTree(rootfs, inventory) {
  const expected = new Map()
  for (const entry of inventory.entries) {
    const segments = entry.path.split('/')
    for (let i = 1; i < segments.length; i++) {
      const parent = segments.slice(0, i).join('/')
      if (!expected.has(parent)) expected.set(parent, 'Directory')
    }
    expected.set(entry.path, entry.type)
  }
  const pending = [{ directory: rootfs, prefix: '' }]
  while (pending.length) {
    const { directory, prefix } = pending.pop()
    for (const name of await readdir(directory)) {
      const relative = prefix ? `${prefix}/${name}` : name
      const type = expected.get(relative)
      if (!type) throw rejected('Rootfs contains an unlisted entry')
      const child = path.join(directory, name)
      const info = await lstat(child)
      if (type === 'Directory') {
        if (!info.isDirectory() || info.isSymbolicLink()) {
          throw rejected('Rootfs directory changed type')
        }
        pending.push({ directory: child, prefix: relative })
      } else if (type === 'SymbolicLink' ? !info.isSymbolicLink() : !info.isFile()) {
        throw rejected('Rootfs entry changed type')
      }
    }
  }
  for (const entry of inventory.entries) {
    const filename = path.join(rootfs, ...entry.path.split('/'))
    const info = await lstat(filename).catch(() => null)
    if (!info) throw rejected(`Rootfs entry missing after extraction: ${entry.path}`)
    if (entry.type === 'Directory' && !info.isDirectory()) throw rejected('Rootfs directory changed type')
    if ((entry.type === 'File' || entry.type === 'Link') &&
        (!info.isFile() || info.size !== entry.expectedFileBytes)) throw rejected('Rootfs file changed type or size')
    if (entry.type === 'File' && await hashExtractedFile(filename, info) !== entry.sha256) {
      throw rejected('Rootfs file contents do not match the pinned archive')
    }
    if (entry.type === 'Link') {
      const targetInfo = await lstat(path.join(rootfs, ...entry.target.split('/')))
      if (info.dev !== targetInfo.dev || info.ino !== targetInfo.ino) {
        throw rejected('Rootfs hardlink no longer points to its source')
      }
    }
    if (entry.type === 'SymbolicLink' &&
        (!info.isSymbolicLink() || (await readlink(filename)).replaceAll('\\', '/') !== entry.hostLink)) {
      throw rejected('Rootfs link changed type or target')
    }
  }
}

async function hashExtractedFile(filename, before) {
  const handle = await open(filename, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = await handle.stat()
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino ||
        opened.size !== before.size) throw rejected('Rootfs file changed during verification')
    const hash = createHash('sha256')
    const chunk = Buffer.allocUnsafe(64 * 1024)
    let offset = 0
    while (offset < opened.size) {
      const { bytesRead } = await handle.read(chunk, 0, Math.min(chunk.length, opened.size - offset), offset)
      if (!bytesRead) throw rejected('Rootfs file ended during verification')
      hash.update(chunk.subarray(0, bytesRead))
      offset += bytesRead
    }
    const after = await handle.stat()
    if (after.size !== opened.size || after.dev !== opened.dev || after.ino !== opened.ino ||
        after.mtimeMs !== opened.mtimeMs) throw rejected('Rootfs file changed during verification')
    return hash.digest('hex')
  } finally {
    await handle.close()
  }
}

async function materializeLinks(rootfs, inventory) {
  const types = new Map(inventory.entries.map(entry => [entry.path, entry.type]))
  // No symlink exists during tar extraction or hardlink creation. This avoids
  // following an archive-controlled symlink while writing a later entry.
  for (const entry of inventory.entries) {
    if (entry.type !== 'Link') continue
    await link(path.join(rootfs, ...entry.target.split('/')),
      path.join(rootfs, ...entry.path.split('/')))
  }
  for (const entry of inventory.entries) {
    if (entry.type !== 'SymbolicLink') continue
    await symlink(entry.hostLink, path.join(rootfs, ...entry.path.split('/')),
      types.get(entry.target) === 'Directory' ? 'dir' : 'file')
  }
}

/**
 * Stage one trusted, digest-pinned data image as a candidate release. The
 * caller still must independently approve and activate a guest backend.
 * This function never launches an ELF, PRoot, or a model-authored command.
 */
export async function publishRootfsCandidate({ verifiedImage, installationRoot }) {
  requireVerifiedLinuxUserlandImage(verifiedImage)
  const digest = verifiedImage?.rootfs?.sha256
  const bytes = verifiedImage?.rootfs?.bytes
  const source = verifiedImage?.rootfs?.path
  if (verifiedImage?.executable !== false || !SHA256.test(digest) ||
      !Number.isSafeInteger(bytes) || bytes < 1 || bytes > MAX_ARCHIVE_BYTES ||
      typeof source !== 'string' || !path.isAbsolute(source)) {
    throw rejected('Only an already verified ARM64 image may be staged')
  }
  const root = requireAbsoluteDirectory(installationRoot, 'Installation root')
  await requireUnlinkedDirectory(root, 'Installation root')
  const versions = path.join(root, 'versions')
  await mkdir(versions, { recursive: true, mode: 0o700 })
  await requireUnlinkedDirectory(versions, 'Version directory')
  const final = path.join(versions, digest)
  if (await lstat(final).catch(() => null)) throw rejected('Rootfs candidate already exists')
  const stage = path.join(versions, `.staging-${randomUUID()}`)
  await mkdir(stage, { mode: 0o700 })
  try {
    const archive = path.join(stage, 'image.tar.gz')
    await copyPinnedArchive(source, archive, { sha256: digest, bytes })
    const inventory = await inspectPinnedRootfsArchive(archive)
    const rootfs = path.join(stage, 'rootfs')
    await mkdir(rootfs, { mode: 0o700 })
    let index = 0
    let changedEntry
    try {
      await tar.x({
        file: archive,
        cwd: rootfs,
        strict: true,
        keep: true,
        preservePaths: false,
        preserveOwner: false,
        noMtime: true,
        maxDecompressionRatio: 100,
        filter: (archiveName, entry) => {
          if (changedEntry) return false
          try {
            const next = entryPath(archiveName)
            if (next === '') return true
            const planned = inventory.entries[index++]
            if (!planned || planned.path !== next || planned.type !== entry.type ||
                planned.size !== entry.size ||
                (planned.target && planned.target !== linkedTarget(entry.linkpath,
                  entry.type === 'Link' ? '.' : path.posix.dirname(next), next))) {
              throw rejected('Rootfs archive changed between validation and extraction')
            }
          return planned.type !== 'SymbolicLink' && planned.type !== 'Link'
          } catch (error) { changedEntry = error; return false }
        },
      })
    } catch (error) {
      if (changedEntry) throw changedEntry
      throw rejected(`Rootfs tar extraction failed: ${error.message}`)
    }
    if (changedEntry) throw changedEntry
    if (index !== inventory.entries.length) throw rejected('Rootfs extraction omitted entries')
    await materializeLinks(rootfs, inventory)
    await ensureExtractedTree(rootfs, inventory)
    const receipt = {
      format: RELEASE_FORMAT,
      abi: 'arm64-v8a',
      rootfsSha256: digest,
      archiveBytes: bytes,
      entryCount: inventory.entryCount,
      expandedBytes: inventory.expandedBytes,
      executable: false,
    }
    await writeFile(path.join(stage, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx', mode: 0o600 })
    // Rename makes a complete candidate visible atomically, but fsync of the
    // containing directory is platform-specific. Crash durability is not
    // promised until a separate activation transaction is designed.
    await rename(stage, final)
    return Object.freeze({ directory: final, rootfs: path.join(final, 'rootfs'), ...receipt })
  } catch (error) {
    if (path.dirname(stage) !== versions || !path.basename(stage).startsWith('.staging-')) {
      throw rejected('Refusing to clean a directory outside the candidate release root')
    }
    await rm(stage, { recursive: true, force: true })
    throw error
  }
}

/**
 * Inspect a previously published data-only release after process restart.
 * A caller must re-verify the shipped image source first; this does not grant
 * execution or treat the writable receipt as an authority.
 */
export async function verifyPublishedRootfsCandidate({ verifiedImage, installationRoot }) {
  requireVerifiedLinuxUserlandImage(verifiedImage)
  const digest = verifiedImage?.rootfs?.sha256
  const bytes = verifiedImage?.rootfs?.bytes
  if (verifiedImage?.executable !== false || !SHA256.test(digest) ||
      !Number.isSafeInteger(bytes) || bytes < 1 || bytes > MAX_ARCHIVE_BYTES) {
    throw rejected('Only a pinned data image may verify a published release')
  }
  const root = requireAbsoluteDirectory(installationRoot, 'Installation root')
  await requireUnlinkedDirectory(root, 'Installation root')
  const versions = path.join(root, 'versions')
  await requireUnlinkedDirectory(versions, 'Version directory')
  const directory = path.join(versions, digest)
  await requireUnlinkedDirectory(directory, 'Published release')
  const rootfs = path.join(directory, 'rootfs')
  await requireUnlinkedDirectory(rootfs, 'Published rootfs')
  const archive = path.join(directory, 'image.tar.gz')
  await verifyPinnedArchive(archive, { sha256: digest, bytes })
  const inventory = await inspectPinnedRootfsArchive(archive)
  const receiptFile = path.join(directory, 'receipt.json')
  const receiptInfo = await lstat(receiptFile).catch(() => null)
  if (!receiptInfo?.isFile() || receiptInfo.isSymbolicLink() || receiptInfo.size > 4096) {
    throw rejected('Published release receipt is unavailable or linked')
  }
  let receipt
  try {
    receipt = JSON.parse(await readFile(receiptFile, 'utf8'))
  } catch {
    throw rejected('Published release receipt is malformed')
  }
  if (!receipt || receipt.format !== RELEASE_FORMAT || receipt.abi !== 'arm64-v8a' ||
      receipt.rootfsSha256 !== digest || receipt.archiveBytes !== bytes ||
      receipt.entryCount !== inventory.entryCount ||
      receipt.expandedBytes !== inventory.expandedBytes || receipt.executable !== false) {
    throw rejected('Published release receipt disagrees with the pinned archive')
  }
  const topLevel = await readdir(directory)
  if (topLevel.length !== 3 ||
      !['image.tar.gz', 'receipt.json', 'rootfs'].every(name => topLevel.includes(name))) {
    throw rejected('Published release contains an unexpected top-level entry')
  }
  await ensureExtractedTree(rootfs, inventory)
  return Object.freeze({
    directory, rootfs, format: RELEASE_FORMAT, abi: 'arm64-v8a',
    rootfsSha256: digest, archiveBytes: bytes,
    entryCount: inventory.entryCount, expandedBytes: inventory.expandedBytes,
    executable: false,
  })
}
