import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'

/**
 * Check real attachment results using synthetic DEX/ELF bytes, not directory counts.
 * @param {object} services - upload(name, bytes) references the fixture in the current Session;
 * call(args) invokes android_attachments through the caller's real ToolRuntime/PTC path.
 * @returns {Promise<object>} Body hashes and explicit paging/limit evidence for the device report.
 */
export async function runApkCodeAcceptance({ upload, call }) {
  const fixture = JSON.parse(await readFile(new URL('./apk-code-fixture.json', import.meta.url), 'utf8'))
  assert.equal(fixture.kind, 'synthetic-apk-code-v1')
  const decode = entry => {
    const bytes = Buffer.from(entry.base64, 'base64')
    assert.equal(bytes.length, entry.bytes)
    assert.equal(createHash('sha256').update(bytes).digest('hex'), entry.sha256)
    return bytes
  }
  const reference = await upload('synthetic-code.apk', decode(fixture))
  const identity = { action: 'inspect_apk', attachmentId: reference.attachmentId, name: reference.name }
  assert.equal(reference.attachmentId, `sha256:${fixture.sha256}`)
  const body = (page, part, name) => {
    assert.equal(page.part, part)
    assert.equal(page.verified, true)
    assert.equal(page.results.length, 1)
    assert.equal(page.coverage.selectedEntryContentsOnly, true)
    assert.equal(page.coverage.apkSignaturesVerified, false)
    assert.equal(page.coverage.codeExecuted, false)
    const result = page.results[0]
    assert.equal(result.name, name)
    assert.equal(result.sha256, fixture.entries[name].sha256)
    assert.equal(result.bytes, fixture.entries[name].bytes)
    assert.equal(result.crc32Verified, true)
    assert.ok(result.analysis, `Missing decoded ${part} body`)
    return result.analysis
  }
  const dexHashes = [], elfHashes = []
  for (const [offset, name, descriptor, marker] of [
    [0, 'classes.dex', 'Lsample/App;', 'DexClassLoader'],
    [1, 'classes2.dex', 'Lsample/Second;', 'loadLibrary'],
  ]) {
    const page = await call({ ...identity, part: 'dex', offset, limit: 1, sampleLimit: 2 })
    assert.equal(page.matchingEntries, 2)
    assert.equal(page.nextOffset, offset === 0 ? 1 : null)
    const analysis = body(page, 'dex', name)
    assert.equal(analysis.format, 'dex')
    assert.equal(analysis.header.version, '039')
    assert.deepEqual(analysis.counts, { strings: 3, types: 2, protos: 1, fields: 1, methods: 1, classes: 1 })
    assert.equal(analysis.descriptors[0].text, descriptor)
    assert.equal(analysis.markerStrings[0].text, marker)
    assert.equal(analysis.coverage.bytecode, 'not-inspected')
    assert.equal(analysis.coverage.integrityChecks, 'not-verified')
    dexHashes.push(page.results[0].sha256)
  }
  for (const [offset, name, architecture, bits] of [
    [0, 'lib/arm64-v8a/libsample.so', 'AArch64', 64],
    [1, 'lib/armeabi-v7a/libsample.so', 'ARM', 32],
  ]) {
    const page = await call({ ...identity, part: 'native', offset, limit: 1, sampleLimit: 2 })
    assert.equal(page.matchingEntries, 2)
    assert.equal(page.nextOffset, offset === 0 ? 1 : null)
    const analysis = body(page, 'native', name)
    assert.equal(analysis.format, 'elf')
    assert.equal(analysis.header.architecture, architecture)
    assert.equal(analysis.header.bits, bits)
    assert.equal(analysis.dependencies.available, true)
    assert.deepEqual(analysis.dependencies.items.map(item => item.name), ['libc.so'])
    assert.equal(analysis.dependencies.soname.name, 'libsample.so')
    assert.equal(analysis.symbols.items[0].name, 'JNI_OnLoad')
    assert.equal(analysis.coverage.code, 'not-inspected')
    elfHashes.push(page.results[0].sha256)
  }
  const metadata = await call({ ...identity, part: 'dex', sampleLimit: 0 })
  const metadataDex = body(metadata, 'dex', 'classes.dex')
  assert.deepEqual(metadataDex.descriptors, [])
  assert.deepEqual(metadataDex.markerStrings, [])
  assert.equal(metadataDex.counts.classes, 1)
  const bounded = await upload('synthetic-oversize.apk', decode(fixture.oversized))
  await assert.rejects(call({ action: 'inspect_apk', attachmentId: bounded.attachmentId,
    name: bounded.name, part: 'dex' }), /APK entry exceeds byte limit/u)
  await assert.rejects(call({ ...identity, part: 'native', limit: 5 }), /limit/u)
  const retry = await call({ ...identity, part: 'native', offset: 1, limit: 1, sampleLimit: 0 })
  const retryElf = body(retry, 'native', 'lib/armeabi-v7a/libsample.so')
  assert.equal(retryElf.header.architecture, 'ARM')
  assert.deepEqual(retryElf.symbols.items, [])
  assert.equal(retry.nextOffset, null)
  return { fixture: fixture.kind, fixtureSha256: fixture.sha256, fixtureBytes: fixture.bytes,
    dexBodySha256: dexHashes, elfBodySha256: elfHashes, bodyCrcVerified: true,
    dexPagination: true, elfPagination: true, metadataOnly: true,
    oversizedDecodedEntryRejected: true, oversizedPageRejected: true, recoveredAfterRejection: true,
    codeExecuted: false, apkSignaturesVerified: false }
}
