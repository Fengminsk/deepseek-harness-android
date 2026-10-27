import test from 'node:test'
import assert from 'node:assert/strict'
import { chmod, mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { createRequire, registerHooks } from 'node:module'
import { pathToFileURL } from 'node:url'
import { modelFileObservationDenial } from '../runtime/model-file-read-guard.mjs'
import { inspectAttachmentArchive } from '../runtime/attachment-archive.mjs'
import { eventFileReferences } from '../runtime/attachment-references.mjs'

const requireStaged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const load = specifier => import(pathToFileURL(requireStaged.resolve(specifier)).href)
const resolver = registerHooks({ resolve(specifier, context, next) {
  if (context.parentURL?.includes('/apps/android/runtime/') && (specifier.startsWith('@deepseek-ai/') || specifier === 'zod')) {
    return { url: pathToFileURL(requireStaged.resolve(specifier)).href, shortCircuit: true }
  }
  return next(specifier, context)
} })
const { modelAttachmentProjection, registerAndroidAttachmentsTool, isFirstPartyAndroidAttachmentsDefinition } = await import('../runtime/tool-android-attachments.mjs')
const { registerAndroidFilesTool, isFirstPartyAndroidFilesDefinition } = await import('../runtime/tool-android-files.mjs')
const { default: AndroidFileSystem } = await import('../runtime/android-filesystem.mjs')
resolver.deregister()
const [{ Context }, projections, { Session, SessionId }, llm, policy, attachments, prompt, tools] = await Promise.all([
  load('@deepseek-ai/cordis'), load('@deepseek-ai/dsh-session-projection'), load('@deepseek-ai/dsh-session'),
  load('@deepseek-ai/dsh-llm'), load('@deepseek-ai/dsh-sandbox-policy'), load('@deepseek-ai/dsh-attachment-local'),
  load('@deepseek-ai/dsh-system-prompt'), load('@deepseek-ai/dsh-tools'),
])
const { zipSync } = requireStaged('fflate')

async function fixture(t) {
  const home = await mkdtemp(join(tmpdir(), 'android-model-attachment-')), workspace = join(home, 'workspace')
  await mkdir(workspace)
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(home, { recursive: true, force: true }) })
  await ctx.plugin(prompt.default)
  await ctx.plugin(tools.default)
  await ctx.plugin(projections.default)
  await ctx.plugin(policy.default, { mode: 'workspace-write', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  const store = new attachments.default(ctx, { dshHome: home })
  ctx.provide('workingDirectory', { ensure: async () => workspace })
  const owner = registerAndroidAttachmentsTool(ctx, workspace)
  const session = Session.create(SessionId('attachment-model-test'))
  const agent = { session, id: session.id }
  ctx.provide('agents', { get(id) { return id === agent.id ? agent : undefined } })
  let callId = 0
  const execution = (selectedAgent = agent, signal = new AbortController().signal) => ({ agent: selectedAgent, callId: `attachment-${++callId}`, signal })
  const call = (args, selectedAgent, signal) => owner.execute(args, execution(selectedAgent, signal))
  const upload = async (name, data) => {
    const ref = await store.saveFile({ name, data: Buffer.from(data) })
    session.append('user/message', llm.createUserMessage({ content: [{ type: 'file', attachment: ref }], source: { kind: 'user' } }), { surfaceOp: 'append' })
    return ref
  }
  return { home, workspace, ctx, store, owner, session, agent, execution, call, upload }
}

test('current-session projection authorizes exact references and original attachment reads', async t => {
  const f = await fixture(t), ref = await f.upload('notes.txt', '天气晴朗 abc\n第二行')
  assert.deepEqual((await f.call({ action: 'list' })).files, [ref])
  const args = { action: 'read', attachmentId: ref.attachmentId, name: ref.name }
  const page = await f.call({ ...args, limit: 7 })
  assert.equal(page.content, '天气'); assert.equal(page.nextOffset, 6)
  const remainder = await f.call({ ...args, offset: page.nextOffset })
  assert.equal(page.content + remainder.content, '天气晴朗 abc\n第二行')
  assert.equal(remainder.nextOffset, null)
  const other = { session: Session.create(SessionId('other')) }
  await assert.rejects(f.call(args, other), { code: 'android-attachments/not-referenced' })
  await assert.rejects(f.call({ ...args, sessionId: String(f.session.id) }), /不能指定会话/)
  await assert.rejects(f.call({ ...args, name: '../notes.txt' }), /未引用/)
  await assert.rejects(f.call({ ...args, offset: 1 }), /UTF-8/)
  assert.deepEqual(eventFileReferences({ type: 'external/opaque', data: { content: [{ type: 'file', attachment: ref }] } }), [])
  assert.deepEqual(eventFileReferences({ type: 'user/message', data: { content: [{ type: 'text', text: JSON.stringify(ref) }] } }), [])
  const unknown = modelAttachmentProjection.apply([], { type: 'unknown', data: { attachment: ref } })
  assert.deepEqual(unknown, [])
  const privatePath = await f.store.fileHostPath(ref)
  assert.match(modelFileObservationDenial(f.workspace, f.workspace, 'read', { file_path: privatePath }), /android_attachments/)
})

test('binary pages and verified workspace materialization preserve bytes and current policy', async t => {
  const f = await fixture(t), data = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 255])
  const ref = await f.upload('image.png', data), args = { attachmentId: ref.attachmentId, name: ref.name }
  await assert.rejects(f.call({ ...args, action: 'read' }), /UTF-8|二进制/)
  const hex = await f.call({ ...args, action: 'read', encoding: 'hex', limit: 4 })
  assert.equal(hex.content, '89504e47'); assert.equal(hex.nextOffset, 4)
  const materialized = await f.call({ ...args, action: 'materialize' })
  assert.deepEqual(await readFile(materialized.file_path), data)
  assert.equal(modelFileObservationDenial(f.workspace, f.workspace, 'read_image', { file_path: materialized.file_path }), undefined)
  assert.match(materialized.file_path, /image\.png$/)
  f.session.append('sandbox/mode', { mode: 'read-only' })
  await assert.rejects(f.call({ ...args, action: 'materialize' }), { code: 'FS_SANDBOX_DENIED' })
  assert.equal((await f.call({ ...args, action: 'read', encoding: 'hex' })).verified, true)
  const outcome = await f.ctx.tools.execute({ name: 'android_attachments', arguments: { action: 'list' }, ...f.execution() })
  assert.equal(outcome.isError, false, JSON.stringify(outcome))
  assert.match(JSON.stringify(outcome.content), /image\.png/)
  const definition = f.ctx.tools.get('android_attachments')
  assert.equal(isFirstPartyAndroidAttachmentsDefinition(definition, f.agent), true)
  assert.equal(isFirstPartyAndroidAttachmentsDefinition({ ...definition }, f.agent), false)
  assert.equal(isFirstPartyAndroidAttachmentsDefinition(definition, { ...f.agent }), false)
})

