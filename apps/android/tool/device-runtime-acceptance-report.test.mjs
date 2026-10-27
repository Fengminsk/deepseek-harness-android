import assert from 'node:assert/strict'
import test from 'node:test'
import { summarizeAcceptance } from './device-runtime-acceptance/report.mjs'
import { WORKFLOW_DEVICE_CHECKS, WORKFLOW_UNVERIFIED_CHECKS } from './device-runtime-acceptance/workflow-checks.mjs'

const workflow = () => ({ suite: 'workflow', passed: 11,
  details: WORKFLOW_DEVICE_CHECKS.map(name => ({ case: name, runId: name })),
  unverified: [...WORKFLOW_UNVERIFIED_CHECKS] })

test('disruptive lifecycle checks require explicit suites and cannot join all implicitly', () => {
  const all = summarizeAcceptance('all', [])
  assert.ok(all.coverage.required.every(check => !check.startsWith('ptc-process-death:') && !check.startsWith('ptc-saf:')))
  for (const [suite, name] of [['ptc-process-death', 'ptc-killed-dispatch-no-replay'], ['ptc-saf', 'saf-revocation-and-search']]) {
    assert.equal(summarizeAcceptance(suite, []).complete, false)
    const result = summarizeAcceptance(suite, [{ suite, checks: [{ name, status: 'passed' }] }])
    assert.equal(result.complete, true)
    assert.deepEqual(result.coverage.required, [`${suite}:${name}`])
  }
})
const ptc = () => ({ kind: 'production-node-native-ptc', passed: 9, failed: 0, checks: [
  'first-party-list-read-glob-roots-and-guard',
  'authorized-saf-read-through-native-ptc-callback',
  'current-session-attachment-read-and-archive-through-ptc',
  'workspace-mutations-through-native-ptc-callback',
  'current-session-apk-through-native-ptc-callback',
  'apk-oversize-callback-can-retry-a-smaller-page',
  'model-cancellation-joins-native-retirement',
  'model-busy-loop-has-independent-cpu-limit',
  'real-public-web-fetch',
].map(name => ({ name, status: 'passed' })).concat({ name: 'saf-revocation-and-search', status: 'unverified' }) })
const linux = () => ({ suite: 'linux', passed: 6, failed: 0, checks: [
  'production-tool-shell-and-session-persistence',
  'production-python-stdlib-file-analysis',
  'production-tool-import-hash-and-guest-readback',
  'production-tool-export-hash-and-no-overwrite',
  'production-read-only-policy-discards-disk-and-denies-import',
  'workflow-child-linux-import-exec-export',
].map(name => ({ name, status: 'passed' })),
unverified: ['Guest networking', 'Process-death import recovery'] })

test('workflow retains detail-format compatibility but names its unexecuted lifecycle boundaries', () => {
  const report = workflow(), original = structuredClone(report)
  const result = summarizeAcceptance('workflow', [report])
  assert.equal(result.passed, true)
  assert.equal(result.complete, false)
  assert.deepEqual(result.coverage.required, [...original.details.map(detail => `workflow:${detail.case}`),
    ...WORKFLOW_UNVERIFIED_CHECKS.map(name => `workflow:${name}`)])
  assert.deepEqual(result.coverage.passed, original.details.map(detail => `workflow:${detail.case}`))
  assert.deepEqual(result.coverage.failed, [])
  assert.deepEqual(result.coverage.unverified, WORKFLOW_UNVERIFIED_CHECKS.map(name => `workflow:${name}`))
  assert.deepEqual(result.coverage.issues, [])
  assert.deepEqual(report, original, 'aggregation does not change the retained raw report')
})

test('a numeric success count without named checks cannot claim execution or completion', () => {
  const result = summarizeAcceptance('workflow', [{ suite: 'workflow', passed: 3, details: [] }])
  assert.equal(result.passed, false)
  assert.equal(result.complete, false)
  assert.deepEqual(result.coverage.unverified, result.coverage.required)
  assert.ok(result.coverage.issues.includes('No checks executed'))
})

