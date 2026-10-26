import assert from 'node:assert/strict'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, join, resolve, sep } from 'node:path'
import { test } from 'node:test'
import { assertCurrentAndroidRuntimeSources, validateRecordedSessionManifest } from './run-recorded-sessions.mjs'

const scenario = { id: 'saf-image', script: 'smoke-authorized-image.mjs',
  input: 'scenarios/saf-image.json',
  expected: 'expected/saf-image-session.expected.json' }

test('Android recorded Session manifest accepts owner-local scenarios', () => {
  assert.deepEqual(validateRecordedSessionManifest({ version: 1, scenarios: [scenario] }), [scenario])
})

test('Android recorded Session manifest rejects duplicate IDs and scripts', () => {
  assert.throws(() => validateRecordedSessionManifest({ version: 1,
    scenarios: [scenario, { ...scenario, script: 'another.mjs' }] }), /Duplicate.*ID/)
  assert.throws(() => validateRecordedSessionManifest({ version: 1,
    scenarios: [scenario, { ...scenario, id: 'another' }] }), /Duplicate.*script/)
})

test('Android recorded Session manifest rejects path escapes', () => {
  for (const path of ['../secret.mjs', 'subdir/secret.mjs', 'C:\\secret.mjs']) {
    assert.throws(() => validateRecordedSessionManifest({ version: 1,
      scenarios: [{ ...scenario, script: path }] }))
  }
  assert.throws(() => validateRecordedSessionManifest({ version: 1,
    scenarios: [{ ...scenario, expected: '../../secret.json' }] }))
  assert.throws(() => validateRecordedSessionManifest({ version: 1,
    scenarios: [{ ...scenario, input: '../secret.json' }] }))
})

test('Android recorded Session lane rejects stale and missing staged runtime sources', async () => {
  const parent = resolve(tmpdir())
  const root = await mkdtemp(join(parent, 'dsh-android-recorded-test-'))
  try {
    const source = join(root, 'source')
    const staged = join(root, 'staged')
    await mkdir(source)
    await mkdir(staged)
    await writeFile(join(source, 'index.mjs'), 'export const version = 1\n')
    await writeFile(join(staged, 'index.mjs'), 'export const version = 1\n')
    assert.equal(await assertCurrentAndroidRuntimeSources(source, staged), 1)
    await writeFile(join(staged, 'index.mjs'), 'export const version = 0\n')
    await assert.rejects(assertCurrentAndroidRuntimeSources(source, staged), /stale at index\.mjs/)
    await writeFile(join(staged, 'index.mjs'), 'export const version = 1\n')
    await writeFile(join(source, 'added.mjs'), 'export const added = true\n')
    await assert.rejects(assertCurrentAndroidRuntimeSources(source, staged), /lacks added\.mjs/)
  } finally {
    const target = resolve(root)
    assert.ok(target.startsWith(parent + sep)
      && /^dsh-android-recorded-test-[A-Za-z0-9]{6}$/.test(basename(target)))
    await rm(target, { recursive: true, force: true })
  }
})
