import { randomUUID } from 'node:crypto'
import {
  IsolatedExecutionContractError,
  projectIsolatedReceipt,
  requireModelFacingIsolatedExecution,
} from './isolated-execution-contract.mjs'
import { prepareIsolatedTypeScriptRun } from './isolated-typescript-body.mjs'
import { requireIsolatedSandboxPolicy } from './isolated-sandbox-policy.mjs'
import { startIsolatedExecutionRun } from './isolated-execution-run.mjs'
import { NativeIsolatedToolCallbacks } from './native-isolated-tool-callbacks.mjs'
import { requireNativeIsolatedExecutionBridge } from './native-isolated-execution-bridge.mjs'
import { prepareModelPtcGuestSdk } from './model-ptc-guest-sdk.mjs'

const FORMAT = 'typescript-function-body'
const encoder = new TextEncoder()
const issuedDrafts = new WeakSet()

function invalid(field) {
  throw new IsolatedExecutionContractError('ANDROID_MODEL_SCRIPT_INVALID', `Invalid ${field}`)
}

function plainRecord(value, name, keys) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) invalid(name)
  const ownKeys = Reflect.ownKeys(value)
  if (ownKeys.length !== keys.length) invalid(name)
  const copy = Object.create(null)
  for (const key of ownKeys) {
    if (typeof key !== 'string' || !keys.includes(key)) invalid(`${name}.${String(key)}`)
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) invalid(`${name}.${key}`)
    copy[key] = descriptor.value
  }
  if (keys.some(key => !Object.hasOwn(copy, key))) invalid(name)
  return copy
}

/**
 * Translate a future model tool's untrusted arguments into a single script
 * request. Session, run ID and authority are supplied by the trusted App host,
 * never copied from the model. This does not register or enable a model tool.
 */
export function prepareModelIsolatedScript(modelArguments, host) {
  const input = plainRecord(modelArguments, 'model script arguments',
    ['code', 'description', 'language'])
  const authority = plainRecord(host, 'trusted host context',
    ['sessionId', 'sandboxPolicy', 'deadlineMillis'])
  if (input.language !== FORMAT) invalid('model script language')
  if (typeof input.description !== 'string' || input.description.trim().length === 0
    || encoder.encode(input.description).length > 256) invalid('model script description')
  if (typeof input.code !== 'string' || input.code.length === 0) invalid('model script code')
  // The native V8 entry receives only an erasable TypeScript body's compiled
  // JavaScript. The original run_code tools bindings still require admission.
  // The host projects an already App-approved policy before preparing a model
  // draft. This module never accepts policy fields from model arguments.
  // Native admission remains responsible for checking the approval itself.
  const scope = requireIsolatedSandboxPolicy(authority.sandboxPolicy).scope
  const prepared = prepareIsolatedTypeScriptRun({
    kind: 'script',
    runId: randomUUID(),
    sessionId: authority.sessionId,
    program: input.code,
    args: null,
    deadlineMillis: authority.deadlineMillis,
  }, scope)
  const draft = Object.freeze({
    description: input.description,
    language: FORMAT,
    source: prepared.source,
    compiled: prepared.compiled,
    execution: prepared.execution,
  })
  issuedDrafts.add(draft)
  return draft
}

/**
 * Trusted App-host implementation behind the still-closed model tool gate.
 * The guest receives only the App-selected pure/read-only ToolRuntime allowlist;
 * native admission refuses file, write and network grants on this route. A
 * matching durable terminal receipt is required before result publication.
 * No model argument can call this function through the Android profile.
 */
export function startAppOwnedModelIsolatedScript(draft, host) {
  if (!issuedDrafts.has(draft)) invalid('issued script draft')
  const owner = plainRecord(host, 'script execution host',
    ['bridge', 'callbacks', 'runtime', 'parent', 'allowedToolNames', 'authorizeTool', 'signal'])
  const bridge = requireNativeIsolatedExecutionBridge(owner.bridge)
  if (!(owner.callbacks instanceof NativeIsolatedToolCallbacks)
    || !Array.isArray(owner.allowedToolNames)
    || typeof owner.authorizeTool !== 'function'
    || !(owner.signal instanceof AbortSignal)) invalid('script execution host')
  const execution = draft.execution
  if (owner.parent?.agent?.session?.id !== execution.sessionId
    || owner.parent.signal !== owner.signal) invalid('script parent Session and signal')
  // This is a single-use App-issued draft. A lost native admission is uncertain
  // and must never cause this model body/run ID to be retried from the host.
  issuedDrafts.delete(draft)
  const sdk = prepareModelPtcGuestSdk(execution.program, owner.allowedToolNames)
  return startIsolatedExecutionRun({
    request: {
      kind: execution.kind, runId: execution.runId, sessionId: execution.sessionId,
      program: sdk.program, args: sdk.args,
      deadlineMillis: execution.deadlineMillis,
    },
    scope: execution.scope,
    bridge,
    toolBinding: { bind: (prepared, admission) => owner.callbacks.bind({
      prepared, admission, runtime: owner.runtime, parent: owner.parent,
      allowedToolNames: owner.allowedToolNames, authorizeTool: owner.authorizeTool,
    }) },
    signal: owner.signal,
  })
}

/**
 * Deliberate product gate. Native guest function-body admission and device
 * isolation must be proven before an App model tool can execute this draft.
 * The supplied bridge is never touched while the gate is closed.
 */
export function runModelIsolatedScript(_draft, _bridge, _signal) {
  requireModelFacingIsolatedExecution()
}

/** Project only the durable terminal record. Uncertain/cancelled output stays hidden. */
export function projectModelIsolatedScriptReceipt(receipt, expectedRunId) {
  const projected = projectIsolatedReceipt(receipt, expectedRunId)
  return projected.state === 'completed'
    ? Object.freeze({ runId: projected.runId, state: 'completed', value: projected.value,
      logs: projected.logs })
    : Object.freeze({
      runId: projected.runId, state: 'failed', failure: projected.failure,
      requiresReview: projected.requiresReview, detail: projected.detail,
    })
}
