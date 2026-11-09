import { defineTool } from '@deepseek-ai/dsh-tools'
import { CodeRunFailedError } from '@deepseek-ai/dsh-tool-executor-ptc'
import { IsolatedExecutionContractError } from './isolated-execution-contract.mjs'
import { requireAppOwnedListAgentsPtcOwner } from './model-ptc-owner.mjs'

const LANGUAGE = 'typescript-function-body'
const TOOL_NAME = 'android_ptc'

function unavailable() {
  throw new IsolatedExecutionContractError('ANDROID_PTC_UNAVAILABLE',
    'Android model PTC requires accepted isolated-UID and lifecycle evidence')
}

function argumentsForOwner(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new TypeError('Android PTC requires code and description')
  }
  const keys = Reflect.ownKeys(value)
  if (keys.length !== 2 || !['code', 'description'].every(key => keys.includes(key))
    || keys.some(key => typeof key !== 'string'
      || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) {
    throw new TypeError('Android PTC accepts only code and description')
  }
  return { code: value.code, description: value.description, language: LANGUAGE }
}

function requireAvailability(available) {
  if (typeof available !== 'function') {
    throw new TypeError('Android PTC requires a trusted product availability check')
  }
  return available
}

/** Keep model-visible output in the original PTC order: console lines, then value. */
export function renderAndroidPtcResult(_args, result) {
  const value = result.result === undefined ? ''
    : typeof result.result === 'string' ? result.result : JSON.stringify(result.result)
  const parts = [...result.logs, value].filter(part => part.length > 0)
  return [{ type: 'text', text: parts.length ? parts.join('\n') : '(android_ptc completed with no output)' }]
}

/** The product gate is build-owned; it is never a user, model or profile option. */
export function modelPtcCapability(available) {
  return Object.freeze({
    available: available === true,
    reason: available === true ? null : 'device-isolation-unverified',
    language: LANGUAGE,
    reviewedTools: Object.freeze(['list_agents']),
    filesystem: 'none',
    network: 'off',
  })
}

/**
 * A narrow Android presentation, not the original general `run_code` mode.
 * The actual native run is owned by the App's live ToolRuntime parent and
 * exposes only the captured, first-party direct-child list_agents definition.
 */
export function createAndroidPtcToolDefinition({ owner, available } = {}) {
  requireAppOwnedListAgentsPtcOwner(owner)
  requireAvailability(available)
  return defineTool({
    name: TOOL_NAME,
    description: 'Run one bounded TypeScript function body in an isolated Android process. Only tools.list_agents({ scope: "children" }) is available. No files, network, shell or writable paths.',
    parameters: {
      code: { type: 'string', required: true },
      description: { type: 'string', required: true },
    },
    output: {
      schema: { type: 'json' },
      render: renderAndroidPtcResult,
    },
    async execute(args, execution) {
      if (available() !== true) unavailable()
      const run = owner.start(argumentsForOwner(args), execution)
      const receipt = await run.result
      if (available() !== true) unavailable()
      // IsolatedExecutionRun has already validated ownership and the durable
      // terminal receipt. Re-projecting it as a raw native receipt would fail.
      if (receipt.state !== 'completed') {
        throw new CodeRunFailedError(`Android isolated program ${receipt.failure}${
          receipt.requiresReview ? '; execution requires review' : ''}`)
      }
      return { logs: receipt.logs, result: receipt.value }
    },
  })
}

/** Register only when the trusted build gate is open at the point of effect. */
export function registerAndroidPtcTool(ctx, options = {}) {
  requireAppOwnedListAgentsPtcOwner(options.owner)
  const available = requireAvailability(options.available)
  if (available() !== true) return false
  const definition = createAndroidPtcToolDefinition(options)
  ctx.effect(() => {
    if (available() !== true) return
    return ctx.tools.register(definition)
  })
  return true
}