test('corrupt originals never return even the first page and failed imports leave no file', async t => {
  const f = await fixture(t), ref = await f.upload('report.txt', 'approved text')
  const source = await f.store.fileHostPath(ref)
  await chmod(source, 0o600)
  await writeFile(source, 'modified text')
  for (const action of ['read', 'materialize', 'inspect_archive', 'inspect_apk']) {
    await assert.rejects(f.call({ action, attachmentId: ref.attachmentId, name: ref.name }), /integrity|完整性/)
  }
  assert.deepEqual(await readdir(f.workspace), [])
  const oversized = { ...ref, bytes: 256 * 1024 * 1024 + 1 }
  f.session.append('user/message', llm.createUserMessage({ content: [{ type: 'file', attachment: oversized }], source: { kind: 'user' } }), { surfaceOp: 'append' })
  await assert.rejects(f.call({ action: 'read', attachmentId: ref.attachmentId, name: ref.name }), /256 MiB/)
})

test('archive inspection is paged metadata, never a packing verdict or decompression', async t => {
  const f = await fixture(t)
  const archive = zipSync({ 'AndroidManifest.xml': Buffer.from('manifest'), 'classes.dex': Buffer.from('dex'),
    'lib/arm64-v8a/libflutter.so': Buffer.from('library'), 'assets/info.txt': Buffer.from('payload') })
  const ref = await f.upload('example.apk', archive)
  const first = await f.call({ action: 'inspect_archive', attachmentId: ref.attachmentId, name: ref.name, limit: 2 })
  assert.equal(first.format, 'apk'); assert.equal(first.entryCount, 4)
  assert.deepEqual(first.apk, { hasManifest: true, dexCount: 1, nativeLibraryCount: 1, abis: ['arm64-v8a'] })
  assert.equal(first.nextOffset, 2)
  const second = await f.call({ action: 'inspect_archive', attachmentId: ref.attachmentId, name: ref.name, offset: 2, limit: 2 })
  assert.equal(second.nextOffset, null)
  assert.equal(new Set([...first.entries, ...second.entries].map(entry => entry.name)).size, 4)
  const lib = await f.call({ action: 'inspect_archive', attachmentId: ref.attachmentId, name: ref.name, contains: 'lib/' })
  assert.equal(lib.entries.length, 1)
  assert.match(lib.evidence, /have not been verified/)
  assert.deepEqual(await readdir(f.workspace), [])
})

