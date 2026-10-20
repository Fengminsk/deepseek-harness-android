import assert from 'node:assert/strict'
import { test } from 'node:test'
import { chmod, link, mkdtemp, readFile, readdir, rm, stat, unlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createCopiedFilePublisher, publishImmutableFile } from '../runtime/immutable-file-publisher.mjs'

// Windows has no renameat2. Only this native syscall is adapted; real files,
// bounded copying, fsync, target visibility and cleanup execute unchanged.
async function renameExclusive(source, target) {
  await link(source, target)
  await unlink(source)
}

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'pocket-publish-'))
  t.after(() => rm(root, { recursive: true, force: true, maxRetries: 3 }))
  const source = join(root, 'source'), target = join(root, 'target')
  const bytes = Buffer.from('Synthetic 中文🙂\n'.repeat(8192))
  await writeFile(source, bytes)
  return { root, source, target, bytes }
}

test('copied publication exposes only complete bytes and keeps a read-only source intact', async t => {
  const { root, source, target, bytes } = await fixture(t)
  await chmod(source, 0o400)
  let entered
  const atRename = new Promise(resolve => { entered = resolve })
  let proceed
  const gate = new Promise(resolve => { proceed = resolve })
  const publish = createCopiedFilePublisher(async (temporary, destination) => {
    assert.equal(destination, target)
    assert.deepEqual(await readFile(temporary), bytes)
    entered()
    await gate
    await renameExclusive(temporary, destination)
  })
  const operation = publish(source, target)
  try {
    await Promise.race([atRename, operation])
    await assert.rejects(stat(target), { code: 'ENOENT' })
  } finally {
    proceed()
    await operation
  }
  assert.deepEqual(await readFile(source), bytes)
  assert.deepEqual(await readFile(target), bytes)
  assert.notEqual((await stat(source)).ino, (await stat(target)).ino)
  assert.equal((await stat(target)).mode & 0o777, (await stat(source)).mode & 0o777)
  assert.deepEqual((await readdir(root)).sort(), ['source', 'target'])
})

test('two competing producers cannot replace the winning complete target', async t => {
  const { root, source, target, bytes } = await fixture(t)
  const other = join(root, 'other')
  const otherBytes = Buffer.from('another producer')
  await writeFile(other, otherBytes)
  const publish = createCopiedFilePublisher(renameExclusive)
  const outcomes = await Promise.allSettled([publish(source, target), publish(other, target)])
  assert.equal(outcomes.filter(item => item.status === 'fulfilled').length, 1)
  assert.equal(outcomes.find(item => item.status === 'rejected').reason.code, 'EEXIST')
  const winner = await readFile(target)
  assert.ok(winner.equals(bytes) || winner.equals(otherBytes))
  await assert.rejects(publish(source, target), { code: 'EEXIST' })
  assert.deepEqual(await readFile(target), winner)
  assert.deepEqual((await readdir(root)).sort(), ['other', 'source', 'target'])
})

test('native publication failure preserves source, removes only its staging file and reports errno', async t => {
  const { root, source, target, bytes } = await fixture(t)
  const failure = Object.assign(new Error('synthetic operation denied'), { code: 'EACCES' })
  const publish = createCopiedFilePublisher(() => { throw failure })
  await assert.rejects(publish(source, target), error => error === failure)
  await assert.rejects(stat(target), { code: 'ENOENT' })
  assert.deepEqual(await readFile(source), bytes)
  assert.deepEqual(await readdir(root), ['source'])
})

test('non-Android hosts retain the original hard-link primitive', { skip: process.platform === 'android' }, () => {
  assert.equal(publishImmutableFile, link)
})
