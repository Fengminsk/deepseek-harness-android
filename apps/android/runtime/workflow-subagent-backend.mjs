/**
 * A trusted Android workflow adapter for the original in-process `spawn`
 * activation manager. The child joins a dedicated tool-restricted preset, never the
 * Android parent preset that offers App-UID Shell and file tools. This adapter
 * does not admit a workflow or expose it to a model.
 */

const PRESET_ID = 'android-workflow-child'
const STRUCTURED_PRESET_ID = 'android-workflow-structured-child'
const SANDBOX_MODULE = new URL('./workflow-child-sandbox.mjs', import.meta.url).href
const STRUCTURED_SANDBOX_MODULE = new URL('./workflow-child-structured-sandbox.mjs', import.meta.url).href
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function denied(message) {
  return Object.assign(new Error(message), { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
}

function requireServices(ctx) {
  if (!ctx?.agents || !ctx?.subagents || !ctx?.agentPresets || !ctx?.tools
    || !ctx.get?.('sessionPersistence') || !ctx.get?.('sessionQuery')) {
    throw denied('Workflow child requires the original agent, subagent, preset, tool, persistence and query services')
  }
  // The dedicated child preset installs a scoped allow: [] restriction on the
  // global registry. The runtime may still offer Android tools to its parent.
}

function requireHost(ctx, parent) {
  requireServices(ctx)
  if (typeof parent?.id !== 'string' || ctx.agents.get(parent.id) !== parent) {
    throw denied('Workflow parent is not the exact live Agent')
  }
}

function requirePreset(ctx) {
  const compositions = ctx.agentPresets.inspectCompositions()
  for (const [id, module] of [[PRESET_ID, SANDBOX_MODULE], [STRUCTURED_PRESET_ID, STRUCTURED_SANDBOX_MODULE]]) {
    const revisions = compositions.filter(row => row.id === id)
    if (revisions.length !== 1 || revisions[0].modules.length !== 1
      || revisions[0].modules[0].moduleName !== module
      || revisions[0].leakedServices.length !== 0) {
      throw denied(`Workflow child preset ${id} is missing, shadowed or not isolated`)
    }
  }
}

function modelRoute(parent) {
  const route = parent.session.requestHeader()?.config ?? parent.options
  return { provider: route.provider, model: route.model }
}

/**
 * Install the same tool-restricted preset once per host runtime, before workflow
 * admission or cold-resume. Keep it registered while any workflow child may
 * run or resume; release it during host teardown after all guests close.
 */
export async function installWorkflowSubagentPreset(ctx) {
  requireServices(ctx)
  const unregisterPlain = await ctx.agentPresets.register({
    id: PRESET_ID, plugins: [{ name: SANDBOX_MODULE }],
  })
  let unregisterStructured
  try {
    unregisterStructured = await ctx.agentPresets.register({
      id: STRUCTURED_PRESET_ID, plugins: [{ name: STRUCTURED_SANDBOX_MODULE }],
    })
    requirePreset(ctx)
  } catch (error) {
    if (unregisterStructured) await unregisterStructured()
    await unregisterPlain()
    throw error
  }
  return async () => { await unregisterStructured(); await unregisterPlain() }
}

/**
 * Bind one admitted workflow's exact live parent to the original `spawn`
 * activation manager. The caller owns durable run admission and progress
 * persistence. `authorize` is a trusted App policy decision, not guest code.
 * Call `close` after its guest has retired every published child.
 */
export function createWorkflowSubagentBackend({ ctx, parent, runId, authorize }) {
  if (typeof authorize !== 'function') throw new TypeError('Workflow child needs an App authorization callback')
  if (typeof runId !== 'string' || !UUID.test(runId)) throw denied('Workflow child needs an admitted run ID')
  requireHost(ctx, parent)
  requirePreset(ctx)
  const approved = new WeakMap()
  let closed = false

  function available() {
    if (closed) throw denied('Workflow child backend has closed')
    requireHost(ctx, parent)
    requirePreset(ctx)
  }

  return Object.freeze({
    async authorizeChild(request, signal, reservedChildId) {
      available()
      signal.throwIfAborted()
      if (typeof reservedChildId !== 'string' || !UUID.test(reservedChildId)) {
        throw denied('Workflow child has no App-issued reservation')
      }
      const grant = await authorize(request, signal, parent, runId, reservedChildId)
      signal.throwIfAborted()
      available()
      if (!grant || typeof grant !== 'object' || grant.runId !== runId
        || grant.parentId !== parent.id || typeof grant.childId !== 'string'
        || !UUID.test(grant.childId) || grant.childId !== reservedChildId
        || grant.childId === parent.id) {
        throw denied('Workflow child has no exact durable App reservation')
      }
      const route = modelRoute(parent)
      if (typeof route.provider !== 'string' || !route.provider
        || typeof route.model !== 'string' || !route.model) {
        throw denied('Workflow parent has no fixed model route')
      }
      if (request.provider !== undefined && request.provider !== route.provider
        || request.model !== undefined && request.model !== route.model) {
        throw denied('Workflow child cannot widen its parent model route')
      }
      approved.set(request, { childId: grant.childId, route })
      return true
    },
    async activateChild(request, signal) {
      available()
      const approval = approved.get(request)
      approved.delete(request)
      if (!approval) throw denied('Workflow child request has no current App authorization')
      signal.throwIfAborted()
      const { childId, route } = approval
      const current = modelRoute(parent)
      if (current.provider !== route.provider || current.model !== route.model) {
        throw denied('Workflow parent model route changed after child authorization')
      }
      const run = await ctx.subagents.startActivation({
        provider: 'spawn',
        label: 'Workflow child',
        delivery: 'caller',
        childId,
        signal,
        request: {
          parent,
          prompt: [{ type: 'text', text: request.prompt }],
          agentPreset: request.schema === undefined ? PRESET_ID : STRUCTURED_PRESET_ID,
          agentOptions: route,
          ...(request.schema === undefined ? {} : { outputSchema: request.schema }),
        },
      })
      // Return even a mismatched handle to WorkflowChildPort. It owns the
      // cancellation and retains an unretired child if disposal fails.
      return { childId: run.childId, result: run.result, dispose: () => run.dispose() }
    },
    close() { closed = true },
  })
}
