import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const args = process.argv.slice(2)
if (args.some(value => !['--expect-eviction', '--remove-atomic-release'].includes(value))) throw new Error('Unknown snapshot race argument')
const expectedEviction = args.includes('--expect-eviction')
const root = resolve(import.meta.dirname, '../../..')
const directory = mkdtempSync(join(root, '.cache/android/document-snapshot-race-'))
const sources = join(root, 'apps/android/android/app/src/main/java/com/minnnng/dsh_android')
let source = readFileSync(join(sources, 'DocumentSnapshotStore.java'), 'utf8').replaceAll('\r\n', '\n')
if (args.includes('--remove-atomic-release')) {
  const release = '                RESERVATIONS.remove(temporary);\n                RESERVATIONS.remove(temporaryInfo);\n'
  assert.equal(source.split(release).length, 2, 'Negative control requires exactly one atomic commit release')
  source = source.replace(release, '')
}
// Delay an existing legal scheduling point, without changing the file/cache operations.
// The production source has no test callback or configurable synchronization behavior.
const point = '        } finally {\n            synchronized (LOCK) {'
assert.equal(source.split(point).length, 2, 'The capture finalizer must have one unambiguous scheduling point')
source = source.replace(point, '        } finally {\n            SnapshotCommitProbe.afterPublication();\n            synchronized (LOCK) {')
const copy = join(directory, 'DocumentSnapshotStore.java')
writeFileSync(copy, source)
execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', directory,
  copy, join(sources, 'DocumentRevision.java'), join(import.meta.dirname, 'document-provider-host/DocumentSnapshotCommitRace.java')],
{ stdio: 'inherit', windowsHide: true, timeout: 60000 })
const result = spawnSync('java', ['-cp', directory, 'com.minnnng.dsh_android.DocumentSnapshotCommitRace', join(directory, 'fixture')],
  { encoding: 'utf8', windowsHide: true, timeout: 30000 })
writeFileSync(join(directory, 'result.json'), JSON.stringify({ expectedEviction, status: result.status,
  signal: result.signal, error: result.error?.message, stdout: result.stdout, stderr: result.stderr }, null, 2))
assert.equal(result.error, undefined)
assert.equal(result.signal, null, 'A terminated child is not a race result')
if (expectedEviction) {
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /Committed snapshot A was evicted by double-counted reservation/)
} else assert.equal(result.status, 0, result.stderr)
process.stdout.write(`${expectedEviction ? 'Expected eviction reproduced' : 'Concurrent commit retained both files'}: ${directory}\n`)
