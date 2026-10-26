import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { ALPINE_ROOTFS_SOURCE, TERMUX_PROOT_SOURCE, verifyLockedAlpineRootfs } from './linux-userland-source-lock.mjs'

test('locks both upstream URLs to fixed release archives and checksums', () => {
  assert.match(ALPINE_ROOTFS_SOURCE.url, /alpine-minirootfs-3\.24\.3-aarch64\.tar\.gz$/)
  assert.match(TERMUX_PROOT_SOURCE.url, /v5\.1\.107\.96\.zip$/)
  assert.match(ALPINE_ROOTFS_SOURCE.sha256, /^[a-f0-9]{64}$/)
  assert.match(TERMUX_PROOT_SOURCE.sha256, /^[a-f0-9]{64}$/)
  assert.equal(ALPINE_ROOTFS_SOURCE.bytes, 4_029_999)
})

test('rejects a same-sized Alpine archive with the wrong digest', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'pocket-source-lock-'))
  try {
    const archive = path.join(directory, 'rootfs.tar.gz')
    const wrong = Buffer.alloc(ALPINE_ROOTFS_SOURCE.bytes)
    assert.notEqual(createHash('sha256').update(wrong).digest('hex'), ALPINE_ROOTFS_SOURCE.sha256)
    await writeFile(archive, wrong)
    await assert.rejects(verifyLockedAlpineRootfs(archive), /fixed SHA-256 check/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})