test('the historical three workflow cases cannot certify the expanded DSL and lifecycle requirements', () => {
  const result = summarizeAcceptance('workflow', [{ suite: 'workflow', passed: 3, details: [
    { case: 'real-tool-runtime-native-compute' },
    { case: 'real-confined-child-and-durable-session' },
    { case: 'real-background-job-kill-and-child-retirement' },
  ] }])
  assert.equal(result.passed, true)
  assert.equal(result.complete, false)
  assert.equal(result.coverage.passed.length, 3)
  assert.equal(result.coverage.unverified.length, 11)
  for (const name of ['real-dsl-parallel-pipeline-phase-log', 'real-structured-child-and-json-contract',
    'real-child-and-item-limits', 'real-ordinary-child-failure-and-sibling-result',
    'real-infrastructure-failure-and-child-retirement']) {
    assert.ok(result.coverage.unverified.includes(`workflow:${name}`))
  }
})

test('explicit workflow failure and stopped later checks override a passing numeric counter', () => {
  const checks = WORKFLOW_DEVICE_CHECKS.map((name, index) => ({ name,
    status: index < 2 ? 'passed' : index === 2 ? 'failed' : 'unverified' }))
  const report = { suite: 'workflow', passed: 11, failed: 0, checks, unverified: [...WORKFLOW_UNVERIFIED_CHECKS] }
  const result = summarizeAcceptance('workflow', [report])
  assert.equal(result.passed, false)
  assert.equal(result.complete, false)
  assert.deepEqual(result.coverage.failed, ['workflow:real-dsl-parallel-pipeline-phase-log'])
  assert.equal(result.coverage.passed.length, 2)
  assert.equal(result.coverage.unverified.length, 11)
  assert.deepEqual(result.coverage.issues, [])
})

test('omitting declared workflow lifecycle gaps does not make eleven execution checks complete', () => {
  const result = summarizeAcceptance('workflow', [{ suite: 'workflow',
    checks: WORKFLOW_DEVICE_CHECKS.map(name => ({ name, status: 'passed' })) }])
  assert.equal(result.passed, true)
  assert.equal(result.complete, false)
  assert.deepEqual(result.coverage.unverified, WORKFLOW_UNVERIFIED_CHECKS.map(name => `workflow:${name}`))
  for (const name of WORKFLOW_UNVERIFIED_CHECKS) {
    assert.ok(result.coverage.issues.includes(`Missing required check: workflow:${name}`))
  }
})

test('a missing workflow check preserves an executed pass but blocks complete acceptance', () => {
  const report = workflow()
  report.details.pop()
  const result = summarizeAcceptance('workflow', [report])
  assert.equal(result.passed, true)
  assert.equal(result.complete, false)
  assert.ok(result.coverage.unverified.includes('workflow:real-background-job-kill-and-child-retirement'))
  assert.equal(result.coverage.unverified.length, WORKFLOW_UNVERIFIED_CHECKS.length + 1)
})

test('the existing PTC SAF gap remains visible despite nine passing checks', () => {
  const result = summarizeAcceptance('ptc', [ptc()])
  assert.equal(result.passed, true)
  assert.equal(result.complete, false)
  assert.equal(result.coverage.required.length, 10)
  assert.equal(result.coverage.passed.length, 9)
  assert.deepEqual(result.coverage.unverified, ['ptc:saf-revocation-and-search'])
})

test('omitting an unverified PTC declaration cannot erase its requirement', () => {
  const report = ptc()
  report.checks.pop()
  const result = summarizeAcceptance('ptc', [report])
  assert.equal(result.complete, false)
  assert.deepEqual(result.coverage.unverified, ['ptc:saf-revocation-and-search'])
  assert.ok(result.coverage.issues.includes('Missing required check: ptc:saf-revocation-and-search'))
})

test('Linux free-standing evidence gaps participate in completeness and cannot silently disappear', () => {
  const report = linux()
  for (const input of [report, { ...report, unverified: [] }]) {
    const result = summarizeAcceptance('linux', [input])
    assert.equal(result.passed, true)
    assert.equal(result.complete, false)
    assert.equal(result.coverage.passed.length, 6)
    assert.deepEqual(result.coverage.unverified, report.unverified.map(name => `linux:${name}`))
  }
})

test('parent Linux checks cannot certify a workflow child Linux execution', () => {
  const report = linux()
  report.checks.pop()
  const result = summarizeAcceptance('linux', [report])
  assert.equal(result.passed, true)
  assert.equal(result.complete, false)
  assert.ok(result.coverage.unverified.includes('linux:workflow-child-linux-import-exec-export'))
  assert.ok(result.coverage.issues.includes('Missing required check: linux:workflow-child-linux-import-exec-export'))
})