test('built-in APK inspection uses the live ToolRuntime, honors session policy and reports partial coverage', async t => {
  const f = await fixture(t)
  const archive = zipSync({ 'AndroidManifest.xml': Buffer.from('<manifest package="example"/>'),
    'classes.dex': Buffer.from('unsupported bytes'), 'lib/arm64-v8a/libsample.so': Buffer.from('not ELF') })
  const ref = await f.upload('sample.apk', archive)
  const args = { action: 'inspect_apk', attachmentId: ref.attachmentId, name: ref.name }
  f.session.append('sandbox/mode', { mode: 'read-only' })
  const call = async extra => {
    const outcome = await f.ctx.tools.execute({ name: 'android_attachments', arguments: { ...args, ...extra }, ...f.execution() })
    assert.equal(outcome.isError, false, JSON.stringify(outcome))
    return JSON.parse(outcome.content.map(part => part.text ?? '').join(''))
  }
  const summary = await call({})
  assert.equal(summary.verified, true); assert.equal(summary.coverage.apkSignaturesVerified, false)
  assert.equal(summary.results[0].analysis.status, 'unsupported')
  assert.equal(summary.archive.dexCount, 1); assert.equal(summary.archive.nativeLibraryCount, 1)
  for (const part of ['dex', 'native']) {
    const result = await call({ part })
    assert.equal(result.results[0].status, 'unparsed')
    assert.match(result.results[0].error.code, /^apk-code\//)
    assert.equal(result.nextOffset, null)
  }
  await assert.rejects(f.call({ ...args, part: 'shell' }), /part=/)
  await assert.rejects(f.call({ ...args, part: 'dex', limit: 5 }), /limit/)
  await assert.rejects(f.call(args, { session: Session.create(SessionId('unrelated-apk')) }), /未引用/)
  assert.deepEqual(await readdir(f.workspace), [], 'inspection does not materialize or modify files')
})

test('APK golden Manifest and minimal ELF survive real tool JSON output and pagination', async t => {
  const f = await fixture(t)
  const golden = JSON.parse(await readFile(new URL('./fixtures/apk-manifest-aapt2.json', import.meta.url), 'utf8'))
  const elf = Buffer.alloc(64)
  elf.set([127, 69, 76, 70, 2, 1, 1]); elf.writeUInt16LE(3, 16); elf.writeUInt16LE(183, 18)
  elf.writeUInt32LE(1, 20); elf.writeUInt16LE(64, 52)
  const ref = await f.upload('golden.apk', zipSync({ 'AndroidManifest.xml': Buffer.from(golden.base64, 'base64'),
    'lib/arm64-v8a/one.so': elf, 'lib/arm64-v8a/two.so': elf }))
  const call = async extra => {
    const outcome = await f.ctx.tools.execute({ name: 'android_attachments', arguments: {
      action: 'inspect_apk', attachmentId: ref.attachmentId, name: ref.name, ...extra }, ...f.execution() })
    assert.equal(outcome.isError, false, JSON.stringify(outcome))
    return JSON.parse(outcome.content.map(part => part.text ?? '').join(''))
  }
  const manifest = (await call({ part: 'manifest', limit: 2 })).results[0].analysis
  assert.equal(manifest.package, 'org.example.apkparser'); assert.equal(manifest.nextComponentOffset, 2)
  const remaining = (await call({ part: 'manifest', offset: 2, limit: 2 })).results[0].analysis
  assert.equal(remaining.components.length, 2); assert.equal(remaining.nextComponentOffset, null)
  const first = await call({ part: 'native' })
  assert.equal(first.results[0].analysis.header.architecture, 'AArch64'); assert.equal(first.nextOffset, 1)
  const second = await call({ part: 'native', offset: first.nextOffset })
  assert.notEqual(second.results[0].name, first.results[0].name); assert.equal(second.nextOffset, null)
})

test('APK second-pass readers are serialized and close drains their lifetime', { timeout: 10000 }, async t => {
  const f = await fixture(t), ref = await f.upload('pending.apk', zipSync({ 'AndroidManifest.xml': Buffer.from('manifest') }))
  const original = f.store.readFileStream.bind(f.store), entered = Promise.withResolvers(), drain = Promise.withResolvers()
  let calls = 0, exited = false
  Object.defineProperty(f.store, 'readFileStream', { configurable: true, writable: true, value: async function* (selected, signal) {
    if (++calls !== 2) { yield* original(selected, signal); return }
    try {
      entered.resolve()
      await new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }))
    } finally { await drain.promise; exited = true }
  } })
  const args = { action: 'inspect_apk', attachmentId: ref.attachmentId, name: ref.name }
  const pending = f.call(args).catch(error => error)
  try {
    await Promise.race([entered.promise, pending.then(result => { throw result })])
    await assert.rejects(f.call(args), { code: 'android-attachments/busy' })
    const read = await f.call({ ...args, action: 'read', encoding: 'hex', limit: 4 })
    assert.equal(read.content, '504b0304')
    const closing = f.owner.close(); assert.equal(exited, false)
    drain.resolve(); await closing
    assert.equal(exited, true); assert.match((await pending).message, /unloaded/)
  } finally { drain.resolve(); await f.owner.close(); await pending }
})

