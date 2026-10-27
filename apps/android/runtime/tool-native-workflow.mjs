import { createWorkflowToolDefinition } from '@deepseek-ai/dsh-tool-workflow'
import { projectIsolatedSandboxPolicy } from './isolated-sandbox-policy.mjs'

const DEADLINE_MILLIS = 120_000
const MAX_TOTAL_AGENTS = 8
const MAX_CONCURRENT_AGENTS = 2
const REVIEWED_CHILD_TOOLS = Object.freeze(['read', 'glob', 'grep', 'write', 'edit', 'web_search', 'web_fetch',
  'linux_exec', 'linux_import', 'linux_export'])
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
    childTools: 'reviewed-parent-tools', reviewedChildTools: REVIEWED_CHILD_TOOLS,
    filesystem: 'activation-workspace-policy-intersection', network: 'reviewed-parent-web-tools',
    linuxDisk: 'child-session-private', linuxNetwork: 'off' })
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
    description: original.description + '\n\nAndroid limits: at most 8 children, 2 at once, within 120 seconds, using the parent provider/model. Newly activated children may inherit only the parent\'s live first-party read, glob, grep, write, edit, web_search, web_fetch, linux_exec, linux_import and linux_export registrations; this is the maximum reviewed set, not a guarantee that every tool is available. App file access stays inside the canonical parent directory captured at activation. Writes must satisfy both current parent and child sandbox policies and permission roots, including the original file observation checks. Web tools retain their inherited providers and checks. Linux tools appear only when already registered on the parent. linux_exec uses the child Session\'s private disk with no guest networking or App-UID Shell. Disk changes persist only when activation permitted writes and both current parent and child policies remain writable; otherwise command changes are discarded, and later policy upgrades cannot widen the activation permission. linux_import reads authorized App files; linux_export publishes a new App file. Relative App paths resolve from the child cwd. Both transfers require activation-time and current parent/child write permission and stay within the activation directory and both permission roots. Linux execution capacity is one App-wide; serialize Linux steps across children. A busy refusal means no native dispatch; do not treat it as completed or automatically replay it. Structured children may use authorized tools before submitting structured_output. Children receive no App-UID Shell, PTC, recursive delegation or cross-Session SAF/attachment grants. Cold resume alone restores no file, web or Linux grants. Background runs use job_output and job_kill.',
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
    text: 'Use workflow only when the user explicitly asks for workflows or multi-agent orchestration. Android children use the parent model and only its live first-party read/glob/grep/write/edit/web_search/web_fetch/linux_exec/linux_import/linux_export registrations. These tools are conditional, not guaranteed. App file access stays inside the activation workspace and writes require both current parent and child policies. Linux tools require existing parent registration, use a child-Session-private disk and have no guest networking. linux_exec discards changes unless activation and both current policies permit persistence; later upgrades cannot enlarge that grant. linux_import/linux_export require activation-time and current parent/child write permission, resolve relative App paths from child cwd, and respect the activation directory and both permission roots; export publishes a new file. Serialize Linux steps across children: capacity is one App-wide, and busy means no native dispatch, not completion or permission to replay automatically. Children receive no App-UID Shell, PTC, recursive delegation or cross-Session SAF/attachment grants. Cold resume alone restores no file, web or Linux access.',
  })
  return true
}
