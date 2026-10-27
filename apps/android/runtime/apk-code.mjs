/** Bounded static DEX/ELF metadata readers. No bytecode, native code or decompression is executed. */
const MAX_BYTES = 128 * 1024 * 1024
const MAX_STRING_BYTES = 4096
const MAX_NAME_UNITS = 512
const MAX_SCAN = 4096
const DEX_MARKERS = ['DexClassLoader', 'InMemoryDexClassLoader', 'loadLibrary', 'JNI_OnLoad', 'registerNatives']

/** A malformed, unsupported or oversized binary cannot be treated as evidence of packing. */
export class ApkCodeParseError extends Error {
  constructor(format, code, message, offset = null) {
    super(`${format}: ${message}`)
    this.name = 'ApkCodeParseError'
    this.code = `apk-code/${code}`
    this.format = format
    this.offset = offset
  }
}

function reader(input, format, options) {
  const fail = (code, message, offset) => { throw new ApkCodeParseError(format, code, message, offset) }
  if (!(input instanceof Uint8Array)) fail('invalid', 'expected Buffer or Uint8Array')
  if (input.byteLength > MAX_BYTES) fail('limit', 'binary exceeds 128 MiB inspection limit')
  if (!options || typeof options !== 'object' || Array.isArray(options)
    || Object.keys(options).some(key => key !== 'sampleLimit')) fail('invalid', 'invalid inspection options')
  const sampleLimit = options.sampleLimit === undefined ? 24 : options.sampleLimit
  if (!Number.isInteger(sampleLimit) || sampleLimit < 0 || sampleLimit > 64) fail('invalid', 'sampleLimit must be 0–64')
  const bytes = Buffer.from(input.buffer, input.byteOffset, input.byteLength)
  const range = (offset, size, label = 'data') => {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size) || offset < 0 || size < 0
      || offset > bytes.length || size > bytes.length - offset) fail('bounds', `${label} exceeds binary bounds`, offset)
  }
  const table = (offset, count, stride, label) => {
    if (!Number.isSafeInteger(count) || count < 0 || !Number.isSafeInteger(stride) || stride < 1
      || count > Math.floor(bytes.length / stride)) fail('bounds', `${label} count exceeds binary bounds`, offset)
    range(offset, count * stride, label)
  }
  const r = { bytes, fail, range, table, sampleLimit, little: true }
  r.u16 = offset => { range(offset, 2); return r.little ? bytes.readUInt16LE(offset) : bytes.readUInt16BE(offset) }
  r.u32 = offset => { range(offset, 4); return r.little ? bytes.readUInt32LE(offset) : bytes.readUInt32BE(offset) }
  r.u64 = offset => { range(offset, 8); return r.little ? bytes.readBigUInt64LE(offset) : bytes.readBigUInt64BE(offset) }
  r.number = (value, offset) => {
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) fail('bounds', '64-bit value cannot be represented as a file offset', offset)
    return Number(value)
  }
  return r
}

function dexString(r, offset, dataStart, dataEnd) {
  if (offset < dataStart || offset >= dataEnd) r.fail('bounds', 'string data offset outside data region', offset)
  let cursor = offset, declared = 0
  for (let i = 0; i < 5; i++) {
    if (cursor >= dataEnd) r.fail('bounds', 'truncated string length', cursor)
    const byte = r.bytes[cursor++]
    if (i === 4 && byte > 15) r.fail('invalid', 'ULEB128 exceeds 32 bits', cursor - 1)
    declared += (byte & 127) * 2 ** (i * 7)
    if (!(byte & 128)) break
  }
  const start = cursor, units = []
  while (cursor < dataEnd && cursor - start < MAX_STRING_BYTES) {
    const byte = r.bytes[cursor++]
    if (byte === 0) {
      if (units.length !== declared) r.fail('invalid', 'MUTF-8 length disagrees with UTF-16 length', offset)
      return { text: String.fromCharCode(...units.slice(0, MAX_NAME_UNITS)), truncated: units.length > MAX_NAME_UNITS, offset }
    }
    let unit = byte
    if (byte >= 128) {
      const length = byte >= 0xc0 && byte <= 0xdf ? 2 : byte >= 0xe0 && byte <= 0xef ? 3 : 0
      if (!length) r.fail('invalid', 'invalid MUTF-8 lead byte', cursor - 1)
      if (length - 1 > dataEnd - cursor) r.fail('bounds', 'truncated MUTF-8 sequence', cursor - 1)
      unit = byte & (length === 2 ? 31 : 15)
      for (let i = 1; i < length; i++) {
        const next = r.bytes[cursor++]
        if ((next & 0xc0) !== 0x80) r.fail('invalid', 'invalid MUTF-8 continuation', cursor - 1)
        unit = unit * 64 + (next & 63)
      }
      if ((length === 2 && unit < 128 && unit !== 0) || (length === 3 && unit < 2048)) {
        r.fail('invalid', 'overlong MUTF-8 sequence', cursor - length)
      }
    }
    units.push(unit)
    if (units.length > declared) r.fail('invalid', 'string exceeds declared UTF-16 length', offset)
  }
  if (cursor >= dataEnd) r.fail('bounds', 'unterminated MUTF-8 string', offset)
  return { text: String.fromCharCode(...units.slice(0, MAX_NAME_UNITS)), truncated: true, offset }
}

