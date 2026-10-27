import { WORKFLOW_DEVICE_CHECKS, WORKFLOW_UNVERIFIED_CHECKS } from './workflow-checks.mjs'

const requiredChecks = {
  'ptc-process-death': ['ptc-killed-dispatch-no-replay'],
  'ptc-saf': ['saf-revocation-and-search'],
  workflow: [...WORKFLOW_DEVICE_CHECKS, ...WORKFLOW_UNVERIFIED_CHECKS],
  ptc: [
    'first-party-list-read-glob-roots-and-guard',
    'authorized-saf-read-through-native-ptc-callback',
    'current-session-attachment-read-and-archive-through-ptc',
    'workspace-mutations-through-native-ptc-callback',
    'current-session-apk-through-native-ptc-callback',
    'apk-oversize-callback-can-retry-a-smaller-page',
    'model-cancellation-joins-native-retirement',
    'model-busy-loop-has-independent-cpu-limit',
    'real-public-web-fetch',
    'saf-revocation-and-search',
  ],
  linux: [
    'production-tool-shell-and-session-persistence',
    'production-python-stdlib-file-analysis',
    'production-tool-import-hash-and-guest-readback',
    'production-tool-export-hash-and-no-overwrite',
    'production-read-only-policy-discards-disk-and-denies-import',
    'workflow-child-linux-import-exec-export',
    'Guest networking',
    'Process-death import recovery',
  ],
}

/** Summarize selected fixture suites without treating omitted or unverified checks as complete.
 * `passed` retains the executed-check result; `complete` additionally requires every declared check.
 * @param {string} suite - One supported suite name or `all`.
 * @param {object[]} reports - Unmodified results from the workflow, PTC and Linux fixtures.
 * @returns {{passed: boolean, complete: boolean, coverage: object}} Scoped acceptance and named evidence gaps.
 */
export function summarizeAcceptance(suite, reports) {
  const suites = suite === 'all' ? ['workflow', 'ptc', 'linux']
    : Object.hasOwn(requiredChecks, suite) ? [suite] : []
  const coverage = { required: suites.flatMap(name => requiredChecks[name].map(check => `${name}:${check}`)),
    passed: [], failed: [], unverified: [], issues: [] }
  if (!suites.length) coverage.issues.push(`Unknown acceptance suite: ${suite}`)
  const observations = new Map()
  const seenSuites = new Set()
  for (const report of reports) {
    const name = report.suite ?? (report.kind === 'production-node-native-ptc' ? 'ptc' : undefined)
    if (!suites.includes(name)) {
      coverage.issues.push(`Unexpected suite report: ${name ?? 'unnamed'}`)
      continue
    }
    if (seenSuites.has(name)) coverage.issues.push(`Duplicate suite report: ${name}`)
    seenSuites.add(name)
    const checks = report.checks ?? (name === 'workflow'
      ? (report.details ?? []).map(detail => ({ name: detail.case, status: 'passed' })) : [])
    for (const check of [...checks, ...(report.unverified ?? []).map(name => ({ name, status: 'unverified' }))]) {
      if (typeof check.name !== 'string' || !check.name) {
        coverage.issues.push(`Unnamed check in suite: ${name}`)
        continue
      }
      const id = `${name}:${check.name}`
      if (!coverage.required.includes(id)) coverage.issues.push(`Unexpected check: ${id}`)
      const statuses = observations.get(id) ?? []
      statuses.push(check.status)
      observations.set(id, statuses)
    }
  }
  for (const id of coverage.required) if (!observations.has(id)) observations.set(id, [])
  for (const [id, statuses] of observations) {
    if (statuses.includes('failed')) coverage.failed.push(id)
    if (statuses.length === 1 && statuses[0] === 'passed') coverage.passed.push(id)
    else if (!statuses.length || statuses.some(status => status !== 'passed' && status !== 'failed') || statuses.length > 1) {
      coverage.unverified.push(id)
    }
    if (!statuses.length) coverage.issues.push(`Missing required check: ${id}`)
    else if (statuses.length > 1) coverage.issues.push(`Duplicate check: ${id}`)
    else if (!['passed', 'failed', 'unverified'].includes(statuses[0])) coverage.issues.push(`Unknown check status: ${id}`)
  }
  const executed = [...observations.values()].flat().filter(status => status === 'passed' || status === 'failed').length
  if (executed === 0) coverage.issues.push('No checks executed')
  return { passed: suites.length > 0 && executed > 0 && coverage.failed.length === 0
      && !coverage.issues.some(issue => issue.startsWith('Unexpected suite report:')),
    complete: coverage.required.length > 0 && coverage.required.every(id => coverage.passed.includes(id))
      && coverage.failed.length === 0 && coverage.unverified.length === 0 && coverage.issues.length === 0,
    coverage }
}
