const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u
const STATUS = new Set(['absent', 'ready', 'active', 'blocked', 'unknown'])
const OPERATIONS = new Set(['execute', 'import', 'export', 'unknown'])
const STATES = new Set(['admitted', 'running', 'retired', 'completed', 'interrupted',
  'recovered_committed', 'outcome_uncertain', 'unknown'])
const REASONS = new Set(['no_record', 'live_owner', 'admitted_not_dispatched', 'execution_in_flight',
  'retirement_unconfirmed', 'retired_before_publication', 'terminal_record', 'pointer_committed',
  'interrupted_before_commit', 'export_publication_unconfirmed', 'legacy_terminal', 'legacy_unconfirmed',
  'record_invalid', 'pointer_invalid', 'scan_incomplete'])
const recordFields = ['runId', 'operation', 'state', 'retirementConfirmed', 'diskCommitted',
  'filePublished', 'exitCode', 'reason', 'needsReview']

function object(value, fields) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))
    || Reflect.ownKeys(value).some(key => !fields.includes(key)
      || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) {
    throw new TypeError('Invalid Linux inspection object')
  }
  return value
}

function runId(value) { return typeof value === 'string' && value.length === 36 && UUID.test(value) }
function nullableBoolean(value) { return value === null || typeof value === 'boolean' }

/** Validate the model's optional run identity; Session identity is supplied by the host. */
export function prepareLinuxVmInspection(args) {
  object(args, ['runId'])
  if (Object.hasOwn(args, 'runId') && !runId(args.runId)) throw new TypeError('Invalid Linux run ID')
  return Object.hasOwn(args, 'runId') ? { id: args.runId } : {}
}

/** Parse only bounded, same-Session recovery facts from the native process. */
export function parseLinuxVmInspection(value, request) {
  object(value, ['version', 'sessionId', 'status', 'blocked', 'needsReview', 'requestedRunFound',
    'truncated', 'automaticReplay', 'records'])
  if (value.version !== 1 || value.sessionId !== request.sessionId || !STATUS.has(value.status)
    || typeof value.blocked !== 'boolean' || typeof value.needsReview !== 'boolean'
    || typeof value.truncated !== 'boolean' || value.automaticReplay !== false
    || !Array.isArray(value.records) || value.records.length > (request.id ? 1 : 32)
    || (request.id ? !(typeof value.requestedRunFound === 'boolean'
      || value.status === 'unknown' && value.requestedRunFound === null) : value.requestedRunFound !== null)
    || value.status === 'absent' && (value.records.length !== 0 || value.needsReview)
    || ['blocked', 'unknown'].includes(value.status) && (!value.blocked || !value.needsReview)
    || value.status === 'active' && !value.blocked
    || ['absent', 'ready'].includes(value.status) && value.blocked) {
    throw new TypeError('Invalid Linux inspection response')
  }
  const seen = new Set()
  const records = value.records.map(record => {
    object(record, recordFields)
    if (!runId(record.runId) || seen.has(record.runId) || request.id && record.runId !== request.id
      || !OPERATIONS.has(record.operation) || !STATES.has(record.state)
      || !['retirementConfirmed', 'diskCommitted', 'filePublished'].every(key => nullableBoolean(record[key]))
      || !(record.exitCode === null || Number.isInteger(record.exitCode) && record.exitCode >= 0 && record.exitCode <= 255)
      || typeof record.needsReview !== 'boolean' || !REASONS.has(record.reason)
      || ['completed', 'retired', 'recovered_committed', 'interrupted'].includes(record.state)
        && record.retirementConfirmed !== true
      || record.state === 'recovered_committed' && record.diskCommitted !== true
      || record.operation === 'export' && record.diskCommitted === true
      || record.operation !== 'export' && record.filePublished !== null) {
      throw new TypeError('Invalid Linux recovery record')
    }
    seen.add(record.runId)
    return Object.freeze(Object.fromEntries(recordFields.map(key => [key, record[key]])))
  })
  if (request.id && value.requestedRunFound !== null && value.requestedRunFound !== (records.length === 1)
    || request.id && value.requestedRunFound === null && records.some(record => record.state !== 'unknown'
      || !record.needsReview || record.retirementConfirmed !== null || record.diskCommitted !== null
      || record.filePublished !== null || record.exitCode !== null)
    || records.some(record => record.needsReview) && !value.needsReview) {
    throw new TypeError('Inconsistent Linux inspection response')
  }
  return Object.freeze({ ...value, records: Object.freeze(records) })
}
