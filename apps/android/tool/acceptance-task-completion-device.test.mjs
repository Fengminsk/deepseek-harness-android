import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseCommittedHold, parseTaskCompletionPhase,
  requireTaskCompletionInstrumentation } from './acceptance-task-completion-device.mjs'

const app = 'com.minnnng.dsh_android'
const token = 'a'.repeat(32)
const declaration = `E: instrumentation (line=50)\n` +
  `  A: android:name(0x01010003)="${app}.TaskCompletionCrashInstrumentation"\n` +
  `  A: android:targetPackage(0x01010021)="${app}"\n` +
  `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
const result = (phase, pid = 345) => `INSTRUMENTATION_RESULT: phase=${phase}\n` +
  `INSTRUMENTATION_RESULT: token=${token}\n` +
  `INSTRUMENTATION_RESULT: processPid=${pid}\n` +
  'INSTRUMENTATION_RESULT: endSeq=41\n' +
  (phase === 'verify'
    ? 'INSTRUMENTATION_RESULT: validNotice=true\n' +
      'INSTRUMENTATION_RESULT: invalidNotices=false\n' +
      'INSTRUMENTATION_RESULT: receiptsCleared=true\n'
    : 'INSTRUMENTATION_RESULT: cleaned=true\n') +
  'INSTRUMENTATION_RESULT: passed=true\nINSTRUMENTATION_CODE: -1\n'

test('requires one completion instrumentation entry in the Agent process', () => {
  assert.doesNotThrow(() => requireTaskCompletionInstrumentation(declaration))
  assert.throws(() => requireTaskCompletionInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireTaskCompletionInstrumentation(declaration + declaration), /lacks/)
})

test('accepts only the committed hold from this process and token', () => {
  const held = `INSTRUMENTATION_STATUS: holdReady=true\n` +
    `INSTRUMENTATION_STATUS: token=${token}\n` +
    'INSTRUMENTATION_STATUS: processPid=123\n' +
    'INSTRUMENTATION_STATUS: receiptCommitted=true\n' +
    'INSTRUMENTATION_STATUS_CODE: 1\n'
  assert.equal(parseCommittedHold(held, token), 123)
  assert.equal(parseCommittedHold(held.replace('STATUS_CODE: 1', 'STATUS_CODE: 0'), token), null)
  assert.throws(() => parseCommittedHold(held.replace('receiptCommitted=true', 'receiptCommitted=false'), token),
    /no committed/)
  assert.throws(() => parseCommittedHold(held.replace('processPid=123', 'processPid=0'), token),
    /does not match/)
})

test('requires a fresh Agent process, valid notice and terminal cleanup', () => {
  assert.deepEqual(parseTaskCompletionPhase(result('verify'), 'verify', token, 123), {
    phase: 'verify', processPid: 345, validNotice: true, invalidNotices: false, receiptsCleared: true,
  })
  assert.deepEqual(parseTaskCompletionPhase(result('cleanup', 346), 'cleanup', token), {
    phase: 'cleanup', processPid: 346, cleaned: true,
  })
  assert.throws(() => parseTaskCompletionPhase(result('verify', 123), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('validNotice=true',
    'validNotice=false'), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('receiptsCleared=true',
    'receiptsCleared=false'), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('CODE: -1',
    'CODE: 0'), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify') +
    'INSTRUMENTATION_CODE: -1\n', 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('passed=true',
    'passed=false'), 'verify', token, 123), /failed/)
})
