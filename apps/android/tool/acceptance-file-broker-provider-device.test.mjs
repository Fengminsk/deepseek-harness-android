import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseFileBrokerResult, requireFileBrokerInstrumentation } from './acceptance-file-broker-provider-device.mjs'

const app = 'com.minnnng.dsh_android'
const names = 'secure-provider-and-revision,edit-create-and-stale,cancel-and-link-isolation'
const passed = `INSTRUMENTATION_RESULT: passed=${names}\n` +
  'INSTRUMENTATION_RESULT: failed=\n' +
  'INSTRUMENTATION_RESULT: passedCount=3\n' +
  'INSTRUMENTATION_RESULT: failedCount=0\n' +
  'INSTRUMENTATION_RESULT: provider=sun.nio.fs.UnixSecureDirectoryStream\n' +
  'INSTRUMENTATION_RESULT: links=1\n' +
  'INSTRUMENTATION_CODE: -1\n'

test('requires the exact file-broker runner in the Agent process', () => {
  const declaration = `E: instrumentation (line=30)\n` +
    `  A: android:name(0x01010003)="${app}.FileBrokerProviderInstrumentation"\n` +
    `  A: android:targetPackage(0x01010021)="${app}"\n` +
    `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
  assert.doesNotThrow(() => requireFileBrokerInstrumentation(declaration))
  assert.throws(() => requireFileBrokerInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireFileBrokerInstrumentation(declaration + declaration), /lacks/)
})

test('requires every provider, revision, and isolation result exactly once', () => {
  assert.deepEqual(parseFileBrokerResult(passed), {
    passed: names.split(','), provider: 'sun.nio.fs.UnixSecureDirectoryStream', links: 1,
  })
  assert.throws(() => parseFileBrokerResult(passed.replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parseFileBrokerResult(passed.replace('failedCount=0', 'failedCount=1')), /failed/)
  assert.throws(() => parseFileBrokerResult(passed.replace('cancel-and-link-isolation', 'other')), /failed/)
  assert.throws(() => parseFileBrokerResult(passed + 'INSTRUMENTATION_CODE: -1\n'), /failed/)
  assert.throws(() => parseFileBrokerResult(passed.replace('passedCount=3', 'passedCount=2')), /failed/)
  assert.throws(() => parseFileBrokerResult(passed.replace('links=1', 'links=2')), /failed/)
  assert.throws(() => parseFileBrokerResult(passed.replace('UnixSecureDirectoryStream', 'BasicDirectoryStream')), /failed/)
  assert.throws(() => parseFileBrokerResult(passed.replace('failed=\n', 'failed=stale\n')), /failed/)
})
