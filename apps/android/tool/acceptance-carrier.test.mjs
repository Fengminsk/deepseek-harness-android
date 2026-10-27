import assert from 'node:assert/strict'
import test from 'node:test'
import { acceptanceCarrier, carrierEvidence, requireNodeCarrierReady } from './acceptance-carrier.mjs'

const state = JSON.stringify({ interactive: false, keyguardLocked: true, deviceLocked: true, displays: [{ id: 0, state: 1 }] })
const fields = { foregroundCarrier: 'service', foregroundConfirmed: 'true', foregroundClosed: 'true',
  nativeOwnersClosed: 'true', deviceStateBefore: state, deviceStateReady: state, deviceStateAfter: state }
const output = (changes = {}, prefix = 'RESULT') => Object.entries({ ...fields, ...changes })
  .map(([name, value]) => `INSTRUMENTATION_${prefix}: ${name}=${value}\n`).join('')

test('service carrier is explicit; unknown, missing and duplicate selection fail before device work', () => {
  assert.equal(acceptanceCarrier([]), 'activity')
  assert.equal(acceptanceCarrier(['--foreground-carrier', 'service']), 'service')
  for (const args of [['--foreground-carrier'], ['--foreground-carrier', ''], ['--foreground-carrier', 'Service'],
    ['--foreground-carrier', '--apk'], ['--foreground-carrier', 'service', '--foreground-carrier', 'activity']])
    assert.throws(() => acceptanceCarrier(args))
})

test('carrier result preserves locked/off framework observations and requires actual owner closure', () => {
  const evidence = carrierEvidence(output(), 'service')
  assert.equal(evidence.deviceStateReady.deviceLocked, true)
  assert.equal(evidence.foregroundClosed, true)
  for (const changes of [{ foregroundCarrier: 'activity' }, { foregroundClosed: 'false' },
    { nativeOwnersClosed: 'false' }, { deviceStateAfter: '{}' }, { deviceStateReady: '{' }])
    assert.throws(() => carrierEvidence(output(changes), 'service'))
  assert.throws(() => carrierEvidence(output() + 'INSTRUMENTATION_RESULT: foregroundClosed=true\n', 'service'))
})

test('death readiness requires carrier acknowledgement but never invents a close ACK for the killed process', () => {
  const ready = carrierEvidence(output({}, 'STATUS'), 'service', { prefix: 'STATUS', closed: false })
  assert.equal(Object.hasOwn(ready, 'foregroundClosed'), false)
  assert.throws(() => carrierEvidence(output({ foregroundConfirmed: 'false' }, 'STATUS'), 'service',
    { prefix: 'STATUS', closed: false }))
})

test('Node death readiness must be paired with the actual requested carrier-ready status frame', () => {
  const ready = 'INSTRUMENTATION_STATUS: foregroundCarrier=service\nINSTRUMENTATION_STATUS: stage=foreground-ready\nINSTRUMENTATION_STATUS_CODE: 1\n'
  requireNodeCarrierReady(ready, 'service')
  for (const invalid of ['', ready.replace('service', 'activity'), ready.replace('foreground-ready', 'foreground-starting'), ready + ready])
    assert.throws(() => requireNodeCarrierReady(invalid, 'service'))
})
