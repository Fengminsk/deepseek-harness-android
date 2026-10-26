import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  createAndroidPtcToolDefinition,
  modelPtcCapability,
  registerAndroidPtcTool,
  renderAndroidPtcResult,
} from '../runtime/tool-isolated-ptc.mjs'

test('model-visible PTC output keeps ordered console lines before the result', () => {
  assert.deepEqual(renderAndroidPtcResult({}, { logs: ['first', 'second'], result: { ok: true } }),
    [{ type: 'text', text: 'first\nsecond\n{"ok":true}' }])
  assert.deepEqual(renderAndroidPtcResult({}, { logs: ['diagnostic'] }),
    [{ type: 'text', text: 'diagnostic' }])
  assert.deepEqual(renderAndroidPtcResult({}, { logs: [] }),
    [{ type: 'text', text: '(android_ptc completed with no output)' }])
})

test('closed model PTC capability is an honest zero-grant subset', () => {
  const value = modelPtcCapability(false)
  assert.deepEqual(value, {
    available: false,
    reason: 'device-isolation-unverified',
    language: 'typescript-function-body',
    reviewedTools: ['list_agents'],
    filesystem: 'none',
    network: 'off',
  })
  assert(Object.isFrozen(value))
  assert(Object.isFrozen(value.reviewedTools))
  assert.deepEqual(modelPtcCapability(true), {
    ...value, available: true, reason: null,
  })
})

test('a forged App owner cannot construct or register a model tool', () => {
  const fake = Object.freeze({ start() { throw new Error('forged owner ran') } })
  assert.throws(() => createAndroidPtcToolDefinition({
    owner: fake, available: () => true,
  }), /App-owned list_agents PTC owner required/)
  let effects = 0
  assert.throws(() => registerAndroidPtcTool({ effect() { effects++ } }, {
    owner: fake, available: () => true,
  }), /App-owned list_agents PTC owner required/)
  assert.equal(effects, 0)
})
