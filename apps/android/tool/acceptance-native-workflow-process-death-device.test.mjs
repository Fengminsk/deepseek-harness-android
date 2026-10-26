import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  parsePids, parseProcessDeathRecovery, parseReadyMarker, requireProcessDeathInstrumentation,
} from './acceptance-native-workflow-process-death-device.mjs'

const app = 'com.minnnng.dsh_android'
const runId = '8c16b259-06bf-4125-9349-63db1d125102'
const childId = 'd3577250-3c21-4c0f-a98a-c87fb8f9d2ef'
const marker = { schema: 1, runId, childId, agentPid: 5123 }
const result = `INSTRUMENTATION_RESULT: passed=process-kill-interruption-no-replay-and-guarded-retirement\n` +
  `INSTRUMENTATION_RESULT: oldRunId=${runId}\n` +
  `INSTRUMENTATION_RESULT: oldChildId=${childId}\n` +
  'INSTRUMENTATION_RESULT: oldAgentPid=5123\n' +
  'INSTRUMENTATION_RESULT: newAgentPid=6201\n' +
  'INSTRUMENTATION_CODE: -1\n'

test('requires the exact process-death test target in the Agent process', () => {
  const declaration = `E: instrumentation (line=30)\n` +
    `  A: android:name(0x01010003)="${app}.NativeWorkflowProcessDeathInstrumentation"\n` +
    `  A: android:targetPackage(0x01010021)="${app}"\n` +
    `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
  assert.doesNotThrow(() => requireProcessDeathInstrumentation(declaration))
  assert.throws(() => requireProcessDeathInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireProcessDeathInstrumentation(declaration + declaration), /lacks/)
})

test('binds a synced ready marker and fresh recovery result to the same run and process', () => {
  assert.deepEqual(parseReadyMarker(JSON.stringify(marker), runId), marker)
  assert.deepEqual(parseProcessDeathRecovery(result, runId, marker), {
    passed: 'process-kill-interruption-no-replay-and-guarded-retirement',
    oldAgentPid: 5123, newAgentPid: 6201,
  })
  assert.throws(() => parseReadyMarker(JSON.stringify({ ...marker, runId: childId }), runId), /invalid/)
  assert.throws(() => parseReadyMarker(JSON.stringify({ ...marker, extra: true }), runId), /invalid/)
  assert.throws(() => parseProcessDeathRecovery(result.replace('newAgentPid=6201',
    'newAgentPid=5123'), runId, marker), /failed/)
  assert.throws(() => parseProcessDeathRecovery(result.replace('CODE: -1',
    'CODE: 0'), runId, marker), /failed/)
  assert.throws(() => parseProcessDeathRecovery(result.replace(childId,
    runId), runId, marker), /failed/)
  assert.throws(() => parseProcessDeathRecovery(result +
    'INSTRUMENTATION_RESULT: oldAgentPid=5123\n', runId, marker), /duplicate/)
})

test('requires decimal, distinct, positive process IDs', () => {
  assert.deepEqual(parsePids('5123 8142\n'), [5123, 8142])
  assert.deepEqual(parsePids(''), [])
  assert.throws(() => parsePids('5123 5123'), /Invalid/)
  assert.throws(() => parsePids('5123 abc'), /Invalid/)
  assert.throws(() => parsePids('0'), /Invalid/)
})
