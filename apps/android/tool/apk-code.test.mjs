import assert from 'node:assert/strict'
import test from 'node:test'
import { analyzeDex, analyzeElf, ApkCodeParseError } from '../runtime/apk-code.mjs'

import { dexFixture, elfFixture } from './fixtures/apk-code-fixtures.mjs'

test('DEX metadata preserves offsets and counts without claiming executable validation or packing detection', () => {
  const fixture = dexFixture(), result = analyzeDex(fixture.buffer)
  assert.deepEqual(result.counts, { strings: 3, types: 2, protos: 1, fields: 1, methods: 1, classes: 1 })
  assert.equal(result.header.version, '039')
  assert.equal(result.header.fileSize, fixture.buffer.length)
  assert.equal(result.mapEntries.length, 9)
  assert.deepEqual(result.descriptors.map(value => [value.typeIndex, value.stringIndex, value.text]),
    [[0, 0, 'Lsample/App;'], [1, 1, 'Ljava/lang/Object;']])
  assert.equal(result.markerStrings[0].text, 'DexClassLoader')
  assert.equal(result.coverage.integrityChecks, 'not-verified')
  assert.equal(result.coverage.bytecode, 'not-inspected')
  assert.equal(Object.hasOwn(result, 'packed'), false)
  assert.equal(Object.hasOwn(result, 'valid'), false)
})

test('DEX reverse endian and experimental container retain separate logical versus physical lengths', () => {
  const big = analyzeDex(dexFixture({ big: true }).buffer)
  assert.equal(big.header.endian, 'big'); assert.equal(big.counts.methods, 1)
  const container = dexFixture({ version: '041', trailing: 120 })
  const result = analyzeDex(container.buffer)
  assert.equal(result.header.headerSize, 120)
  assert.equal(result.header.containerSize, container.buffer.length)
  assert.equal(result.coverage.remainingContainerBytes, 120)
  assert.equal(result.coverage.logicalHeadersInspected, 1)
})

test('DEX rejects unsupported magic/version, declared sizes, indices, table overlap and malicious map counts', () => {
  const cases = [
    fixture => { fixture.buffer[0] = 0 },
    fixture => { fixture.buffer.write('999', 4) },
    fixture => fixture.put(32, fixture.buffer.length - 1),
    fixture => fixture.put(36, 113),
    fixture => fixture.put(40, 0),
    fixture => fixture.put(56, 0xffffffff),
    fixture => fixture.put(60, 0xfffffff0),
    fixture => fixture.put(68, fixture.tables[0].offset),
    fixture => fixture.put(fixture.tables[1].offset, 999),
    fixture => fixture.put(fixture.tables[0].offset, fixture.buffer.length),
    fixture => fixture.put(fixture.mapOffset, 0xffffffff),
    fixture => fixture.short(fixture.mapOffset + 4 + 12, 0),
    fixture => fixture.put(fixture.mapOffset + 4 + 12 + 4, 4),
    fixture => fixture.put(108, 112),
  ]
  for (const mutate of cases) {
    const fixture = dexFixture(); mutate(fixture)
    assert.throws(() => analyzeDex(fixture.buffer), error => error instanceof ApkCodeParseError && error.format === 'dex')
  }
  assert.throws(() => analyzeDex(Buffer.alloc(111)), error => error.code === 'apk-code/bounds')
})

test('DEX MUTF-8 malformed lengths, continuations and ULEB overflow fail explicitly', () => {
  for (const bytes of [[0x80, 0x80, 0x80, 0x80, 0x10], [1, 0xe0, 0x80, 0x80], [1, 0xc2, 0x41], [1, 65, 66, 0], [2, 65, 0]]) {
    const fixture = dexFixture(); fixture.buffer.set(bytes, fixture.offsets[0])
    assert.throws(() => analyzeDex(fixture.buffer), ApkCodeParseError)
  }
  const fixture = dexFixture({ strings: ['abc', 'def'] })
  fixture.buffer.set([1, 0xc0, 0x80, 0], fixture.offsets[0])
  assert.equal(analyzeDex(fixture.buffer).descriptors[0].text, '\0')
})

test('DEX long strings and sample limits are explicit, and Uint8Array subviews use the supplied bounds', () => {
  const fixture = dexFixture({ strings: ['A'.repeat(5000), 'DexClassLoader'] })
  const result = analyzeDex(fixture.buffer, { sampleLimit: 1 })
  assert.equal(result.descriptors[0].truncated, true)
  assert.equal(result.coverage.truncatedStrings, 1)
  assert.equal(result.descriptors[0].text.length, 512)
  assert.equal(result.coverage.descriptorSamplesTruncated, true)
  const padded = Buffer.concat([Buffer.alloc(17), dexFixture().buffer, Buffer.alloc(8)])
  const view = new Uint8Array(padded.buffer, padded.byteOffset + 17, padded.length - 25)
  assert.equal(analyzeDex(view).counts.strings, 3)
  assert.deepEqual(analyzeDex(dexFixture().buffer, { sampleLimit: 0 }).descriptors, [])
  assert.throws(() => analyzeDex(fixture.buffer, { sampleLimit: 65 }), ApkCodeParseError)
})

