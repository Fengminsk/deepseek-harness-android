import {
  IsolatedExecutionContractError, normalizeExecutionScope,
} from './isolated-execution-contract.mjs'

const issued = new WeakSet()

function invalid(field) {
  throw new IsolatedExecutionContractError('ANDROID_SANDBOX_POLICY_INVALID',
    `Invalid isolated sandbox ${field}`)
}

function decisionFields(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) invalid('decision')
  const copy = Object.create(null)
  for (const key of Reflect.ownKeys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (typeof key !== 'string' || !['approvedScope', 'mode', 'networkMode'].includes(key)
      || !descriptor || !Object.hasOwn(descriptor, 'value')) invalid('decision')
    copy[key] = descriptor.value
  }
  if (!Object.hasOwn(copy, 'approvedScope')) invalid('approved scope')
  return copy
}

/**
 * Project one App-selected, already approved capability scope into an Android
 * sandbox decision. This is host preflight, not native admission or approval.
 * The model and isolated guest never supply `approvedScope` or these modes.
 * A child may only narrow its live parent decision and native scope.
 */
export function projectIsolatedSandboxPolicy(decision, parent) {
  const input = decisionFields(decision)
  const mode = Object.hasOwn(input, 'mode') ? input.mode : 'read-only'
  const networkMode = Object.hasOwn(input, 'networkMode') ? input.networkMode : 'deny'
  if (mode !== 'read-only' && mode !== 'workspace-write') invalid('file mode')
  if (networkMode !== 'deny' && networkMode !== 'allow-listed-https') invalid('network mode')
  if (parent !== undefined && !issued.has(parent)) invalid('parent')

  const scope = normalizeExecutionScope(input.approvedScope, parent?.scope)
  if (mode === 'read-only' && scope.writablePaths.length !== 0) invalid('read-only writes')
  if (networkMode === 'deny' && (scope.exactHosts.length !== 0 || scope.networkCallLimit !== 0)) {
    invalid('denied network grants')
  }
  if (parent?.mode === 'read-only' && mode !== 'read-only') invalid('child file mode')
  if (parent?.networkMode === 'deny' && networkMode !== 'deny') invalid('child network mode')

  const policy = Object.freeze({ mode, networkMode, scope })
  issued.add(policy)
  return policy
}

/** Accept only a policy previously projected by this trusted host module. */
export function requireIsolatedSandboxPolicy(value) {
  if (!issued.has(value)) invalid('issued policy')
  return value
}
