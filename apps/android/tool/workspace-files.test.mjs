import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { mkdtemp, mkdir, readFile, rename, rm, symlink, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { AppWorkspaceFiles } from '../runtime/workspace-files.mjs'

const defaults = () => ({
  readPageBytes: 64, maxDirectoryEntries: 100, listPageSize: 3, maxSearches: 2, closeTimeoutMs: 5000,
  search: { fileBytes: 1024, totalBytes: 8192, maxEntries: 100, maxFiles: 50,
    maxDepth: 8, maxMatches: 20, previewChars: 80, maxDurationMs: 5000 },
})
const request = (changes = {}) => ({ requestId: randomUUID(), path: '', query: 'needle',
  mode: 'content', caseSensitive: true, ...changes })

async function fixture(t) {
  const parent = await mkdtemp(path.join(os.tmpdir(), 'pocket-workspace-'))
  const root = path.join(parent, 'workspace')
  await mkdir(root)
  const limits = defaults()
  const service = new AppWorkspaceFiles({ root, limits: () => limits })
  t.after(async () => {
    await service.close()
    if (path.dirname(parent) !== path.resolve(os.tmpdir()) || !path.basename(parent).startsWith('pocket-workspace-')) {
      throw new Error('Refusing cleanup outside the named test fixture directory')
    }
    await rm(parent, { recursive: true, force: true })
  })
  return { parent, root, limits, service,
    put: async (name, content) => {
      await mkdir(path.dirname(path.join(root, name)), { recursive: true })
      await writeFile(path.join(root, name), content)
    } }
}
const error = (result, code) => assert.equal(result._pocket_error?.code, `workspace-files/${code}`)

test('only the trusted root is exposed and relative path traversal is refused', async t => {
  const h = await fixture(t)
  await h.put('notes.txt', 'inside')
  assert.equal((await h.service.call('info')).root.toLowerCase(), h.root.toLowerCase())
  for (const value of ['../outside', '/outside', 'a/../b', 'a//b', '.', 'C:/secret', 'a\\b', 'note:stream', 'file\0']) {
    error(await h.service.call('read', { path: value }), 'invalid-path')
  }
  error(await h.service.call('list', { root: h.parent }), 'invalid-path')
  error(await h.service.call('read', { sessionId: 'other', path: 'notes.txt' }), 'invalid-path')
  assert.equal(await readFile(path.join(h.root, 'notes.txt'), 'utf8'), 'inside')
})

test('private document bytes keep root authority, exact version and bounded binary windows', async t => {
  const h = await fixture(t)
  const signal = new AbortController().signal
  const limits = { maxFileBytes: 8, maxWindowBytes: 3 }
  const original = Buffer.from([0, 255, 1, 2, 3])
  await h.put('image.png', original)
  const source = await h.service.document('stat', { path: 'image.png' }, signal, limits)
  assert.equal(source.bytes, 5)
  assert.equal(source.absolutePath, path.join(h.root, 'image.png'))
  const complete = await h.service.document('readBytes', { path: source.absolutePath }, signal, limits)
  assert.deepEqual(complete.data, original)
  assert.equal(complete.version, source.version)
  assert.equal(complete.eof, true)
  const window = await h.service.document('readBytes', {
    path: 'image.png', options: { range: { offset: 2, length: 3 } },
  }, signal, limits)
  assert.deepEqual(window.data, original.subarray(2))
  assert.equal(window.offset, 2)
  for (const target of ['../outside.png', path.join(h.parent, 'outside.png'), 'a/../image.png']) {
    await assert.rejects(h.service.document('stat', { path: target }, signal, limits),
      error => error.code === 'workspace-files/outside-workspace' || error.code === 'workspace-files/invalid-path')
  }
  await assert.rejects(h.service.document('readBytes', {
    path: 'image.png', options: { range: { offset: 0, length: 4 } },
  }, signal, limits), { code: 'workspace-files/invalid-page' })
  await h.put('large.pdf', Buffer.alloc(9))
  await assert.rejects(h.service.document('readBytes', { path: 'large.pdf' }, signal, limits),
    { code: 'workspace-files/file-bytes' })
  const stopped = new AbortController()
  stopped.abort(new Error('cancelled'))
  await assert.rejects(h.service.document('readBytes', { path: 'image.png' }, stopped.signal, limits), /cancelled/)
})

test('directory pages have stable ordering and a changed directory invalidates the next page', async t => {
  const h = await fixture(t)
  for (const name of ['z.txt', 'b.txt', 'a.txt', 'nested/n.txt']) await h.put(name, 'text')
  const first = await h.service.call('list', { path: '' })
  assert.deepEqual(first.entries.map(row => row.name), ['a.txt', 'b.txt', 'nested'])
  assert.equal(first.nextOffset, 3)
  const second = await h.service.call('list', { path: '', offset: 3, version: first.version })
  assert.deepEqual(second.entries.map(row => row.name), ['z.txt'])
  await h.put('new.txt', 'changed')
  error(await h.service.call('list', { path: '', offset: 3, version: first.version }), 'changed')
  const nested = await h.service.call('list', { path: 'nested' })
  assert.equal(nested.entries[0].path, 'nested/n.txt')
})

test('directory entry budgets disclose truncation instead of claiming completeness', async t => {
  const h = await fixture(t)
  h.limits.maxDirectoryEntries = 2
  for (const name of ['a', 'b', 'c']) await h.put(name, name)
  const result = await h.service.call('list')
  assert.equal(result.entries.length, 2)
  assert.equal(result.truncated, true)
  assert.equal(result.listedEntries, 2)
})

test('large UTF-8 files page by byte boundary without loss or replacement characters', async t => {
  const h = await fixture(t)
  h.limits.readPageBytes = 7
  const content = '\ufeff中文🙂abcdef\r\n'.repeat(70)
  await h.put('utf8.txt', content)
  let offset = 0, version, output = '', pages = 0
  do {
    const page = await h.service.call('read', { path: 'utf8.txt', offset, ...(version ? { version } : {}) })
    assert.equal(page._pocket_error, undefined)
    assert.equal(page.offset, offset)
    assert.equal(page.text.includes('\ufffd'), false)
    output += page.text
    version = page.version
    pages++
    if (page.eof) break
    assert.ok(page.nextOffset > offset)
    offset = page.nextOffset
  } while (pages < 1000)
  assert.equal(output, content.slice(1))
  assert.ok(pages > 30)
})

test('binary, invalid UTF-8, missing files and changed file versions are explicit', async t => {
  const h = await fixture(t)
  await h.put('binary', Buffer.from([65, 0, 66]))
  await h.put('invalid', Buffer.from([0xc3, 0x28]))
  await h.put('change', 'old text')
  error(await h.service.call('read', { path: 'binary' }), 'not-text')
  error(await h.service.call('read', { path: 'invalid' }), 'not-text')
  error(await h.service.call('read', { path: 'missing' }), 'not-found')
  error(await h.service.call('read', { path: '' }), 'not-file')
  const old = await h.service.call('read', { path: 'change' })
  await h.put('change', 'new and longer text')
  error(await h.service.call('read', { path: 'change', version: old.version }), 'changed')
  error(await h.service.call('read', { path: 'change', offset: -1 }), 'invalid-page')
})

test('outside directory junctions are listed but never followed by reads, lists or searches', async t => {
  const h = await fixture(t)
  const outside = path.join(h.parent, 'outside')
  await mkdir(outside)
  await writeFile(path.join(outside, 'secret.txt'), 'outside needle')
  await symlink(outside, path.join(h.root, 'linked'), process.platform === 'win32' ? 'junction' : 'dir')
  await h.put('normal.txt', 'inside needle')
  const directory = await h.service.call('list')
  assert.equal(directory.entries.find(row => row.name === 'linked').kind, 'link')
  error(await h.service.call('list', { path: 'linked' }), 'symlink')
  error(await h.service.call('read', { path: 'linked/secret.txt' }), 'symlink')
  const found = await h.service.call('search', request())
  assert.deepEqual(found.matches.map(row => row.path), ['normal.txt'])
  assert.deepEqual(found.skipped, [{ path: 'linked', reason: 'symlink' }])
  assert.equal(found.complete, false)
})

test('literal content matches carry a readable byte offset including UTF-8 BOM and CRLF', async t => {
  const h = await fixture(t)
  await h.put('notes/a.txt', '\ufeff中文\r\nneedle on line two\r\nTail')
  await h.put('notes/b.txt', 'NEEDLE uppercase')
  const result = await h.service.call('search', request({ path: 'notes' }))
  assert.equal(result.complete, true)
  assert.equal(result.matches.length, 1)
  const hit = result.matches[0]
  assert.equal(hit.line, 2)
  assert.equal(hit.offset, Buffer.byteLength('\ufeff中文\r\n'))
  const page = await h.service.call('read', { path: hit.path, offset: hit.offset, version: hit.version })
  assert.ok(page.text.startsWith('needle on line two'))
  const insensitive = await h.service.call('search', request({ path: 'notes', caseSensitive: false }))
  assert.equal(insensitive.matches.length, 2)
})

test('name search includes nested directories and never decodes binary content', async t => {
  const h = await fixture(t)
  await h.put('needle-folder/Needle.bin', Buffer.from([0, 255]))
  const result = await h.service.call('search', request({ mode: 'name', caseSensitive: false }))
  assert.deepEqual(result.matches.map(row => [row.path, row.kind]), [
    ['needle-folder', 'directory'], ['needle-folder/Needle.bin', 'file'],
  ])
  assert.equal(result.scanned.bytes, 0)
  assert.equal(result.complete, true)
})

test('content search budgets and unsupported files remain visible as incomplete', async t => {
  const h = await fixture(t)
  await h.put('big', 'needle'.repeat(1000))
  await h.put('binary', Buffer.from([0, 65]))
  await h.put('lines', 'needle\nneedle\nneedle')
  h.limits.search.maxMatches = 1
  const result = await h.service.call('search', request())
  assert.equal(result.complete, false)
  assert.equal(result.stoppedBy, 'matches')
  assert.equal(result.matches.length, 1)
  assert.ok(result.skipped.some(row => row.reason === 'file-bytes'))
  assert.ok(result.skipped.some(row => row.reason === 'not-text'))
})

test('cancellation waits for scan ownership to end and close rejects new work', async t => {
  const h = await fixture(t)
  for (let i = 0; i < 15; i++) await h.put(`${i}.txt`, 'needle')
  const params = request()
  const pending = h.service.call('search', params)
  const cancelled = await h.service.call('search.cancel', { requestId: params.requestId })
  assert.deepEqual(cancelled, { cancelled: true })
  error(await pending, 'cancelled')
  assert.equal(h.service.searches.size, 0)
  await h.service.close()
  error(await h.service.call('list'), 'closed')
})

test('close waits for an already-open file operation to release its handle', async t => {
  const h = await fixture(t)
  await h.put('held.txt', 'text')
  const started = Promise.withResolvers(), release = Promise.withResolvers()
  const original = h.service.withFile.bind(h.service)
  let openedHandle
  h.service.withFile = (name, version, operation) => original(name, version, async (handle, ...rest) => {
    openedHandle = handle
    started.resolve()
    await release.promise
    return operation(handle, ...rest)
  })
  const read = h.service.call('read', { path: 'held.txt' })
  await started.promise
  let finished = false
  const closing = h.service.close().then(() => { finished = true })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(finished, false)
  assert.equal(h.service.pending.size, 1)
  error(await h.service.call('list'), 'closed')
  release.resolve()
  error(await read, 'closed')
  await closing
  assert.equal(openedHandle.fd, -1)
  assert.equal(h.service.pending.size, 0)
})

test('a close timeout stays visible and pending cleanup remains owned until released', async t => {
  const h = await fixture(t)
  h.limits.closeTimeoutMs = 10
  await h.put('held.txt', 'text')
  const started = Promise.withResolvers(), release = Promise.withResolvers()
  const original = h.service.withFile.bind(h.service)
  let openedHandle
  h.service.withFile = (name, version, operation) => original(name, version, async (handle, ...rest) => {
    openedHandle = handle
    started.resolve()
    await release.promise
    return operation(handle, ...rest)
  })
  const read = h.service.call('read', { path: 'held.txt' })
  await started.promise
  try {
    await assert.rejects(h.service.close(), { code: 'workspace-files/close-timeout' })
    assert.equal(h.service.pending.size, 1)
    assert.notEqual(openedHandle.fd, -1)
  } finally { release.resolve() }
  error(await read, 'closed')
  await h.service.close()
  assert.equal(openedHandle.fd, -1)
  assert.equal(h.service.pending.size, 0)
})

test('moving or replacing a file during a read never publishes the already-open content', async t => {
  for (const replacement of [false, true]) {
    const h = await fixture(t)
    await h.put('moving.txt', 'old content')
    const entered = Promise.withResolvers(), release = Promise.withResolvers()
    const original = h.service.withFile.bind(h.service)
    let openedHandle
    h.service.withFile = (name, version, operation) => original(name, version, async (handle, ...rest) => {
      openedHandle = handle
      entered.resolve()
      await release.promise
      return operation(handle, ...rest)
    })
    const reading = h.service.call('read', { path: 'moving.txt' })
    await entered.promise
    try {
      await rename(path.join(h.root, 'moving.txt'), path.join(h.root, 'moved.txt'))
      if (replacement) await h.put('moving.txt', 'new content')
    } finally { release.resolve() }
    const result = await reading
    // Metadata may expose the move before the old path lookup reports absence.
    assert.ok((replacement ? ['workspace-files/changed'] : ['workspace-files/changed', 'workspace-files/not-found'])
      .includes(result._pocket_error?.code))
    assert.equal(result.text, undefined)
    assert.equal(openedHandle.fd, -1)
    assert.equal(await readFile(path.join(h.root, 'moved.txt'), 'utf8'), 'old content')
    h.service.withFile = original
    const reopened = await h.service.call('read', { path: replacement ? 'moving.txt' : 'moved.txt' })
    assert.equal(reopened.text, replacement ? 'new content' : 'old content')
  }
})
