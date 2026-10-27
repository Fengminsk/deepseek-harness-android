import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtemp, readdir, rmdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import test from 'node:test'
import { preparePythonAnalysis, validatePythonAnalysis } from './device-runtime-acceptance/python-analysis.mjs'

test('the exact device Python script analyzes real host fixture files and removes its temporary directory', async t => {
  const directory = await mkdtemp(resolve('.cache/android/python-analysis-'))
  t.after(() => rmdir(directory))
  const fixture = await preparePythonAnalysis('host-script-validation')
  const run = spawnSync('python', ['-', fixture.argument], { cwd: directory, input: fixture.script,
    encoding: 'utf8', timeout: 60000, windowsHide: true })
  assert.equal(run.error, undefined)
  assert.equal(run.status, 0, run.stderr)
  const result = validatePythonAnalysis(run.stdout, fixture.expected)
  assert.equal(result.platform, process.platform === 'win32' ? 'win32' : process.platform)
  assert.equal(result.files.length, 3)
  assert.equal(result.zipEntries.length, 4)
  assert.deepEqual(await readdir(directory), [])
  const altered = structuredClone(result)
  altered.files[0][2] = '0'.repeat(64)
  assert.throws(() => validatePythonAnalysis(JSON.stringify(altered), fixture.expected))
  altered.files = result.files
  altered.subprocess.sha256 = '0'.repeat(64)
  assert.throws(() => validatePythonAnalysis(JSON.stringify(altered), fixture.expected))
})

test('malformed input fails without a success record or residual files', async t => {
  const directory = await mkdtemp(resolve('.cache/android/python-analysis-'))
  t.after(() => rmdir(directory))
  const fixture = await preparePythonAnalysis('host-negative-validation')
  const run = spawnSync('python', ['-', Buffer.from('{invalid json').toString('base64')], {
    cwd: directory, input: fixture.script, encoding: 'utf8', timeout: 60000, windowsHide: true,
  })
  assert.equal(run.error, undefined)
  assert.notEqual(run.status, 0)
  assert.equal(run.stdout, '')
  assert.deepEqual(await readdir(directory), [])
})