/**
 * Read DEX headers, fixed table ranges and bounded descriptor/string samples.
 * @param input - Complete uncompressed DEX bytes, at most 128 MiB; ZIP limits belong to the caller.
 * @param options - sampleLimit (0–64, default 24); scan budgets remain fixed.
 * @returns JSON metadata and explicit coverage; this is not a complete bytecode or integrity validator.
 * @throws ApkCodeParseError for invalid ranges, unsupported formats or exceeded input limits.
 */
export function analyzeDex(input, options = {}) {
  const r = reader(input, 'dex', options)
  r.range(0, 112, 'DEX header')
  if (r.bytes.subarray(0, 4).toString('hex') !== '6465780a' || r.bytes[7] !== 0) r.fail('invalid', 'invalid DEX magic', 0)
  const version = r.bytes.toString('ascii', 4, 7)
  if (!['035', '037', '038', '039', '040', '041'].includes(version)) r.fail('unsupported', `unsupported DEX version ${version}`, 4)
  const endian = r.u32(40)
  if (![0x12345678, 0x78563412].includes(endian)) r.fail('invalid', 'invalid DEX endian tag', 40)
  r.little = endian === 0x12345678
  const headerSize = r.u32(36), fileSize = r.u32(32), container = version === '041'
  if (headerSize !== (container ? 120 : 112)) r.fail('invalid', 'invalid DEX header size', 36)
  r.range(0, headerSize, 'DEX header')
  if (fileSize < headerSize || fileSize > r.bytes.length || (!container && fileSize !== r.bytes.length)) {
    r.fail('bounds', 'DEX file size disagrees with complete input', 32)
  }
  const containerSize = container ? r.u32(112) : fileSize
  if (container && (containerSize !== r.bytes.length || r.u32(116) !== 0)) r.fail('invalid', 'expected a complete DEX container starting at header zero', 112)
  const tables = {}, counts = {}, regions = [{ offset: 0, size: headerSize }]
  for (const [index, name, stride] of [[0, 'strings', 4], [1, 'types', 4], [2, 'protos', 12],
    [3, 'fields', 8], [4, 'methods', 8], [5, 'classes', 32]]) {
    const count = r.u32(56 + index * 8), offset = r.u32(60 + index * 8)
    if ((!count && offset) || (count && (offset < headerSize || offset % 4))) r.fail('invalid', `invalid ${name} table offset`, 60 + index * 8)
    if (['types', 'protos'].includes(name) && count > 65535) r.fail('invalid', `${name} exceeds DEX index limit`, 56 + index * 8)
    r.table(offset, count, stride, name)
    tables[name] = { count, offset, stride }; counts[name] = count
    if (count) regions.push({ offset, size: count * stride })
  }
  regions.sort((a, b) => a.offset - b.offset)
  for (let i = 1; i < regions.length; i++) {
    if (regions[i].offset < regions[i - 1].offset + regions[i - 1].size) r.fail('invalid', 'overlapping fixed DEX tables', regions[i].offset)
  }
  const linkSize = r.u32(44), linkOffset = r.u32(48), dataSize = r.u32(104), dataOffset = r.u32(108), mapOffset = r.u32(52)
  if ((!linkSize && linkOffset) || (linkSize && linkOffset < headerSize)) r.fail('invalid', 'invalid link section', 44)
  r.range(linkOffset, linkSize, 'link section')
  if (!container) {
    if ((!dataSize && dataOffset) || (dataSize && (dataOffset < headerSize || dataOffset % 4 || dataSize % 4))) r.fail('invalid', 'invalid data section', 104)
    r.range(dataOffset, dataSize, 'data section')
    const last = regions.at(-1)
    if (dataSize && dataOffset < last.offset + last.size) r.fail('invalid', 'data overlaps fixed DEX tables', dataOffset)
  }
  const dataStart = container ? headerSize : dataOffset, dataEnd = container ? containerSize : dataOffset + dataSize
  if (!mapOffset || mapOffset % 4 || mapOffset < dataStart || mapOffset + 4 > dataEnd) r.fail('bounds', 'invalid map offset', 52)
  const mapCount = r.u32(mapOffset)
  if (!mapCount || mapCount > 256) r.fail('limit', 'DEX map count outside inspection limit', mapOffset)
  r.table(mapOffset + 4, mapCount, 12, 'map entries')
  if (mapCount * 12 + 4 > dataEnd - mapOffset) r.fail('bounds', 'map exceeds data section', mapOffset)
  const mapEntries = [], kinds = new Set(); let previous = -1, previousEnd = 0
  const fixed = [headerSize, 4, 4, 12, 8, 8, 32, 4, 8]
  for (let i = 0; i < mapCount; i++) {
    const at = mapOffset + 4 + i * 12, type = r.u16(at), count = r.u32(at + 4), offset = r.u32(at + 8)
    if (r.u16(at + 2) || !count || kinds.has(type) || offset <= previous || offset < previousEnd) r.fail('invalid', 'invalid, overlapping or duplicate DEX map entry', at)
    r.range(offset, 1, 'mapped item')
    if (fixed[type]) r.table(offset, count, fixed[type], 'mapped fixed items')
    if (type === 0 && (count !== 1 || offset !== 0)) r.fail('invalid', 'invalid mapped header', at)
    if (type === 0x1000 && (count !== 1 || offset !== mapOffset)) r.fail('invalid', 'map does not reference itself', at)
    if (type >= 1 && type <= 6) {
      const source = Object.values(tables)[type - 1]
      if (source.offset !== offset || source.count !== count) r.fail('invalid', 'map disagrees with DEX header', at)
    }
    kinds.add(type); previous = offset
    previousEnd = offset + (fixed[type] ? count * fixed[type] : type === 0x1000 ? 4 + mapCount * 12 : 1)
    mapEntries.push({ type: `0x${type.toString(16)}`, count, offset })
  }
  if (!kinds.has(0) || !kinds.has(0x1000)
    || Object.values(tables).some((table, i) => table.count && !kinds.has(i + 1))) r.fail('invalid', 'DEX map omits declared tables', mapOffset)
  const cache = new Map(); let truncatedStrings = 0
  const stringAt = index => {
    if (index >= counts.strings) r.fail('bounds', 'descriptor string index exceeds string table', tables.strings.offset)
    if (!cache.has(index)) {
      const value = dexString(r, r.u32(tables.strings.offset + index * 4), dataStart, dataEnd)
      cache.set(index, value); if (value.truncated) truncatedStrings++
    }
    return cache.get(index)
  }
  const descriptors = []
  for (let i = 0; i < Math.min(counts.types, r.sampleLimit); i++) {
    const stringIndex = r.u32(tables.types.offset + i * 4), value = stringAt(stringIndex)
    descriptors.push({ typeIndex: i, stringIndex, ...value })
  }
  const markerStrings = [], scannedStrings = Math.min(counts.strings, 512)
  let markerMatchesObserved = 0
  for (let i = 0; i < scannedStrings; i++) {
    const value = stringAt(i)
    if (DEX_MARKERS.some(marker => value.text.includes(marker))) {
      markerMatchesObserved++
      if (markerStrings.length < r.sampleLimit) markerStrings.push({ stringIndex: i, ...value })
    }
  }
  return { schemaVersion: 1, format: 'dex', header: { version, fileSize, headerSize,
    endian: r.little ? 'little' : 'big', endianTag: `0x${endian.toString(16)}`,
    linkSize, linkOffset, mapOffset, dataSize, dataOffset, containerSize, headerOffset: 0,
    checksum: r.u32(8), signature: r.bytes.subarray(12, 32).toString('hex') },
    counts, tables, mapEntries, descriptors, markerStrings,
    coverage: { logicalHeadersInspected: 1, remainingContainerBytes: containerSize - fileSize,
      descriptorsSampled: descriptors.length, descriptorSamplesTruncated: descriptors.length < counts.types,
      stringsScanned: scannedStrings, stringScanTruncated: scannedStrings < counts.strings,
      markerMatchesObserved, markerSamplesTruncated: markerStrings.length < markerMatchesObserved,
      truncatedStrings, stringByteLimit: MAX_STRING_BYTES, displayedStringUnitLimit: MAX_NAME_UNITS,
      integrityChecks: 'not-verified', bytecode: 'not-inspected' },
    limitations: ['Descriptor and marker samples are bounded; absence is not evidence of absence.',
      'Marker strings do not establish packing, protection or runtime behavior.',
      ...(container ? ['Only the first logical DEX header is inspected; later container headers are not validated.'] : [])] }
}

