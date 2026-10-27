import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { lstat, open } from 'node:fs/promises'
import path from 'node:path'

const SHA256 = /^[0-9a-f]{64}$/
const MAX_ROOTFS_BYTES = 96 * 1024 * 1024
const MAX_LAUNCHER_BYTES = 8 * 1024 * 1024
const issuedImages = new WeakSet()

function invalid(message) {
  const error = new Error(message)
  error.code = 'LINUX_USERLAND_IMAGE_INVALID'
  return error
}

function requireDirectory(directory, label) {
  if (typeof directory !== 'string' || !path.isAbsolute(directory)) {
    throw invalid(`${label} must be an absolute App-owned directory`)
  }
  return directory
}

function requireArtifact(spec, label, expectedName, limit) {
  if (!spec || typeof spec !== 'object' || Array.isArray(spec) ||
      spec.file !== expectedName || !SHA256.test(spec.sha256) ||
      !Number.isSafeInteger(spec.bytes) || spec.bytes < 1 || spec.bytes > limit) {
    throw invalid(`Invalid ${label} artifact descriptor`)
  }
  return Object.freeze({ file: spec.file, sha256: spec.sha256, bytes: spec.bytes })
}

async function hashPinnedFile(directory, spec, label) {
  const base = await lstat(directory).catch(() => null)
  if (!base?.isDirectory() || base.isSymbolicLink()) {
    throw invalid(`${label} directory is unavailable or linked`)
  }
  const filename = path.join(directory, spec.file)
  const before = await lstat(filename).catch(() => null)
  if (!before?.isFile() || before.isSymbolicLink() || before.size !== spec.bytes) {
    throw invalid(`${label} is missing, linked, or changed in size`)
  }
  const handle = await open(filename, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = await handle.stat()
    if (!opened.isFile() || opened.size !== spec.bytes ||
        opened.dev !== before.dev || opened.ino !== before.ino) {
      throw invalid(`${label} changed before verification`)
    }
    const digest = createHash('sha256')
    const chunk = Buffer.allocUnsafe(64 * 1024)
    let position = 0
    while (position < spec.bytes) {
      const { bytesRead } = await handle.read(chunk, 0, Math.min(chunk.length, spec.bytes - position), position)
      if (bytesRead < 1) throw invalid(`${label} ended during verification`)
      digest.update(chunk.subarray(0, bytesRead))
      position += bytesRead
    }
    const after = await handle.stat()
    if (after.size !== opened.size || after.mtimeMs !== opened.mtimeMs ||
        after.dev !== opened.dev || after.ino !== opened.ino ||
        digest.digest('hex') !== spec.sha256) {
      throw invalid(`${label} failed its pinned SHA-256 check`)
    }
    return Object.freeze({ path: filename, sha256: spec.sha256, bytes: spec.bytes })
  } finally {
    await handle.close()
  }
}

/**
 * Packaging preflight only. This does not inspect tar entries, install a
 * rootfs, launch PRoot, or authorize guest execution.
 */
export async function verifyLinuxUserlandArtifacts({
  manifest,
  rootfsAssetDirectory,
  nativeLibraryDirectory,
}) {
  if (manifest?.format === 'pocket-linux-userland-v1') {
    throw invalid('Linux userland manifest v1 is unsupported; regenerate it as pocket-linux-userland-v2 with source URL, revision, and license')
  }
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest) ||
      manifest.format !== 'pocket-linux-userland-v2' ||
      manifest.abi !== 'arm64-v8a' ||
      manifest.architecture !== 'aarch64' ||
      !manifest.source || typeof manifest.source !== 'object' ||
      !/^https:\/\//.test(manifest.source.sourceUrl) ||
      !/^[0-9a-f]{40,64}$/.test(manifest.source.sourceRevision) ||
      typeof manifest.source.license !== 'string' ||
      manifest.source.license.length < 3) {
    throw invalid('Invalid Linux userland manifest or source URL, revision, or license')
  }
  const rootfs = requireArtifact(manifest.rootfs, 'rootfs', 'linux-rootfs.tar.gz', MAX_ROOTFS_BYTES)
  const launcher = requireArtifact(manifest.launcher, 'launcher', 'libpocket_proot.so', MAX_LAUNCHER_BYTES)
  const source = Object.freeze({
    sourceUrl: manifest.source.sourceUrl,
    sourceRevision: manifest.source.sourceRevision,
    license: manifest.source.license,
  })
  const assetDir = requireDirectory(rootfsAssetDirectory, 'Rootfs asset')
  const libraryDir = requireDirectory(nativeLibraryDirectory, 'Native library')
  const verifiedRootfs = await hashPinnedFile(assetDir, rootfs, 'Rootfs')
  const verifiedLauncher = await hashPinnedFile(libraryDir, launcher, 'Launcher')
  const image = Object.freeze({
    format: manifest.format,
    abi: manifest.abi,
    rootfs: verifiedRootfs,
    launcher: verifiedLauncher,
    source,
    executable: false,
  })
  issuedImages.add(image)
  return image
}

/** Only the packaging preflight can issue an image for candidate installation. */
export function requireVerifiedLinuxUserlandImage(image) {
  if (!image || !issuedImages.has(image)) {
    throw invalid('Linux userland image was not issued by the packaging preflight')
  }
  return image
}

export function requireLinuxUserlandExecution() {
  const error = new Error('Linux userland execution is gated until isolated-process confinement and device acceptance pass.')
  error.code = 'LINUX_USERLAND_EXECUTOR_UNAVAILABLE'
  throw error
}
