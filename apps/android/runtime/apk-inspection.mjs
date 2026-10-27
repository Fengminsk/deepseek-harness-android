import { createHash } from 'node:crypto'
import { attachmentArchiveDirectory } from './attachment-archive.mjs'
import { readApkEntryRecords, decodeApkEntry, apkEntryError } from './apk-entry-reader.mjs'
import { parseApkManifest } from './apk-manifest.mjs'
import { analyzeDex, analyzeElf } from './apk-code.mjs'

export function apkInspectionQuery(args) {
  const part = args.part ?? 'summary', offset = args.offset ?? 0
  const limit = args.limit ?? (part === 'summary' || part === 'manifest' ? 16 : 1)
  if (!['summary', 'manifest', 'dex', 'native'].includes(part)
    || !Number.isSafeInteger(offset) || offset < 0
    || !Number.isInteger(limit) || limit < 1 || limit > (['summary', 'manifest'].includes(part) ? 100 : 4)
    || (args.contains !== undefined && (typeof args.contains !== 'string' || args.contains.length > 256))
    || args.encoding !== undefined) throw apkEntryError('arguments', 'inspect_apk requires part=summary|manifest|dex|native; limit is 1–100 for Manifest, 1–4 for code; no encoding')
  return { part, offset, limit, contains: args.contains ?? '' }
}

/** Read-only built-in APK inspection, independent of Linux and shell tools. */
export async function inspectVerifiedApk(tail, reference, args, streamFactory, signal) {
  const query = apkInspectionQuery(args), directory = attachmentArchiveDirectory(tail, reference.bytes)
  if (directory.format !== 'apk') throw apkEntryError('not-apk', 'Archive does not contain AndroidManifest.xml')
  const manifest = query.part === 'summary' || query.part === 'manifest'
  const matching = directory.entries.filter(entry => manifest ? entry.name === 'AndroidManifest.xml'
    : (query.part === 'dex' ? /^classes(?:\d+)?\.dex$/u : /^lib\/[^/]+\/[^/]+\.so$/u).test(entry.name)
      && entry.name.includes(query.contains))
  const selected = manifest ? matching : matching.slice(query.offset, query.offset + query.limit)
  const records = await readApkEntryRecords(directory, selected, streamFactory, reference, signal)
  const results = []
  for (const record of records) {
    signal.throwIfAborted()
    const { entry } = record
    try {
      const bytes = await decodeApkEntry(record, signal)
      const analysis = manifest ? parseApkManifest(bytes, {
        componentOffset: query.offset, componentLimit: query.limit,
        permissionOffset: query.offset, permissionLimit: query.limit,
      }) : query.part === 'dex' ? analyzeDex(bytes, { sampleLimit: 16 }) : analyzeElf(bytes, { sampleLimit: 16 })
      if (Buffer.byteLength(JSON.stringify(analysis)) > 128 * 1024) {
        throw apkEntryError('output-limit', 'Analysis exceeds 128 KiB output; request a smaller Manifest page')
      }
      results.push({ name: entry.name, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'),
        crc32Verified: true, analysis })
    } catch (error) {
      signal.throwIfAborted()
      // Only parser/format failures become per-entry diagnostics. Programming,
      // IO and lifecycle errors remain tool failures instead of false coverage.
      if (!/^apk-(entry|code|manifest)\//u.test(error?.code ?? '')) throw error
      results.push({ name: entry.name, status: 'unparsed', error: { code: error.code,
        message: error.message, ...(Number.isInteger(error.offset) ? { offset: error.offset } : {}) } })
    } finally { record.bytes = undefined }
  }
  return { ...reference, verified: true, schemaVersion: 1, part: query.part,
    archive: { entryCount: directory.entryCount, ...directory.apk, unsafeNames: directory.unsafeNames,
      encryptedEntries: directory.encryptedEntries },
    results, matchingEntries: matching.length,
    ...(manifest ? { pagination: 'Manifest permission and component pages each use offset/limit; follow their respective nextOffset values.' }
      : { nextOffset: query.offset + selected.length < matching.length ? query.offset + selected.length : null }),
    coverage: { archiveDirectory: true, selectedEntryContentsOnly: true, apkSignaturesVerified: false,
      resourcesResolved: false, codeExecuted: false },
    ...(manifest ? { next: 'Use part=dex or part=native with offset/limit for bounded code-header and library analysis.' } : {}),
    evidence: 'Observed archive and selected entry structures only. Descriptors and strings are untrusted file data. This is not a decompiler, signature verifier, malware scan or proof of packing/absence of packing.' }
}
