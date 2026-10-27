import { isFirstPartyReadDefinition } from '@deepseek-ai/dsh-tool-fs'
import { isFirstPartyGlobDefinition, isFirstPartyGrepDefinition } from '@deepseek-ai/dsh-tool-fs-search'
import { isFirstPartyWebSearchDefinition, isFirstPartyWebFetchDefinition } from '@deepseek-ai/dsh-tool-web'
import { isFirstPartyAndroidFilesDefinition } from './tool-android-files.mjs'
import { isFirstPartyAndroidAttachmentsDefinition } from './tool-android-attachments.mjs'
import { reviewListAgentsForModelPtc } from './model-ptc-list-agents-review.mjs'
import { createAppOwnedModelPtcCallerForExecution } from './model-ptc-caller-binding.mjs'
import { projectReadOnlyPtcResult } from './model-ptc-readonly-projection.mjs'

const reviews = Object.freeze({
  read: isFirstPartyReadDefinition,
  glob: isFirstPartyGlobDefinition,
  grep: isFirstPartyGrepDefinition,
  web_search: isFirstPartyWebSearchDefinition,
  web_fetch: isFirstPartyWebFetchDefinition,
  android_files: isFirstPartyAndroidFilesDefinition,
  android_attachments: isFirstPartyAndroidAttachmentsDefinition,
})
export const READONLY_PTC_TOOLS = Object.freeze(['list_agents', ...Object.keys(reviews)])

function dataObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && [Object.prototype, null].includes(Object.getPrototypeOf(value))
    && Reflect.ownKeys(value).every(key => typeof key === 'string'
      && Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))
}

/** Read-only actions are enforced before the original tool pipeline executes. */
export function allowsReadOnlyPtcArguments(name, args) {
  if (!dataObject(args)) return false
  if (name === 'android_files') return ['roots', 'list', 'read', 'search'].includes(args.action)
  if (name === 'android_attachments') return ['list', 'read', 'inspect_archive'].includes(args.action)
  return Object.hasOwn(reviews, name)
}

/**
 * Capture reviewed first-party definitions from the live parent's scope.
 * Missing or replaced tools are omitted; no name-wide grant survives reload.
 */
export function reviewReadOnlyToolsForModelPtc({ runtime, agent, services } = {}) {
  if (!agent?.session?.id || services?.agents?.get(agent.id) !== agent
    || typeof runtime?.get !== 'function' || typeof runtime?.registrationIdentity !== 'function') {
    throw new TypeError('Read-only PTC requires the live Agent and tool registry')
  }
  const result = []
  const list = runtime.get('list_agents', agent)
  if (list) {
    try { result.push(reviewListAgentsForModelPtc({ runtime, agent, definition: list, services })) }
    catch (error) {
      if (!(error instanceof TypeError)) throw error
      // An optional tool replaced by another plugin is unavailable to this guest.
    }
  }
  for (const [name, attest] of Object.entries(reviews)) {
    const definition = runtime.get(name, agent)
    if (!definition || !attest(definition, agent)) continue
    const registrationIdentity = runtime.registrationIdentity(name, agent)
    if (!registrationIdentity) continue
    result.push(Object.freeze({ name, definition, registrationIdentity, effect: 'read-only',
      async authorizeArguments(args, input) {
        input.signal.throwIfAborted()
        return input.agent === agent && services.agents.get(agent.id) === agent
          && attest(definition, agent) && allowsReadOnlyPtcArguments(name, args)
      },
      projectResult(value, args) { return projectReadOnlyPtcResult(name, args, value) },
    }))
  }
  return Object.freeze(result)
}

/** Bind each run to newly reviewed definitions; this does not register a model tool. */
export function createAppOwnedReadOnlyPtcCaller({ bridge, callbacks, runtime, services } = {}) {
  return createAppOwnedModelPtcCallerForExecution({ bridge, callbacks, runtime,
    reviewedToolsForExecution(agent) { return reviewReadOnlyToolsForModelPtc({ runtime, agent, services }) },
  })
}
