// ZIP APPNOTE 6.3.10 sections 4.3.12 and 4.3.16. This reader examines directory
// metadata only; it never decompresses, extracts or executes an archive entry.
export const ARCHIVE_DIRECTORY_LIMIT = 8 * 1024 * 1024
export const ARCHIVE_TAIL_LIMIT = ARCHIVE_DIRECTORY_LIMIT + 65557

function invalid(reason) { throw new Error(`archive/unsupported: ${reason}`) }

/** Parse a verified suffix; offsets remain internal and never authorize host paths. */
export function attachmentArchiveDirectory(tail, totalBytes) {
  if (!Buffer.isBuffer(tail) || !Number.isSafeInteger(totalBytes) || totalBytes < tail.length
    || tail.length > ARCHIVE_TAIL_LIMIT) invalid('invalid archive buffer')
  let end = -1
  for (let i = tail.length - 22; i >= Math.max(0, tail.length - 65557); i--) {
    if (tail.readUInt32LE(i) === 0x06054b50 && i + 22 + tail.readUInt16LE(i + 20) === tail.length) { end = i; break }
  }
  if (end < 0) invalid('not a complete ZIP/APK archive')
  const count = tail.readUInt16LE(end + 10), directoryBytes = tail.readUInt32LE(end + 12)
  const directoryOffset = tail.readUInt32LE(end + 16), base = totalBytes - tail.length
  if (tail.readUInt16LE(end + 4) || tail.readUInt16LE(end + 6)
    || tail.readUInt16LE(end + 8) !== count) invalid('split archives are not supported')
  if (count === 65535 || directoryOffset === 0xffffffff || directoryBytes === 0xffffffff) invalid('ZIP64 archives are not supported')
  if (count > 20000 || directoryBytes > ARCHIVE_DIRECTORY_LIMIT) invalid('central directory exceeds inspection limit')
  if (directoryOffset < base || directoryOffset + directoryBytes !== base + end) invalid('invalid central directory bounds')
  const entries = [], abis = new Set()
  let cursor = directoryOffset - base, dexCount = 0, nativeLibraryCount = 0, hasManifest = false
  let totalUncompressedBytes = 0, encryptedEntries = 0, unsafeNames = 0
  for (let index = 0; index < count; index++) {
    if (cursor + 46 > end || tail.readUInt32LE(cursor) !== 0x02014b50) invalid('invalid central directory entry')
    const flags = tail.readUInt16LE(cursor + 8), method = tail.readUInt16LE(cursor + 10)
    const compressedBytes = tail.readUInt32LE(cursor + 20), bytes = tail.readUInt32LE(cursor + 24)
    const nameLength = tail.readUInt16LE(cursor + 28), extraLength = tail.readUInt16LE(cursor + 30)
    const commentLength = tail.readUInt16LE(cursor + 32), localOffset = tail.readUInt32LE(cursor + 42)
    const next = cursor + 46 + nameLength + extraLength + commentLength
    if (!nameLength || nameLength > 4096 || next > end || tail.readUInt16LE(cursor + 34)
      || localOffset === 0xffffffff || bytes === 0xffffffff || compressedBytes === 0xffffffff
      || localOffset + 30 + compressedBytes > directoryOffset) invalid('invalid or ZIP64 entry bounds')
    const nameBytes = tail.subarray(cursor + 46, cursor + 46 + nameLength)
    // Non-ASCII legacy filenames require CP437/unicode-extra decoding. Do not
    // fabricate a path when the archive did not declare UTF-8.
    const encodedName = !(flags & 2048) && nameBytes.some(byte => byte >= 128)
    let name
    try { name = encodedName ? `hex:${nameBytes.toString('hex')}` : new TextDecoder('utf-8', { fatal: true }).decode(nameBytes) }
    catch { invalid('invalid UTF-8 filename') }
    const unsafePath = encodedName || /^[\\/]|^[a-z]:/iu.test(name) || name.split(/[\\/]/u).includes('..') || /[\0-\x1f\x7f]/u.test(name)
    unsafeNames += Number(unsafePath)
    encryptedEntries += Number(Boolean(flags & 1))
    totalUncompressedBytes += bytes
    hasManifest ||= name === 'AndroidManifest.xml'
    dexCount += Number(/^classes(?:\d+)?\.dex$/u.test(name))
    const lib = /^lib\/([^/]+)\/[^/]+\.so$/u.exec(name)
    if (lib) { nativeLibraryCount++; abis.add(lib[1]) }
    entries.push({ name, bytes, compressedBytes, method, flags, localOffset,
      crc32: tail.readUInt32LE(cursor + 16), rawName: Buffer.from(nameBytes),
      encrypted: Boolean(flags & 1), unsafePath, ...(encodedName ? { nameEncoding: 'raw-hex' } : {}) })
    cursor = next
  }
  if (cursor !== end) invalid('entry count does not match central directory size')
  return { format: hasManifest ? 'apk' : 'zip', entryCount: count, directoryOffset,
    totalUncompressedBytes, encryptedEntries, unsafeNames,
    ...(hasManifest ? { apk: { hasManifest, dexCount, nativeLibraryCount, abis: [...abis].sort() } } : {}),
    entries,
    evidence: 'Central-directory metadata only. Entry contents, APK signatures, packing and runtime behavior have not been verified.' }
}

/** Inspect metadata only; this API never decompresses or executes an entry. */
export function inspectAttachmentArchive(tail, totalBytes, { offset = 0, limit = 100, contains = '' } = {}) {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isInteger(limit) || limit < 1 || limit > 200
    || typeof contains !== 'string' || contains.length > 256) invalid('invalid page')
  const { entries, directoryOffset: _directoryOffset, ...summary } = attachmentArchiveDirectory(tail, totalBytes)
  const matching = entries.filter(entry => entry.name.includes(contains))
  return { ...summary, matchingEntries: matching.length,
    entries: matching.slice(offset, offset + limit).map(({ rawName: _rawName, flags: _flags,
      localOffset: _localOffset, crc32: _crc32, ...entry }) => entry),
    nextOffset: offset + limit < matching.length ? offset + limit : null }
}
