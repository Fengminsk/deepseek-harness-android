import assert from 'node:assert/strict'
import test from 'node:test'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'

const execute = promisify(execFile)
const fixture = fileURLToPath(new URL('./model-attachment-publication.fixture.mjs', import.meta.url))
const cwd = fileURLToPath(new URL('../../../', import.meta.url))
const recovery = 'The verified file was published. Later cancellation or cleanup may remove it; inspect this path before retrying.'

async function run(scenario) {
  // Timeout/nonzero exit rejects before result assertions; no killed child can
  // masquerade as a successful cancellation scenario.
  const { stdout } = await execute(process.execPath, ['--import', 'tsx', fixture, scenario], {
    cwd, windowsHide: true, timeout: 30000, maxBuffer: 128 * 1024,
  })
  const result = JSON.parse(stdout)
  assert.equal(result.injected, true)
  assert.equal(result.isError, true)
  return result
}

function publishedReceipt(result) {
  assert.deepEqual(result.receipts, [{ operation: 'android_attachments/materialize',
    file_path: result.publishedPath, attachmentId: result.expected.attachmentId,
    bytes: result.expected.bytes, state: 'published', recovery }])
}

test('materialization retains the actual published path when partial cleanup fails', { timeout: 45000 }, async () => {
  const result = await run('cleanup-failure')
  assert.equal(result.cancelled, false)
  assert.equal(result.errorMessage, 'Injected post-publication cleanup I/O failure')
  publishedReceipt(result)
  assert.equal(result.actual, result.expected.content)
  assert.equal(result.remainingEntries.length, 1)
})

test('post-publication cancellation retains a factual receipt even when cleanup removes the file', { timeout: 45000 }, async () => {
  const result = await run('cancel-after-publication')
  assert.equal(result.cancelled, true)
  assert.equal(result.errorMessage, 'Injected publication-boundary cancellation')
  publishedReceipt(result)
  assert.equal(result.actual, null)
  assert.deepEqual(result.remainingEntries, [])
})

test('pre-publication cancellation creates no publication receipt or workspace residue', { timeout: 45000 }, async () => {
  const result = await run('cancel-before-publication')
  assert.equal(result.cancelled, true)
  assert.equal(result.errorMessage, 'Injected publication-boundary cancellation')
  assert.deepEqual(result.receipts, [])
  assert.equal(result.actual, null)
  assert.deepEqual(result.remainingEntries, [])
})
