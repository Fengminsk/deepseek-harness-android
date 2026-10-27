import { createWorkflowToolDefinition } from '@deepseek-ai/dsh-tool-workflow'
import { projectIsolatedSandboxPolicy } from './isolated-sandbox-policy.mjs'

const DEADLINE_MILLIS = 120_000
const MAX_TOTAL_AGENTS = 8
const MAX_CONCURRENT_AGENTS = 2
const closedByDefault = () => false

function unavailable() {
  throw Object.assign(new Error('Android workflow is unavailable until device acceptance'),
    { code: 'ANDROID_WORKFLOW_UNAVAILABLE' })
}

export function modelWorkflowCapability(available = false) {
  return Object.freeze({ available: available === true,
    reason: available === true ? null : 'device-lifecycle-unverified',
    maxTotalAgents: MAX_TOTAL_AGENTS, maxConcurrentAgents: MAX_CONCURRENT_AGENTS,
    deadlineMillis: DEADLINE_MILLIS, background: available === true,
    childTools: 'structured-result-only', filesystem: 'none', network: 'model-provider-only' })
}

/** App-owned registration; neither profile settings nor model arguments can open this gate. */
export function registerAndroidWorkflowTool(ctx, { owner, available = closedByDefault } = {}) {
  if (!owner || typeof owner.modelAdmission !== 'function' || typeof available !== 'function') {
    throw new TypeError('Android workflow requires the native owner and a trusted availability check')
  }
  if (available() !== true) return false
  let registered = false
  let registrationIdentity
  let definition
  const current = () => registered && available() === true
  const original = createWorkflowToolDefinition({ toolName: 'workflow',
    maxResultChars: 12_000, enableRunInBackground: true }, async (args, execution) => {
    if (!current()) unavailable()
    const admission = owner.modelAdmission({ agent: execution.agent, definition,
      registrationIdentity, modelAvailable: current,
      issueHost({ agent, signal }) {
        if (!current() || ctx.agents.get(agent.id) !== agent) unavailable()
        signal.throwIfAborted()
        return { deadlineMillis: DEADLINE_MILLIS,
          maxTotalAgents: MAX_TOTAL_AGENTS, maxConcurrentAgents: MAX_CONCURRENT_AGENTS,
          allowBackground: true,
          sandboxPolicy: projectIsolatedSandboxPolicy({ approvedScope: {
            ownerId: 'app-native-workflow', sessionId: agent.session.id, version: 1,
            workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
            fileCallLimit: 0, networkCallLimit: 0, leaseMillis: DEADLINE_MILLIS,
          } }),
        }
      },
    })
    const ticket = await admission.prepare(args, execution)
    const result = await admission.run(ticket)
    if (!current()) unavailable()
    return result
  })
  definition = Object.freeze({ ...original,
    description: original.description + '\n\nAndroid limits: at most 8 model-only subagents, 2 at once, within 120 seconds. Children can analyze supplied text and produce structured results; they cannot read files, browse, run shell commands or choose another provider/model. Supply all evidence in prompts or args. Background runs use job_output and job_kill.',
  })
  ctx.effect(() => {
    if (available() !== true) return
    const unregister = ctx.tools.register(definition)
    registrationIdentity = ctx.tools.registrationIdentity(definition.name)
    registered = true
    return () => { registered = false; unregister() }
  })
  ctx.systemPrompt.section({ name: 'tool:workflow',
    order: ctx.systemPrompt.getSectionOrder('TOOL_WORKFLOW'),
    text: 'Use workflow only when the user explicitly asks for workflows or multi-agent orchestration. Android workflow children analyze supplied content with the current model; they have no file, browser or shell tools.',
  })
  return true
}
