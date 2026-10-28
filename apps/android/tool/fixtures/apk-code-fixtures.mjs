/** Synthetic metadata fixtures shared by host parsers and device acceptance; never executed as code. */
function uleb(value) {
  const bytes = []
  do { const part = value % 128; value = Math.floor(value / 128); bytes.push(part | (value ? 128 : 0)) } while (value)
  return Buffer.from(bytes)
}

export function dexFixture({ version = '039', big = false, strings = ['Lsample/App;', 'Ljava/lang/Object;', 'DexClassLoader'], trailing = 0 } = {}) {
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

export function elfFixture({ bits = 64, big = false, sections = true, extended = false } = {}) {
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
