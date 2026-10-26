import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, mkdir, readFile, readlink, readdir, rm, stat, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { after, before, test } from 'node:test'
import { gzipSync } from 'node:zlib'
import * as tar from 'tar'
import { verifyLinuxUserlandArtifacts } from '../runtime/linux-userland-image.mjs'
import { inspectPinnedRootfsArchive, publishRootfsCandidate, verifyPublishedRootfsCandidate } from './linux-userland-rootfs.mjs'

let fixture
let installationRoot

before(async () => {
  fixture = await mkdtemp(path.join(os.tmpdir(), 'pocket-rootfs-candidate-'))
  installationRoot = path.join(fixture, 'install')
  await mkdir(installationRoot)
})

after(async () => {
  if (fixture && path.dirname(fixture) === os.tmpdir() &&
      path.basename(fixture).startsWith('pocket-rootfs-candidate-')) {
    await rm(fixture, { recursive: true, force: true })
  }
})

const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const launcher = Buffer.from('test-only fixed ARM64 launcher identity')
let assetSequence = 0

async function pinnedArchive(bytes) {
  const source = path.join(fixture, `source-${++assetSequence}`)
  const assetDir = path.join(source, 'assets')
  const libraryDir = path.join(source, 'libs')
  await mkdir(source)
  await Promise.all([mkdir(assetDir), mkdir(libraryDir)])
  await Promise.all([
    writeFile(path.join(assetDir, 'linux-rootfs.tar.gz'), bytes),
    writeFile(path.join(libraryDir, 'libpocket_proot.so'), launcher),
  ])
  return verifyLinuxUserlandArtifacts({
    manifest: {
      format: 'pocket-linux-userland-v1',
      abi: 'arm64-v8a',
      architecture: 'aarch64',
      rootfs: { file: 'linux-rootfs.tar.gz', bytes: bytes.length, sha256: digest(bytes) },
      launcher: { file: 'libpocket_proot.so', bytes: launcher.length, sha256: digest(launcher) },
      provenance: {
        sourceUrl: 'https://example.invalid/only-a-test',
        sourceRevision: 'a'.repeat(40),
        license: 'GPL-2.0-only',
      },
    },
    rootfsAssetDirectory: assetDir,
    nativeLibraryDirectory: libraryDir,
  })
}

function archive(entries) {
  const parts = []
  for (const entry of entries) {
    if (entry.paxPath) parts.push(new tar.Pax({ path: entry.paxPath }).encode())
    const content = Buffer.from(entry.content ?? '')
    const header = new tar.Header({
      path: entry.path,
      type: entry.type ?? 'File',
      linkpath: entry.linkpath,
      size: (entry.type ?? 'File') === 'File' ? content.length : 0,
      mode: 0o644,
      mtime: new Date(0),
    })
    assert.equal(header.encode(), false)
    parts.push(header.block, content, Buffer.alloc((512 - content.length % 512) % 512))
  }
  parts.push(Buffer.alloc(1024))
  return gzipSync(Buffer.concat(parts))
}

test('publishes a verified candidate atomically without granting execution', async () => {
  const bytes = archive([
    { path: './bin/', type: 'Directory' },
    { path: './bin/tool', content: 'hello rootfs\n' },
    { path: './etc/', type: 'Directory' },
    { path: './etc/release', content: 'fixture\n' },
  ])
  const image = await pinnedArchive(bytes)
  const release = await publishRootfsCandidate({ verifiedImage: image, installationRoot })
  assert.equal(release.rootfsSha256, digest(bytes))
  assert.equal(release.executable, false)
  assert.equal(await readFile(path.join(release.rootfs, 'bin', 'tool'), 'utf8'), 'hello rootfs\n')
  assert.deepEqual(await verifyPublishedRootfsCandidate({ verifiedImage: image, installationRoot }), release)
  assert.deepEqual((await readdir(path.join(installationRoot, 'versions'))), [digest(bytes)])
  await assert.rejects(publishRootfsCandidate({ verifiedImage: image, installationRoot }),
    { code: 'LINUX_ROOTFS_REJECTED' })
})

test('recovery rejects a same-size edited file and an unlisted file', async () => {
  const image = await pinnedArchive(archive([{ path: 'bin/tool', content: 'original' }]))
  const release = await publishRootfsCandidate({ verifiedImage: image, installationRoot })
  await writeFile(path.join(release.rootfs, 'bin', 'tool'), 'tampered')
  await assert.rejects(verifyPublishedRootfsCandidate({ verifiedImage: image, installationRoot }),
    { code: 'LINUX_ROOTFS_REJECTED' })
  await writeFile(path.join(release.rootfs, 'bin', 'tool'), 'original')
  await writeFile(path.join(release.rootfs, 'bin', 'unexpected'), 'new')
  await assert.rejects(verifyPublishedRootfsCandidate({ verifiedImage: image, installationRoot }),
    { code: 'LINUX_ROOTFS_REJECTED' })
})

