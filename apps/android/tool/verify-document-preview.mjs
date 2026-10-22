import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { unzipSync } from 'fflate'

const PREFIX = 'assets/document-preview/'
const PACKAGES = ['dsh-client-ui-renderer', 'dsh-client-resources', 'dsh-client-locale',
  'dsh-api-workspace-files', 'dsh-client-ui-sidebar-documentpreview'].map(name => `@deepseek-ai/${name}`)
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const safePath = value => typeof value === 'string' && value.length > 0 && !value.startsWith('/')
  && !/[\\:\x00]/.test(value) && value.split('/').every(part => part && part !== '.' && part !== '..')

/** Read the actual APK, not the staging folder, and verify every document asset. */
export function verifyDocumentPreview(apkBytes) {
  const files = unzipSync(apkBytes, { filter: entry => {
    if (!entry.name.startsWith(PREFIX)) return false
    assert(entry.originalSize <= 64 * 1024 * 1024, 'Document asset exceeds verification limit')
    return true
  } })
  const manifestBytes = files[`${PREFIX}asset-manifest.json`]
  assert(manifestBytes && manifestBytes.length <= 1024 * 1024, 'Missing or oversized document asset manifest')
  const manifest = JSON.parse(Buffer.from(manifestBytes).toString('utf8'))
  assert.equal(manifest.format, 1)
  assert.equal(manifest.composition, 'document-only')
  assert(Array.isArray(manifest.assets) && manifest.assets.length > 0, 'Missing document asset inventory')
  const seen = new Set()
  let bytes = 0
  for (const asset of manifest.assets) {
    assert(safePath(asset.path) && asset.path !== 'asset-manifest.json', 'Invalid document asset path')
    assert(!seen.has(asset.path), 'Duplicate document asset identity')
    seen.add(asset.path)
    const data = files[PREFIX + asset.path]
    assert(data?.length > 0, `Missing or empty document asset: ${asset.path}`)
    assert.equal(data.length, asset.bytes, `Wrong asset size: ${asset.path}`)
    assert.equal(hash(data), asset.sha256, `Wrong asset hash: ${asset.path}`)
    bytes += data.length
  }
  assert(seen.has('index.html') && seen.has('licenses/DSH-LICENSE.txt'), 'Missing entry or original license')
  assert(Array.isArray(manifest.packages) && manifest.packages.length === 5, 'Incomplete original document modules')
  assert.deepEqual(manifest.packages.map(pkg => pkg.id).sort(), [...PACKAGES].sort(), 'Wrong original module set')
  for (const pkg of manifest.packages) {
    assert(typeof pkg.id === 'string' && pkg.id.startsWith('@deepseek-ai/'), 'Invalid original module identity')
    assert(Array.isArray(pkg.files) && pkg.files.some(file => file.name === 'client.js'), 'Missing original client factory')
    for (const file of pkg.files) {
      const path = `bundles/${pkg.id}/${file.name}`
      assert(seen.has(path), `Original module not inventoried: ${path}`)
      assert.equal(hash(files[PREFIX + path]), file.sha256, `Original module changed: ${path}`)
    }
  }
  const preview = manifest.packages.find(pkg => pkg.id === '@deepseek-ai/dsh-client-ui-sidebar-documentpreview')
  assert(preview?.files.some(file => file.name === 'client.pdf.js'), 'Missing original PDF renderer')
  assert(preview.files.some(file => file.name === 'client.excel.js'), 'Missing original Excel renderer')
  for (const name of Object.keys(files)) {
    const path = name.slice(PREFIX.length)
    if (path.endsWith('/')) continue
    assert(path === 'asset-manifest.json' || seen.has(path), `Unlisted document asset: ${path}`)
  }
  return { success: true, manifest: manifest.manifest, assets: seen.size, bytes,
    packages: manifest.packages.map(pkg => pkg.id) }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error('Pass the APK path to verify')
  console.log(JSON.stringify(verifyDocumentPreview(await readFile(resolve(process.argv[2]))), null, 2))
}
