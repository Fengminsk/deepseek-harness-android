import { isFirstPartyLinuxDefinition } from './tool-linux-vm.mjs'
import { READONLY_PTC_RESULT_BYTES } from './model-ptc-readonly-projection.mjs'
import { reviewedToolProjectionError } from './isolated-tool-call-port.mjs'

export const LINUX_PTC_TOOLS = Object.freeze(['linux_exec', 'linux_import', 'linux_export', 'linux_inspect'])
const WRITABLE = new Set(['workspace-write', 'danger-full-access'])

/** Preserve complete native facts; an oversized reply must not encourage replay. */
function projectLinuxResult(value) {
  if (Buffer.byteLength(JSON.stringify(value), 'utf8') > READONLY_PTC_RESULT_BYTES) {
    throw reviewedToolProjectionError('Linux returned a result exceeding the 48 KiB PTC reply limit. '
      + 'Inspect linux_inspect and the recorded Linux receipt before retrying; execution or publication may already have occurred. '
      + 'Read any retained host output; for future commands, bound output or use the direct Linux tool with its larger reply limit.')
  }
  return value
}

/** Review only the parent's live original Linux tools; the tools retain all native policy and approval ownership. */
export function reviewLinuxToolsForModelPtc({ runtime, agent, services } = {}) {
  const result = []
  const policy = services?.sandboxPolicy
  const sessions = services?.sessions
  for (const name of LINUX_PTC_TOOLS) {
    const definition = runtime.get(name, agent)
    const registrationIdentity = runtime.registrationIdentity(name, agent)
    const inspection = name === 'linux_inspect'
    if (!definition || !registrationIdentity || !isFirstPartyLinuxDefinition(definition, agent)
      || !inspection && (typeof policy?.resolve !== 'function' || typeof sessions?.flush !== 'function')) continue
    result.push(Object.freeze({ name, definition, registrationIdentity,
      effect: inspection ? 'read-only' : 'isolated-execution',
      async authorizeArguments(args, input) {
        input.signal.throwIfAborted()
        if (input.agent !== agent || services.agents.get(agent.id) !== agent
          || !isFirstPartyLinuxDefinition(definition, agent)
          || args === null || typeof args !== 'object' || Array.isArray(args)
          || ![Object.prototype, null].includes(Object.getPrototypeOf(args))
          || Reflect.ownKeys(args).some(key => typeof key !== 'string'
            || !Object.hasOwn(Object.getOwnPropertyDescriptor(args, key), 'value'))) return false
        if (inspection) return true
        const mode = policy.resolve({ session: agent.session }).mode
        return name === 'linux_exec' ? mode === 'read-only' || WRITABLE.has(mode) : WRITABLE.has(mode)
      },
      ...(inspection ? {} : { flushSession() { return sessions.flush(agent.session) } }),
      projectResult: projectLinuxResult,
    }))
  }
  return Object.freeze(result)
}
