import assert from 'node:assert/strict'
import { test } from 'node:test'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ANDROID_BUNDLES, assertAndroidHostConfiguration } from '../runtime/host-guard.mjs'

const root = resolve(import.meta.dirname, '../../..')
const installAnchor = join(root, '.cache/android/runtime-bundle/node_modules/@deepseek-ai/dsh/package.json')
function fixture(bundles = [...ANDROID_BUNDLES]) {
  const home = mkdtempSync(join(root, '.cache/android/guard-'))
  const profile = join(home, 'profiles/android')
  mkdirSync(profile, { recursive: true })
  const manifest = JSON.stringify({ name: 'guard-fixture', type: 'module', dsh: { profile: { bundles } } }, null, 2) + '\n'
  writeFileSync(join(profile, 'package.json'), manifest)
  return { home, profile, check: () => assertAndroidHostConfiguration({ home, installAnchor }) }
}

test('normal settings and extension entries survive without rewriting user source', () => {
  const f = fixture()
  const patch = '# preserve this comment\n- id: android-runtime\n  config:\n    shellOutputLimit: 8192\n'
    + '- id: connection\n  config:\n    cookieMaxAgeDays: 7\n'
    + '- insert:\n    - id: user-extension\n      name: ./user-extension.mjs\n      disabled: true\n'
  const home = '# home preference\n- id: approval\n  config:\n    policy: never\n'
  writeFileSync(join(f.profile, 'cordis.patch.yml'), patch)
  writeFileSync(join(f.home, 'cordis.patch.yml'), home)
  const before = readFileSync(join(f.profile, 'package.json'))
  f.check()
  assert.equal(readFileSync(join(f.profile, 'cordis.patch.yml'), 'utf8'), patch)
  assert.equal(readFileSync(join(f.home, 'cordis.patch.yml'), 'utf8'), home)
  assert.deepEqual(readFileSync(join(f.profile, 'package.json')), before)
})

for (const layer of ['profile', 'home']) {
  for (const id of ['web-startup', 'webserver', 'web-runtime', 'android-runtime']) {
    test(`${layer} cannot change ${id} activation`, () => {
      const f = fixture()
      const directory = layer === 'profile' ? f.profile : f.home
      const patch = `- id: ${id}\n  disabled: ${id === 'android-runtime' ? 'true' : 'false'}\n`
      writeFileSync(join(directory, 'cordis.patch.yml'), patch)
      assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION' })
      assert.equal(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), patch)
    })
  }
}

test('required bundles cannot be missing or duplicated', () => {
  for (const bundles of [ANDROID_BUNDLES.slice(0, 2), [...ANDROID_BUNDLES, ANDROID_BUNDLES[2]]]) {
    const f = fixture(bundles)
    const before = readFileSync(join(f.profile, 'package.json'))
    assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION' })
    assert.deepEqual(readFileSync(join(f.profile, 'package.json')), before)
  }
})

test('Web activation expression and context interception are not evaluated or accepted', () => {
  for (const patch of [
    '- id: webserver\n  disabled: !!js false\n',
    '- id: android-runtime\n  intercept: { connection: other }\n',
    '- id: connection\n  config:\n    trustedHosts: [example.com]\n',
    "- id: connection\n  config: !!js '({ trustedHosts: [] })'\n",
  ]) {
    const f = fixture()
    writeFileSync(join(f.profile, 'cordis.patch.yml'), patch)
    assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION' })
  }
})

test('another row cannot instantiate the same Web module by name or absolute file alias', () => {
  const modulePath = fileURLToPath(new URL(
    '../../../.cache/android/runtime-bundle/node_modules/@deepseek-ai/dsh-host-webserver/lib/index.js', import.meta.url))
  for (const name of ['@deepseek-ai/dsh-host-webserver', pathToFileURL(modulePath).href]) {
    const f = fixture()
    writeFileSync(join(f.profile, 'cordis.patch.yml'),
      `- insert:\n    - id: unowned-listener\n      name: '${name}'\n      config:\n        host: 127.0.0.1\n        port: 12345\n`)
    assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION' })
  }
})

test('PTC and workflow execution cannot be enabled through profile or home overlays', () => {
  for (const layer of ['profile', 'home']) {
    for (const id of ['ptc-runtime', 'workflow-ptc', 'tool-workflow']) {
      const f = fixture()
      const directory = layer === 'profile' ? f.profile : f.home
      const patch = `- id: ${id}\n  disabled: false\n`
      writeFileSync(join(directory, 'cordis.patch.yml'), patch)
      assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION', entry: id })
      assert.equal(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), patch)
    }
  }
})

test('PTC and workflow execution cannot be reintroduced under new IDs or module aliases', () => {
  for (const id of ['ptc-runtime', 'workflow-ptc', 'tool-workflow']) {
    const name = {
      'ptc-runtime': '@deepseek-ai/dsh-ptc-runtime-node',
      'workflow-ptc': '@deepseek-ai/dsh-workflow-ptc',
      'tool-workflow': '@deepseek-ai/dsh-tool-workflow',
    }[id]
    const modulePath = join(root, '.cache/android/runtime-bundle/node_modules', name, 'lib/index.js')
    for (const alias of [name, pathToFileURL(modulePath).href]) {
      const f = fixture()
      writeFileSync(join(f.profile, 'cordis.patch.yml'),
        `- insert:\n    - id: alternate-${id}\n      name: '${alias}'\n`)
      assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION', entry: `alternate-${id}` })
    }
  }
})

test('unknown PTC activation expressions fail closed before evaluation', () => {
  const f = fixture()
  writeFileSync(join(f.profile, 'cordis.patch.yml'), '- id: ptc-runtime\n  disabled: !!js false\n')
  assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION', entry: 'ptc-runtime' })
})

test('an active Android preset cannot hide PTC under nested plugins', () => {
  const f = fixture()
  writeFileSync(join(f.profile, 'cordis.patch.yml'),
    "- id: preset-android\n  config:\n    id: android\n    plugins:\n      - id: nested-runner\n        name: '@deepseek-ai/dsh-ptc-runtime-node'\n")
  assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION', entry: 'nested-runner' })
})

test('an active Android preset cannot hide PTC in a computed plugin list', () => {
  const f = fixture()
  writeFileSync(join(f.profile, 'cordis.patch.yml'),
    "- id: preset-android\n  config:\n    id: android\n    plugins: !!js '[]'\n")
  assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION', entry: 'preset-android' })
})

test('duplicate host ID and a host row inside a new group are rejected', () => {
  for (const patch of [
    "- insert:\n    - id: android-runtime\n      name: '@minnnng/dsh-android-runtime'\n",
    "- insert:\n    - id: extra-group\n      name: '@deepseek-ai/cordis-plugin-group'\n      group: true\n      config:\n        - id: extra-web\n          name: '@deepseek-ai/dsh-host-webserver'\n",
  ]) {
    const f = fixture()
    writeFileSync(join(f.profile, 'cordis.patch.yml'), patch)
    assert.throws(f.check, { code: 'ANDROID_HOST_CONFIGURATION' })
  }
})

test('unavailable optional bundle is left to the original loader without normalizing the manifest', () => {
  const f = fixture([...ANDROID_BUNDLES, '@fixture/unavailable-extension'])
  const before = readFileSync(join(f.profile, 'package.json'))
  f.check()
  assert.deepEqual(readFileSync(join(f.profile, 'package.json')), before)
})
