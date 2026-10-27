import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync, renameSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { modelFileExecutionScope, modelFileObservationDenial, registerModelFileReadGuard } from '../runtime/model-file-read-guard.mjs'
import { createRequire, registerHooks } from 'node:module'
import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

const requireStaged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const loadStaged = specifier => import(pathToFileURL(requireStaged.resolve(specifier)).href)
const androidFileSystemSource = new URL('../runtime/android-filesystem.mjs', import.meta.url).href
const androidFileSystemResolver = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === androidFileSystemSource && specifier.startsWith('@deepseek-ai/')) {
      return { url: pathToFileURL(requireStaged.resolve(specifier)).href, shortCircuit: true }
    }
    return next(specifier, context)
  },
})
const { default: AndroidFileSystem } = await import(androidFileSystemSource)
androidFileSystemResolver.deregister()

test('ordinary model file tools cannot reach App-private home outside the workspace', () => {
  const home = mkdtempSync(join(tmpdir(), 'android-file-read-guard-'))
  try {
    const workspace = join(home, 'workspace')
    const similar = join(home, 'workspace-private')
    mkdirSync(workspace)
    mkdirSync(similar)
    writeFileSync(join(workspace, 'visible.txt'), 'safe')
    writeFileSync(join(home, 'account.sqlite'), 'private')
    writeFileSync(join(home, 'runtime.png'), 'private image')
    writeFileSync(join(similar, 'secret.txt'), 'similar-prefix private')
    symlinkSync(home, join(workspace, 'home-link'), process.platform === 'win32' ? 'junction' : 'dir')

    const check = (name, args, cwd = workspace) => modelFileObservationDenial(workspace, cwd, name, args)
    assert.equal(check('read', { file_path: join(workspace, 'visible.txt') }), undefined)
    assert.equal(check('read_image', { file_path: join(workspace, 'visible.txt') }), undefined)
    assert.equal(check('glob', { pattern: '**/*.txt', path: workspace }), undefined)
    assert.equal(check('grep', { pattern: 'safe', path: join(workspace, 'visible.txt') }), undefined)
    assert.equal(check('edit', { file_path: join(workspace, 'visible.txt') }), undefined)
    assert.equal(check('write', { file_path: 'new.txt', content: 'safe' }), undefined)
    assert.equal(check('str_replace_editor', { command: 'view', path: join(workspace, 'visible.txt') }), undefined)
    assert.match(check('str_replace_editor', { command: 'view', path: workspace }), /path inside the App workspace/,
      'directory view recurses into child symlinks and must fail closed')
    assert.equal(check('present', { files: [{ path: join(workspace, 'visible.txt') }] }), undefined)
    assert.equal(check('read', { file_path: 'visible.txt' }), undefined)
    assert.equal(check('glob', { pattern: '*' }), undefined)
    assert.equal(check('grep', { pattern: 'safe', path: '.' }), undefined)
    assert.equal(check('present', { files: [{ path: 'visible.txt' }] }), undefined)

    for (const [name, args] of [
      ['read', { file_path: join(home, 'account.sqlite') }],
      ['read_image', { file_path: join(home, 'runtime.png') }],
      ['glob', { pattern: '**/*', path: home }],
      ['grep', { pattern: 'private', path: home }],
      ['str_replace_editor', { command: 'view', path: home }],
      ['present', { files: [{ path: join(home, 'account.sqlite') }] }],
      ['present', { files: [{ path: join(workspace, 'visible.txt') }, { path: join(home, 'account.sqlite') }] }],
      ['str_replace_editor', { command: 'create', path: join(home, 'new.txt') }],
      ['edit', { file_path: join(home, 'account.sqlite') }],
      ['write', { file_path: join(home, 'new.txt'), content: 'private' }],
      ['write', { file_path: join(workspace, 'home-link', 'new.txt'), content: 'private' }],
      ['read', { file_path: join(similar, 'secret.txt') }],
      ['glob', { pattern: '*', path: join(workspace, 'home-link') }],
      ['grep', { pattern: 'private', path: join(workspace, 'home-link', 'account.sqlite') }],
      ['glob', { pattern: '../*.sqlite' }],
      ['glob', { pattern: '/account.sqlite' }],
      ['grep', { pattern: 'private', include: '../*.sqlite' }],
      ['str_replace_editor', { command: 'view', path: join(workspace, 'home-link') }],
      ['read', { file_path: '../account.sqlite' }],
      ['read', { file_path: 'content://provider/document/1' }],
    ]) assert.match(check(name, args), /path inside the App workspace/, `${name}: ${JSON.stringify(args)}`)
    assert.match(check('glob', { pattern: '*', path: workspace }, home), /path inside the App workspace/)
    assert.match(modelFileObservationDenial(workspace, undefined, 'read', { file_path: join(workspace, 'visible.txt') }), /path inside the App workspace/)
    assert.match(check('grep', { pattern: 'x', path: null }), /path inside the App workspace/)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test('runtime guard fails closed without a prepared Agent cwd and cleans completed calls', async () => {
  const home = mkdtempSync(join(tmpdir(), 'android-file-guard-registration-'))
  try {
    const workspace = join(home, 'workspace')
    mkdirSync(workspace)
    writeFileSync(join(workspace, 'allowed.txt'), 'safe')
    const handlers = new Map()
    let guard
    const ctx = {
      on(name, handler) { handlers.set(name, handler) },
      effect(register) { register() },
      tools: { guard(value) { guard = value; return () => {} } },
      workingDirectory: { async ensure() { return workspace } },
    }
    registerModelFileReadGuard(ctx, workspace)
    const call = { name: 'read', arguments: { file_path: join(workspace, 'allowed.txt') },
      agent: { session: { id: 'test' } }, token: Symbol('call'), signal: new AbortController().signal }
    assert.match(guard(call), /path inside the App workspace/)
    assert.deepEqual(await handlers.get('tools/pre-execute')(call, async () => ({ kind: 'allow' })), { kind: 'allow' })
    assert.equal(guard(call), undefined)
    handlers.get('tools/result')(call)
    assert.match(guard(call), /path inside the App workspace/)
    assert.deepEqual(await handlers.get('tools/pre-execute')({ ...call, agent: undefined }, async () => ({ kind: 'allow' })),
      { kind: 'deny', reason: guard(call) })
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test('a Session cwd change after pre-execute cannot redirect a model file target into App home', async () => {
  const home = mkdtempSync(join(tmpdir(), 'android-file-guard-cwd-race-'))
  try {
    const workspace = join(home, 'workspace')
    mkdirSync(workspace)
    writeFileSync(join(workspace, 'public.txt'), 'safe')
    writeFileSync(join(home, 'account.sqlite'), 'private')
    let currentCwd = workspace
    const handlers = new Map()
    let guard
    registerModelFileReadGuard({
      on(name, handler) { handlers.set(name, handler) },
      effect(register) { register() },
      tools: { guard(value) { guard = value; return () => {} } },
      workingDirectory: { async ensure() { return currentCwd } },
      subprocess: { spawn() {} },
    }, workspace)
    const base = { agent: { session: { id: 'test' } }, signal: new AbortController().signal }
    const relative = { ...base, name: 'read', arguments: { file_path: 'account.sqlite' }, token: Symbol('relative') }
    assert.equal((await handlers.get('tools/pre-execute')(relative, async () => ({ kind: 'allow' }))).kind, 'allow')
    currentCwd = home
    assert.equal(guard(relative), undefined)

    currentCwd = workspace
    for (const [name, args] of [
      ['read', { file_path: join(workspace, 'public.txt') }],
      ['read_image', { file_path: join(workspace, 'public.txt') }],
      ['glob', { pattern: '*.txt', path: workspace }],
      ['grep', { pattern: 'safe', path: workspace }],
    ]) {
      const call = { ...base, name, arguments: args, token: Symbol(name) }
      assert.equal((await handlers.get('tools/pre-execute')(call, async () => ({ kind: 'allow' }))).kind, 'allow')
      currentCwd = home // the original tool body would call ensure() again here
      assert.equal(guard(call), undefined)
      assert.equal(resolve(workspace, args.path ?? args.file_path), args.path ?? args.file_path)
      handlers.get('tools/result')(call)
      currentCwd = workspace
    }
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test('real ToolRuntime guards original file, search, delivery and editor tools at dispatch', async t => {
  const home = mkdtempSync(join(tmpdir(), 'android-file-guard-runtime-'))
  let ctx
  t.after(async () => { await ctx?.fiber.dispose(); rmSync(home, { recursive: true, force: true }) })
  const workspace = join(home, 'workspace')
  const similar = join(home, 'workspace-private')
  mkdirSync(workspace)
  mkdirSync(similar)
  writeFileSync(join(workspace, 'visible.txt'), 'public value')
  writeFileSync(join(home, 'account.sqlite'), 'private value')
  writeFileSync(join(similar, 'account.sqlite'), 'similar-prefix private')
  symlinkSync(home, join(workspace, 'home-link'), process.platform === 'win32' ? 'junction' : 'dir')
  mkdirSync(join(workspace, 'swappable'))
  mkdirSync(join(workspace, 'read-swappable'))
  writeFileSync(join(workspace, 'read-swappable', 'account.sqlite'), 'public value')
  writeFileSync(join(workspace, 'view-swap'), 'safe file')
  mkdirSync(join(workspace, 'view-target'))
  symlinkSync(home, join(workspace, 'view-target', 'secret-link'), process.platform === 'win32' ? 'junction' : 'dir')
  const [cordis, policy, projections, prompt, tools, toolFs, search, editor, present] = await Promise.all([
    loadStaged('@deepseek-ai/cordis'),
    loadStaged('@deepseek-ai/dsh-sandbox-policy'),
    loadStaged('@deepseek-ai/dsh-session-projection'),
    loadStaged('@deepseek-ai/dsh-system-prompt'),
    loadStaged('@deepseek-ai/dsh-tools'),
    loadStaged('@deepseek-ai/dsh-tool-fs'),
    loadStaged('@deepseek-ai/dsh-tool-fs-search'),
    loadStaged('@deepseek-ai/dsh-tool-str-replace-editor'),
    loadStaged('@deepseek-ai/dsh-tool-present'),
  ])
  ctx = new cordis.Context()
  let cwd = workspace
  let driftBeforeBody = false
  let swapBeforeBody = false
  let swapViewBeforeBody = false
  ctx.provide('workingDirectory', { async ensure() { return cwd } })
  const spawns = []
  let runSearches = false
  // Production providers extend Service: each ctx.subprocess.spawn read is a
  // new Cordis trace proxy. A plain provided object misses that boundary.
  class SearchSubprocess extends cordis.Service {
    constructor(context) { super(context, 'subprocess') }
    spawn(spec) {
    spawns.push(spec)
    if (runSearches) {
      const result = spawnSync(spec.argv[0], spec.argv.slice(1), {
        cwd: spec.cwd, encoding: 'utf8', windowsHide: true, timeout: 10000,
        stdio: ['ignore', 'pipe', 'pipe'],
      })
      assert.equal(result.error, undefined)
      assert.equal(result.signal, null, 'ripgrep must finish rather than be killed by the fixture')
      assert.ok(result.status === 0 || result.status === 1, result.stderr)
      return {
        done: Promise.resolve({ exitCode: result.status, signal: null }),
        collected: {
          stdout: { readFrom: () => ({ text: result.stdout, lossy: false }) },
          stderr: { readFrom: () => ({ text: result.stderr, lossy: false }) },
        },
      }
    }
    return {
      done: Promise.resolve({ exitCode: 1, signal: null }),
      collected: {
        stdout: { readFrom: () => ({ text: '', lossy: false }) },
        stderr: { readFrom: () => ({ text: '', lossy: false }) },
      },
    }
    }
  }
  await ctx.plugin(SearchSubprocess)
  assert.notEqual(ctx.subprocess.spawn, ctx.subprocess.spawn)
  await ctx.plugin(prompt.default)
  await ctx.plugin(tools.default)
  await ctx.plugin(projections.default)
  await ctx.plugin(policy.default, { mode: 'workspace-write', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(toolFs, { read: true, readImage: false, write: true, edit: true })
  await ctx.plugin(search, { sampleOverCapGlobResults: false })
  await ctx.plugin(editor)
  await ctx.plugin(present, { maxFiles: 8 })
  const agent = { session: { header: { id: 'guard-integration', cwd: workspace }, inheritedEventCount: 0,
    seq: 0, append() {}, snapshotEvents() { return [] } } }
  let serial = 0
  const call = (name, args) => ctx.tools.execute({
    name, arguments: args, agent, callId: `guard-${++serial}`, signal: new AbortController().signal,
  })
  const originalDirectory = await call('str_replace_editor', { command: 'view', path: workspace })
  assert.equal(originalDirectory.isError, false, JSON.stringify(originalDirectory.content))
  assert.match(JSON.stringify(originalDirectory.content), /account\.sqlite/,
    'original two-level directory view follows a child link and reveals App-private names')
  registerModelFileReadGuard(ctx, workspace)
  const internalTemp = await ctx.fs.resolve(join(home, 'internal-temp.txt'))
  await ctx.fs.writeText(internalTemp, 'internal service still uses the host temp root')
  assert.equal(existsSync(internalTemp.displayPath), true,
    'ordinary App services retain the original sandbox policy outside model dispatch')
  const workspaceDirectory = await ctx.fs.resolve(workspace)
  const internalEntries = await ctx.fs.listDir(workspaceDirectory)
  assert.ok(internalEntries.some(entry => entry.name === 'visible.txt'),
    'internal App services retain directory enumeration')
  await modelFileExecutionScope.run({ root: workspace, cwd: workspace, name: 'read' }, async () => {
    const target = await ctx.fs.resolve(join(workspace, 'read-swappable', 'account.sqlite'))
    const delayedStream = await ctx.fs.streamText(target)
    renameSync(join(workspace, 'read-swappable'), join(workspace, 'read-swappable-old'))
    symlinkSync(home, join(workspace, 'read-swappable'), process.platform === 'win32' ? 'junction' : 'dir')
    for (const observation of [
      () => ctx.fs.stat(target),
      () => ctx.fs.readText(target),
      () => ctx.fs.readBytes(target, undefined, 64),
      () => ctx.fs.readByteRange(target, { offset: 0, length: 8 }),
      async () => { for await (const _chunk of delayedStream) assert.fail('private stream chunk escaped') },
    ]) await assert.rejects(observation, { code: 'FS_SANDBOX_DENIED' })
  })
  rmSync(join(workspace, 'read-swappable-old'), { recursive: true })
  await assert.rejects(modelFileExecutionScope.run({ root: workspace, cwd: workspace, name: 'str_replace_editor' },
    () => ctx.fs.listDir(workspaceDirectory)), { code: 'FS_SANDBOX_DENIED' })
  ctx.on('tools/execute', async (_execution, next) => {
    if (driftBeforeBody) { cwd = home; driftBeforeBody = false }
    if (swapBeforeBody) {
      renameSync(join(workspace, 'swappable'), join(workspace, 'swappable-old'))
      symlinkSync(home, join(workspace, 'swappable'), process.platform === 'win32' ? 'junction' : 'dir')
      swapBeforeBody = false
    }
    if (swapViewBeforeBody) {
      renameSync(join(workspace, 'view-swap'), join(workspace, 'view-swap-old'))
      renameSync(join(workspace, 'view-target'), join(workspace, 'view-swap'))
      swapViewBeforeBody = false
    }
    return next()
  })
  const visible = await call('read', { file_path: join(workspace, 'visible.txt') })
  assert.equal(visible.isError, false, JSON.stringify(visible.content))
  assert.match(JSON.stringify(visible.content), /public value/)
  const blocked = await call('read', { file_path: join(home, 'account.sqlite') })
  assert.equal(blocked.isError, true)
  assert.doesNotMatch(JSON.stringify(blocked), /private value/)
  const similarBlocked = await call('read', { file_path: join(similar, 'account.sqlite') })
  assert.equal(similarBlocked.isError, true)
  const symlinkBlocked = await call('read', { file_path: join(workspace, 'home-link', 'account.sqlite') })
  assert.equal(symlinkBlocked.isError, true)
  const relative = await call('read', { file_path: 'account.sqlite' })
  assert.equal(relative.isError, true)
  const relativeVisible = await call('read', { file_path: 'visible.txt' })
  assert.equal(relativeVisible.isError, false, JSON.stringify(relativeVisible.content))
  assert.match(JSON.stringify(relativeVisible.content), /public value/)
  const relativeEditor = await call('str_replace_editor', { command: 'view', path: 'visible.txt' })
  assert.equal(relativeEditor.isError, true)
  const editorOutside = await call('str_replace_editor', { command: 'view', path: home })
  assert.equal(editorOutside.isError, true)
  assert.doesNotMatch(JSON.stringify(editorOutside), /private value/)
  const editorInside = await call('str_replace_editor', { command: 'view', path: join(workspace, 'visible.txt') })
  assert.equal(editorInside.isError, false, JSON.stringify(editorInside.content))
  assert.match(JSON.stringify(editorInside.content), /public value/)
  const editorDirectory = await call('str_replace_editor', { command: 'view', path: workspace })
  assert.equal(editorDirectory.isError, true)
  assert.doesNotMatch(JSON.stringify(editorDirectory), /account\.sqlite|private value/,
    'a directory view must not recursively observe a symlink into App-private home')
  swapViewBeforeBody = true
  const replacedView = await call('str_replace_editor', { command: 'view', path: join(workspace, 'view-swap') })
  assert.equal(swapViewBeforeBody, false, 'the file was replaced after the pre-execute observation')
  assert.equal(replacedView.isError, true)
  assert.match(JSON.stringify(replacedView.content), /model directory view is unavailable/,
    'the provider rejects the directory at the actual listDir operation')
  assert.doesNotMatch(JSON.stringify(replacedView), /account\.sqlite|private value/,
    'a newly inserted directory cannot recurse after the pre-execute file check')
  assert.deepEqual([
    { case: 'original', isError: originalDirectory.isError,
      privateNameVisible: /account\.sqlite/.test(JSON.stringify(originalDirectory.content)) },
    { case: 'guarded-directory', isError: editorDirectory.isError,
      privateNameVisible: /account\.sqlite/.test(JSON.stringify(editorDirectory.content)) },
    { case: 'replaced-file', isError: replacedView.isError,
      providerDenied: /model directory view is unavailable/.test(JSON.stringify(replacedView.content)),
      privateNameVisible: /account\.sqlite/.test(JSON.stringify(replacedView.content)) },
  ], JSON.parse(readFileSync(new URL('./expected/model-directory-guard.expected.json', import.meta.url), 'utf8')))
  const relativeWrite = await call('write', { file_path: 'created.txt', content: 'created under workspace' })
  assert.equal(relativeWrite.isError, false, JSON.stringify(relativeWrite.content))
  const absoluteWrite = await call('write', { file_path: join(workspace, 'absolute-created.txt'), content: 'safe absolute' })
  assert.equal(absoluteWrite.isError, false, JSON.stringify(absoluteWrite.content))
  const privateWrite = await call('write', { file_path: join(home, 'new-private.txt'), content: 'must not be created' })
  assert.equal(privateWrite.isError, true)
  assert.equal(existsSync(join(home, 'new-private.txt')), false,
    'the original sandbox permits the host temp root, but model write must not')
  assert.match(JSON.stringify(privateWrite.content), /Android file tools require a path inside the App workspace/)
  const linkedWrite = await call('write', { file_path: join(workspace, 'home-link', 'linked.txt'), content: 'escape' })
  assert.equal(linkedWrite.isError, true)
  assert.equal(existsSync(join(home, 'linked.txt')), false)
  swapBeforeBody = true
  const swappedWrite = await call('write', { file_path: join(workspace, 'swappable', 'escape.txt'), content: 'escape' })
  assert.equal(swappedWrite.isError, true)
  assert.equal(existsSync(join(home, 'escape.txt')), false,
    'the provider must resolve the original write target after a parent link changes')
  const writeProjection = [
    relativeWrite, absoluteWrite, privateWrite, linkedWrite, swappedWrite,
  ].map(result => ({ isError: result.isError,
    content: result.content.map(item => item.text).join('\n').replaceAll(workspace, '<workspace>')
      .replaceAll(home, '<app-home>').replaceAll('\\', '/') }))
  assert.deepEqual(writeProjection, JSON.parse(readFileSync(
    new URL('./expected/model-file-write-guard.expected.json', import.meta.url), 'utf8')),
  'keyless original ToolRuntime write results match the owner-local model-visible projection')
  const written = await call('read', { file_path: join(workspace, 'created.txt') })
  assert.equal(written.isError, false, JSON.stringify(written.content))
  assert.match(JSON.stringify(written.content), /created under workspace/)
  const absoluteEdit = await call('edit', {
    file_path: join(workspace, 'created.txt'), old_string: 'created', new_string: 'edited',
  })
  assert.equal(absoluteEdit.isError, false, JSON.stringify(absoluteEdit.content))
  const relativeEdit = await call('edit', {
    file_path: 'created.txt', old_string: 'edited', new_string: 'relative edit',
  })
  assert.equal(relativeEdit.isError, false, JSON.stringify(relativeEdit.content))
  const presentOutside = await call('present', { files: [{ path: join(home, 'account.sqlite') }] })
  assert.equal(presentOutside.isError, true)
  const presentRelative = await call('present', { files: [{ path: 'visible.txt' }] })
  assert.match(JSON.stringify(presentRelative.content), /present requires an open turn/,
    'the path guard accepts the relative path; the synthetic Session has no open turn')
  const presentInside = await call('present', { files: [{ path: join(workspace, 'visible.txt') }] })
  assert.match(JSON.stringify(presentInside.content), /present requires an open turn/)
  assert.doesNotMatch(JSON.stringify(presentInside), /private value/)
  const searchBlocked = await call('glob', { pattern: '*', path: home })
  assert.equal(searchBlocked.isError, true)
  const globDefault = await call('glob', { pattern: '*.txt' })
  assert.equal(globDefault.isError, false, JSON.stringify(globDefault.content))
  const globRelative = await call('glob', { pattern: '*.txt', path: '.' })
  assert.equal(globRelative.isError, false, JSON.stringify(globRelative.content))
  const grepDefault = await call('grep', { pattern: 'value' })
  assert.equal(grepDefault.isError, false, JSON.stringify(grepDefault.content))
  const grepRelative = await call('grep', { pattern: 'value', path: '.' })
  assert.equal(grepRelative.isError, false, JSON.stringify(grepRelative.content))
  const grepSymlink = await call('grep', { pattern: 'private', path: join(workspace, 'home-link') })
  assert.equal(grepSymlink.isError, true)
  assert.equal(spawns.length, 4)
  const searchAllowed = await call('glob', { pattern: '*.txt', path: workspace })
  assert.equal(searchAllowed.isError, false, JSON.stringify(searchAllowed.content))
  assert.equal(spawns.length, 5)
  assert.ok(spawns[4].argv.includes(workspace), 'original rg receives the absolute workspace root')
  const grepAllowed = await call('grep', { pattern: 'public', path: workspace })
  assert.equal(grepAllowed.isError, false, JSON.stringify(grepAllowed.content))
  assert.equal(spawns.length, 6)
  assert.ok(spawns[5].argv.includes(workspace), 'original grep receives the absolute workspace root')
  // Valid leaf/directory names can contain consecutive dots. Exercise the real
  // first-party tools and ripgrep, not just the guard's argument predicate.
  mkdirSync(join(workspace, 'v1..v2'))
  writeFileSync(join(workspace, 'v1..v2', 'release..txt'), 'named file search needle')
  runSearches = true
  const dottedGlob = await call('glob', { pattern: 'v1..v2/release..txt' })
  assert.equal(dottedGlob.isError, false, JSON.stringify(dottedGlob.content))
  assert.match(JSON.stringify(dottedGlob.content), /release\.\.txt/)
  const dottedGrep = await call('grep', { pattern: 'search needle', include: 'v1..v2/release..txt' })
  assert.equal(dottedGrep.isError, false, JSON.stringify(dottedGrep.content))
  assert.match(JSON.stringify(dottedGrep.content), /named file search needle/, JSON.stringify(spawns.at(-1).argv))
  for (const [name, args] of [
    ['glob', { pattern: 'v1..v2/../../*.sqlite' }],
    ['grep', { pattern: 'private', include: '../*.sqlite' }],
  ]) {
    const count = spawns.length
    const denied = await call(name, args)
    assert.equal(denied.isError, true)
    assert.equal(spawns.length, count, 'parent traversal must be rejected before spawning')
    assert.doesNotMatch(JSON.stringify(denied.content), /private value/)
  }
  runSearches = false
  if (process.platform === 'win32') {
    // The original searches bypass ctx.fs and spawn ripgrep. Prove that the
    // bundled binary does not traverse a child junction when rooted at the
    // workspace; a model-selected junction as the root is denied above.
    const rgPath = requireStaged('@vscode/ripgrep').rgPath
    const files = spawnSync(rgPath, ['--files', '--no-ignore', '--hidden', '--', workspace],
      { encoding: 'utf8' })
    assert.equal(files.status, 0, files.stderr)
    assert.doesNotMatch(files.stdout, /account\.sqlite|workspace-private/)
    const matches = spawnSync(rgPath, ['--json', '--regexp=private', '--', workspace],
      { encoding: 'utf8' })
    assert.equal(matches.status, 1, matches.stderr)
    assert.doesNotMatch(matches.stdout, /account\.sqlite|private value/)
  }
  cwd = workspace
  driftBeforeBody = true
  const readAfterDrift = await call('read', { file_path: join(workspace, 'visible.txt') })
  assert.equal(readAfterDrift.isError, false, JSON.stringify(readAfterDrift.content))
  assert.match(JSON.stringify(readAfterDrift.content), /public value/)
  cwd = workspace
  driftBeforeBody = true
  const globAfterDrift = await call('glob', { pattern: '*.txt', path: workspace })
  assert.equal(globAfterDrift.isError, false, JSON.stringify(globAfterDrift.content))
  assert.equal(spawns.at(-1).cwd, workspace, 'the search must use the pinned Session cwd')
  assert.ok(spawns.at(-1).argv.includes(workspace), 'the original search still receives the pinned absolute target')
  cwd = workspace
  driftBeforeBody = true
  const relativeSearchAfterDrift = await call('glob', { pattern: '*.txt' })
  assert.equal(relativeSearchAfterDrift.isError, false, JSON.stringify(relativeSearchAfterDrift.content))
  assert.equal(spawns.at(-1).cwd, workspace)
  cwd = workspace
  driftBeforeBody = true
  const relativeAfterDrift = await call('read', { file_path: 'visible.txt' })
  assert.equal(relativeAfterDrift.isError, false, JSON.stringify(relativeAfterDrift.content))
  assert.match(JSON.stringify(relativeAfterDrift.content), /public value/)
  cwd = workspace
  driftBeforeBody = true
  const privateAfterDrift = await call('read', { file_path: 'account.sqlite' })
  assert.equal(privateAfterDrift.isError, true)
  assert.doesNotMatch(JSON.stringify(privateAfterDrift), /private value/)
  cwd = home
  assert.equal((await call('glob', { pattern: '*.txt', path: workspace })).isError, true,
    'a Session moved outside the App workspace cannot use ordinary model file tools')
})
