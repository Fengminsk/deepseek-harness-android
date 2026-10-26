import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readAuthorizedDocument } from '../runtime/document-read.mjs'

const before = 'a'.repeat(64)
const after = 'b'.repeat(64)
const page = version => ({ text: 'part', offset: 8, nextOffset: 12, truncated: false, version })

test('model-facing SAF continuation requires the observed version before native IO', async () => {
  let opened = 0
  const read = async request => { opened++; assert.equal(request.version, before); return page(before) }
  await assert.rejects(readAuthorizedDocument(read, { root: 'grant', path: 'note.txt', offset: 8 }, true), /version/)
  await assert.rejects(readAuthorizedDocument(read, { root: 'grant', path: 'note.txt', offset: 8, version: 'bad' }, true), /版本/)
  await assert.rejects(readAuthorizedDocument(read, { root: 'grant', path: 'note.txt', offset: -1 }, true), /位置/)
  assert.equal(opened, 0)
  assert.deepEqual(await readAuthorizedDocument(read,
    { root: 'grant', path: 'note.txt', offset: 8, version: before }, true), page(before))
  assert.equal(opened, 1)
})

test('moved or replaced SAF document cannot return a continuation from a new version', async () => {
  await assert.rejects(readAuthorizedDocument(async () => page(after),
    { root: 'grant', path: 'note.txt', offset: 8, version: before }, true), /文件已移动或变化/)
  await assert.rejects(readAuthorizedDocument(async () => ({ ...page(before), version: null }),
    { root: 'grant', path: 'note.txt', offset: 8, version: before }, true), /未返回可核对的版本/)
  assert.deepEqual(await readAuthorizedDocument(async () => page(after),
    { root: 'grant', path: 'note.txt', offset: 8 }, false), page(after),
  'the App may explicitly rebase its visible reader after a connection change')
})

test('SAF pages must cover exactly the requested range before reaching the Agent', async () => {
  const request = { root: 'grant', path: 'notes.txt', offset: 8, version: before }
  const invalidPages = [
    { ...page(before), offset: 4 },
    { ...page(before), nextOffset: 7 },
    { ...page(before), nextOffset: 8 },
    { ...page(before), nextOffset: Number.MAX_SAFE_INTEGER + 1 },
    { ...page(before), nextOffset: 8, truncated: true },
    { ...page(before), text: '' },
    { ...page(before), text: null },
    { ...page(before), truncated: 'false' },
    { ...page(before), text: 'lost', nextOffset: 13 },
    { ...page(before), text: 'a'.repeat(262145), nextOffset: 262153 },
    { ...page(before), text: '\ud800', nextOffset: 11 },
  ]
  for (const invalid of invalidPages) {
    await assert.rejects(readAuthorizedDocument(async () => invalid, request, true),
      /不一致的分页位置/, JSON.stringify(invalid))
  }
  const finalEmptyPage = { text: '', offset: 8, nextOffset: 8, truncated: false, version: before }
  assert.deepEqual(await readAuthorizedDocument(async () => finalEmptyPage, request, true), finalEmptyPage,
    'an empty final page is valid at EOF')
  const unicodePage = { text: '中🙂', offset: 8, nextOffset: 15, truncated: true, version: before }
  assert.deepEqual(await readAuthorizedDocument(async () => unicodePage, request, true), unicodePage,
    'the continuation offset counts UTF-8 bytes, not JavaScript characters')
})
