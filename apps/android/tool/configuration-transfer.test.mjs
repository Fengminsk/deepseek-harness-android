import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { createRequire, registerHooks } from 'node:module'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { test } from 'node:test'

const require = createRequire(new URL('../../../packages/settings/settings/package.json', import.meta.url))
const schemaUrl = pathToFileURL(require.resolve('@deepseek-ai/schemastery')).href
const resolver = registerHooks({
  resolve(specifier, context, next) {
    return specifier === '@deepseek-ai/schemastery' ? next(schemaUrl, context) : next(specifier, context)
  },
})
const { default: Schema } = await import(schemaUrl)
const { AppConfigurationTransfers } = await import('../runtime/configuration-transfer.mjs')
resolver.deregister()

function fixture() {
  const schema = Schema.object({
    maxTokens: Schema.natural().min(1).max(10000),
    apiKey: Schema.string().role('secret'),
    apiKeyEnv: Schema.string(),
    cwd: Schema.string(),
    retry: Schema.object({ count: Schema.natural(), token: Schema.string().role('secret') }),
    profiles: Schema.array(Schema.object({ name: Schema.string(), token: Schema.string().role('secret') })),
    models: Schema.array(Schema.object({ id: Schema.string(), limit: Schema.natural() })),
    extra: Schema.any(),
  })
  const values = { maxTokens: 100, apiKeyEnv: 'DEVICE_KEY', cwd: '/private/device',
    retry: { count: 1 }, profiles: [{ name: 'one' }], models: [{ id: 'old', limit: 10 }], extra: { arbitrary: true } }
  const descriptors = ['models', 'other', 'android-runtime'].map(ns => ({
    ns, revision: 1, value: structuredClone(values), schema: schema.toJSON(),
    secrets: [{ path: ['apiKey'], set: true }, { path: ['retry', 'token'], set: true }],
  }))
  const writes = []
  const settings = {
    describe(options) {
      assert.equal(options.redactSecrets, true)
      return structuredClone(descriptors)
    },
    async mutate(ns, ops, revision) {
      writes.push({ ns, ops: structuredClone(ops), revision })
      const descriptor = descriptors.find(row => row.ns === ns)
      if (descriptor.revision !== revision) throw Object.assign(new Error('conflict'), { code: 'SETTINGS_CONFLICT' })
      for (const op of ops) {
        assert.equal(op.op, 'set')
        let parent = descriptor.value
        for (const key of op.path.slice(0, -1)) parent = parent[key] ??= {}
        parent[op.path.at(-1)] = structuredClone(op.value)
      }
      descriptor.revision++
    },
  }
  const service = new AppConfigurationTransfers({ settings }, { protectedNamespaces: new Set(['android-runtime']) })
  return { service, settings, descriptors, writes }
}

const document = (sections, extras = {}) => JSON.stringify({
  format: 'pocket-harness-settings', version: 1, sections, ...extras,
})
const field = (path, value) => ({ path, value })
const section = (ns, fields = [field(['maxTokens'], 200)]) => ({ ns, fields })

test('exports actual schema-declared ordinary leaves and lists every protected omission', () => {
  const { service } = fixture()
  const exported = service.export()
  const fields = exported.sections.find(row => row.ns === 'models').fields
  assert.deepEqual(fields, [
    field(['maxTokens'], 100), field(['retry', 'count'], 1),
    field(['models'], [{ id: 'old', limit: 10 }]),
  ])
  assert.ok(exported.excluded.some(row => row.ns === 'android-runtime'))
  for (const path of [['apiKey'], ['apiKeyEnv'], ['cwd'], ['profiles'], ['retry', 'token'], ['extra', 'arbitrary']]) {
    assert.ok(exported.excluded.some(row => row.ns === 'models' && JSON.stringify(row.path) === JSON.stringify(path)))
  }
  assert.ok(!exported.text.includes('/private/device'))
  const plan = service.preview({ text: exported.text })
  assert.equal(plan.issues.length, 0)
  assert.ok(plan.sections.every(row => row.changes.length === 0))
})

test('preview has no write; selected namespace applies leaf edits through original revision', async () => {
  const { service, writes, descriptors } = fixture()
  const plan = service.preview({ text: document([
    section('models', [field(['retry', 'count'], 4)]), section('other'),
  ]) })
  assert.equal(writes.length, 0)
  assert.deepEqual(plan.sections[0].changes, [{ path: ['retry', 'count'], before: 1, after: 4 }])
  const result = await service.apply({ id: plan.id, namespaces: ['models'] })
  assert.equal(result.busy, false)
  assert.equal(result.sections[0].status, 'applied')
  assert.equal(result.sections[1].status, 'pending')
  assert.deepEqual(writes, [{ ns: 'models', ops: [{ op: 'set', path: ['retry', 'count'], value: 4 }], revision: 1 }])
  assert.equal(descriptors[0].value.maxTokens, 100)
  assert.equal(descriptors[0].value.apiKeyEnv, 'DEVICE_KEY')
})

