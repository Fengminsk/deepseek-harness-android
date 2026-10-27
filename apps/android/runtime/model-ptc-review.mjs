import { isFirstPartyWriteDefinition, isFirstPartyEditDefinition } from '@deepseek-ai/dsh-tool-fs'
import { isFirstPartyAndroidAttachmentsDefinition } from './tool-android-attachments.mjs'
import { READONLY_PTC_TOOLS, allowsReadOnlyPtcArguments,
  reviewReadOnlyToolsForModelPtc } from './model-ptc-readonly-review.mjs'
import { projectReadOnlyPtcResult, READONLY_PTC_RESULT_BYTES } from './model-ptc-readonly-projection.mjs'
import { createAppOwnedModelPtcCallerForExecution } from './model-ptc-caller-binding.mjs'
import { reviewedToolProjectionError } from './isolated-tool-call-port.mjs'

const WRITABLE = new Set(['workspace-write', 'danger-full-access'])
const mutations = { write: isFirstPartyWriteDefinition, edit: isFirstPartyEditDefinition,
  android_attachments: isFirstPartyAndroidAttachmentsDefinition }
export const PTC_TOOLS = Object.freeze([...READONLY_PTC_TOOLS, 'write', 'edit'])

/** Mutations keep their complete bounded receipt; a lost result never authorizes replay. */
function projectMutation(value) {
  if (Buffer.byteLength(JSON.stringify(value), 'utf8') > READONLY_PTC_RESULT_BYTES) {
    throw reviewedToolProjectionError('The file operation settled but its result exceeds the PTC reply limit. '
      + 'Inspect the recorded operation and target file before retrying; an error does not imply rollback.')
  }
  return value
}

/**
 * Review the current parent's original tools with per-call mutation policies.
 * The guest keeps zero direct file grants; the original Android file provider
 * and ToolRuntime enforce paths, observation, schema and cancellation.
 */
export function reviewToolsForModelPtc({ runtime, agent, services } = {}) {
  const result = [...reviewReadOnlyToolsForModelPtc({ runtime, agent, services })]
  const policy = services?.sandboxPolicy
  const sessions = services?.sessions
  if (!policy || typeof sessions?.flush !== 'function') return Object.freeze(result)
  for (const [name, attest] of Object.entries(mutations)) {
    const definition = runtime.get(name, agent)
    const registrationIdentity = runtime.registrationIdentity(name, agent)
    if (!definition || !registrationIdentity || !attest(definition, agent)) continue
    const attachment = name === 'android_attachments'
    const effectForArguments = args => attachment && args.action !== 'materialize' ? 'read-only' : 'workspace-write'
    const existing = result.findIndex(entry => entry.name === name)
    if (existing !== -1) result.splice(existing, 1)
    result.push(Object.freeze({ name, definition, registrationIdentity, effect: 'workspace-write',
      ...(attachment ? { effectForArguments } : {}),
      async authorizeArguments(args, input) {
        input.signal.throwIfAborted()
        if (input.agent !== agent || services.agents.get(agent.id) !== agent || !attest(definition, agent)) return false
        if (!args || typeof args !== 'object' || Array.isArray(args)
          || ![Object.prototype, null].includes(Object.getPrototypeOf(args))
          || Reflect.ownKeys(args).some(key => typeof key !== 'string'
            || !Object.hasOwn(Object.getOwnPropertyDescriptor(args, key), 'value'))
          || args.sandbox_permissions !== undefined && args.sandbox_permissions !== 'use_default') return false
        if (attachment && args.action !== 'materialize') return allowsReadOnlyPtcArguments(name, args)
        return WRITABLE.has(policy.resolve({ session: agent.session }).mode)
      },
      flushSession() { return sessions.flush(agent.session) },
      projectResult(value, args) {
        return effectForArguments(args) === 'read-only' ? projectReadOnlyPtcResult(name, args, value) : projectMutation(value)
      },
    }))
  }
  return Object.freeze(result)
}

/** Bind reviewed tool authority separately for each active parent execution. */
export function createAppOwnedPtcCaller({ bridge, callbacks, runtime, services } = {}) {
  return createAppOwnedModelPtcCallerForExecution({ bridge, callbacks, runtime,
    reviewedToolsForExecution(agent) { return reviewToolsForModelPtc({ runtime, agent, services }) },
  })
}
