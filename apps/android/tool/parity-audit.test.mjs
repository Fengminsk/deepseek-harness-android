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
  bundleBase: 'packages/bundle/base/cordis.patch.yml',
  bundleHeadless: 'packages/bundle/headless/cordis.patch.yml',
  bundleSdkMinimal: 'packages/bundle/sdk-minimal/cordis.patch.yml',
  bundleSdkApp: 'packages/bundle/sdk-app/cordis.patch.yml',
  bundleAcpApp: 'packages/bundle/acp-app/cordis.patch.yml',
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
  assert.match(result.scope, /insert\/override rows from base, headless/u)
  assert.deepEqual(Object.keys(result.counts).sort(),
    ['androidDisabled', 'optionalBundle', 'standardDelegation', 'standardNested', 'standardPreset', 'webService', 'webUi'])
  assert.ok(result.counts.webUi > 0)
  assert.ok(result.counts.webService > 0)
  assert.ok(result.counts.standardDelegation > 0)
  assert.ok(result.counts.optionalBundle > 0)
  assert.equal(Object.values(result.counts).reduce((sum, count) => sum + count, 0), baseline.entries.length)
  // Existing implementation files are deliberately not proof of feature or device acceptance.
  const missing = baseline.entries.find(entry => entry.key === 'webUi/ui-sidebar-documentpreview')
  assert.equal(missing.status, 'partial')
  assert.notEqual(missing.evidence.device, 'verified')
})

test('optional bundle rows retain source identity even when plugins repeat between bundles', () => {
  const rows = inventory()
  const base = rows.find(row => row.key === 'optionalBundle/base/insert/llm')
  const minimal = rows.find(row => row.key === 'optionalBundle/sdk-minimal/insert/llm')
  assert.equal(base.plugin, minimal.plugin)
  assert.notEqual(base.source, minimal.source)
  assert.equal(base.sourceDigest, minimal.sourceDigest)
  assert.ok(rows.some(row => row.key === 'optionalBundle/headless/override/tools'))
  assert.ok(rows.some(row => row.key === 'optionalBundle/acp-app/insert/acp'))
  assert.ok(rows.some(row => row.key === 'optionalBundle/sdk-app/insert/sdk-jsonrpc-server'))
})

test('new or changed optional bundle declarations require a manual ledger review', async () => {
  const added = patches()
  added.bundleHeadless.push({ insert: [{ id: 'new-runner', name: '@test/new-runner' }] })
  const addition = await check(manifest(), collectParityInventory(added))
  assert.ok(addition.errors.includes('Unmapped source declaration: optionalBundle/headless/insert/new-runner'))
  const changed = patches()
  changed.bundleAcpApp.flatMap(row => row.insert ?? [])
    .find(row => row.id === 'acp').config.provider = 'other'
  const modification = await check(manifest(), collectParityInventory(changed))
  assert.ok(modification.errors.some(error => error.includes(
    'optionalBundle/acp-app/insert/acp: source declaration changed')))
  const removed = patches()
  removed.bundleSdkMinimal[0].insert = removed.bundleSdkMinimal[0].insert
    .filter(row => row.id !== 'sdk-jsonrpc-server')
  const deletion = await check(manifest(), collectParityInventory(removed))
  assert.ok(deletion.errors.includes(
    'Stale or unknown manifest entry: optionalBundle/sdk-minimal/insert/sdk-jsonrpc-server'))
})

test('unassessed rows cannot be promoted to partial without Android mapping', async () => {
  const key = 'optionalBundle/headless/insert/headless-runner'
  const ledger = manifest()
  ledger.entries.find(row => row.key === key).status = 'partial'
  const result = await check(ledger)
  assert.ok(result.errors.includes(`${key}: partial mapping requires Android source references`))
  const exaggerated = manifest()
  const entry = exaggerated.entries.find(row => row.key === key)
  entry.status = 'unassessed'
  entry.evidence.behavior = 'verified'
  const claim = await check(exaggerated)
  assert.ok(claim.errors.includes(`${key}: unassessed rows cannot claim Android mapping or evidence`))
})

