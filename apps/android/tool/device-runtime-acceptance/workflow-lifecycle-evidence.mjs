import assert from 'node:assert/strict'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

/** Validate native expiry separately from user cancellation and uncertain retirement. */
export function validateWorkflowDeadline(evidence) {
  assert.equal(evidence.deadlineMillis, 120000)
  assert.equal(evidence.outerAborted, false, 'Outer fixture cancellation cannot certify native expiry')
  assert.equal(evidence.scriptState, 'TIMED_OUT')
  assert.equal(evidence.nativeState, 'FAILED')
  assert.equal(evidence.outputAbsent, true)
  assert.equal(evidence.released, true)
  assert.equal(evidence.activeModels, 0)
  assert.equal(evidence.modelAborted, true)
  assert.equal(evidence.childRetired, true)
  assert.equal(evidence.terminalCount, 1)
  assert.ok(evidence.elapsedMs >= 110000 && evidence.elapsedMs < 175000)
  return evidence
}

/** Bind a persisted marker to the dedicated Session, native child and process lease. */
export function validateWorkflowDeathMarker(marker, caseId) {
  assert.equal(marker.schema, 1); assert.equal(marker.caseId, caseId)
  assert.match(caseId, UUID); assert.match(marker.runId, UUID)
  assert.match(marker.childId, UUID); assert.match(marker.processLeaseId, UUID)
  assert.equal(marker.sessionId, `workflow-death-${caseId}`)
  assert.equal(typeof marker.childSessionId, 'string'); assert.notEqual(marker.childSessionId, marker.sessionId)
  assert.ok(Number.isSafeInteger(marker.agentPid) && marker.agentPid > 0)
  for (const prefix of ['parent', 'child']) {
    assert.match(marker[`${prefix}Hash`], /^[0-9a-f]{64}$/)
    assert.ok(Number.isSafeInteger(marker[`${prefix}Events`]) && marker[`${prefix}Events`] > 0
      && marker[`${prefix}Events`] <= 10000)
  }
  return marker
}
