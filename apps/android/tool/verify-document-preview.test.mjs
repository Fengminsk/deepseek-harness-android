import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'
import { zipSync } from 'fflate'
import { verifyDocumentPreview } from './verify-document-preview.mjs'

const PREFIX = 'assets/document-preview/'
const PREVIEW = '@deepseek-ai/dsh-client-ui-sidebar-documentpreview'
const PACKAGES = ['@deepseek-ai/dsh-client-ui-renderer', '@deepseek-ai/dsh-client-resources',
  '@deepseek-ai/dsh-client-locale', '@deepseek-ai/dsh-api-workspace-files', PREVIEW]
const hash = data => createHash('sha256').update(data).digest('hex')

// These tiny chunks exercise APK inventory integrity, not renderer behavior.
// No fixture, extraction directory, APK, or staging file is written to disk.
function fixture() {
  const files = {
    'index.html': Buffer.from('<html><script src="assets/shell.js"></script></html>'),
    'assets/shell.js': Buffer.from('/* synthetic document shell */'),
    'assets/shell.css': Buffer.from('body { margin: 0; }'),
    'licenses/DSH-LICENSE.txt': Buffer.from('Synthetic original license fixture'),
    'licenses/KaTeX-LICENSE.txt': Buffer.from('Synthetic math font license fixture'),
  }
  const packages = PACKAGES.map(id => {
    const names = id === PREVIEW ? ['client.js', 'client.pdf.js', 'client.excel.js'] : ['client.js']
    return { id, version: 'test', source: 'synthetic', files: names.map(name => {
      const data = Buffer.from(`/* ${id}/${name} */`)
      files[`bundles/${id}/${name}`] = data
      return { name, sha256: hash(data) }
    }) }
  })
  const assets = Object.entries(files).map(([path, data]) => ({ path, sha256: hash(data), bytes: data.length }))
  return { files, manifest: { format: 1, composition: 'document-only', manifest: 'synthetic-manifest', packages, assets } }
}

function apk({ files, manifest }) {
  return zipSync({ 'AndroidManifest.xml': Buffer.from('synthetic non-document APK entry'),
    ...Object.fromEntries(Object.entries(files).map(([path, data]) => [PREFIX + path, data])),
    [PREFIX + 'asset-manifest.json']: Buffer.from(JSON.stringify(manifest)),
  })
}

test('verifies the complete document inventory in a synthetic APK', () => {
  const source = fixture()
  assert.deepEqual(verifyDocumentPreview(apk(source)), {
    success: true, manifest: 'synthetic-manifest', assets: Object.keys(source.files).length,
    bytes: Object.values(source.files).reduce((sum, data) => sum + data.length, 0), packages: PACKAGES,
  })
})

for (const [name, expected] of [['client.pdf.js', /Missing original PDF renderer/],
  ['client.excel.js', /Missing original Excel renderer/]]) {
  test(`refuses an APK whose inventory and module list both omit ${name}`, () => {
    const source = fixture(), path = `bundles/${PREVIEW}/${name}`
    delete source.files[path]
    source.manifest.assets = source.manifest.assets.filter(asset => asset.path !== path)
    const preview = source.manifest.packages.find(pkg => pkg.id === PREVIEW)
    preview.files = preview.files.filter(file => file.name !== name)
    assert.throws(() => verifyDocumentPreview(apk(source)), expected)
  })
}

test('refuses an altered asset even when its byte length is unchanged', () => {
  const source = fixture()
  source.files['assets/shell.js'] = Buffer.alloc(source.files['assets/shell.js'].length, 88)
  assert.throws(() => verifyDocumentPreview(apk(source)), /Wrong asset hash: assets\/shell\.js/)
})

test('refuses an asset with a changed byte length', () => {
  const source = fixture()
  source.files['assets/shell.css'] = Buffer.from('different size')
  assert.throws(() => verifyDocumentPreview(apk(source)), /Wrong asset size: assets\/shell\.css/)
})

test('refuses a listed asset that was dropped from the APK', () => {
  const source = fixture()
  delete source.files['assets/shell.css']
  assert.throws(() => verifyDocumentPreview(apk(source)), /Missing or empty document asset: assets\/shell\.css/)
})

test('refuses an empty asset instead of accepting a hash for no content', () => {
  const source = fixture()
  source.files['assets/shell.js'] = Buffer.alloc(0)
  const asset = source.manifest.assets.find(item => item.path === 'assets/shell.js')
  asset.sha256 = hash(source.files[asset.path])
  asset.bytes = 0
  assert.throws(() => verifyDocumentPreview(apk(source)), /Missing or empty document asset: assets\/shell\.js/)
})

test('refuses duplicate asset inventory identities even when hashes agree', () => {
  const source = fixture()
  source.manifest.assets.push({ ...source.manifest.assets[0] })
  assert.throws(() => verifyDocumentPreview(apk(source)), /Duplicate document asset identity/)
})

test('refuses an altered original chunk even if the asset inventory was rehashed', () => {
  const source = fixture(), path = `bundles/${PREVIEW}/client.pdf.js`
  source.files[path] = Buffer.from('replaced original PDF implementation')
  const asset = source.manifest.assets.find(item => item.path === path)
  asset.sha256 = hash(source.files[path])
  asset.bytes = source.files[path].length
  assert.throws(() => verifyDocumentPreview(apk(source)), /Original module changed:/)
})

test('refuses an original chunk omitted only from the asset inventory', () => {
  const source = fixture(), path = `bundles/${PREVIEW}/client.excel.js`
  source.manifest.assets = source.manifest.assets.filter(asset => asset.path !== path)
  assert.throws(() => verifyDocumentPreview(apk(source)), /Original module not inventoried:/)
})

for (const path of ['', '/absolute.js', '../escape.js', 'nested/../../escape.js', './script.js',
  'nested//script.js', 'nested/', 'C:/drive.js', 'nested\\script.js', 'bad\0name.js', 'asset-manifest.json']) {
  test(`refuses unsafe or reserved inventory path ${JSON.stringify(path)}`, () => {
    const source = fixture()
    source.manifest.assets[0].path = path
    assert.throws(() => verifyDocumentPreview(apk(source)), /Invalid document asset path/)
  })
}

test('refuses an APK without document asset manifest', () => {
  assert.throws(() => verifyDocumentPreview(zipSync({ 'AndroidManifest.xml': Buffer.from('synthetic') })), /Missing or oversized document asset manifest/)
})

test('refuses an empty document asset inventory', () => {
  const source = fixture()
  source.manifest.assets = []
  assert.throws(() => verifyDocumentPreview(apk(source)), /Missing document asset inventory/)
})

test('refuses stale chunks left over from an earlier renderer build', () => {
  const source = fixture()
  source.files['assets/stale.js'] = Buffer.from('old renderer')
  assert.throws(() => verifyDocumentPreview(apk(source)), /Unlisted document asset: assets\/stale\.js/)
})
