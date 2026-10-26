import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseWorkflowResult, requireWorkflowInstrumentation } from './acceptance-native-workflow-device.mjs'

const app = 'com.minnnng.dsh_android'
const names = [
  'isolated-callbacks-and-durable-result',
  'isolated-guest-reported-error-is-durable-failure',
  'isolated-malformed-dsl-outcome-needs-review',
  'isolated-child-reservation-result-and-retirement',
  'admitted-workflow-pre-execution-cancel',
  'bounded-extended-workflow-and-upper-limit',
  'in-flight-child-cancel-retirement-and-cold-owner',
].join(',')
const passed = `INSTRUMENTATION_RESULT: passed=${names}\n` +
  'INSTRUMENTATION_RESULT: failed=\n' +
  'INSTRUMENTATION_RESULT: passedCount=7\n' +
  'INSTRUMENTATION_RESULT: failedCount=0\n' +
  'INSTRUMENTATION_CODE: -1\n'

test('requires the exact workflow runner in the Agent process', () => {
  const declaration = `E: instrumentation (line=30)\n` +
    `  A: android:name(0x01010003)="${app}.NativeWorkflowAcceptanceInstrumentation"\n` +
    `  A: android:targetPackage(0x01010021)="${app}"\n` +
    `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
  assert.doesNotThrow(() => requireWorkflowInstrumentation(declaration))
  assert.throws(() => requireWorkflowInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireWorkflowInstrumentation(declaration + declaration), /lacks/)
})

test('requires every private workflow device assertion exactly once', () => {
  assert.deepEqual(parseWorkflowResult(passed), { passed: names.split(',') })
  assert.throws(() => parseWorkflowResult(passed.replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('failedCount=0', 'failedCount=1')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('pre-execution-cancel', 'other')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('bounded-extended-workflow-and-upper-limit', 'other')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('in-flight-child-cancel-retirement-and-cold-owner', 'other')), /failed/)
  assert.throws(() => parseWorkflowResult(passed + 'INSTRUMENTATION_CODE: -1\n'), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('passedCount=7', 'passedCount=1')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('in-flight-child-cancel-retirement-and-cold-owner',
    'bounded-extended-workflow-and-upper-limit')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('passedCount=7', 'passedCount=8')
    .replace(`passed=${names}`, `passed=${names},extra`)), /failed/)
})