test('DEX sample budgets report unscanned strings and marker truncation, and accept MUTF-8 surrogate pairs', () => {
  const fixture = dexFixture({ strings: Array.from({ length: 513 }, (_, i) => `DexClassLoader${i}`) })
  const result = analyzeDex(fixture.buffer, { sampleLimit: 1 })
  assert.equal(result.coverage.stringsScanned, 512)
  assert.equal(result.coverage.stringScanTruncated, true)
  assert.equal(result.coverage.markerMatchesObserved, 512)
  assert.equal(result.coverage.markerSamplesTruncated, true)
  const surrogate = dexFixture({ strings: ['abcdef', 'Lx/A;'] })
  surrogate.buffer.set([2, 0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80, 0], surrogate.offsets[0])
  assert.equal(analyzeDex(surrogate.buffer).descriptors[0].text, '😀')
})

test('ELF 32/64-bit and both byte orders expose exact architectures, symbols, dependencies and high addresses', () => {
  for (const bits of [32, 64]) for (const big of [false, true]) {
    const fixture = elfFixture({ bits, big }), result = analyzeElf(fixture.buffer)
    assert.equal(result.header.bits, bits)
    assert.equal(result.header.endian, big ? 'big' : 'little')
    assert.equal(result.header.architecture, bits === 64 ? 'AArch64' : 'ARM')
    assert.equal(result.header.entry, `0x${(fixture.base + 0x240n).toString(16)}`)
    assert.equal(result.programHeaders[0].address, `0x${fixture.base.toString(16)}`)
    assert.equal(result.sections[3].name, '.dynsym')
    assert.equal(result.symbols.totalCount, 2)
    assert.equal(result.symbols.items[0].name, 'JNI_OnLoad')
    assert.equal(result.symbols.items[0].binding, 1)
    assert.equal(result.symbols.items[0].type, 2)
    assert.deepEqual(result.dependencies.items.map(item => item.name), ['libc.so'])
    assert.equal(result.dependencies.soname.name, 'libsample.so')
    assert.equal(result.symbols.truncated, false)
    assert.doesNotThrow(() => JSON.stringify(result))
  }
})

test('ELF extended header counts are resolved from section zero', () => {
  const result = analyzeElf(elfFixture({ extended: true }).buffer)
  assert.equal(result.header.sectionCount, 5)
  assert.equal(result.header.programCount, 2)
  assert.equal(result.header.sectionNameIndex, 1)
})

test('ELF sectionless libraries resolve dependencies through PT_DYNAMIC and PT_LOAD, without inventing symbols', () => {
  const result = analyzeElf(elfFixture({ sections: false }).buffer)
  assert.equal(result.symbols.available, false)
  assert.match(result.symbols.unavailableReason, /not reconstructed/)
  assert.equal(result.dependencies.source, 'program-header')
  assert.equal(result.dependencies.items[0].name, 'libc.so')
  assert.equal(result.sections.length, 0)
})

test('ELF rejects unsafe 64-bit offsets, multiplication bounds, bad linked strings, wrong strides and sizes', () => {
  const cases = [
    fixture => { fixture.buffer[0] = 0 },
    fixture => { fixture.buffer[4] = 3 },
    fixture => fixture.word(40, 0xffffffffffffffffn),
    fixture => fixture.put16(60, 65534),
    fixture => fixture.put16(62, 9),
    fixture => fixture.put16(54, 1),
    fixture => fixture.word(fixture.headerSize + 32, fixture.buffer.length + 1),
    fixture => fixture.word(fixture.headerSize + 40, 1),
    fixture => fixture.put32(fixture.sectionOffset + 3 * fixture.shStride + 40, 99),
    fixture => fixture.word(fixture.sectionOffset + 3 * fixture.shStride + 56, 16),
    fixture => fixture.put32(0x200 + 24, 0xffffffff),
    fixture => fixture.word(0x180 + 2 * fixture.dynamicStride + 8, 9999),
    fixture => fixture.word(0x180 + 4 * fixture.dynamicStride, 1),
    fixture => fixture.word(fixture.sectionOffset + 4 * fixture.shStride + 56, 1),
  ]
  for (const mutate of cases) {
    const fixture = elfFixture(); mutate(fixture)
    assert.throws(() => analyzeElf(fixture.buffer), error => error instanceof ApkCodeParseError && error.format === 'elf')
  }
})

