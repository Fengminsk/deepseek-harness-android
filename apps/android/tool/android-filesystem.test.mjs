import assert from 'node:assert/strict'
import { test } from 'node:test'
import { link, mkdir, mkdtemp, readFile, readdir, stat, unlink, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import SandboxPolicyService from '@deepseek-ai/dsh-sandbox-policy'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { createCopiedFilePublisher, publishImmutableFile } from '../runtime/immutable-file-publisher.mjs'

const root = resolve(import.meta.dirname, '../../..')
// Windows has no renameat2; adapt only that native syscall. Copying, fsync,
// original guards, source ownership and both staging cleanups remain real.
async function renameExclusive(source, target) { await link(source, target); await unlink(source) }
async function fixture(t) {
  const home = await mkdtemp(join(root, '.cache/android/file-tools-publication-'))
  const workspace = join(home, 'workspace')
  await mkdir(workspace)
  const ctx = new Context()
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SandboxPolicyService, { mode: 'workspace-write', workspaceRoot: workspace })
  const fiber = await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  t.after(() => fiber.dispose())
  assert.equal(ctx.fs.internals.linkFile, publishImmutableFile, 'Android provider must inject the production publisher')
  assert.equal(ctx.fs.sandboxMode, 'workspace-write')
  const target = await ctx.fs.resolve('created.txt')
  return { ctx, workspace, target, path: join(workspace, 'created.txt') }
}

test('original guarded create publishes a complete copied file and cleans both staging owners', async t => {
  const { ctx, workspace, target, path } = await fixture(t)
  const content = '整段内容\r\n'.repeat(8192)
  let originalTemp
  ctx.fs.internals.inspectTemp = ({ tempPath }) => { originalTemp = tempPath }
  ctx.fs.internals.linkFile = createCopiedFilePublisher(async (temporary, destination) => {
    assert.equal(destination, path)
    await assert.rejects(stat(destination), { code: 'ENOENT' })
    assert.equal(await readFile(temporary, 'utf8'), content)
    assert.equal(await readFile(originalTemp, 'utf8'), content)
    assert.equal((await stat(temporary)).mode & 0o777, (await stat(originalTemp)).mode & 0o777)
    await renameExclusive(temporary, destination)
    assert.equal(await readFile(originalTemp, 'utf8'), content, 'publisher must retain the original owner source')
  })
  const result = await ctx.fs.writeText(target, content, { kind: 'createIfAbsent' })
  assert.equal(result.operation, 'create')
  assert.equal(await readFile(path, 'utf8'), content)
  assert.deepEqual(await readdir(workspace), ['created.txt'])
})

test('a concurrent creator wins without replacement and retains the original structured failure', async t => {
  const { ctx, workspace, target, path } = await fixture(t)
  ctx.fs.internals.linkFile = createCopiedFilePublisher(async (temporary, destination) => {
    await writeFile(destination, 'concurrent owner', { flag: 'wx' })
    await renameExclusive(temporary, destination)
  })
  await assert.rejects(ctx.fs.writeText(target, 'loser', { kind: 'createIfAbsent' }), { code: 'FS_NOT_OBSERVED' })
  assert.equal(await readFile(path, 'utf8'), 'concurrent owner')
  assert.deepEqual(await readdir(workspace), ['created.txt'])
})

test('native publication failure cleans both temporary owners and leaves the destination absent', async t => {
  const { ctx, workspace, target, path } = await fixture(t)
  ctx.fs.internals.linkFile = createCopiedFilePublisher(() => {
    throw Object.assign(new Error('Synthetic Android native publication refused'), { code: 'EACCES' })
  })
  await assert.rejects(ctx.fs.writeText(target, 'not published', { kind: 'createIfAbsent' }), { code: 'FS_IO_ERROR' })
  await assert.rejects(stat(path), { code: 'ENOENT' })
  assert.deepEqual(await readdir(workspace), [])
})

test('owner cancellation before publication never creates a second staging file or destination', async t => {
  const { ctx, workspace, target, path } = await fixture(t)
  const controller = new AbortController()
  let publications = 0
  ctx.fs.internals.inspectTemp = () => controller.abort()
  ctx.fs.internals.linkFile = createCopiedFilePublisher(async (temporary, destination) => {
    publications++
    await renameExclusive(temporary, destination)
  })
  await assert.rejects(ctx.fs.writeText(target, 'cancelled', { kind: 'createIfAbsent' }, controller.signal),
    { code: 'FS_ABORTED' })
  assert.equal(publications, 0)
  await assert.rejects(stat(path), { code: 'ENOENT' })
  assert.deepEqual(await readdir(workspace), [])
})
