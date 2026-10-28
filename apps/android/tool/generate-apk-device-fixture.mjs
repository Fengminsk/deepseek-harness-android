/** Reproduce the small synthetic APK used by device checks; no user attachment is read. */
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dexFixture, elfFixture } from './fixtures/apk-code-fixtures.mjs'

const args = process.argv.slice(2)
if (args.some(arg => arg !== '--check')) throw new Error('Only --check is supported')
const staged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const { zipSync } = staged('fflate')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const golden = JSON.parse(await readFile(new URL('./fixtures/apk-manifest-aapt2.json', import.meta.url), 'utf8'))
const contents = {
  'AndroidManifest.xml': Buffer.from(golden.base64, 'base64'),
  'classes.dex': dexFixture().buffer,
  'classes2.dex': dexFixture({ strings: ['Lsample/Second;', 'Ljava/lang/Object;', 'loadLibrary'] }).buffer,
  'lib/arm64-v8a/libsample.so': elfFixture().buffer,
  'lib/armeabi-v7a/libsample.so': elfFixture({ bits: 32 }).buffer,
}
const options = { level: 6, mtime: new Date(1980, 0, 1, 0, 0, 0) }
const archive = Buffer.from(zipSync(contents, options))
const oversized = Buffer.from(zipSync({ 'AndroidManifest.xml': contents['AndroidManifest.xml'],
  'classes.dex': contents['classes.dex'] }, options))
// Only the generated central-directory declaration is forged. The input remains
// tiny; rejection must happen before any 128 MiB allocation or decompression.
const end = oversized.length - 22, directory = oversized.readUInt32LE(end + 16)
let cursor = directory, changed = false
while (cursor < end) {
  if (oversized.readUInt32LE(cursor) !== 0x02014b50) throw new Error('Generated ZIP directory changed')
  const nameLength = oversized.readUInt16LE(cursor + 28)
  const name = oversized.toString('utf8', cursor + 46, cursor + 46 + nameLength)
  if (name === 'classes.dex') { oversized.writeUInt32LE(128 * 1024 * 1024 + 1, cursor + 24); changed = true }
  cursor += 46 + nameLength + oversized.readUInt16LE(cursor + 30) + oversized.readUInt16LE(cursor + 32)
}
if (!changed || cursor !== end) throw new Error('Generated DEX record was not found')
const fixture = { kind: 'synthetic-apk-code-v1', description: 'Synthetic metadata only, not an installable or original user APK.',
  sha256: sha256(archive), bytes: archive.length, base64: archive.toString('base64'),
  entries: Object.fromEntries(Object.entries(contents).map(([name, bytes]) => [name, { bytes: bytes.length, sha256: sha256(bytes) }])),
  oversized: { sha256: sha256(oversized), bytes: oversized.length, base64: oversized.toString('base64'), declaredDecodedBytes: 128 * 1024 * 1024 + 1 } }
const destination = new URL('./device-runtime-acceptance/apk-code-fixture.json', import.meta.url)
const source = JSON.stringify(fixture, null, 2) + '\n'
if (args.includes('--check')) {
  if (await readFile(destination, 'utf8') !== source) throw new Error('APK device fixture differs from its shared builders')
} else await writeFile(destination, source)
