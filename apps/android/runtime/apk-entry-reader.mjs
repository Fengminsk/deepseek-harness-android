import { createHash } from 'node:crypto'
import { Readable, Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { createInflateRaw } from 'node:zlib'
import { setImmediate } from 'node:timers/promises'

export const APK_ENTRY_MAX_BYTES = 128 * 1024 * 1024
export const APK_REQUEST_MAX_BYTES = 64 * 1024 * 1024
export const APK_DECODED_MAX_BYTES = 128 * 1024 * 1024
const crcTable = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
  return value >>> 0
})
export function apkEntryError(code, message) {
  const error = new Error(message); error.code = `apk-entry/${code}`; return error
}
function check(condition, code, message) { if (!condition) throw apkEntryError(code, message) }

/** Keep only bounded selected local records, then verify the ENTIRE second stream.
 * No archive filename is passed to a filesystem API, and nothing is executed.
 */
export async function readApkEntryRecords(directory, selected, streamFactory, reference, signal) {
  signal.throwIfAborted()
  check(selected.length <= 4, 'limit', 'At most four APK entries per request')
  const names = new Set(), offsets = new Set()
  for (const entry of directory.entries) {
    check(!names.has(entry.name) && !offsets.has(entry.localOffset), 'ambiguous', 'Duplicate ZIP name or local record offset')
    names.add(entry.name); offsets.add(entry.localOffset)
  }
  const ordered = [...directory.entries].sort((a, b) => a.localOffset - b.localOffset)
  const ends = new Map(ordered.map((entry, index) => [entry, ordered[index + 1]?.localOffset ?? directory.directoryOffset]))
  let compressedTotal = 0, decodedTotal = 0
  const records = selected.map(entry => {
    check(ends.has(entry) && !entry.unsafePath, 'invalid', 'Unsafe or unknown ZIP entry')
    check(!(entry.flags & ~0x080e) && [0, 8].includes(entry.method), 'unsupported', 'Encrypted or unsupported ZIP entry')
    const maxBytes = entry.name === 'AndroidManifest.xml' ? 4 * 1024 * 1024 : APK_ENTRY_MAX_BYTES
    check(entry.bytes <= maxBytes && entry.compressedBytes <= APK_REQUEST_MAX_BYTES, 'limit', 'APK entry exceeds byte limit')
    check(entry.bytes <= Math.max(1024 * 1024, entry.compressedBytes * 1024), 'limit', 'APK entry compression ratio exceeds limit')
    compressedTotal += entry.compressedBytes; decodedTotal += entry.bytes
    check(compressedTotal <= APK_REQUEST_MAX_BYTES && decodedTotal <= APK_DECODED_MAX_BYTES,
      'limit', 'Selected APK entries exceed 64 MiB compressed / 128 MiB decoded; request a smaller page')
    const end = Math.min(ends.get(entry), entry.localOffset + 30 + 4096 + 65535 + entry.compressedBytes)
    check(end >= entry.localOffset + 30 + entry.compressedBytes, 'invalid', 'Overlapping ZIP records')
    return { entry, end, bytes: Buffer.alloc(end - entry.localOffset), received: 0 }
  })
  const hash = createHash('sha256')
  let offset = 0
  for await (const input of streamFactory(signal)) {
    signal.throwIfAborted()
    const chunk = Buffer.from(input)
    check(offset + chunk.length <= reference.bytes, 'integrity', 'APK stream exceeds declared size')
    hash.update(chunk)
    for (const record of records) {
      const start = Math.max(offset, record.entry.localOffset), end = Math.min(offset + chunk.length, record.end)
      if (start < end) {
        chunk.copy(record.bytes, start - record.entry.localOffset, start - offset, end - offset)
        record.received += end - start
      }
    }
    offset += chunk.length
  }
  signal.throwIfAborted()
  check(offset === reference.bytes && `sha256:${hash.digest('hex')}` === reference.attachmentId,
    'integrity', 'APK changed or failed SHA256 verification')
  for (const record of records) check(record.received === record.bytes.length, 'integrity', 'Truncated ZIP local record')
  return records
}

/** Async zlib with exact length, consumed-input and CRC checks; bounded allocation. */
export async function decodeApkEntry(record, signal) {
  signal.throwIfAborted()
  const { entry, bytes } = record
  check(bytes.length >= 30 && bytes.readUInt32LE(0) === 0x04034b50, 'invalid', 'Invalid ZIP local signature')
  check(bytes.readUInt16LE(6) === entry.flags && bytes.readUInt16LE(8) === entry.method,
    'invalid', 'ZIP local flags or method disagree with directory')
  const nameLength = bytes.readUInt16LE(26), extraLength = bytes.readUInt16LE(28), start = 30 + nameLength + extraLength
  check(nameLength === entry.rawName.length && start + entry.compressedBytes <= bytes.length
    && bytes.subarray(30, 30 + nameLength).equals(entry.rawName), 'invalid', 'ZIP local name or data bounds disagree')
  for (const [position, expected] of [[14, entry.crc32], [18, entry.compressedBytes], [22, entry.bytes]]) {
    const actual = bytes.readUInt32LE(position)
    check(actual === expected || Boolean(entry.flags & 8) && actual === 0, 'invalid', 'ZIP local sizes or CRC disagree')
  }
  check(entry.method !== 0 || entry.compressedBytes === entry.bytes, 'invalid', 'Stored ZIP size mismatch')
  const input = bytes.subarray(start, start + entry.compressedBytes), output = Buffer.alloc(entry.bytes)
  let length = 0, crc = 0xffffffff
  const sink = new Writable({ write(chunk, _encoding, callback) {
    if (length + chunk.length > output.length) return callback(apkEntryError('limit', 'Inflated ZIP data exceeds declared length'))
    chunk.copy(output, length); length += chunk.length
    for (const byte of chunk) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8)
    callback()
  } })
  const inflater = entry.method === 8 ? createInflateRaw() : undefined
  async function* chunks() {
    for (let at = 0; at < input.length; at += 65536) {
      if (at) await setImmediate(undefined, { signal })
      signal.throwIfAborted()
      yield input.subarray(at, at + 65536)
    }
  }
  try {
    await pipeline(...[Readable.from(chunks()), inflater, sink].filter(Boolean), { signal })
  } catch (error) {
    signal.throwIfAborted()
    if (error?.code?.startsWith('apk-entry/')) throw error
    throw apkEntryError('invalid', 'Invalid deflated ZIP data')
  }
  signal.throwIfAborted()
  check(!inflater || inflater.bytesWritten === input.length, 'invalid', 'Trailing compressed ZIP data')
  check(length === entry.bytes && ((crc ^ 0xffffffff) >>> 0) === entry.crc32, 'integrity', 'ZIP entry length or CRC32 mismatch')
  return output
}
