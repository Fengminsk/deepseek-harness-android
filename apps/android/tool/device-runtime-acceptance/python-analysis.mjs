import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'

/** Prepare one bounded guest script and independently computed expected file analysis. */
export async function preparePythonAnalysis(token) {
  const files = [
    { name: 'alpha.txt', text: 'alpha\n', kind: 'text' },
    { name: 'unicode.txt', text: '中文与文件分析\n', kind: 'text' },
    { name: 'numbers.txt', text: '17,23,42\n', kind: 'data' },
  ]
  const payload = Buffer.from(JSON.stringify({ token, files }) + '\n')
  const argument = payload.toString('base64')
  const script = await readFile(new URL('./python-analysis.py', import.meta.url), 'utf8')
  const rows = files.map(file => [file.name, Buffer.byteLength(file.text),
    createHash('sha256').update(file.text).digest('hex'), file.kind])
    .sort((left, right) => left[0] < right[0] ? -1 : 1)
  const groups = ['data', 'text'].map(kind => {
    const matches = rows.filter(row => row[3] === kind)
    return [kind, matches.length, matches.reduce((sum, row) => sum + row[1], 0)]
  })
  return { script, argument,
    command: `python3 - '${argument}' <<'DSH_PYTHON_ANALYSIS'\n${script}\nDSH_PYTHON_ANALYSIS`,
    expected: { token, inputSha256: createHash('sha256').update(payload).digest('hex'),
      files: rows, groups, zipEntries: ['source.json', ...files.map(file => file.name)].sort() } }
}

/** Check real script output without asserting the host or device execution carrier. */
export function validatePythonAnalysis(output, expected) {
  const result = JSON.parse(output.trim())
  assert.equal(result.check, 'python-stdlib-file-analysis-v1')
  for (const field of ['token', 'inputSha256', 'files', 'groups', 'zipEntries']) {
    assert.deepEqual(result[field], expected[field], field)
  }
  assert.deepEqual(result.subprocess, { sha256: expected.inputSha256, token: expected.token, entries: expected.zipEntries })
  assert.match(result.pythonVersion, /^3\.\d+\.\d+$/u)
  assert.match(result.sqliteVersion, /^3\.\d+\.\d+$/u)
  assert.match(result.opensslVersion, /^OpenSSL /u)
  assert.equal(result.tls.checkHostname, true)
  assert.equal(result.tls.certificateRequired, true)
  assert.ok(Number.isSafeInteger(result.tls.caCount) && result.tls.caCount > 0)
  return result
}
