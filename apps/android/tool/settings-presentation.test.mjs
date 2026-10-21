import assert from 'node:assert/strict'
import { test } from 'node:test'
import { describeAndroidSettings } from '../runtime/settings-presentation.mjs'

function context(forms, entries, packages) {
  const editor = entries === undefined ? undefined : { configuration: () => entries }
  return {
    settings: { describe(options) { assert.deepEqual(options, { redactSecrets: true }); return forms } },
    get(name) {
      if (name === 'configEditor') return editor
      if (name === 'pluginPackages') return packages
      throw new Error(`Unexpected service ${name}`)
    },
  }
}

test('settings artwork uses the exact configured entry and its own resolver base', () => {
  const form = { ns: 'custom-entry', revision: 6, value: { key: '[redacted]' }, secrets: [{ path: ['key'] }] }
  const metadata = { title: { zh: '测试工具' }, icon: 'data:image/svg+xml;base64,PHN2Zy8+' }
  const calls = []
  const ctx = context([form], [
    { entry: { options: { id: 'another-entry', name: '@test/other' }, parent: { tree: { ctx: { baseUrl: 'file:///other/' } } } } },
    { entry: { options: { id: 'custom-entry', name: '@test/plugin' }, parent: { tree: { ctx: { baseUrl: 'file:///profile/' } } } } },
  ], { metaOf(...args) { calls.push(args); return metadata } })
  assert.deepEqual(describeAndroidSettings(ctx), [{ ...form, display: { moduleName: '@test/plugin', ...metadata } }])
  assert.deepEqual(calls, [['@test/plugin', 'file:///profile/']])
  assert.equal(Object.hasOwn(form, 'display'), false)
})

test('missing entry and resolver base keep editable settings without fabricating artwork', () => {
  const forms = [{ ns: 'without-base', revision: 0, value: {} }, { ns: 'not-in-configuration', revision: 4, value: { timeout: 60 } }]
  const ctx = context(forms, [
    { entry: { options: { id: 'without-base', name: '@test/tool' }, parent: { tree: { ctx: {} } } } },
  ], { metaOf() { assert.fail('No metadata lookup without an owner base') } })
  assert.deepEqual(describeAndroidSettings(ctx), [
    { ...forms[0], display: { moduleName: '@test/tool' } }, forms[1],
  ])
})

test('optional presentation providers may be absent in a minimal profile', () => {
  const forms = [{ ns: 'tool', revision: 8, value: { key: '[redacted]' } }]
  for (const [entries, packages] of [[undefined, undefined], [[], undefined], [undefined, { metaOf() {} }]]) {
    assert.equal(describeAndroidSettings(context(forms, entries, packages)), forms)
  }
})

test('presentation never hides a real settings read failure', () => {
  const failure = new Error('settings unavailable')
  const ctx = { settings: { describe() { throw failure } }, get() { assert.fail('Settings read must occur first') } }
  assert.throws(() => describeAndroidSettings(ctx), error => error === failure)
})

test('updated metadata and resource diagnostics are read again without caching old icons', () => {
  let metadata = { icon: 'data:image/png;base64,Zmlyc3Q=' }
  const ctx = context([{ ns: 'plugin', revision: 2, value: {} }], [
    { entry: { options: { id: 'plugin', name: '@test/plugin' }, parent: { tree: { ctx: { baseUrl: 'file:///profile/' } } } } },
  ], { metaOf: () => metadata })
  assert.equal(describeAndroidSettings(ctx)[0].display.icon, metadata.icon)
  metadata = { error: 'icon is missing' }
  assert.deepEqual(describeAndroidSettings(ctx)[0].display, { moduleName: '@test/plugin', error: 'icon is missing' })
})
