import assert from 'node:assert/strict'
import { test } from 'node:test'
import { link, mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, unlink, writeFile } from 'node:fs/promises'
import { createRequire, registerHooks } from 'node:module'
import { tmpdir } from 'node:os'
import { join, relative, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createCopiedFilePublisher, publishImmutableFile } from '../runtime/immutable-file-publisher.mjs'
import { executeToolCall } from './tool-batch-fixture.mjs'

const root = resolve(import.meta.dirname, '../../..')
const source = new URL('../runtime/android-filesystem.mjs', import.meta.url).href
const requireStaged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const staged = specifier => import(pathToFileURL(requireStaged.resolve(specifier)).href)
const resolver = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === source && specifier.startsWith('@deepseek-ai/')) {
      return { url: pathToFileURL(requireStaged.resolve(specifier)).href, shortCircuit: true }
    }
    return next(specifier, context)
  },
})
const [
  { Context },
  { default: SandboxPolicyService },
  { default: SessionProjectionRegistry },
  { default: SystemPrompt },
  { default: ToolRuntime },
  NativeToolExecutor,
  ToolFs,
  { default: AndroidFileSystem },
] = await Promise.all([
  staged('@deepseek-ai/cordis'),
  staged('@deepseek-ai/dsh-sandbox-policy'),
  staged('@deepseek-ai/dsh-session-projection'),
  staged('@deepseek-ai/dsh-system-prompt'),
  staged('@deepseek-ai/dsh-tools'),
  staged('@deepseek-ai/dsh-tool-executor-native'),
  staged('@deepseek-ai/dsh-tool-fs'),
  import(source),
])
resolver.deregister()
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

test('workspace-write provider protects metadata names on write and edit while ordinary siblings work', async t => {
  const { ctx, workspace } = await fixture(t)
  for (const name of ['.git', '.agents', '.codex', '.aws']) {
    const directory = join(workspace, name)
    await mkdir(directory)
    const file = join(directory, 'existing.txt')
    await writeFile(file, 'original')
    const created = await ctx.fs.resolve(join(name, 'created.txt'))
    const existing = await ctx.fs.resolve(file)
    await assert.rejects(ctx.fs.writeText(created, 'blocked'), { code: 'FS_SANDBOX_DENIED' })
    await assert.rejects(ctx.fs.writeText(existing, 'blocked'), { code: 'FS_SANDBOX_DENIED' })
    await assert.rejects(ctx.fs.editText(existing,
      { oldString: 'original', newString: 'blocked', replaceAll: false }), { code: 'FS_SANDBOX_DENIED' })
    assert.equal(await readFile(file, 'utf8'), 'original')
    await assert.rejects(stat(join(directory, 'created.txt')), { code: 'ENOENT' })
    assert.equal(await ctx.fs.readText(existing), 'original', 'protected paths remain readable')
  }
  const ordinary = await ctx.fs.resolve('.gitignore')
  await ctx.fs.writeText(ordinary, 'before')
  await ctx.fs.editText(ordinary, { oldString: 'before', newString: 'after', replaceAll: false })
  assert.equal(await readFile(join(workspace, '.gitignore'), 'utf8'), 'after')
  if (process.platform !== 'win32') await mkdir(join(workspace, '.CoDeX'))
  const mixedCase = await ctx.fs.resolve('.CoDeX/sample.txt')
  if (process.platform === 'win32') {
    await assert.rejects(ctx.fs.writeText(mixedCase, 'blocked'), { code: 'FS_SANDBOX_DENIED' })
  } else {
    await ctx.fs.writeText(mixedCase, 'allowed on case-sensitive Android')
    assert.equal(await readFile(join(workspace, '.CoDeX/sample.txt'), 'utf8'), 'allowed on case-sensitive Android')
  }
})

test('workspace-write provider denies a symlink alias into protected metadata', async t => {
  const { ctx, workspace } = await fixture(t)
  await mkdir(join(workspace, '.codex'))
  await symlink(join(workspace, '.codex'), join(workspace, 'metadata-alias'),
    process.platform === 'win32' ? 'junction' : 'dir')
  const alias = await ctx.fs.resolve('metadata-alias/config.txt')
  await assert.rejects(ctx.fs.writeText(alias, 'blocked'), { code: 'FS_SANDBOX_DENIED' })
  await assert.rejects(stat(join(workspace, '.codex/config.txt')), { code: 'ENOENT' })
})