test('secret ancestors, secret arrays, unknown nested keys, device fields and invalid ranges block writes visibly', async () => {
  const { service, writes } = fixture()
  for (const entry of [
    field(['apiKey'], 'do-not-import'),
    field(['retry'], { count: 4 }),
    field(['profiles'], [{ name: 'replacement' }]),
    field(['models'], [{ id: 'known', limit: 1, hidden: 'unknown' }]),
    field(['apiKeyEnv'], 'OTHER_DEVICE'),
    field(['cwd'], '/other'),
    field(['maxTokens'], -5),
    field(['unknown'], 'value'),
    field(['extra'], {}),
  ]) {
    const plan = service.preview({ text: document([section('models', [entry])]) })
    assert.equal(plan.issues.length, 1, JSON.stringify(entry.path))
    await assert.rejects(service.apply({ id: plan.id, namespaces: ['models'] }), /未处理/)
    service.release({ id: plan.id })
  }
  assert.equal(writes.length, 0)
})

test('Android-owned and unavailable namespaces do not mutate or implicitly install plugins', () => {
  const { service, writes } = fixture()
  const plan = service.preview({ text: document([section('android-runtime'), section('missing')]) })
  assert.equal(plan.issues.length, 2)
  assert.equal(plan.sections.length, 0)
  assert.equal(writes.length, 0)
})

test('preflight and original service CAS both stop after an earlier acknowledged namespace', async () => {
  for (const duringWrite of [false, true]) {
    const { service, settings, descriptors, writes } = fixture()
    const plan = service.preview({ text: document([section('models'), section('other')]) })
    if (duringWrite) {
      const mutate = settings.mutate
      settings.mutate = async (ns, ops, revision) => {
        if (ns === 'other') descriptors[1].revision++
        return mutate(ns, ops, revision)
      }
    } else descriptors[1].revision++
    const result = await service.apply({ id: plan.id, namespaces: ['models', 'other'] })
    assert.equal(result.sections[0].status, 'applied')
    assert.equal(result.sections[1].status, 'conflict')
    assert.equal(descriptors[0].value.maxTokens, 200)
    assert.equal(descriptors[1].value.maxTokens, 100)
    await assert.rejects(service.apply({ id: plan.id, namespaces: ['models', 'other'] }), /不会自动重放/)
    assert.equal(writes.filter(row => row.ns === 'models').length, 1)
  }
})

test('lost acknowledgement never becomes a retryable failure or rolls back earlier writes', async () => {
  const { service, settings, writes, descriptors } = fixture()
  const original = settings.mutate
  settings.mutate = async (...args) => {
    await original(...args)
    throw new Error('write completed but acknowledgement lost')
  }
  const plan = service.preview({ text: document([section('models'), section('other')]) })
  const result = await service.apply({ id: plan.id, namespaces: ['models', 'other'] })
  assert.equal(result.sections[0].status, 'unknown')
  assert.equal(result.sections[1].status, 'pending')
  assert.equal(descriptors[0].value.maxTokens, 200)
  assert.equal(writes.length, 1)
  await assert.rejects(service.apply({ id: plan.id, namespaces: ['models'] }), /不会自动重放/)
})

test('editing returned preview cannot modify the held plan and double taps cannot write twice', async () => {
  const { service, settings, writes } = fixture()
  const gate = Promise.withResolvers()
  const original = settings.mutate
  settings.mutate = async (...args) => { await gate.promise; return original(...args) }
  const plan = service.preview({ text: document([section('models')]) })
  plan.sections[0].changes[0].after = 999
  const applying = service.apply({ id: plan.id, namespaces: ['models'] })
  await assert.rejects(service.apply({ id: plan.id, namespaces: ['models'] }), /正在应用/)
  assert.throws(() => service.release({ id: plan.id }), /正在写入/)
  gate.resolve()
  await applying
  assert.equal(writes[0].ops[0].value, 200)
})

test('unknown document keys, unsafe paths, overlapping fields, YAML and oversized input fail before preview', () => {
  const { service } = fixture()
  for (const text of [
    document([section('models')], { credentials: { key: 'secret' } }),
    document([section('models', [field(['retry'], {}), field(['retry', 'count'], 1)])]),
    document([section('models', [field(['__proto__', 'polluted'], true)])]),
    document([section('models'), section('models')]),
    '- id: web-startup\n  disabled: false',
    ' '.repeat(1048577),
  ]) assert.throws(() => service.preview({ text }))
  assert.equal(service.plans.size, 0)
  assert.equal({}.polluted, undefined)
})