test('source review distinguishes alternative launchers from shared capabilities without claiming execution evidence', async () => {
  const optional = baseline.entries.filter(entry => entry.key.startsWith('optionalBundle/'))
  assert.ok(optional.length > 0)
  for (const entry of optional) {
    assert.notEqual(entry.status, 'unassessed')
    assert.deepEqual(Object.values(entry.evidence), ['unverified', 'unverified', 'unverified', 'unverified'])
  }
  const lookup = key => baseline.entries.find(entry => entry.key === key)
  assert.equal(lookup('optionalBundle/headless/insert/headless-runner').status, 'not-applicable')
  const alternateTool = lookup('optionalBundle/sdk-minimal/insert/tool-fs')
  assert.equal(alternateTool.status, 'not-applicable')
  assert.ok(alternateTool.assessment.relatedDeclarations.includes('optionalBundle/base/insert/tool-fs'))
  assert.equal(alternateTool.capability, lookup('standardPreset/tool-fs').capability)
  assert.equal(lookup('optionalBundle/base/insert/tool-fs').assessment.composition, 'preset')
  assert.equal(lookup('optionalBundle/base/insert/ptc-runtime').status, 'not-migrated')
  assert.equal(lookup('optionalBundle/sdk-app/insert/skill-office').status, 'not-migrated')
  const result = await check(manifest())
  assert.equal(result.migration.unassessed, 0)
  assert.equal(result.capabilities.find(capability => capability.id === 'linux').declarations.length, 0)
  const linuxRemaining = result.capabilities.find(capability => capability.id === 'linux').remaining
  assert.match(linuxRemaining, /offline Alpine candidate/u)
  assert.match(linuxRemaining, /exact image\/build evidence/u)
  assert.match(linuxRemaining, /LINUX_VM_DEVICE_ACCEPTED=true/u)
  assert.match(linuxRemaining, /LINUX_VM_NETWORK_DEVICE_ACCEPTED=false/u)
  assert.match(linuxRemaining, /Build 116 r28 adds a shipped-profile workflow child/u)
  assert.match(linuxRemaining, /Build 117 retains these registrations and passed a retained-data upgrade/u)
  assert.match(linuxRemaining, /Guest HTTPS approval and routes remain unaccepted and source-disabled/u)
  const programmaticRemaining = result.capabilities.find(capability => capability.id === 'programmatic').remaining
  assert.match(programmaticRemaining, /MODEL_PTC_DEVICE_ACCEPTED=true/u)
  assert.match(programmaticRemaining, /MODEL_WORKFLOW_DEVICE_ACCEPTED=true/u)
  assert.match(programmaticRemaining, /Build 116 r28 passed the shipped profile with expectWorkflow=true/u)
  assert.match(programmaticRemaining, /ordinary upgrades to 116 and 117 retained the recorded data/u)
  assert.match(programmaticRemaining, /r25 workflow hang came from unbounded Node waits/u)
  assert.match(programmaticRemaining, /OEM freezer, which suspended the App while AMS reported no freeze/u)
  assert.match(programmaticRemaining, /original Node PTC\/workflow plugins remain disabled/u)
  const background = result.capabilities.find(capability => capability.id === 'background')
  assert.match(background.remaining, /natural alarm startup.*have no device acceptance/u)
  assert.ok(background.sources.includes('apps/android/runtime/native-schedule-wakeup.mjs'))
  assert.equal(lookup('webService/schedule').status, 'partial')
  assert.notEqual(lookup('webService/schedule').evidence.device, 'verified')
})

test('excluding a declaration requires an explicit native-entrypoint reason', async () => {
  const ledger = manifest()
  const entry = ledger.entries.find(row => row.key === 'optionalBundle/headless/insert/headless-runner')
  delete entry.notApplicableReason
  const result = await check(ledger)
  assert.ok(result.errors.includes(`${entry.key}: not-applicable status needs a native-entrypoint exclusion reason`))
})

test('a reviewed optional declaration needs a valid composition and related source identity', async () => {
  const ledger = manifest()
  const entry = ledger.entries.find(row => row.key === 'optionalBundle/base/insert/llm')
  entry.assessment = { composition: 'alternate-profile', entryPoint: 'available-because-imported',
    relatedDeclarations: [entry.key, 'webUi/imaginary'] }
  const result = await check(ledger)
  assert.ok(result.errors.includes(`${entry.key}: composition must distinguish the selected base from alternative profiles`))
  assert.ok(result.errors.includes(`${entry.key}: invalid Android entrypoint assessment`))
  assert.equal(result.errors.filter(error => error.startsWith(`${entry.key}: invalid related declaration`)).length, 2)
})