test('ELF limited samples and unavailable dynamic strings stay explicit', () => {
  const result = analyzeElf(elfFixture().buffer, { sampleLimit: 0 })
  assert.deepEqual(result.programHeaders, [])
  assert.deepEqual(result.sections, [])
  assert.deepEqual(result.symbols.items, [])
  assert.equal(result.symbols.truncated, true)
  assert.equal(result.dependencies.truncated, true)
  const fixture = elfFixture({ sections: false })
  fixture.word(0x180 + 8, 0xffffffffffffffffn)
  const missing = analyzeElf(fixture.buffer)
  assert.equal(missing.dependencies.available, false)
  assert.match(missing.dependencies.unavailableReason, /file-backed/)
})

test('ELF non-UTF-8 names preserve bytes rather than producing fabricated replacement text', () => {
  const fixture = elfFixture(); fixture.buffer[0x100 + 1] = 0xff
  const result = analyzeElf(fixture.buffer)
  assert.equal(result.dependencies.items[0].name, null)
  assert.equal(result.dependencies.items[0].nameHex, 'ff6962632e736f')
})

test('ELF very long names and symbol tables stop at the explicit byte and entry scan budgets', () => {
  const fixture = elfFixture()
  const longNames = Buffer.concat([fixture.buffer, Buffer.alloc(32768)])
  const stringsAt = 0x1000, stringsSize = 6000, stringSection = fixture.sectionOffset + 2 * fixture.shStride
  longNames.fill(65, stringsAt, stringsAt + stringsSize - 1)
  longNames.writeBigUInt64LE(BigInt(stringsAt), stringSection + 24)
  longNames.writeBigUInt64LE(BigInt(stringsSize), stringSection + 32)
  const result = analyzeElf(longNames)
  assert.equal(result.dependencies.items[0].name, null)
  assert.equal(result.dependencies.items[0].truncated, true)
  assert.equal(result.dependencies.truncated, true)
  const manySymbols = Buffer.concat([fixture.buffer, Buffer.alloc(24 * 5000 + 4096)])
  const symbolSection = fixture.sectionOffset + 3 * fixture.shStride
  manySymbols.writeBigUInt64LE(4096n, symbolSection + 24)
  manySymbols.writeBigUInt64LE(24n * 5000n, symbolSection + 32)
  const bounded = analyzeElf(manySymbols)
  assert.equal(bounded.symbols.totalCount, 5000)
  assert.equal(bounded.symbols.scannedCount, 4096)
  assert.equal(bounded.symbols.truncated, true)
})

test('truncated complete binaries and deterministic malformed headers never leak buffer RangeErrors', () => {
  for (const [analyze, original] of [[analyzeDex, dexFixture().buffer], [analyzeElf, elfFixture().buffer]]) {
    for (let size = 0; size < original.length; size += 7) {
      assert.throws(() => analyze(original.subarray(0, size)), ApkCodeParseError)
    }
    let state = 0x12345678
    for (let i = 0; i < 256; i++) {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0
      const mutated = Buffer.from(original), offset = state % Math.min(120, mutated.length)
      mutated[offset] ^= (state >>> 24) || 255
      try { JSON.stringify(analyze(mutated)) }
      catch (error) { assert.ok(error instanceof ApkCodeParseError, `${offset}: ${error.stack}`) }
    }
  }
})

test('input and options limits reject before unbounded parsing', () => {
  for (const analyze of [analyzeDex, analyzeElf]) {
    assert.throws(() => analyze('binary'), error => error.code === 'apk-code/invalid')
    assert.throws(() => analyze(Buffer.alloc(128 * 1024 * 1024 + 1)), error => error.code === 'apk-code/limit')
    assert.throws(() => analyze(Buffer.alloc(200), { sampleLimit: -1 }), error => error.code === 'apk-code/invalid')
    assert.throws(() => analyze(Buffer.alloc(200), { unknown: true }), error => error.code === 'apk-code/invalid')
  }
})

test('ELF input above 64 MiB retains bounded metadata sampling under the 128 MiB cap', () => {
  const bytes = Buffer.alloc(64 * 1024 * 1024 + 1)
  elfFixture().buffer.copy(bytes)
  const result = analyzeElf(bytes, { sampleLimit: 1 })
  assert.equal(result.header.architecture, 'AArch64')
  assert.equal(result.programHeaders.length, 1)
  assert.equal(result.sections.length, 1)
  assert.equal(result.symbols.items.length, 1)
  assert.equal(result.coverage.programSamplesTruncated, true)
})
