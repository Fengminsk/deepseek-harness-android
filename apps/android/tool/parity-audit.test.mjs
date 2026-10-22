import assert from 'node:assert/strict'
import test from 'node:test'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import {
  auditParity, collectParityInventory, parseParityPatch, validateParityManifest,
} from './parity-audit.mjs'

const root = resolve(import.meta.dirname, '../../..')
const paths = {
  webUi: 'packages/bundle/web-app/cordis.patch.yml',
  standardPreset: 'packages/bundle/web-app/presets/standard.patch.yml',
  androidDisabled: 'apps/android/runtime/cordis.patch.yml',
}
const texts = Object.fromEntries(await Promise.all(Object.entries(paths).map(async ([kind, path]) =>
  [kind, await readFile(resolve(root, path), 'utf8')])))
const baseline = JSON.parse(await readFile(resolve(root, 'apps/android/tool/parity-manifest.json'), 'utf8'))
const patches = () => Object.fromEntries(Object.entries(texts).map(([kind, source]) =>
  [kind, parseParityPatch(source)]))
const inventory = () => collectParityInventory(patches())
const manifest = () => structuredClone(baseline)
const check = (ledger, declarations = inventory()) => validateParityManifest(root, ledger, declarations)

test('the committed ledger covers current source declarations without certifying feature completion', async () => {
  const result = await auditParity(root)
  assert.deepEqual(result.errors, [])
  assert.equal(result.ok, true)
  assert.deepEqual(Object.keys(result.counts).sort(), ['androidDisabled', 'standardDelegation', 'standardPreset', 'webUi'])
  assert.ok(result.counts.webUi > 0)
  assert.ok(result.counts.standardDelegation > 0)
  assert.equal(Object.values(result.counts).reduce((sum, count) => sum + count, 0), baseline.entries.length)
  // Existing implementation files are deliberately not proof of feature or device acceptance.
  const missing = baseline.entries.find(entry => entry.key === 'webUi/ui-sidebar-documentpreview')
  assert.equal(missing.status, 'partial')
  assert.equal(missing.evidence.device, 'unverified')
})

test('JavaScript in patch tags remains inert during inventory collection', () => {
  delete globalThis.pocketParityShouldNeverRun
  const source = parseParityPatch('- id: terminal-controller\n  disabled: !!js "globalThis.pocketParityShouldNeverRun = true"\n')
  assert.equal(source[0].disabled.source, 'globalThis.pocketParityShouldNeverRun = true')
  const world = patches()
  world.androidDisabled = source
  assert.ok(collectParityInventory(world).some(row => row.key === 'androidDisabled/terminal-controller'))
  assert.equal(globalThis.pocketParityShouldNeverRun, undefined)
})

for (const kind of ['webUi', 'standardPreset', 'standardDelegation', 'androidDisabled']) {
  test(`an unreviewed new ${kind} declaration fails the ledger check`, async () => {
    const world = patches()
    const row = { id: 'ui-audit-new-feature', name: '@test/new-feature', disabled: true }
    if (kind === 'webUi') world.webUi.push({ insert: [row] })
    else if (kind === 'androidDisabled') world.androidDisabled.push(row)
    else {
      const standard = world.standardPreset.flatMap(item => item.insert ?? [])
        .find(item => item.id === 'preset-standard').config.plugins
      if (kind === 'standardPreset') standard.push(row)
      else standard.find(item => item.id === 'delegation').config.push(row)
    }
    const result = await check(manifest(), collectParityInventory(world))
    assert.equal(result.ok, false)
    assert.ok(result.errors.includes(`Unmapped source declaration: ${kind}/ui-audit-new-feature`))
  })
}

test('removing an original declaration leaves a stale ledger entry that fails', async () => {
  const world = patches()
  for (const row of world.webUi) {
    if (Array.isArray(row.insert)) row.insert = row.insert.filter(item => item.id !== 'ui-sidebar-files')
  }
  const result = await check(manifest(), collectParityInventory(world))
  assert.equal(result.ok, false)
  assert.ok(result.errors.includes('Stale or unknown manifest entry: webUi/ui-sidebar-files'))
})

test('a changed plugin under the same stable source id requires review', async () => {
  const world = patches()
  world.webUi.flatMap(row => row.insert ?? []).find(row => row.id === 'ui-chat').name = '@test/replacement'
  const result = await check(manifest(), collectParityInventory(world))
  assert.equal(result.ok, false)
  assert.ok(result.errors.some(error => error.includes('webUi/ui-chat: source plugin changed')))
})

for (const mutation of ['config', 'disabled', 'nested']) {
  test(`changing only original ${mutation} content invalidates the reviewed source digest`, async () => {
    const world = patches()
    const standard = world.standardPreset.flatMap(row => row.insert ?? [])
      .find(row => row.id === 'preset-standard').config.plugins
    let key
    if (mutation === 'config') {
      standard.find(row => row.id === 'tool-web').config.searchTimeoutMs++
      key = 'standardPreset/tool-web'
    } else if (mutation === 'disabled') {
      const original = standard.find(row => row.id === 'tool-bash')
      original.disabled = parseParityPatch('- disabled: !!js "process.platform !== \'linux\'"')[0].disabled
      key = 'standardPreset/tool-bash'
    } else {
      standard.find(row => row.id === 'planning').config.push({ id: 'new-policy', name: '@test/new-policy' })
      key = 'standardPreset/planning'
    }
    const result = await check(manifest(), collectParityInventory(world))
    assert.equal(result.ok, false)
    assert.ok(result.errors.includes(`${key}: source declaration changed; review sourceDigest and migration evidence`))
  })
}

