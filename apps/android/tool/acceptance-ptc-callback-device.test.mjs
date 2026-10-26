import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parsePtcCallbackResult, requirePtcCallbackInstrumentation } from './acceptance-ptc-callback-device.mjs'

const app = 'com.minnnng.dsh_android'
const names = 'ptc-binder-read-only-callback-isolated-uid,ptc-binder-cancel-replay-denied,ptc-binder-invalid-reply-no-success-receipt'
const passed = `INSTRUMENTATION_RESULT: passed=${names}\n` +
  'INSTRUMENTATION_RESULT: failed=\n' +
  'INSTRUMENTATION_RESULT: passedCount=3\n' +
  'INSTRUMENTATION_RESULT: failedCount=0\n' +
  'INSTRUMENTATION_CODE: -1\n'

test('requires the exact PTC callback runner in the Agent process', () => {
  const declaration = `E: instrumentation (line=30)\n` +
    `  A: android:name(0x01010003)="${app}.IsolatedScriptAcceptanceInstrumentation"\n` +
    `  A: android:targetPackage(0x01010021)="${app}"\n` +
    `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
  assert.doesNotThrow(() => requirePtcCallbackInstrumentation(declaration))
  assert.throws(() => requirePtcCallbackInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requirePtcCallbackInstrumentation(declaration + declaration), /lacks/)
})

test('requires isolated UID, cancellation replay and invalid-reply device assertions', () => {
  assert.deepEqual(parsePtcCallbackResult(passed), { passed: names.split(',') })
  assert.throws(() => parsePtcCallbackResult(passed.replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parsePtcCallbackResult(passed.replace('failedCount=0', 'failedCount=1')), /failed/)
  assert.throws(() => parsePtcCallbackResult(passed.replace('ptc-binder-read-only-callback-isolated-uid', 'other')), /failed/)
  assert.throws(() => parsePtcCallbackResult(passed.replace('cancel-replay-denied', 'other')), /failed/)
  assert.throws(() => parsePtcCallbackResult(passed.replace('ptc-binder-invalid-reply-no-success-receipt', 'other')), /failed/)
  assert.throws(() => parsePtcCallbackResult(passed + 'INSTRUMENTATION_CODE: -1\n'), /failed/)
  assert.throws(() => parsePtcCallbackResult(passed.replace('passedCount=3', 'passedCount=1')), /failed/)
  assert.throws(() => parsePtcCallbackResult(passed.replace('passedCount=3', 'passedCount=4')
    .replace(names, `${names},ptc-binder-cancel-replay-denied`)), /failed/)
})
