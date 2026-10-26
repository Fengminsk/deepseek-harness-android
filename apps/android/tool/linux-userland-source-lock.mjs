import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { lstat, open } from 'node:fs/promises'
import path from 'node:path'
import { inspectPinnedRootfsArchive } from './linux-userland-rootfs.mjs'

// Reviewed source identities, not an authorization to execute downloaded code.
export const ALPINE_ROOTFS_SOURCE = Object.freeze({
  name: 'alpine-minirootfs',
  version: '3.24.3',
  architecture: 'aarch64',
  url: 'https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.3-aarch64.tar.gz',
  sha256: '4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50',
  bytes: 4_029_999,
})

export const TERMUX_PROOT_SOURCE = Object.freeze({
  name: 'termux-proot',
  version: '5.1.107.96',
  url: 'https://github.com/termux/proot/archive/v5.1.107.96.zip',
  sha256: '75f654fe60dea92dabff2bf083ae8bfe4f91baa6a1a374786a6bf391015eebaa',
  license: 'GPL-2.0',
  status: 'source-only; no reviewed Android launcher binary',
})

/** Verify the exact reviewed Alpine source before entering a package build. */
export async function verifyLockedAlpineRootfs(archivePath) {
  if (typeof archivePath !== 'string' || !path.isAbsolute(archivePath)) {
    throw new TypeError('Rootfs source path must be absolute')
  }
  const before = await lstat(archivePath)
  if (!before.isFile() || before.isSymbolicLink() || before.size !== ALPINE_ROOTFS_SOURCE.bytes) {
    throw new Error('Locked Alpine rootfs source is missing, linked, or changed in size')
  }
  const input = await open(archivePath, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = await input.stat()
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino ||
        opened.size !== before.size) throw new Error('Locked Alpine rootfs changed before reading')
    const hash = createHash('sha256')
    const chunk = Buffer.allocUnsafe(64 * 1024)
    let offset = 0
    while (offset < opened.size) {
      const { bytesRead } = await input.read(chunk, 0, Math.min(chunk.length, opened.size - offset), offset)
      if (!bytesRead) throw new Error('Locked Alpine rootfs ended during reading')
      hash.update(chunk.subarray(0, bytesRead))
      offset += bytesRead
    }
    const after = await input.stat()
    if (after.dev !== opened.dev || after.ino !== opened.ino ||
        after.size !== opened.size || after.mtimeMs !== opened.mtimeMs ||
        hash.digest('hex') !== ALPINE_ROOTFS_SOURCE.sha256) {
      throw new Error('Locked Alpine rootfs failed its fixed SHA-256 check')
    }
  } finally {
    await input.close()
  }
  const inventory = await inspectPinnedRootfsArchive(archivePath)
  return Object.freeze({ ...ALPINE_ROOTFS_SOURCE, entryCount: inventory.entryCount,
    expandedBytes: inventory.expandedBytes })
}