test('source digests ignore mapping key order but preserve array order and inert expression identity', () => {
  const original = patches()
  const expected = collectParityInventory(original)
  const reordered = patches()
  reordered.standardPreset = reordered.standardPreset.map(row => Object.fromEntries(Object.entries(row).reverse()))
  const standard = reordered.standardPreset.flatMap(row => row.insert ?? [])
    .find(row => row.id === 'preset-standard').config.plugins
  const index = standard.findIndex(row => row.id === 'tool-web')
  standard[index] = { ...standard[index], config: Object.fromEntries(Object.entries(standard[index].config).reverse()) }
  standard[index] = Object.fromEntries(Object.entries(standard[index]).reverse())
  assert.deepEqual(collectParityInventory(reordered), expected)
  const compaction = standard.find(row => row.id === 'compaction')
  assert.ok(compaction.config.length > 1)
  compaction.config.reverse()
  const after = collectParityInventory(reordered)
  assert.notEqual(after.find(row => row.key === 'standardPreset/compaction').sourceDigest,
    expected.find(row => row.key === 'standardPreset/compaction').sourceDigest)
  const bash = standard.find(row => row.id === 'tool-bash')
  bash.disabled = { source: bash.disabled.source }
  assert.notEqual(collectParityInventory(reordered).find(row => row.key === 'standardPreset/tool-bash').sourceDigest,
    expected.find(row => row.key === 'standardPreset/tool-bash').sourceDigest)
})

test('deleting a ledger row cannot hide an original capability', async () => {
  const ledger = manifest()
  ledger.entries = ledger.entries.filter(entry => entry.key !== 'standardPreset/present')
  const result = await check(ledger)
  assert.equal(result.ok, false)
  assert.ok(result.errors.includes('Unmapped source declaration: standardPreset/present'))
})

for (const field of ['sources', 'android', 'evidenceRefs']) {
  test(`an absent ${field} reference fails instead of serving as evidence`, async () => {
    const ledger = manifest()
    const entry = ledger.entries[0]
    const missing = 'apps/android/tool/parity-audit-file-does-not-exist.dart'
    if (field === 'evidenceRefs') entry.evidenceRefs = { behavior: [missing] }
    else entry[field].push(missing)
    const result = await check(ledger)
    assert.equal(result.ok, false)
    assert.ok(result.errors.some(error => error.includes(`reference unavailable: ${missing}`)))
  })
}

test('invalid migration and evidence states fail with their record identity', async () => {
  const ledger = manifest()
  ledger.entries[0].status = 'done-because-file-exists'
  ledger.entries[0].evidence.ui = 'looks-complete'
  const result = await check(ledger)
  assert.equal(result.ok, false)
  assert.ok(result.errors.some(error => error.includes('invalid migration status')))
  assert.ok(result.errors.some(error => error.includes('invalid ui evidence state')))
})

test('verified and not-applicable claims need explicit support', async () => {
  const ledger = manifest()
  ledger.entries[0].evidence.behavior = 'verified'
  ledger.entries[0].evidence.device = 'not-applicable'
  ledger.entries[0].notApplicable = { device: 1 }
  const result = await check(ledger)
  assert.equal(result.ok, false)
  assert.ok(result.errors.some(error => error.includes('verified behavior needs evidence references')))
  assert.ok(result.errors.some(error => error.includes('device not-applicable needs a reason')))
})

test('duplicate source or ledger entries cannot inflate inventory coverage', async () => {
  const world = patches()
  const row = world.webUi.flatMap(item => item.insert ?? []).find(item => item.id === 'ui-chat')
  world.webUi.push({ insert: [row] })
  assert.throws(() => collectParityInventory(world), /Duplicate source declaration: webUi\/ui-chat/u)
  const ledger = manifest()
  ledger.entries.push(ledger.entries[0])
  const result = await check(ledger)
  assert.equal(result.ok, false)
  assert.ok(result.errors.some(error => error.startsWith('Duplicate manifest entry:')))
})

test('reference paths and malformed entries are rejected without inspecting outside the repository', async () => {
  const ledger = manifest()
  ledger.entries[0].sources = {}
  ledger.entries[0].android = ['../private-token.json', 'C:\\private\\token.json']
  const result = await check(ledger)
  assert.equal(result.ok, false)
  assert.ok(result.errors.some(error => error.includes('sources must be a nonempty array')))
  assert.equal(result.errors.filter(error => error.includes('reference must be a repository-relative file')).length, 2)
})

test('malformed source composition fails rather than silently yielding an empty scope', () => {
  assert.throws(() => parseParityPatch('not: a sequence'), /must be a sequence/u)
  const world = patches()
  world.standardPreset = []
  assert.throws(() => collectParityInventory(world), /exactly one standard preset/u)
})
