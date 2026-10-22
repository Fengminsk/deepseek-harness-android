/** Real original Office engine smoke: simulate Android host selection on Node. */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { verifyOfficeEngine } from './stage-office-runtime.mjs'

const root = resolve(import.meta.dirname, '../../..')
const modules = join(root, '.cache/android/runtime-bundle/node_modules')
const kit = join(modules, '@deepseek-ai/libreoffice-kit/lib/index.js')
const wasm = join(modules, '@deepseek-ai/libreoffice-kit-wasm')
const fixture = join(root, 'packages/bundle/web-app/tests/fixtures/document-conversion.docx')
const workbook = join(root, 'packages/client/ui-sidebar-documentpreview/tests/fixtures/excel-xml/rich.xlsx')
if (!existsSync(kit) || !existsSync(fixture)) throw new Error('Stage Android runtime and build original Office fixture first')
await verifyOfficeEngine(wasm, '0.2.0')

// The package uses process.platform/arch to dispatch. This validates the
// Android decision path on the host; it is not presented as phone evidence.
Object.defineProperty(process, 'platform', { value: 'android' })
Object.defineProperty(process, 'arch', { value: 'arm64' })
const { createConverter, discoverRuntime } = await import(pathToFileURL(kit).href)
const runtime = await discoverRuntime()
assert.equal(runtime.backend, 'wasm')
const scratch = await mkdtemp(join(tmpdir(), 'dsh-android-office-smoke-'))
try {
  const converter = await createConverter({ timeoutMs: 90_000, maxInputBytes: 10 * 1024 * 1024,
    maxOutputBytes: 20 * 1024 * 1024, maxImageResolution: 96,
    fontDirectories: [join(process.env.WINDIR ?? 'C:/Windows', 'Fonts')],
    maxFontFiles: 256, maxFontFileBytes: 16 * 1024 * 1024, maxLoadedFontBytes: 64 * 1024 * 1024 })
  try {
    const output = join(scratch, 'document.pdf')
    const result = await converter.render({ inputPath: fixture, outputPath: output })
    const bytes = await readFile(output)
    assert.equal(result.backend, 'wasm')
    assert.ok(result.pageCount > 0)
    assert.ok(bytes.subarray(0, 5).equals(Buffer.from('%PDF-')))
    assert.ok(bytes.length > 1000)
    console.log(JSON.stringify({ backend: runtime.backend, pages: result.pageCount, bytes: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'), maxRssKiB: process.resourceUsage().maxRSS,
      currentRssMiB: Math.round(process.memoryUsage().rss / 1048576) }))
    const sheetOutput = join(scratch, 'workbook.pdf')
    const sheet = await converter.render({ inputPath: workbook, outputPath: sheetOutput })
    const sheetBytes = await readFile(sheetOutput)
    assert.equal(sheet.backend, 'wasm')
    assert.ok(sheet.pageCount > 0 && sheetBytes.subarray(0, 5).equals(Buffer.from('%PDF-')))
    console.log(JSON.stringify({ workbookBackend: sheet.backend, pages: sheet.pageCount,
      bytes: sheetBytes.length, maxRssKiB: process.resourceUsage().maxRSS,
      currentRssMiB: Math.round(process.memoryUsage().rss / 1048576) }))
  } finally { await converter.dispose() }
  console.log(JSON.stringify({ afterDisposeCurrentRssMiB: Math.round(process.memoryUsage().rss / 1048576) }))
  if (typeof globalThis.gc === 'function') {
    globalThis.gc()
    console.log(JSON.stringify({ afterGcCurrentRssMiB: Math.round(process.memoryUsage().rss / 1048576) }))
  }
  const tiny = await createConverter({ maxInputBytes: 1, fontDirectories: [] })
  try {
    await assert.rejects(tiny.render({ inputPath: fixture, outputPath: join(scratch, 'oversized.pdf') }))
    assert.equal(existsSync(join(scratch, 'oversized.pdf')), false)
  } finally { await tiny.dispose() }
} finally { await rm(scratch, { recursive: true, force: true }) }
