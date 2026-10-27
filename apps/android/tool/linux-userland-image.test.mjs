import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { after, before, test } from 'node:test'
import {
  requireLinuxUserlandExecution,
  requireVerifiedLinuxUserlandImage,
  verifyLinuxUserlandArtifacts,
} from '../runtime/linux-userland-image.mjs'

let fixture
let assetDir
let libraryDir
const rootfsBytes = Buffer.from('fixture rootfs archive; intentionally not executable')
const launcherBytes = Buffer.from('fixture ARM64 launcher; intentionally not executable')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')

const manifest = {
  format: 'pocket-linux-userland-v2',
  abi: 'arm64-v8a',
  architecture: 'aarch64',
  rootfs: { file: 'linux-rootfs.tar.gz', sha256: sha256(rootfsBytes), bytes: rootfsBytes.length },
  launcher: { file: 'libpocket_proot.so', sha256: sha256(launcherBytes), bytes: launcherBytes.length },
  source: {
    sourceUrl: 'https://example.invalid/pinned-source',
    sourceRevision: 'a'.repeat(40),
    license: 'GPL-2.0-only',
  },
}

before(async () => {
  fixture = await mkdtemp(path.join(os.tmpdir(), 'pocket-linux-image-'))
  assetDir = path.join(fixture, 'assets')
  libraryDir = path.join(fixture, 'lib')
  await Promise.all([mkdir(assetDir), mkdir(libraryDir)])
  await Promise.all([
    writeFile(path.join(assetDir, manifest.rootfs.file), rootfsBytes),
    writeFile(path.join(libraryDir, manifest.launcher.file), launcherBytes),
  ])
})
after(async () => { if (fixture) await rm(fixture, { recursive: true, force: true }) })

test('accepts only matching pinned artifact bytes and identifies verification as non-executable', async () => {
  const result = await verifyLinuxUserlandArtifacts({
    manifest, rootfsAssetDirectory: assetDir, nativeLibraryDirectory: libraryDir,
  })
  assert.equal(result.rootfs.sha256, manifest.rootfs.sha256)
  assert.equal(result.launcher.sha256, manifest.launcher.sha256)
  assert.equal(result.executable, false)
  assert.equal(result.format, 'pocket-linux-userland-v2')
  assert.deepEqual(result.source, manifest.source)
  assert.equal(Object.isFrozen(result.source), true)
  assert.equal(requireVerifiedLinuxUserlandImage(result), result)
  assert.throws(() => requireVerifiedLinuxUserlandImage({ ...result }),
    { code: 'LINUX_USERLAND_IMAGE_INVALID' })
})

test('rejects the old candidate format with regeneration guidance before file access', async () => {
  const oldManifest = Object.freeze({ format: 'pocket-linux-userland-v1' })
  await assert.rejects(verifyLinuxUserlandArtifacts({
    manifest: oldManifest,
    rootfsAssetDirectory: null,
    nativeLibraryDirectory: null,
  }), {
    code: 'LINUX_USERLAND_IMAGE_INVALID',
    message: 'Linux userland manifest v1 is unsupported; regenerate it as pocket-linux-userland-v2 with source URL, revision, and license',
  })
  assert.deepEqual(oldManifest, { format: 'pocket-linux-userland-v1' })
})

test('rejects path substitution, oversize, architecture and digest drift', async () => {
  for (const altered of [
    { ...manifest, rootfs: { ...manifest.rootfs, file: '../escape.tar.gz' } },
    { ...manifest, rootfs: { ...manifest.rootfs, bytes: 97 * 1024 * 1024 } },
    { ...manifest, abi: 'x86_64' },
    { ...manifest, launcher: { ...manifest.launcher, sha256: '0'.repeat(64) } },
    { ...manifest, source: { ...manifest.source, sourceRevision: 'latest' } },
  ]) {
    await assert.rejects(
      verifyLinuxUserlandArtifacts({
        manifest: altered, rootfsAssetDirectory: assetDir, nativeLibraryDirectory: libraryDir,
      }),
      { code: 'LINUX_USERLAND_IMAGE_INVALID' },
    )
  }
})

test('snapshots artifact paths before asynchronous file reads', async () => {
  const changing = {
    ...manifest,
    rootfs: { ...manifest.rootfs },
    launcher: { ...manifest.launcher },
  }
  const verification = verifyLinuxUserlandArtifacts({
    manifest: changing, rootfsAssetDirectory: assetDir, nativeLibraryDirectory: libraryDir,
  })
  changing.rootfs.file = '../outside.tar.gz'
  changing.launcher.sha256 = '0'.repeat(64)
  const result = await verification
  assert.equal(result.rootfs.sha256, manifest.rootfs.sha256)
  assert.equal(result.launcher.sha256, manifest.launcher.sha256)
})

test('rejects a linked artifact instead of following it', async t => {
  const linkDir = path.join(fixture, 'linked')
  await mkdir(linkDir)
  try {
    await symlink(path.join(libraryDir, manifest.launcher.file), path.join(linkDir, manifest.launcher.file))
  } catch (error) {
    if (error.code === 'EPERM') return t.skip('host disallows symlink creation')
    throw error
  }
  await assert.rejects(
    verifyLinuxUserlandArtifacts({
      manifest, rootfsAssetDirectory: assetDir, nativeLibraryDirectory: linkDir,
    }),
    { code: 'LINUX_USERLAND_IMAGE_INVALID' },
  )
})

test('execution stays closed after a matching image preflight', async () => {
  await verifyLinuxUserlandArtifacts({
    manifest, rootfsAssetDirectory: assetDir, nativeLibraryDirectory: libraryDir,
  })
  assert.throws(requireLinuxUserlandExecution, { code: 'LINUX_USERLAND_EXECUTOR_UNAVAILABLE' })
})
