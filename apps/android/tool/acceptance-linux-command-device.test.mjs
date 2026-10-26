import assert from 'node:assert/strict'
import { test } from 'node:test'
import { connectedDevice, delayProcessIds, parseGuestStorageProbeInstrumentation, parseImageInstallationInstrumentation, parseImageInstrumentation, parseInstrumentation } from './acceptance-linux-command-device.mjs'

test('selects only one authorized device or the requested one', () => {
  const listing = 'List of devices attached\nabc\tdevice\nunauth\tunauthorized\n\n'
  assert.equal(connectedDevice(listing), 'abc')
  assert.equal(connectedDevice(listing, 'abc'), 'abc')
  assert.throws(() => connectedDevice(listing, 'unauth'), /not connected and authorized/)
  assert.throws(() => connectedDevice('List of devices attached\na\tdevice\nb\tdevice\n'), /exactly one/)
})

test('instrumentation result must contain its terminal pass code and test counts', () => {
  const passed = 'INSTRUMENTATION_RESULT: passed=a,b\nINSTRUMENTATION_RESULT: failed=\n' +
    'INSTRUMENTATION_RESULT: passedCount=2\nINSTRUMENTATION_RESULT: failedCount=0\nINSTRUMENTATION_CODE: -1\n'
  assert.deepEqual(parseInstrumentation(passed, 'synthetic'), { phase: 'synthetic', passedCount: 2, passed: ['a', 'b'] })
  assert.throws(() => parseInstrumentation(passed.replace('CODE: -1', 'CODE: 0'), 'baseline'), /failed/)
  assert.throws(() => parseInstrumentation(passed.replace('failedCount=0', 'failedCount=1'), 'baseline'), /failed/)
  assert.throws(() => parseInstrumentation(passed.replace('passedCount=2', 'passedCount=0'), 'baseline'), /failed/)
  assert.throws(() => parseInstrumentation(passed.replace('failed=\n', 'failed=worker died\n'), 'baseline'), /failed/)
  assert.throws(() => parseInstrumentation(passed, 'baseline'), /failed/)
  const baselineNames = ['kernel-command-isolated', 'identity-command-matches-child-uid',
    'pre-admission-cancel', 'sha256-stdin', 'apk-packaged-core-boundaries',
    'count-and-sort-stdin', 'literal-filter-stdin', 'literal-filter-no-match',
    'app-rpc-fixed-sha256', 'app-rpc-rejects-test-command-and-cwd']
  const baseline = `INSTRUMENTATION_RESULT: passed=${baselineNames.join(',')}\n` +
    `INSTRUMENTATION_RESULT: failed=\nINSTRUMENTATION_RESULT: passedCount=${baselineNames.length}\n` +
    'INSTRUMENTATION_RESULT: failedCount=0\nINSTRUMENTATION_CODE: -1\n'
  assert.equal(parseInstrumentation(baseline, 'baseline').passedCount, baselineNames.length)
  assert.throws(() => parseInstrumentation(baseline.replace('apk-packaged-core-boundaries', 'other'),
    'baseline'), /failed/)
  const lifecycle = 'INSTRUMENTATION_RESULT: passed=apk-packaged-fixed-utility,in-flight-cancel,guest-deadline,output-limit,isolated-worker-death\n' +
    'INSTRUMENTATION_RESULT: failed=\nINSTRUMENTATION_RESULT: passedCount=5\n' +
    'INSTRUMENTATION_RESULT: failedCount=0\nINSTRUMENTATION_CODE: -1\n'
  assert.equal(parseInstrumentation(lifecycle, 'lifecycle').passedCount, 5)
  assert.throws(() => parseInstrumentation(lifecycle.replace('isolated-worker-death', 'other'), 'lifecycle'), /failed/)
  assert.throws(() => parseInstrumentation(lifecycle.replace('apk-packaged-fixed-utility', 'other'), 'lifecycle'), /failed/)
})

test('orphan scan identifies only the fixed delayed child and requires an argv-capable ps', () => {
  assert.deepEqual([...delayProcessIds('PID ARGS\n102 /system/bin/toybox sleep 30\n104 /system/bin/toybox true\n')], [102])
  assert.deepEqual([...delayProcessIds('PID COMMAND\n5 sleep 30\n')], [5])
  assert.throws(() => delayProcessIds('USER PID NAME\nroot 5 sleep\n'), /did not provide PID/)
})

test('image transport result must carry an explicit isolated guest pass receipt', () => {
  const passed = 'INSTRUMENTATION_RESULT: result=linux-image-guest-bridge-pass\nINSTRUMENTATION_CODE: -1\n'
  assert.deepEqual(parseImageInstrumentation(passed), {
    phase: 'image-transport', result: 'linux-image-guest-bridge-pass',
  })
  assert.throws(() => parseImageInstrumentation(passed.replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parseImageInstrumentation(passed.replace('bridge-pass', 'bridge-fail')), /failed/)
})

test('image installation fixture requires its data-only pass receipt', () => {
  const passed = 'INSTRUMENTATION_RESULT: result=linux-image-install-data-only-pass\nINSTRUMENTATION_CODE: -1\n'
  assert.deepEqual(parseImageInstallationInstrumentation(passed), {
    phase: 'image-installation-data-only', result: 'linux-image-install-data-only-pass',
  })
  assert.throws(() => parseImageInstallationInstrumentation(passed.replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parseImageInstallationInstrumentation(passed.replace('data-only-pass', 'fail')), /failed/)
})

test('guest storage probe accepts only explicit isolated read-only boundaries', () => {
  const passed = [
    'result=guest-storage-probe-pass',
    'privateRead=denied', 'privateWrite=denied', 'fdRead=allowed', 'fdWrite=denied',
    'memoryRead=allowed', 'memoryWrite=denied',
    'tempWrite=denied', 'tempRead=untested', 'tempExec=untested',
  ].map((item) => `INSTRUMENTATION_RESULT: ${item}\n`).join('') + 'INSTRUMENTATION_CODE: -1\n'
  assert.deepEqual(parseGuestStorageProbeInstrumentation(passed), {
    phase: 'guest-storage-probe', privateRead: 'denied', privateWrite: 'denied',
    fdRead: 'allowed', fdWrite: 'denied', memoryRead: 'allowed', memoryWrite: 'denied',
    tempWrite: 'denied', tempRead: 'untested', tempExec: 'untested',
  })
  assert.throws(() => parseGuestStorageProbeInstrumentation(passed.replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parseGuestStorageProbeInstrumentation(passed.replace('privateRead=denied', 'privateRead=allowed')), /failed/)
  assert.throws(() => parseGuestStorageProbeInstrumentation(passed.replace('fdRead=allowed', 'fdRead=untested')), /failed/)
  assert.throws(() => parseGuestStorageProbeInstrumentation(passed.replace('tempExec=untested', 'tempExec=other')), /failed/)
  assert.throws(() => parseGuestStorageProbeInstrumentation(passed.replace('memoryWrite=denied\n', '')), /failed/)
})