test('recovery binds the receipt and archive to the independently verified image', async () => {
  const image = await pinnedArchive(archive([{ path: 'etc/version', content: 'one' }]))
  const release = await publishRootfsCandidate({ verifiedImage: image, installationRoot })
  const receiptFile = path.join(release.directory, 'receipt.json')
  const originalReceipt = await readFile(receiptFile, 'utf8')
  await writeFile(receiptFile, originalReceipt.replace('"executable": false', '"executable": true '))
  await assert.rejects(verifyPublishedRootfsCandidate({ verifiedImage: image, installationRoot }),
    { code: 'LINUX_ROOTFS_REJECTED' })
  await writeFile(receiptFile, originalReceipt)
  await writeFile(path.join(release.directory, 'image.tar.gz'),
    archive([{ path: 'etc/version', content: 'two' }]))
  await assert.rejects(verifyPublishedRootfsCandidate({ verifiedImage: image, installationRoot }),
    { code: 'LINUX_ROOTFS_REJECTED' })
})

test('rewrites guest-root absolute symlinks into staged relative links', async t => {
  const bytes = archive([
    { path: './bin/', type: 'Directory' },
    { path: './bin/busybox', content: 'safe applet\n' },
    { path: './usr/', type: 'Directory' },
    { path: './usr/bin/', type: 'Directory' },
    { path: './usr/bin/yes', type: 'SymbolicLink', linkpath: '/bin/busybox' },
  ])
  const image = await pinnedArchive(bytes)
  const inventory = await inspectPinnedRootfsArchive(image.rootfs.path)
  assert.equal(inventory.entries.find(entry => entry.path === 'usr/bin/yes').hostLink, '../../bin/busybox')
  let release
  try {
    release = await publishRootfsCandidate({ verifiedImage: image, installationRoot })
  } catch (error) {
    if (process.platform === 'win32' && ['EPERM', 'EACCES'].includes(error.code)) {
      t.skip('Windows host disallows symlink creation; archive inspection passed')
      return
    }
    throw error
  }
  assert.equal(await readlink(path.join(release.rootfs, 'usr/bin/yes')), '../../bin/busybox')
  assert.equal(await readFile(path.join(release.rootfs, 'usr/bin/yes'), 'utf8'), 'safe applet\n')
})

test('materializes earlier-file hardlinks without extracting archive links', async () => {
  const bytes = archive([
    { path: './share/', type: 'Directory' },
    { path: './share/source', content: 'one inode\n' },
    { path: './share/alias', type: 'Link', linkpath: './share/source' },
  ])
  const image = await pinnedArchive(bytes)
  const release = await publishRootfsCandidate({ verifiedImage: image, installationRoot })
  const source = await stat(path.join(release.rootfs, 'share/source'))
  const alias = await stat(path.join(release.rootfs, 'share/alias'))
  assert.equal(source.ino, alias.ino)
  assert.equal(await readFile(path.join(release.rootfs, 'share/alias'), 'utf8'), 'one inode\n')
})

test('rejects traversal, absolute paths, devices, case collisions and link escape before extraction', async () => {
  const existingVersions = await readdir(path.join(installationRoot, 'versions'))
  const malicious = [
    archive([{ path: '../escape', content: 'no' }]),
    archive([{ path: '/absolute', content: 'no' }]),
    archive([{ path: 'dev/bad', type: 'CharacterDevice' }, { path: 'ok', content: 'x' }]),
    archive([{ path: 'Readme', content: 'a' }, { path: 'README', content: 'b' }]),
    archive([{ path: './same', content: 'a' }, { path: 'same', content: 'b' }]),
    archive([{ path: 'ignored', paxPath: 'same', content: 'a' }, { path: 'same', content: 'b' }]),
    archive([{ path: 'link', type: 'SymbolicLink', linkpath: '../../escape' }, { path: 'ok', content: 'x' }]),
    archive([{ path: 'bin', type: 'SymbolicLink', linkpath: '/usr/bin' }, { path: 'bin/evil', content: 'x' }]),
    archive([{ path: 'first', type: 'SymbolicLink', linkpath: '/second' },
      { path: 'second', type: 'SymbolicLink', linkpath: '../../escape' },
      { path: 'ok', content: 'x' }]),
    archive([{ path: 'hard', type: 'Link', linkpath: '../escape' }, { path: 'ok', content: 'x' }]),
  ]
  for (const [i, bytes] of malicious.entries()) {
    const image = await pinnedArchive(bytes)
    await assert.rejects(publishRootfsCandidate({ verifiedImage: image, installationRoot }),
      { code: 'LINUX_ROOTFS_REJECTED' })
  }
  assert.deepEqual(await readdir(path.join(installationRoot, 'versions')), existingVersions)
  assert.equal((await readdir(path.join(installationRoot, 'versions')))
    .some(name => name.startsWith('.staging-')), false)
})

test('rejects digest drift and removes only its own incomplete stage', async () => {
  const bytes = archive([{ path: 'file', content: 'payload' }])
  const image = await pinnedArchive(bytes)
  await writeFile(image.rootfs.path, archive([{ path: 'file', content: 'tampered' }]))
  await assert.rejects(publishRootfsCandidate({ verifiedImage: image, installationRoot }),
    { code: 'LINUX_ROOTFS_REJECTED' })
  assert.equal((await readdir(path.join(installationRoot, 'versions')))
    .some(name => name.startsWith('.staging-')), false)
})

test('archive inspection enforces expanded-file and archive-entry budgets', async () => {
  const huge = archive([{ path: 'huge', content: Buffer.alloc(32 * 1024 * 1024 + 1) }])
  const image = await pinnedArchive(huge)
  await assert.rejects(inspectPinnedRootfsArchive(image.rootfs.path),
    { code: 'LINUX_ROOTFS_REJECTED' })
})