function cstring(r, offset, end) {
  if (!Number.isSafeInteger(end) || offset < 0 || offset >= end) r.fail('bounds', 'string offset outside string table', offset)
  r.range(offset, end - offset, 'string table')
  const bound = Math.min(end, offset + MAX_STRING_BYTES), relativeZero = r.bytes.subarray(offset, bound).indexOf(0)
  if (relativeZero < 0) {
    if (bound === end) r.fail('invalid', 'unterminated ELF string', offset)
    return { name: null, truncated: true, offset }
  }
  const slice = r.bytes.subarray(offset, offset + relativeZero)
  try {
    const name = new TextDecoder('utf-8', { fatal: true }).decode(slice)
    return { name: name.slice(0, MAX_NAME_UNITS), truncated: name.length > MAX_NAME_UNITS, offset }
  } catch { return { name: null, nameHex: slice.subarray(0, MAX_NAME_UNITS / 2).toString('hex'), truncated: slice.length > MAX_NAME_UNITS / 2, offset } }
}

/**
 * Read ELF identification, bounded headers, section symbols and dynamic dependencies.
 * @param input - Complete uncompressed ELF bytes, at most 128 MiB.
 * @param options - sampleLimit (0–64, default 24); larger tables have explicit truncated coverage.
 * @returns JSON metadata; address-sized values are hexadecimal strings without precision loss.
 * @throws ApkCodeParseError for invalid offsets, unsupported identification or exceeded limits.
 */