test('closing releases previews and refuses further operations', async () => {
  const { service } = fixture()
  const plan = service.preview({ text: document([section('models')]) })
  service.close()
  assert.equal(service.plans.size, 0)
  assert.throws(() => service.export(), /关闭/)
  await assert.rejects(service.apply({ id: plan.id, namespaces: ['models'] }), /关闭/)
})

test('real Loader and Settings owner persist ordinary imports, preserve secrets and refuse concurrent changes', async () => {
  const load = name => import(pathToFileURL(require.resolve(name)).href)
  const [{ boot, initProfile, readProfilePatches }, { default: ConfigEditor }, { default: Settings }] =
    await Promise.all([
      load('@deepseek-ai/dsh-app-boot'), load('@deepseek-ai/dsh-config-editor'), load('@deepseek-ai/dsh-settings'),
    ])
  const home = await mkdtemp(join(tmpdir(), 'pocket-config-transfer-'))
  const directory = join(home, 'profiles', 'transfer')
  let ctx
  try {
    initProfile(directory, ['transfer-fixture'])
    const bundle = join(directory, 'node_modules', 'transfer-fixture')
    await mkdir(bundle, { recursive: true })
    await writeFile(join(home, 'package.json'), '{"name":"transfer-fixture"}\n')
    await writeFile(join(bundle, 'package.json'), JSON.stringify({
      name: 'transfer-fixture', version: '1.0.0', dsh: { bundle: { patch: 'cordis.patch.yml' } },
    }))
    await writeFile(join(bundle, 'cordis.patch.yml'), JSON.stringify([{ insert: [
      { id: 'config-editor', name: 'cordis:editor' },
      { id: 'settings', name: 'cordis:settings' },
      { id: 'probe', name: 'cordis:probe', config: { token: 'fixture-secret', fixed: 'keep' } },
    ] }]))
    await writeFile(join(directory, 'cordis.yml'), '[]\n')
    const profile = {
      name: 'transfer', startedBundles: ['transfer-fixture'], dir: directory,
      patchPath: join(directory, 'cordis.patch.yml'), installAnchor: join(home, 'package.json'),
      cwd: home, home, overlays: [], telemetryDisabledEnv: undefined,
    }
    const start = () => boot('transfer', join(directory, 'cordis.yml'), readProfilePatches('transfer', profile), ctx => {
      ctx.provide('profileContext', profile)
      ctx.provide('appReady', { onReady(listener) { listener(); return () => {} } })
      Object.assign(ctx.loader.builtins, {
        editor: ConfigEditor, settings: Settings,
        probe: { Config: Schema.object({
          fixed: Schema.string(),
          count: Schema.natural().default(2).volatile(),
          token: Schema.string().role('secret').volatile(),
        }), apply() {} },
      })
    })
    ctx = await start()
    const service = new AppConfigurationTransfers(ctx)
    const before = service.export()
    assert.ok(!before.text.includes('fixture-secret'))
    assert.deepEqual(before.sections, [{ ns: 'probe', fields: [field(['count'], 2)] }])
    const plan = service.preview({ text: document([section('probe', [field(['count'], 7)])]) })
    assert.equal(plan.issues.length, 0)
    const applied = await service.apply({ id: plan.id, namespaces: ['probe'] })
    assert.equal(applied.sections[0].status, 'applied')
    assert.equal(ctx.settings.describe().find(row => row.ns === 'probe').value.token, 'fixture-secret')
    assert.match(await readFile(profile.patchPath, 'utf8'), /count: 7/)
    const stale = service.preview({ text: document([section('probe', [field(['count'], 9)])]) })
    await ctx.settings.mutate('probe', [{ op: 'set', path: ['count'], value: 8 }], stale.sections[0].revision)
    const conflict = await service.apply({ id: stale.id, namespaces: ['probe'] })
    assert.equal(conflict.sections[0].status, 'conflict')
    assert.equal(ctx.settings.describe().find(row => row.ns === 'probe').value.count, 8)
    service.close()
    await ctx.fiber.dispose()
    ctx = await start()
    assert.equal(ctx.settings.describe().find(row => row.ns === 'probe').value.count, 8)
    assert.equal(ctx.settings.describe().find(row => row.ns === 'probe').value.token, 'fixture-secret')
  } finally {
    await ctx?.fiber.dispose()
    // mkdtemp above created this test-owned tree; the absolute target is confined to the temp root.
    assert.ok(resolve(home).startsWith(resolve(tmpdir()) + '\\') || resolve(home).startsWith(resolve(tmpdir()) + '/'))
    await rm(home, { recursive: true, force: true })
  }
})
