import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { checkedAndroidRipgrepPath } from '../runtime/android-ripgrep.mjs'
import { stageRipgrep } from './stage-ripgrep.mjs'

const revision = '3a612f88b805e14aef45bfa43e25a54abc6297fc'
const executable = () => {
  const bytes = Buffer.alloc(64)
  bytes.write('\x7fELF', 0, 'ascii')
  bytes[4] = 2
  bytes[5] = 1
  bytes.writeUInt16LE(3, 16)
  bytes.writeUInt16LE(183, 18)
  return bytes
}
const digest = bytes => createHash('sha256').update(bytes).digest('hex')

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'pocket-ripgrep-'))
  t.after(async () => {
    assert.equal(resolve(root).startsWith(resolve(tmpdir())), true)
    await rm(root, { recursive: true, force: true })
  })
  const library = join(root, 'apps/android/android/app/src/main/jniLibs/arm64-v8a')
  const staged = join(root, 'staging/node_modules/@minnnng/dsh-android-runtime')
  await mkdir(library, { recursive: true })
  await mkdir(staged, { recursive: true })
  await mkdir(join(root, 'apps/android/tool'), { recursive: true })
  const bytes = executable()
  const sha256 = digest(bytes)
  const path = join(library, 'libpocket_ripgrep.so')
  await writeFile(path, bytes)
  const lock = { ripgrep: { version: '15.0.0', revision, abi: 'arm64-v8a',
    target: 'aarch64-linux-android', sha256 } }
  const lockPath = join(root, 'apps/android/tool/runtime-lock.json')
  await writeFile(lockPath, JSON.stringify(lock))
  return { root, library, staged, bytes, sha256, path, lockPath }
}

test('staging pins a valid ARM64 PIE and the runtime accepts only those bytes', async t => {
  const world = await fixture(t)
  const identity = await stageRipgrep({ repositoryRoot: world.root, staging: join(world.root, 'staging') })
  assert.deepEqual(identity, { version: '15.0.0', abi: 'arm64-v8a', sha256: world.sha256, bytes: 64 })
  const descriptor = JSON.parse(await readFile(join(world.staged, 'android-ripgrep.json'), 'utf8'))
  assert.equal(checkedAndroidRipgrepPath(world.library, descriptor), world.path)
  await writeFile(world.path, Buffer.concat([world.bytes, Buffer.from('modified')]))
  assert.throws(() => checkedAndroidRipgrepPath(world.library, descriptor), /checksum mismatch/)
})

test('staging rejects missing, linked and wrong-architecture binaries', async t => {
  const world = await fixture(t)
  const args = { repositoryRoot: world.root, staging: join(world.root, 'staging') }
  await rm(world.path)
  await assert.rejects(stageRipgrep(args), { code: 'ENOENT' })
  const elsewhere = join(world.root, 'elsewhere')
  await writeFile(elsewhere, world.bytes)
  let linked = false
  try {
    await symlink(elsewhere, world.path)
    linked = true
  } catch (error) {
    if (!['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) throw error
  }
  if (linked) {
    await assert.rejects(stageRipgrep(args), /missing/)
    await rm(world.path)
  }
  const wrong = Buffer.from(world.bytes)
  wrong.writeUInt16LE(62, 18)
  await writeFile(world.path, wrong)
  await assert.rejects(stageRipgrep(args), /ARM64 PIE/)
})

test('staging does not publish a descriptor when the pinned hash differs', async t => {
  const world = await fixture(t)
  const lock = JSON.parse(await readFile(world.lockPath, 'utf8'))
  lock.ripgrep.sha256 = '0'.repeat(64)
  await writeFile(world.lockPath, JSON.stringify(lock))
  await assert.rejects(stageRipgrep({ repositoryRoot: world.root, staging: join(world.root, 'staging') }),
    /pinned hash/)
  await assert.rejects(readFile(join(world.staged, 'android-ripgrep.json')), { code: 'ENOENT' })
})
