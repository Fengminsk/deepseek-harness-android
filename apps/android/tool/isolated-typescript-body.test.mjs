import test from 'node:test'
import assert from 'node:assert/strict'
import { stripTypeScriptTypes } from 'node:module'
import {
  compileIsolatedTypeScriptBody, originalTypeScriptLocation,
  prepareIsolatedTypeScriptRun,
} from '../runtime/isolated-typescript-body.mjs'

const PREFIX = 'async function __dsh_program__() {\n'
const SUFFIX = '\n}'
const AsyncFunction = (async () => {}).constructor

test('Android host erases the same erasable TypeScript body as original Node PTC', async () => {
  const source = [
    'interface Item { value: number }',
    'const rows: Item[] = [{ value: 6 }]',
    'const id = <T>(value: T): T => value',
    'const selected = id(rows[0]) satisfies Item',
    'return { answer: (await Promise.resolve(selected.value)) * 7 }',
  ].join('\n')
  const compiled = compileIsolatedTypeScriptBody(source)
  const original = stripTypeScriptTypes(PREFIX + source + SUFFIX)
  assert.equal(compiled.javaScript, original.slice(PREFIX.length, -SUFFIX.length))
  assert.deepEqual(compiled.javaScript.split('\n').map(line => line.length),
    source.split('\n').map(line => line.length))
  assert.equal(compiled.language, 'typescript-function-body')
  assert.match(compiled.sourceSha256, /^[a-f0-9]{64}$/)
  assert.match(compiled.javaScriptSha256, /^[a-f0-9]{64}$/)
  assert.notEqual(compiled.sourceSha256, compiled.javaScriptSha256)
  assert.equal(Object.isFrozen(compiled), true)
  const fn = new AsyncFunction('input', 'host', `'use strict';\n${compiled.javaScript}`)
  assert.deepEqual(await fn(null, null), { answer: 42 })
})

test('native body source locations map to the same physical TypeScript lines and UTF-16 columns', () => {
  const source = 'const n: number = 7;\r\nreturn { emoji: "🙂", n }'
  const compiled = compileIsolatedTypeScriptBody(source)
  assert.deepEqual(compiled.javaScript.split('\n').map(line => line.length),
    source.split('\n').map(line => line.length))
  assert.deepEqual(originalTypeScriptLocation(compiled, 2, 10), { line: 1, utf16Column: 10 })
  assert.deepEqual(originalTypeScriptLocation(compiled, 3, 22), { line: 2, utf16Column: 22 })
  for (const position of [[1, 1], [4, 1], [2, 0], [NaN, 1]]) {
    assert.equal(originalTypeScriptLocation(compiled, ...position), null)
  }
})

test('non-erasable TypeScript and invalid function-body grammar fail before admission', () => {
  for (const source of [
    'enum Color { Red } return Color.Red',
    'namespace N { export const n = 1 } return N.n',
    'class C { constructor(public n: number) {} } return new C(1).n',
    'return 1; }(); globalThis.leaked = true; async function x() {',
    'return 1; }\n(async () => { globalThis.leaked = true })();\nasync function x() {',
    'return <div/>',
    'return (',
    'with ({ n: 1 }) { return n }',
    'const input = 1; return input',
  ]) assert.throws(() => compileIsolatedTypeScriptBody(source),
    { code: 'ANDROID_PTC_TYPESCRIPT_INVALID' }, source)
})

test('host compilation does not execute source code or import modules', () => {
  const marker = '__android_type_erase_no_execute__'
  delete globalThis[marker]
  try {
    const compiled = compileIsolatedTypeScriptBody(`globalThis.${marker} = true; await import('node:fs'); return 1`)
    assert.match(compiled.javaScript, /globalThis/)
    assert.equal(globalThis[marker], undefined)
  } finally {
    delete globalThis[marker]
  }
})

test('source and compiled code stay inside the native 64 KiB UTF-8 limit', () => {
  const atLimit = '//'+ 'x'.repeat(65534)
  assert.equal(Buffer.byteLength(atLimit), 65536)
  assert.equal(compileIsolatedTypeScriptBody(atLimit).javaScript, atLimit)
  for (const source of [atLimit + 'x', '🙂'.repeat(16385), '\ud800', '', '  ', null]) {
    assert.throws(() => compileIsolatedTypeScriptBody(source),
      { code: 'ANDROID_PTC_TYPESCRIPT_INVALID' })
  }
})

test('trusted preparation binds original source and stripped native program to one frozen run', () => {
  const sessionId = 'd7ad4e91-2825-48be-9d82-d964e31c9f19'
  const source = 'const n: number = 6; return n * 7'
  const request = {
    kind: 'script', runId: 'a8f610f2-e665-47d4-b8e9-bdbfdc0324ac', sessionId,
    program: source, args: null, deadlineMillis: 5000,
  }
  const scope = {
    ownerId: 'ptc-type-test', sessionId, version: 1, workspaceId: null,
    readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
  }
  const ready = prepareIsolatedTypeScriptRun(request, scope)
  assert.equal(ready.source, source)
  assert.equal(ready.execution.program, ready.compiled.javaScript)
  assert.equal(ready.execution.runId, request.runId)
  assert.equal(ready.execution.sessionId, sessionId)
  assert.equal(Object.isFrozen(ready), true)
  assert.equal(Object.isFrozen(ready.execution), true)
  assert.equal(Object.isFrozen(ready.compiled), true)

  let invoked = false
  const hostile = Object.defineProperty({ ...request }, 'program', {
    get() { invoked = true; throw new Error('must not run') },
  })
  assert.throws(() => prepareIsolatedTypeScriptRun(hostile, scope),
    { code: 'ANDROID_PTC_TYPESCRIPT_INVALID' })
  assert.equal(invoked, false)
  for (const invalid of [{ ...request, grant: 'any' }, { ...request, kind: 'workflow' }]) {
    assert.throws(() => prepareIsolatedTypeScriptRun(invalid, scope),
      { code: 'ANDROID_PTC_TYPESCRIPT_INVALID' })
  }
})
