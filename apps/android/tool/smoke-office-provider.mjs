/** Isolated real DSH Office provider conversion, without Gateway storage. */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import OfficeKit, { OfficeSourceKey } from '../../../packages/document/office-kit/lib/index.js'

const root = resolve(import.meta.dirname, '../../..')
const officeRequire = createRequire(join(root, 'packages/document/office-kit/package.json'))
const { Context } = await import(pathToFileURL(officeRequire.resolve('@deepseek-ai/cordis')).href)
Object.defineProperty(process, 'platform', { value: 'android' })
Object.defineProperty(process, 'arch', { value: 'arm64' })
const bytes = await readFile(join(root, 'packages/bundle/web-app/tests/fixtures/document-conversion.docx'))
const outputDirectory = await mkdtemp(join(root, '.cache/android/office-provider-outputs-'))
const ctx = new Context()
await ctx.plugin(OfficeKit, {
  outputDirectory,
  maxConcurrentConversions: 1, maxQueuedJobs: 2, maxReaders: 4, maxSourceBytes: 10 * 1024 * 1024,
  maxBackgroundConversions: 0, maxCachedEntries: 2, maxCachedBytes: 32 * 1024 * 1024,
  maxSourceEntries: 8, timeoutMs: 90_000, maxInputBytes: 10 * 1024 * 1024,
  maxOutputBytes: 20 * 1024 * 1024, maxImageResolution: 96,
  maxArchiveEntries: 2_000, maxUncompressedBytes: 64 * 1024 * 1024,
  fontDirectories: [join(process.env.WINDIR ?? 'C:/Windows', 'Fonts')],
  maxFontFiles: 256, maxFontFileBytes: 16 * 1024 * 1024,
  maxLoadedFontBytes: 64 * 1024 * 1024,
})
try {
  const request = { extension: 'docx', priority: 'foreground', source: {
    key: OfficeSourceKey('original-provider-android-smoke'), version: 'fixture-v1', bytes: bytes.length,
    read: async (_signal, maxBytes) => { assert.ok(maxBytes >= bytes.length); return { bytes, version: 'fixture-v1' } },
  } }
  const converted = await ctx.officeKit.convert(request)
  assert.equal(Buffer.from(converted.pdf).subarray(0, 5).toString(), '%PDF-')
  assert.ok(converted.pdf.length > 1000)
  const again = await ctx.officeKit.convert(request)
  assert.equal(again.cacheKey, converted.cacheKey)
  assert.deepEqual(again.pdf, converted.pdf)
  const sourcePath = join(root, 'packages/bundle/web-app/tests/fixtures/document-conversion.docx')
  const source = { absolutePath: sourcePath, version: 'fixture-v1', bytes: bytes.length }
  let authorized = true
  ctx.provide('workspaceFiles', {
    readBytes: async () => {
      if (!authorized) throw new Error('scope rejected')
      return { ...source, offset: 0, eof: false, data: bytes.subarray(0, 1) }
    },
    stat: async () => source,
  })
  ctx.provide('fs', {
    resolve: async () => ({ targetKey: 'office-smoke-target', displayPath: sourcePath }),
    stat: async () => ({ type: 'file', version: source.version, size: bytes.length }),
    processPath: () => sourcePath,
    readBytes: async () => bytes,
  })
  const scope = { sessionId: 'office-smoke-session', workspaceRoot: root }
  const remote = await ctx.officeKit.render(scope, sourcePath, 'foreground', new AbortController().signal)
  assert.deepEqual(remote.data, converted.pdf)
  assert.equal(remote.absolutePath, sourcePath)
  authorized = false
  await assert.rejects(ctx.officeKit.render(scope, sourcePath, 'foreground', new AbortController().signal), /scope rejected/)
  const bad = { ...request, source: { ...request.source, key: OfficeSourceKey('malformed'),
    read: async () => ({ bytes: Buffer.from('bad office file'), version: 'fixture-v1' }) } }
  await assert.rejects(ctx.officeKit.convert(bad))
  console.log(JSON.stringify({ originalProvider: true, bytes: converted.pdf.length,
    sha256: createHash('sha256').update(converted.pdf).digest('hex'), cached: true,
    authorizedRemote: true, unauthorizedRejected: true, malformedRejected: true,
    maxRssKiB: process.resourceUsage().maxRSS }))
} finally {
  await ctx.fiber.dispose()
  await rm(outputDirectory, { recursive: true, force: true })
}