test('capability groups keep every declaration assigned and require their own source and remaining work', async () => {
  const ledger = manifest()
  ledger.entries[0].capability = 'invented'
  ledger.capabilities[0].sources = []
  delete ledger.capabilities[0].remaining
  ledger.capabilities.push(ledger.capabilities[1])
  const result = await check(ledger)
  assert.ok(result.errors.some(error => error.includes('unknown capability invented')))
  assert.ok(result.errors.some(error => error.includes('capability sources must be a nonempty array')))
  assert.ok(result.errors.some(error => error.includes('capability remaining is required')))
  assert.ok(result.errors.some(error => error.startsWith('Duplicate capability:')))
})

test('changes to composition outside declaration rows invalidate the source review', async () => {
  const ledger = manifest()
  const input = ledger.reviewInputs.find(row => row.path === 'apps/android/tool/stage-preset.mjs')
  input.sha256 = '0'.repeat(64)
  ledger.reviewInputs = ledger.reviewInputs.filter(row => row.path !== 'apps/android/runtime/host-guard.mjs')
  const result = await check(ledger)
  assert.ok(result.errors.some(error => error.startsWith(`${input.path}: Android composition changed;`)))
  assert.ok(result.errors.includes('Missing composition review input: apps/android/runtime/host-guard.mjs'))
  const malformed = manifest()
  malformed.reviewInputs = {}
  assert.ok((await check(malformed)).errors.includes('Manifest reviewInputs must be an array'))
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

for (const kind of ['webUi', 'webService', 'standardPreset', 'standardDelegation', 'androidDisabled']) {
  test(`an unreviewed new ${kind} declaration fails the ledger check`, async () => {
    const world = patches()
    const id = kind === 'webService' ? 'audit-new-service' : 'ui-audit-new-feature'
    const row = { id, name: '@test/new-feature', disabled: true }
    if (kind === 'webUi' || kind === 'webService') world.webUi.push({ insert: [row] })
    else if (kind === 'androidDisabled') world.androidDisabled.push(row)
    else {
      const standard = world.standardPreset.flatMap(item => item.insert ?? [])
        .find(item => item.id === 'preset-standard').config.plugins
      if (kind === 'standardPreset') standard.push(row)
      else standard.find(item => item.id === 'delegation').config.push(row)
    }
    const result = await check(manifest(), collectParityInventory(world))
    assert.equal(result.ok, false)
    assert.ok(result.errors.includes(`Unmapped source declaration: ${kind}/${id}`))
  })
}

test('removing or changing a Web service requires ledger review', async () => {
  const removed = patches()
  for (const row of removed.webUi) {
    if (Array.isArray(row.insert)) row.insert = row.insert.filter(item => item.id !== 'workspace-files')
  }
  const removedResult = await check(manifest(), collectParityInventory(removed))
  assert.ok(removedResult.errors.includes('Stale or unknown manifest entry: webService/workspace-files'))
  const changed = patches()
  changed.webUi.flatMap(row => row.insert ?? []).find(row => row.id === 'workspace-files')
    .name = '@test/replaced-workspace-files'
  const changedResult = await check(manifest(), collectParityInventory(changed))
  assert.ok(changedResult.errors.some(error => error.includes('webService/workspace-files: source plugin changed')))
})

test('an unreviewed nested non-delegation plugin fails the ledger check', async () => {
  const world = patches()
  const standard = world.standardPreset.flatMap(item => item.insert ?? [])
    .find(item => item.id === 'preset-standard').config.plugins
  standard.find(item => item.id === 'planning').config.push({
    id: 'new-policy', name: '@test/new-policy',
  })
  const result = await check(manifest(), collectParityInventory(world))
  assert.equal(result.ok, false)
  assert.ok(result.errors.includes('Unmapped source declaration: standardNested/planning/new-policy'))
})

test('nested plugin groups require an inspectable plugin sequence', () => {
  const world = patches()
  const standard = world.standardPreset.flatMap(item => item.insert ?? [])
    .find(item => item.id === 'preset-standard').config.plugins
  standard.find(item => item.id === 'planning').config = {}
  assert.throws(() => collectParityInventory(world), /Expected nested plugins in planning/u)
})

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
