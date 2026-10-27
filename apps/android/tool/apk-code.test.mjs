import assert from 'node:assert/strict'
import test from 'node:test'
import { analyzeDex, analyzeElf, ApkCodeParseError } from '../runtime/apk-code.mjs'

function uleb(value) {
  const bytes = []
  do { const part = value % 128; value = Math.floor(value / 128); bytes.push(part | (value ? 128 : 0)) } while (value)
  return Buffer.from(bytes)
}

function dexFixture({ version = '039', big = false, strings = ['Lsample/App;', 'Ljava/lang/Object;', 'DexClassLoader'], trailing = 0 } = {}) {
  const headerSize = version === '041' ? 120 : 112
  const counts = [strings.length, Math.min(2, strings.length), 1, 1, 1, 1], strides = [4, 4, 12, 8, 8, 32]
  let at = headerSize
  const tables = counts.map((count, i) => { const offset = at; at += count * strides[i]; return { count, offset } })
  const dataOffset = at, offsets = [], chunks = []
  for (const text of strings) {
    const encoded = Buffer.from(text)
    const bytes = Buffer.concat([uleb(text.length), encoded, Buffer.from([0])])
    offsets.push(at); chunks.push({ at, bytes }); at += bytes.length
  }
  const mapOffset = (at + 3) & ~3
  const entries = [{ type: 0, count: 1, offset: 0 }, ...tables.map((table, i) => ({ type: i + 1, ...table })),
    { type: 0x2002, count: strings.length, offset: dataOffset }, { type: 0x1000, count: 1, offset: mapOffset }]
  const fileSize = mapOffset + 4 + entries.length * 12
  const buffer = Buffer.alloc(fileSize + trailing)
  buffer.write(`dex\n${version}\0`, 0, 'ascii')
  const put = (offset, value) => big ? buffer.writeUInt32BE(value, offset) : buffer.writeUInt32LE(value, offset)
  const short = (offset, value) => big ? buffer.writeUInt16BE(value, offset) : buffer.writeUInt16LE(value, offset)
  put(32, fileSize); put(36, headerSize); put(40, 0x12345678); put(52, mapOffset)
  tables.forEach((table, i) => { put(56 + i * 8, table.count); put(60 + i * 8, table.offset) })
  put(104, fileSize - dataOffset); put(108, dataOffset)
  if (version === '041') { put(112, buffer.length); put(116, 0) }
  offsets.forEach((offset, i) => put(tables[0].offset + i * 4, offset))
  for (let i = 0; i < tables[1].count; i++) put(tables[1].offset + i * 4, i)
  for (const chunk of chunks) chunk.bytes.copy(buffer, chunk.at)
  put(mapOffset, entries.length)
  entries.forEach((entry, i) => {
    const offset = mapOffset + 4 + i * 12
    short(offset, entry.type); put(offset + 4, entry.count); put(offset + 8, entry.offset)
  })
  return { buffer, tables, offsets, mapOffset, put, short }
}

function elfFixture({ bits = 64, big = false, sections = true, extended = false } = {}) {
  const wide = bits === 64, headerSize = wide ? 64 : 52, phStride = wide ? 56 : 32, shStride = wide ? 64 : 40
  const sectionOffset = 0x300, sectionCount = sections ? 5 : 0
  const buffer = Buffer.alloc(sections ? sectionOffset + sectionCount * shStride : 0x280)
  buffer.set([0x7f, 69, 76, 70, wide ? 2 : 1, big ? 2 : 1, 1])
  const put16 = (offset, value) => big ? buffer.writeUInt16BE(value, offset) : buffer.writeUInt16LE(value, offset)
  const put32 = (offset, value) => big ? buffer.writeUInt32BE(value, offset) : buffer.writeUInt32LE(value, offset)
  const word = (offset, value) => wide
    ? big ? buffer.writeBigUInt64BE(BigInt(value), offset) : buffer.writeBigUInt64LE(BigInt(value), offset)
    : put32(offset, Number(value))
  const base = wide ? 0x1234567800000000n : 0x10000n
  put16(16, 3); put16(18, wide ? 183 : 40); put32(20, 1)
  word(24, base + 0x240n); word(wide ? 32 : 28, headerSize); word(wide ? 40 : 32, sections ? sectionOffset : 0)
  put16(wide ? 52 : 40, headerSize); put16(wide ? 54 : 42, phStride)
  put16(wide ? 56 : 44, extended ? 65535 : 2); put16(wide ? 58 : 46, sections ? shStride : 0)
  put16(wide ? 60 : 48, extended ? 0 : sectionCount); put16(wide ? 62 : 50, sections ? extended ? 65535 : 1 : 0)
  function program(index, type, offset, size) {
    const at = headerSize + index * phStride
    put32(at, type); put32(at + (wide ? 4 : 24), 4)
    word(at + (wide ? 8 : 4), offset); word(at + (wide ? 16 : 8), base + BigInt(offset))
    word(at + (wide ? 32 : 16), size); word(at + (wide ? 40 : 20), size)
  }
  const strings = Buffer.from('\0libc.so\0libsample.so\0JNI_OnLoad\0')
  strings.copy(buffer, 0x100)
  const stringIndex = name => strings.indexOf(Buffer.from(name))
  const dynamicStride = wide ? 16 : 8
  const dynamic = [[5n, base + 0x100n], [10n, BigInt(strings.length)], [1n, BigInt(stringIndex('libc.so'))],
    [14n, BigInt(stringIndex('libsample.so'))], [0n, 0n]]
  dynamic.forEach(([tag, value], i) => { word(0x180 + i * dynamicStride, tag); word(0x180 + i * dynamicStride + (wide ? 8 : 4), value) })
  program(0, 1, 0, buffer.length); program(1, 2, 0x180, dynamic.length * dynamicStride)
  const names = Buffer.from('\0.shstrtab\0.dynstr\0.dynsym\0.dynamic\0'); names.copy(buffer, 0x240)
  const symbolStride = wide ? 24 : 16, symbol = 0x200 + symbolStride
  put32(symbol, stringIndex('JNI_OnLoad')); buffer[symbol + (wide ? 4 : 12)] = 0x12
  put16(symbol + (wide ? 6 : 14), 3); word(symbol + (wide ? 8 : 4), base + 0x240n); word(symbol + (wide ? 16 : 8), 8)
  function section(index, name, type, offset, size, link = 0, stride = 0) {
    const at = sectionOffset + index * shStride
    put32(at, name ? names.indexOf(Buffer.from(name)) : 0); put32(at + 4, type)
    word(at + (wide ? 24 : 16), offset); word(at + (wide ? 32 : 20), size)
    put32(at + (wide ? 40 : 24), link); word(at + (wide ? 56 : 36), stride)
  }
  if (sections) {
    section(0, '', 0, 0, extended ? sectionCount : 0, extended ? 1 : 0)
    if (extended) put32(sectionOffset + (wide ? 44 : 28), 2)
    section(1, '.shstrtab', 3, 0x240, names.length)
    section(2, '.dynstr', 3, 0x100, strings.length)
    section(3, '.dynsym', 11, 0x200, symbolStride * 2, 2, symbolStride)
    section(4, '.dynamic', 6, 0x180, dynamic.length * dynamicStride, 2, dynamicStride)
  }
  return { buffer, put16, put32, word, headerSize, sectionOffset, shStride, phStride, dynamicStride, base }
}

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