export function analyzeElf(input, options = {}) {
  const r = reader(input, 'elf', options)
  r.range(0, 16, 'ELF identification')
  if (r.bytes.subarray(0, 4).toString('hex') !== '7f454c46') r.fail('invalid', 'invalid ELF magic', 0)
  const bits = r.bytes[4] === 1 ? 32 : r.bytes[4] === 2 ? 64 : 0
  if (!bits || ![1, 2].includes(r.bytes[5]) || r.bytes[6] !== 1) r.fail('unsupported', 'unsupported ELF class, endian or version', 4)
  r.little = r.bytes[5] === 1
  const wide = bits === 64, headerSize = wide ? 64 : 52, phSize = wide ? 56 : 32, shSize = wide ? 64 : 40
  r.range(0, headerSize, 'ELF header')
  if (r.u32(20) !== 1 || r.u16(wide ? 52 : 40) !== headerSize) r.fail('invalid', 'invalid ELF header version or size', 20)
  const word = offset => wide ? r.u64(offset) : BigInt(r.u32(offset))
  const numeric = offset => r.number(word(offset), offset)
  const hex = value => `0x${value.toString(16)}`
  const programOffset = numeric(wide ? 32 : 28), sectionOffset = numeric(wide ? 40 : 32)
  const programStride = r.u16(wide ? 54 : 42), sectionStride = r.u16(wide ? 58 : 46)
  let programCount = r.u16(wide ? 56 : 44), sectionCount = r.u16(wide ? 60 : 48), nameIndex = r.u16(wide ? 62 : 50)
  const section = index => {
    const at = sectionOffset + index * sectionStride
    return { index, nameOffset: r.u32(at), type: r.u32(at + 4), flags: hex(word(at + 8)),
      address: word(at + (wide ? 16 : 12)), offset: numeric(at + (wide ? 24 : 16)),
      size: numeric(at + (wide ? 32 : 20)), link: r.u32(at + (wide ? 40 : 24)),
      info: r.u32(at + (wide ? 44 : 28)), stride: numeric(at + (wide ? 56 : 36)) }
  }
  if (sectionOffset) {
    if (sectionOffset < headerSize || sectionStride !== shSize) r.fail('invalid', 'invalid section table offset or stride', sectionOffset)
    r.range(sectionOffset, shSize, 'section zero')
    const zero = section(0)
    if (zero.type !== 0) r.fail('invalid', 'section zero is not SHT_NULL', sectionOffset)
    if (!sectionCount) sectionCount = zero.size
    if (nameIndex === 65535) nameIndex = zero.link
    if (programCount === 65535) programCount = zero.info
    if (!sectionCount) r.fail('invalid', 'nonempty section table has zero entries', sectionOffset)
  } else if (sectionCount || nameIndex || programCount === 65535) r.fail('invalid', 'missing extended section table', 0)
  if (programCount > 4096 || sectionCount > 16384) r.fail('limit', 'ELF header count exceeds inspection limit')
  if (programCount && (programOffset < headerSize || programStride !== phSize)) r.fail('invalid', 'invalid program header table', programOffset)
  if (!programCount && programOffset) r.fail('invalid', 'program offset without headers', programOffset)
  r.table(programOffset, programCount, programCount ? programStride : 1, 'program headers')
  r.table(sectionOffset, sectionCount, sectionCount ? sectionStride : 1, 'section headers')
  if (nameIndex >= sectionCount && nameIndex !== 0) r.fail('bounds', 'section name index out of range', nameIndex)
  const programs = [], sections = []
  for (let i = 0; i < programCount; i++) {
    const at = programOffset + i * programStride, type = r.u32(at), flags = r.u32(at + (wide ? 4 : 24))
    const offset = numeric(at + (wide ? 8 : 4)), address = word(at + (wide ? 16 : 8))
    const fileSize = numeric(at + (wide ? 32 : 16)), memorySize = word(at + (wide ? 40 : 20))
    r.range(offset, fileSize, 'program segment')
    if (type === 1 && BigInt(fileSize) > memorySize) r.fail('invalid', 'PT_LOAD file size exceeds memory size', at)
    programs.push({ index: i, type, flags, offset, address, fileSize, memorySize: hex(memorySize) })
  }
  for (let i = 0; i < sectionCount; i++) {
    const item = section(i)
    if (item.type !== 0 && item.type !== 8) r.range(item.offset, item.size, 'section contents')
    sections.push(item)
  }
  const names = nameIndex ? sections[nameIndex] : null
  if (names && names.type !== 3) r.fail('invalid', 'section names do not use a string table', names.offset)
  const sectionName = item => names ? cstring(r, names.offset + item.nameOffset, names.offset + names.size) : { name: null, unavailable: true }
  const symbols = { available: false, totalCount: 0, scannedCount: 0, items: [], truncated: false }
  let dynamic = null, namedSymbols = 0
  for (const item of sections) {
    if (item.type === 6 && !dynamic) {
      if (item.stride !== (wide ? 16 : 8) || !sections[item.link]) r.fail('invalid', 'invalid dynamic table stride or link', item.offset)
      dynamic = { offset: item.offset, size: item.size, stringTable: sections[item.link], source: 'section' }
    }
    if (item.type !== 2 && item.type !== 11) continue
    const expected = wide ? 24 : 16, strings = sections[item.link]
    if (item.stride !== expected || item.size % expected || !strings || strings.type !== 3) r.fail('invalid', 'invalid symbol table or string-table link', item.offset)
    const count = item.size / expected; symbols.available = true; symbols.totalCount += count
    for (let i = 0; i < count && symbols.scannedCount < MAX_SCAN; i++) {
      symbols.scannedCount++
      const at = item.offset + i * expected, stringIndex = r.u32(at), info = r.bytes[at + (wide ? 4 : 12)]
      if (!stringIndex) continue
      namedSymbols++
      const name = cstring(r, strings.offset + stringIndex, strings.offset + strings.size)
      if (symbols.items.length < r.sampleLimit) symbols.items.push({ index: i, tableIndex: item.index, ...name,
        binding: info >>> 4, type: info & 15, sectionIndex: r.u16(at + (wide ? 6 : 14)),
        value: hex(word(at + (wide ? 8 : 4))), size: hex(word(at + (wide ? 16 : 8))) })
    }
  }
  symbols.truncated = symbols.scannedCount < symbols.totalCount || symbols.items.length < namedSymbols || symbols.items.some(item => item.truncated)
  if (!symbols.available) symbols.unavailableReason = 'No section-backed symbol table; stripped or segment-only symbols were not reconstructed.'
  if (!dynamic) {
    const segment = programs.find(item => item.type === 2)
    if (segment) dynamic = { offset: segment.offset, size: segment.fileSize, source: 'program-header', stringTable: null }
  }
  const dependencies = { available: false, source: dynamic?.source ?? 'none', items: [], soname: null, scannedEntries: 0, truncated: false }
  if (dynamic) {
    const stride = wide ? 16 : 8
    if (dynamic.size % stride) r.fail('invalid', 'misaligned dynamic table size', dynamic.offset)
    const needed = []; let soname = null, stringAddress = null, stringSize = null, terminated = false
    for (let i = 0; i < Math.min(dynamic.size / stride, MAX_SCAN); i++) {
      const at = dynamic.offset + i * stride, tag = word(at), value = word(at + (wide ? 8 : 4))
      dependencies.scannedEntries++
      if (tag === 0n) { terminated = true; break }
      if (tag === 1n) needed.push(r.number(value, at))
      if (tag === 14n) soname = r.number(value, at)
      if (tag === 5n) {
        if (stringAddress !== null && stringAddress !== value) r.fail('invalid', 'conflicting dynamic string addresses', at)
        stringAddress = value
      }
      if (tag === 10n) {
        const size = r.number(value, at)
        if (stringSize !== null && stringSize !== size) r.fail('invalid', 'conflicting dynamic string sizes', at)
        stringSize = size
      }
    }
    if (!terminated && dynamic.size / stride <= MAX_SCAN) r.fail('invalid', 'dynamic table lacks DT_NULL', dynamic.offset)
    dependencies.truncated = !terminated || needed.length > r.sampleLimit
    let strings = dynamic.stringTable
    if (strings && strings.type !== 3) r.fail('invalid', 'dynamic string-table link is invalid', dynamic.offset)
    if (!strings && stringAddress !== null && stringSize !== null) {
      const load = programs.find(item => item.type === 1 && stringAddress >= item.address
        && stringAddress - item.address <= BigInt(item.fileSize)
        && BigInt(stringSize) <= BigInt(item.fileSize) - (stringAddress - item.address))
      if (load) strings = { offset: load.offset + r.number(stringAddress - load.address, dynamic.offset), size: stringSize }
    }
    if (strings) {
      r.range(strings.offset, strings.size, 'dynamic strings')
      if (needed.some(index => index >= strings.size) || soname !== null && soname >= strings.size) r.fail('bounds', 'dynamic string index outside string table', strings.offset)
      dependencies.available = true
      dependencies.items = needed.slice(0, r.sampleLimit).map(index => ({ stringIndex: index, ...cstring(r, strings.offset + index, strings.offset + strings.size) }))
      if (soname !== null) dependencies.soname = cstring(r, strings.offset + soname, strings.offset + strings.size)
      dependencies.truncated ||= dependencies.items.some(item => item.truncated) || dependencies.soname?.truncated === true
    } else if (!needed.length && soname === null) dependencies.available = terminated
    else dependencies.unavailableReason = 'DT_STRTAB/DT_STRSZ do not identify a file-backed string table.'
  } else dependencies.unavailableReason = 'No dynamic table.'
  const machine = r.u16(18), type = r.u16(16)
  return { schemaVersion: 1, format: 'elf', header: { bits, endian: r.little ? 'little' : 'big',
    machine, architecture: ({ 3: 'x86', 8: 'MIPS', 40: 'ARM', 62: 'x86_64', 183: 'AArch64', 243: 'RISC-V' })[machine] ?? 'unknown',
    type, typeName: ({ 0: 'none', 1: 'relocatable', 2: 'executable', 3: 'shared-object', 4: 'core' })[type] ?? 'other',
    osAbi: r.bytes[7], abiVersion: r.bytes[8], entry: hex(word(24)), headerSize,
    programOffset, programCount, programStride, sectionOffset, sectionCount, sectionStride, sectionNameIndex: nameIndex },
    programHeaders: programs.slice(0, r.sampleLimit).map(item => ({ ...item, address: hex(item.address) })),
    sections: sections.slice(0, r.sampleLimit).map(item => ({ ...item, address: hex(item.address), ...sectionName(item) })),
    symbols, dependencies, coverage: { programHeadersInspected: programCount, sectionsInspected: sectionCount,
      programSamplesTruncated: programCount > r.sampleLimit, sectionSamplesTruncated: sectionCount > r.sampleLimit,
      stringByteLimit: MAX_STRING_BYTES, displayedStringUnitLimit: MAX_NAME_UNITS,
      code: 'not-inspected', relocations: 'not-inspected' },
    limitations: ['Static metadata does not establish packing, protection or runtime behavior.',
      'Names and symbols are bounded samples; unavailable or absent metadata is not proof that code is absent.'] }
}