test('Python analysis is required and a failed analysis cannot be hidden by passing counters', () => {
  const missing = linux()
  missing.checks = missing.checks.filter(check => check.name !== 'production-python-stdlib-file-analysis')
  const omitted = summarizeAcceptance('linux', [missing])
  assert.equal(omitted.complete, false)
  assert.ok(omitted.coverage.unverified.includes('linux:production-python-stdlib-file-analysis'))
  const failed = linux()
  failed.checks.find(check => check.name === 'production-python-stdlib-file-analysis').status = 'failed'
  const result = summarizeAcceptance('linux', [failed])
  assert.equal(result.passed, false)
  assert.equal(result.complete, false)
  assert.deepEqual(result.coverage.failed, ['linux:production-python-stdlib-file-analysis'])
  assert.deepEqual(result.coverage.unverified, ['linux:Guest networking', 'linux:Process-death import recovery'])
})

test('all requires reports from every suite rather than only the reports returned', () => {
  const result = summarizeAcceptance('all', [workflow()])
  assert.equal(result.passed, true)
  assert.equal(result.complete, false)
  assert.equal(result.coverage.required.length, 32)
  assert.equal(result.coverage.unverified.length, 21)
})

test('all can complete only when every declared gap becomes an executed passing check', () => {
  const workflowReport = workflow(), ptcReport = ptc(), linuxReport = linux()
  workflowReport.details.push(...workflowReport.unverified.map(name => ({ case: name })))
  workflowReport.unverified = []
  ptcReport.checks.at(-1).status = 'passed'
  linuxReport.checks.push(...linuxReport.unverified.map(name => ({ name, status: 'passed' })))
  linuxReport.unverified = []
  const result = summarizeAcceptance('all', [workflowReport, ptcReport, linuxReport])
  assert.equal(result.passed, true)
  assert.equal(result.complete, true)
  assert.equal(result.coverage.passed.length, 32)
  assert.deepEqual(result.coverage.unverified, [])
})

test('a failed execution is not erased by passing counters or by another suite', () => {
  const report = ptc()
  report.checks[0].status = 'failed'
  const result = summarizeAcceptance('all', [workflow(), report, linux()])
  assert.equal(result.passed, false)
  assert.equal(result.complete, false)
  assert.deepEqual(result.coverage.failed, ['ptc:first-party-list-read-glob-roots-and-guard'])
})

test('unknown suites and empty reports cannot produce a successful acceptance', () => {
  for (const suite of ['wrong', 'toString', '__proto__', 'workflow', 'all']) {
    const result = summarizeAcceptance(suite, [])
    assert.equal(result.passed, false, suite)
    assert.equal(result.complete, false, suite)
    assert.ok(result.coverage.issues.includes('No checks executed'), suite)
  }
})

test('duplicate reports and duplicate check names block completion', () => {
  const report = workflow()
  for (const reports of [[report, workflow()], [{ ...report, details: [...report.details, report.details[0]] }]]) {
    const result = summarizeAcceptance('workflow', reports)
    assert.equal(result.complete, false)
    assert.ok(result.coverage.unverified.includes('workflow:real-tool-runtime-native-compute'))
    assert.ok(result.coverage.issues.includes('Duplicate check: workflow:real-tool-runtime-native-compute'))
  }
})

test('unexpected suite reports, unknown check names and unknown statuses are not complete evidence', () => {
  assert.equal(summarizeAcceptance('workflow', [workflow(), ptc()]).passed, false)
  const report = workflow()
  report.details.push({ case: 'renamed-without-updating-requirements' })
  assert.equal(summarizeAcceptance('workflow', [report]).complete, false)
  const ptcReport = ptc()
  ptcReport.checks.at(-1).status = 'skipped'
  const result = summarizeAcceptance('ptc', [ptcReport])
  assert.equal(result.complete, false)
  assert.ok(result.coverage.unverified.includes('ptc:saf-revocation-and-search'))
  assert.ok(result.coverage.issues.includes('Unknown check status: ptc:saf-revocation-and-search'))
})