test('concurrency is bounded and unloading waits for cancelled readers and import cleanup', { timeout: 10000 }, async t => {
  const f = await fixture(t), ref = await f.upload('pending.txt', 'pending')
  const entered = [Promise.withResolvers(), Promise.withResolvers()], drain = Promise.withResolvers()
  let readers = 0, exited = 0
  Object.defineProperty(f.store, 'readFileStream', { configurable: true, writable: true, value: async function* (_ref, signal) {
    const index = readers++
    entered[index].resolve()
    try {
      await new Promise((resolve, reject) => {
        if (signal.aborted) reject(signal.reason)
        else signal.addEventListener('abort', () => reject(signal.reason), { once: true })
      })
      yield Buffer.from('pending')
    } finally { await drain.promise; exited++ }
  } })
  const args = { attachmentId: ref.attachmentId, name: ref.name }
  const first = f.call({ ...args, action: 'read' }).then(() => assert.fail('late read result'), error => error)
  const second = f.call({ ...args, action: 'materialize' }).then(() => assert.fail('late import result'), error => error)
  await Promise.all(entered.map(item => item.promise))
  await assert.rejects(f.call({ ...args, action: 'read' }), { code: 'android-attachments/busy' })
  const closing = f.owner.close()
  assert.equal(exited, 0, 'close cannot return while provider iterators are still draining')
  drain.resolve()
  await closing
  assert.equal(exited, 2)
  assert.equal((await first).message, 'Attachment tool unloaded')
  assert.equal((await second).message, 'Attachment tool unloaded')
  assert.deepEqual(await readdir(f.workspace), [])
})

test('ZIP directory inspection refuses malformed, split and unsupported ZIP64 metadata', () => {
  const zip = Buffer.from(zipSync({ 'file.txt': Buffer.from('hello') }))
  assert.throws(() => inspectAttachmentArchive(zip.subarray(0, -1), zip.length - 1), /complete ZIP/)
  const split = Buffer.from(zip); split.writeUInt16LE(1, zip.length - 22 + 4)
  assert.throws(() => inspectAttachmentArchive(split, split.length), /split/)
  const zip64 = Buffer.from(zip); zip64.writeUInt32LE(0xffffffff, zip.length - 22 + 12)
  assert.throws(() => inspectAttachmentArchive(zip64, zip64.length), /ZIP64/)
  const badDirectory = Buffer.from(zip); badDirectory.writeUInt32LE(123456, zip.length - 22 + 16)
  assert.throws(() => inspectAttachmentArchive(badDirectory, badDirectory.length), /bounds/)
  const traverse = Buffer.from(zipSync({ '../outside.txt': Buffer.from('no extraction') }))
  const unsafe = inspectAttachmentArchive(traverse, traverse.length)
  assert.equal(unsafe.unsafeNames, 1); assert.equal(unsafe.entries[0].unsafePath, true)
})

test('SAF tool explains root ids and relative paths before calling document providers', async t => {
  const f = await fixture(t), requests = [], id = 'a'.repeat(64)
  registerAndroidFilesTool(f.ctx, { async request(method, params) {
    requests.push({ method, params })
    if (method === 'native.documents.roots') return [{ id, name: 'Download', available: true }]
    if (method === 'native.documents.list') return [{ name: 'report.txt' }]
    assert.fail(`unexpected request ${method}`)
  } }, { run() { assert.fail('unexpected search') } })
  const call = args => f.ctx.tools.execute({ name: 'android_files', arguments: args, ...f.execution() })
  const definition = f.ctx.tools.get('android_files')
  assert.equal(isFirstPartyAndroidFilesDefinition(definition, f.agent), true)
  assert.equal(isFirstPartyAndroidFilesDefinition({ ...definition }, f.agent), false)
  assert.equal(isFirstPartyAndroidFilesDefinition(definition, { ...f.agent }), false)
  const wrong = await call({ action: 'list', root: 'Download', path: '' })
  assert.equal(wrong.isError, true); assert.match(JSON.stringify(wrong.content), /显示名称/)
  const absolute = await call({ action: 'list', root: id, path: '/' })
  assert.equal(absolute.isError, true); assert.match(JSON.stringify(absolute.content), /相对路径/)
  const right = await call({ action: 'list', root: id })
  assert.equal(right.isError, false, JSON.stringify(right))
  assert.deepEqual(requests.at(-1), { method: 'native.documents.list', params: { root: id, path: '' } })
  const revoked = await call({ action: 'list', root: 'b'.repeat(64) })
  assert.match(JSON.stringify(revoked.content), /不在当前授权/)
})