test('provider retains the original read-only and explicit full-access semantics', async t => {
  const { ctx, workspace } = await fixture(t)
  await mkdir(join(workspace, '.aws'))
  const metadata = await ctx.fs.resolve('.aws/config')
  const ordinary = await ctx.fs.resolve('task.txt')
  await assert.rejects(ctx.fs.writeText(ordinary, 'blocked', undefined, undefined,
    { mode: 'read-only', workspaceRoot: workspace }), { code: 'FS_SANDBOX_DENIED' })
  await ctx.fs.writeText(metadata, 'explicit full access', undefined, undefined,
    { mode: 'danger-full-access', workspaceRoot: workspace })
  assert.equal(await readFile(join(workspace, '.aws/config'), 'utf8'), 'explicit full access')
})

test('linked-worktree gitdir pointer protects its real directory even in a writable temp root', async t => {
  const { ctx, workspace } = await fixture(t)
  const gitdir = await mkdtemp(join(tmpdir(), 'android-protected-gitdir-'))
  t.after(() => rm(gitdir, { recursive: true, force: true }))
  await writeFile(join(workspace, '.git'), `gitdir: ${relative(workspace, gitdir)}\n`)
  await writeFile(join(gitdir, 'HEAD'), 'ref: refs/heads/main\n')
  const pointer = await ctx.fs.resolve('.git')
  assert.match(await ctx.fs.readText(pointer), /^gitdir:/)
  await assert.rejects(ctx.fs.writeText(pointer, 'blocked'), { code: 'FS_SANDBOX_DENIED' })
  const head = await ctx.fs.resolve(join(gitdir, 'HEAD'))
  await assert.rejects(ctx.fs.editText(head,
    { oldString: 'main', newString: 'other', replaceAll: false }), { code: 'FS_SANDBOX_DENIED' })
  await assert.rejects(ctx.fs.writeText(await ctx.fs.resolve(join(gitdir, 'config')), 'blocked'),
    { code: 'FS_SANDBOX_DENIED' })
  await symlink(gitdir, join(workspace, 'gitdir-alias'), process.platform === 'win32' ? 'junction' : 'dir')
  await assert.rejects(ctx.fs.writeText(await ctx.fs.resolve('gitdir-alias/config'), 'blocked'),
    { code: 'FS_SANDBOX_DENIED' })
  assert.equal(await readFile(join(gitdir, 'HEAD'), 'utf8'), 'ref: refs/heads/main\n')
  const ordinary = await ctx.fs.resolve(join(tmpdir(), `android-protected-sibling-${process.pid}.txt`))
  t.after(() => rm(ordinary.displayPath, { force: true }))
  await ctx.fs.writeText(ordinary, 'ordinary temp root stays writable')
  assert.equal(await readFile(ordinary.displayPath, 'utf8'), 'ordinary temp root stays writable')
})

test('real model-facing file tools obey the protected-path provider boundary', async t => {
  const home = await mkdtemp(join(root, '.cache/android/file-tools-protected-'))
  t.after(() => rm(home, { recursive: true, force: true }))
  const workspace = join(home, 'workspace')
  await mkdir(join(workspace, '.agents'), { recursive: true })
  await writeFile(join(workspace, '.agents', 'instructions.md'), 'original')
  const ctx = new Context()
  ctx.provide('workingDirectory', { async ensure() { return workspace } })
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SandboxPolicyService, { mode: 'workspace-write', workspaceRoot: workspace })
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(NativeToolExecutor)
  const provider = await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  const tools = await ctx.plugin(ToolFs, { read: true, readImage: false, write: true, edit: true })
  t.after(async () => { await tools.dispose(); await provider.dispose() })
  const agent = { session: {
    header: { id: 'protected-tools', cwd: workspace }, inheritedEventCount: 0, seq: 0,
    snapshotEvents() { return [] }, append() {},
  } }
  let serial = 0
  const call = (name, args) => executeToolCall(ctx.tools, {
    callId: `protected-${++serial}`, name, arguments: args,
    agent, signal: new AbortController().signal,
  })
  const read = await call('read', { file_path: '.agents/instructions.md' })
  assert.equal(read.isError, false, JSON.stringify(read))
  const blockedWrite = await call('write', { file_path: '.codex/config.json', content: '{}' })
  assert.equal(blockedWrite.isError, true)
  assert.match(JSON.stringify(blockedWrite), /sandbox|protected workspace metadata/i)
  const blockedEdit = await call('edit', {
    file_path: '.agents/instructions.md', old_string: 'original', new_string: 'tampered',
  })
  assert.equal(blockedEdit.isError, true)
  assert.equal(await readFile(join(workspace, '.agents/instructions.md'), 'utf8'), 'original')
  await assert.rejects(stat(join(workspace, '.codex/config.json')), { code: 'ENOENT' })
  const regular = await call('write', { file_path: 'task.txt', content: 'allowed' })
  assert.equal(regular.isError, false, JSON.stringify(regular))
  assert.equal(await readFile(join(workspace, 'task.txt'), 'utf8'), 'allowed')
})

