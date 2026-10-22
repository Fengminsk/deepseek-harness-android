import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { mkdtemp, mkdir, readFile, copyFile, rm, realpath } from 'node:fs/promises'
import { dirname, join, resolve, basename } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createHash } from 'node:crypto'
import { stageSecretMask } from './stage-secret-mask.mjs'
import { createSecretRule } from '../../../packages/client/ui-secret-mask/src/client/secret-rule.ts'

const cache = resolve(import.meta.dirname, '../../../.cache/android')
await mkdir(cache, { recursive: true })
const destination = await mkdtemp(join(cache, 'secret-mask-test-'))
after(async () => {
  const target = await realpath(destination)
  assert.equal(dirname(target), await realpath(cache))
  assert.ok(basename(target).startsWith('secret-mask-test-'))
  await rm(target, { recursive: true, force: true })
})
await stageSecretMask(destination)
await copyFile(new URL('../runtime/user-text-mask.mjs', import.meta.url), join(destination, 'user-text-mask.mjs'))
const { maskUserText } = await import(pathToFileURL(join(destination, 'user-text-mask.mjs')).href)
const key = ['sk', '-', '0123456789abcdef'.repeat(2)].join('')
const original = text => {
  const rule = createSecretRule()
  const ranges = []
  let offset = 0
  while (offset < text.length) {
    const match = rule.match(text, offset)
    if (!match) break
    ranges.push({ start: match.start, end: match.end, masked: match.data.masked })
    offset = match.end
  }
  return { ranges }
}

test('compiled carrier exactly reuses original formats, UTF-16 coordinates and masks', () => {
  for (const text of [
    '', 'ordinary prose password=hunter2', `😀前缀 ${key} suffix`,
    `${key} ${key}`, `https://owner:${key}@example.com/`,
    ['-----BEGIN PRIVATE KEY-----', 'not a real key', '-----END PRIVATE KEY-----'].join('\n'),
    `@[${key}](dsh-session:synthetic) /${key} @folder/${key}`,
    `${'non-secret text '.repeat(10000)}${key}`,
  ]) assert.deepEqual(maskUserText({ text }), original(text))
  const result = maskUserText({ text: `😀 ${key}` })
  assert.equal(result.ranges[0].start, 3)
  assert.ok(!JSON.stringify(result).includes(key))
})

test('scan memo and reveal are not retained across independent calls', () => {
  assert.equal(maskUserText({ text: key }).ranges.length, 1)
  assert.deepEqual(maskUserText({ text: 'clear' }), { ranges: [] })
  assert.deepEqual(maskUserText({ text: key }), original(key))
})

test('malformed and oversized requests fail without echoing submitted values', () => {
  for (const params of [null, {}, { text: 42 }, { text: {} }]) {
    assert.throws(() => maskUserText(params), TypeError)
  }
  const text = key + '中'.repeat(180000)
  assert.throws(() => maskUserText({ text }), error => error instanceof RangeError && !error.message.includes(key))
})

test('packaged manifest records exact upstream and emitted bytes', async () => {
  const manifest = JSON.parse(await readFile(join(destination, 'secret-mask/manifest.json'), 'utf8'))
  assert.equal(manifest.length, 5)
  const root = resolve(import.meta.dirname, '../../..')
  const hash = bytes => createHash('sha256').update(bytes).digest('hex')
  for (const item of manifest) {
    assert.equal(hash(await readFile(join(root, item.source))), item.sourceSha256)
    const compiled = await readFile(join(destination, 'secret-mask', item.file))
    assert.equal(hash(compiled), item.sha256)
    assert.doesNotMatch(compiled.toString(), /from ['"][^'"]+\.ts['"]/u)
  }
})
