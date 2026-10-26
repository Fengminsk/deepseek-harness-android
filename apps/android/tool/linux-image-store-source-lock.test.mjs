import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { test } from 'node:test'
import { ALPINE_ROOTFS_SOURCE, verifyLockedAlpineRootfs } from './linux-userland-source-lock.mjs'

const root = resolve(import.meta.dirname, '../../..')
const javaRoot = resolve(root, 'apps/android/android/app/src/main/java/com/minnnng/dsh_android')
const reviewedArchive = resolve(root,
  '.cache/android/linux-rootfs-prototype/alpine-minirootfs-3.24.3-aarch64.tar.gz')

test('App installer, lease owner and tooling pin the same Alpine image identity', async () => {
  const [installer, lease] = await Promise.all([
    readFile(resolve(javaRoot, 'PinnedLinuxImageStore.java'), 'utf8'),
    readFile(resolve(javaRoot, 'LinuxImageLeaseOwner.java'), 'utf8'),
  ])
  assert.match(installer, /https:\/\/dl-cdn\.alpinelinux\.org\/alpine\/v3\.24\/releases\/aarch64\//)
  assert.ok(installer.includes(`"alpine-minirootfs-${ALPINE_ROOTFS_SOURCE.version}-aarch64.tar.gz"`))
  assert.ok(lease.includes(`VERSION = "${ALPINE_ROOTFS_SOURCE.version}"`))
  assert.ok(lease.includes(`SHA256 = "${ALPINE_ROOTFS_SOURCE.sha256}"`))
  assert.ok(lease.includes(`ARCHIVE_BYTES = ${ALPINE_ROOTFS_SOURCE.bytes.toLocaleString('en-US').replaceAll(',', '_')}L`))
})

test('locally available reviewed source retains its pinned bytes and inventory',
  { skip: !existsSync(reviewedArchive) }, async () => {
    const source = await verifyLockedAlpineRootfs(reviewedArchive)
    assert.equal(source.sha256, ALPINE_ROOTFS_SOURCE.sha256)
    assert.equal(source.bytes, ALPINE_ROOTFS_SOURCE.bytes)
    assert.equal(source.entryCount, 514)
  })
