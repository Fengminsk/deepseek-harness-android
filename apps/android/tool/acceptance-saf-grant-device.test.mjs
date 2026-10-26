import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'
import { parseRead, requireSafInstrumentation, selectDevice } from './acceptance-saf-grant-device.mjs'

const rootId = 'a'.repeat(64)
const digest = createHash('sha256').update('Pocket Harness SAF acceptance v1\n').digest('hex')
const receipt = (pid = 42) => [
  'INSTRUMENTATION_RESULT: result=saf-persisted-read-pass',
  `INSTRUMENTATION_RESULT: rootId=${rootId}`,
  `INSTRUMENTATION_RESULT: contentSha256=${digest}`,
  `INSTRUMENTATION_RESULT: processPid=${pid}`,
  'INSTRUMENTATION_CODE: -1',
  '',
].join('\n')

test('only an authorized, unambiguous device may be selected', () => {
  const devices = 'List of devices attached\nphone\tdevice\noffline\tunauthorized\n'
  assert.equal(selectDevice(devices), 'phone')
  assert.equal(selectDevice(devices, 'phone'), 'phone')
  assert.throws(() => selectDevice(devices, 'offline'), /not authorized/)
  assert.throws(() => selectDevice('List of devices attached\na\tdevice\nb\tdevice\n'), /one authorized/)
})

test('acceptance requires an exact fixture, grant identity, agent PID and terminal pass', () => {
  assert.deepEqual(parseRead(receipt()), { rootId, contentSha256: digest, processPid: 42 })
  assert.throws(() => parseRead(receipt().replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parseRead(receipt().replace('saf-persisted-read-pass', 'other')), /failed/)
  assert.throws(() => parseRead(receipt().replace(rootId, 'other')), /incomplete/)
  assert.throws(() => parseRead(receipt().replace(digest, '0'.repeat(64))), /incomplete/)
  assert.throws(() => parseRead(receipt(0)), /incomplete/)
  assert.throws(() => parseRead(receipt() + 'INSTRUMENTATION_CODE: 0\n'), /failed/)
  assert.throws(() => parseRead(receipt().replace(`INSTRUMENTATION_RESULT: rootId=${rootId}`,
    `INSTRUMENTATION_RESULT: rootId=${rootId}\nINSTRUMENTATION_RESULT: rootId=${rootId}`)), /duplicated/)
})

test('the test APK must declare the exact Agent-process SAF reader', () => {
  const declaration = `E: instrumentation (line=30)\n` +
    `  A: android:name(0x01010003)="com.minnnng.dsh_android.SafGrantReadInstrumentation"\n` +
    `  A: android:targetPackage(0x01010021)="com.minnnng.dsh_android"\n` +
    `  A: android:targetProcesses(0x01010541)="com.minnnng.dsh_android:agent"\n`
  assert.doesNotThrow(() => requireSafInstrumentation(declaration))
  assert.throws(() => requireSafInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireSafInstrumentation(declaration + declaration), /lacks/)
})
