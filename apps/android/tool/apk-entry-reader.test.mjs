import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import { attachmentArchiveDirectory } from '../runtime/attachment-archive.mjs'
import { readApkEntryRecords, decodeApkEntry } from '../runtime/apk-entry-reader.mjs'

const requireStaged = createRequire(new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url))
const { zipSync } = requireStaged('fflate')
const makeZip = (options = {}) => Buffer.from(zipSync({ 'AndroidManifest.xml': Buffer.from('manifest data'),
  'classes.dex': Buffer.from('dex bytes '.repeat(1000)) }, options))
const reference = bytes => ({ bytes: bytes.length, attachmentId: `sha256:${createHash('sha256').update(bytes).digest('hex')}` })
const stream = bytes => async function* (signal) {
  for (let offset = 0; offset < bytes.length; offset += 17) {
    signal.throwIfAborted(); yield bytes.subarray(offset, offset + 17)
  }
}
const selected = (zip, name = 'classes.dex') => {
  const directory = attachmentArchiveDirectory(zip, zip.length)
  return { directory, entry: directory.entries.find(item => item.name === name) }
}
const read = (zip, signal = new AbortController().signal) => {
  const { directory, entry } = selected(zip)
  return readApkEntryRecords(directory, [entry], stream(zip), reference(zip), signal)
}

test('stored and deflated records match central metadata, stream hash, decoded bytes and CRC', async () => {
  for (const level of [0, 6]) {
    const zip = makeZip({ level }), [record] = await read(zip)
    assert.equal((await decodeApkEntry(record, new AbortController().signal)).toString(), 'dex bytes '.repeat(1000))
  }
})

test('a changing second stream is rejected before any entry contents are decoded', async () => {
  const zip = makeZip(), changed = Buffer.from(zip), { directory, entry } = selected(zip)
  changed[35] ^= 1
  await assert.rejects(readApkEntryRecords(directory, [entry], stream(changed), reference(zip), new AbortController().signal),
    { code: 'apk-entry/integrity' })
  await assert.rejects(readApkEntryRecords(directory, [entry], stream(zip.subarray(0, -1)), reference(zip), new AbortController().signal),
    { code: 'apk-entry/integrity' })
})

test('ambiguous names, overlapping records, encryption and budgets fail before stream allocation', async () => {
  const zip = makeZip(), { directory, entry } = selected(zip), signal = new AbortController().signal
  const untouched = () => { assert.fail('must not read archive for rejected directory') }
  for (const mutate of [
    () => { directory.entries[0].name = entry.name },
    () => { entry.localOffset = directory.entries[0].localOffset },
    () => { entry.flags |= 1 },
    () => { entry.bytes = 128 * 1024 * 1024 + 1 },
    () => { entry.bytes = 32 * 1024 * 1024; entry.compressedBytes = 2 },
  ]) {
    const original = directory.entries.map(value => ({ ...value }))
    mutate()
    await assert.rejects(readApkEntryRecords(directory, [entry], untouched, reference(zip), signal), /ZIP|APK/)
    directory.entries.forEach((value, index) => Object.assign(value, original[index]))
  }
})

test('local headers cannot override central names, method, length or CRC', async () => {
  const zip = makeZip(), signal = new AbortController().signal
  for (const position of [0, 6, 8, 14, 18, 22, 26, 30]) {
    const [record] = await read(zip)
    record.bytes[position] ^= 1
    await assert.rejects(decodeApkEntry(record, signal), /ZIP/)
  }
  const stored = makeZip({ level: 0 }), [record] = await read(stored)
  record.bytes[30 + record.entry.rawName.length] ^= 1
  await assert.rejects(decodeApkEntry(record, signal), { code: 'apk-entry/integrity' })
})

test('inflated output cannot exceed a forged size, and deflate truncation is rejected', async () => {
  const signal = new AbortController().signal, zip = makeZip(), [record] = await read(zip)
  record.entry.bytes = 1; record.bytes.writeUInt32LE(1, 22)
  await assert.rejects(decodeApkEntry(record, signal), { code: 'apk-entry/limit' })
  const [truncated] = await read(zip)
  truncated.entry.compressedBytes--; truncated.bytes.writeUInt32LE(truncated.entry.compressedBytes, 18)
  await assert.rejects(decodeApkEntry(truncated, signal), { code: 'apk-entry/invalid' })
})

test('cancellation drains a live source and never yields a decoded result', async () => {
  const zip = makeZip(), { directory, entry } = selected(zip), controller = new AbortController()
  const entered = Promise.withResolvers(), drained = Promise.withResolvers()
  let exited = false
  const pending = readApkEntryRecords(directory, [entry], async function* (signal) {
    try {
      yield zip.subarray(0, 64); entered.resolve()
      await new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }))
    } finally { await drained.promise; exited = true }
  }, reference(zip), controller.signal).catch(error => error)
  await entered.promise; controller.abort(new Error('cancel APK read')); assert.equal(exited, false)
  drained.resolve(); assert.match((await pending).message, /cancel APK read/); assert.equal(exited, true)
  await assert.rejects(read(zip, controller.signal), /cancel APK read/)
})

test('stored entries yield to cancellation while computing their CRC', async () => {
  const zip = Buffer.from(zipSync({ 'classes.dex': Buffer.alloc(4 * 1024 * 1024, 65) }, { level: 0 }))
  const directory = attachmentArchiveDirectory(zip, zip.length), controller = new AbortController()
  const [record] = await readApkEntryRecords(directory, directory.entries, stream(zip), reference(zip), controller.signal)
  const cancel = setImmediate(() => controller.abort(new Error('cancel stored CRC')))
  try { await assert.rejects(decodeApkEntry(record, controller.signal), /cancel stored CRC/) }
  finally { clearImmediate(cancel) }
})
