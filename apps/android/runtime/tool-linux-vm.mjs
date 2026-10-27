import { defineTool } from '@deepseek-ai/dsh-tools'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { realpathSync } from 'node:fs'
import { lstat } from 'node:fs/promises'
import { isAbsolute, relative, resolve, sep } from 'node:path'
import { LINUX_VM_IMPORT_BYTES, LinuxVmOutcomeUncertainError, LinuxVmRecoveryRequiredError, prepareLinuxVmCommand, prepareLinuxVmImport,
  prepareLinuxVmInspection } from './native-linux-vm.mjs'
import { canonicalModelTarget, insideModelWorkspace, modelFileObservationDenial } from './model-file-read-guard.mjs'

const definitionKey = Symbol('Android Linux definition owner')

class LinuxDefinitionOwner {
  #runtime
  #active = true
  #name

  constructor(key, runtime, name) {
    if (key !== definitionKey) throw new TypeError('Only the Linux tool factory can issue its definition')
    this.#runtime = runtime
    this.#name = name
  }

  static owns(definition, scope) {
    return definition !== null && typeof definition === 'object' && #runtime in definition
      && definition.#active && definition.#runtime.get(definition.#name, scope) === definition
  }

  retire() { this.#active = false }
}

/** Attest the exact live factory definition, including in a delegated child scope. */
export function isFirstPartyLinuxDefinition(definition, scope) {
  return LinuxDefinitionOwner.owns(definition, scope)
}

function registerDefinition(ctx, options) {
  const owner = new LinuxDefinitionOwner(definitionKey, ctx.tools, options.name)
  const definition = Object.freeze(Object.assign(owner, defineTool(options)))
  ctx.tools.register(definition)
  ctx.effect(() => () => owner.retire())
}

function sessionPolicy(ctx, execution, priorDelegationCheck, target) {
  const agent = execution.agent
  if (!agent?.session || ctx.agents.get(agent.id) !== agent || !ctx.tools.isActiveExecution(execution)) {
    throw new Error('Linux VM requires the current registered Agent execution')
  }
  const service = ctx.get('sandboxPolicy')
  if (!service) throw new Error('Linux VM requires the session sandbox policy')
  const policy = service.resolve({ session: agent.session })
  if (!['read-only', 'workspace-write', 'danger-full-access'].includes(policy.mode)
    || typeof policy.workspaceRoot !== 'string' || !isAbsolute(policy.workspaceRoot)) {
    throw new Error('Linux VM received an invalid session sandbox policy')
  }
  execution.signal.throwIfAborted()
  // File preparation awaits filesystem services. Revalidate the delegated
  // grant here, immediately before dispatch as well as at tool admission.
  const owner = ctx.get('androidWorkflowChildTools')
  // Retain the original owner across awaits. Unloading it clears its grants;
  // absence of a replacement must not turn a child into an unrestricted caller.
  const checkDelegation = priorDelegationCheck ?? (target => owner?.linuxExecutionPolicy(execution, target))
  const delegated = checkDelegation(target)
  if (delegated?.denial) throw new Error(delegated.denial)
  return { agent, policy, checkDelegation,
    persistChanges: policy.mode !== 'read-only' && delegated?.persistChanges !== false }
}

// ToolRuntime deliberately replaces a late success with TOOL_ABORTED. Its
// deferred contexts survive that normalization and enter the Session inbox log,
// including when cancellation parks them until the next model turn.
function deferReceipt(execution, result) {
  const facts = { version: 1, tool: execution.name, callId: String(execution.callId),
    sessionId: String(execution.agent.session.id), runId: result.runId ?? result.id,
    status: result.status, diskCommitted: result.diskCommitted ?? null,
    cancelRequested: result.cancelRequested === true }
  for (const key of ['filePublished', 'retirementConfirmed']) {
    if (result[key] === null || typeof result[key] === 'boolean') facts[key] = result[key]
  }
  if (typeof result.nativeStatus === 'string' && result.nativeStatus.length <= 32) facts.nativeStatus = result.nativeStatus
  if (result.exitCode === null || Number.isInteger(result.exitCode) && result.exitCode >= 0 && result.exitCode <= 255) facts.exitCode = result.exitCode
  if (Number.isSafeInteger(result.bytes) && result.bytes >= 0 && result.bytes <= LINUX_VM_IMPORT_BYTES) facts.bytes = result.bytes
  if (typeof result.sha256 === 'string' && /^[0-9a-f]{64}$/u.test(result.sha256)) facts.sha256 = result.sha256
  execution.deferContext(createUserMessage({
    source: { kind: 'android-linux-receipt' },
    content: [{ type: 'text', text: JSON.stringify({ linuxVmReceipt: facts }) }],
  }))
}

async function retainReceipt(execution, dispatch) {
  try {
    const result = await dispatch()
    deferReceipt(execution, result)
    return result
  } catch (error) {
    if (error instanceof LinuxVmOutcomeUncertainError) deferReceipt(execution, error.receipt)
    if (error instanceof LinuxVmRecoveryRequiredError) deferInspection(execution, error.inspection)
    throw error
  }
}

function deferInspection(execution, result) {
  execution.deferContext(createUserMessage({ source: { kind: 'android-linux-inspection' },
    content: [{ type: 'text', text: JSON.stringify({ linuxVmInspection: result }) }] }))
}

/** Query current-Session recovery facts without starting or replaying a Linux command. */
export function registerLinuxInspectTool(ctx, owner, available) {
  if (!available) return
  registerDefinition(ctx, {
    name: 'linux_inspect',
    description: 'Inspect Linux execution records in the current Agent Session without booting the guest, changing files, replaying commands or reopening a blocked execution owner. Supply a runId from an earlier receipt, or omit it to see bounded recent and unresolved records. diskCommitted, filePublished and retirementConfirmed are independent facts; null means unknown. A missing record does not establish safe retry. recovered_committed proves the disk pointer belongs to that run, not that its output or successful exit was recovered. blocked or needsReview means stop dependent work and report the facts; never automatically rerun an uncertain command.',
    parameters: { runId: { type: 'string' } },
    output: { schema: { type: 'json' }, render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }] },
    async execute(args, execution) {
      prepareLinuxVmInspection(args)
      const { agent } = sessionPolicy(ctx, execution)
      const result = await owner.inspect(String(agent.session.id), args, execution.signal)
      // Persist the full bounded observation even if caller cancellation later
      // normalizes the canonical result to TOOL_ABORTED.
      deferInspection(execution, result)
      return result
    },
  })
}

/**
 * Export an immutable guest file through the existing model workspace write policy.
 * @param ctx - Live Android services and ToolRuntime.
 * @param owner - Native Linux execution owner.
 * @param available - Source-owned acceptance gate.
 * @param workspaceRoot - Boot-pinned App workspace root.
 */
export function registerLinuxExportTool(ctx, owner, available, workspaceRoot = process.cwd()) {
  if (!available) return
  const root = realpathSync(workspaceRoot)
  registerDefinition(ctx, { name: 'linux_export',
    description: 'Copy one regular file (up to 64 MiB) from this conversation’s Linux VM /workspace into the current Agent workspace. source is guest-relative; destination is relative to the Agent working directory. Absolute paths, .., protected metadata and existing destination files are rejected. Requires a writable session policy. Export does not persist guest disk changes. A confirmed success returns file_path, bytes, sha256 and filePublished:true so the file can be viewed or presented. A cancellation request cannot undo an already published file; inspect cancelRequested and never automatically retry an uncertain publication.',
    parameters: { source: { type: 'string', required: true }, destination: { type: 'string', required: true }, timeoutMs: { type: 'integer' } },
    output: { schema: { type: 'json' }, render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }] },
    async execute(input, execution) {
      const args = prepareLinuxVmImport(input)
      const initial = sessionPolicy(ctx, execution)
      if (!initial.persistChanges) throw new Error('Linux export requires a writable session policy')
      if (typeof ctx.fs.authorizeModelAttachmentWrite !== 'function') throw new Error('Linux export requires the Android workspace write policy')
      const cwd = await ctx.workingDirectory.ensure(initial.agent, execution.signal)
      const denial = modelFileObservationDenial(root, cwd, 'write', { file_path: args.destination })
      if (denial) throw new Error(denial)
      const requested = resolve(cwd, args.destination)
      await ctx.fs.authorizeModelAttachmentWrite(requested, initial.agent)
      try {
        await lstat(requested)
        throw new Error('Linux export destination already exists; choose a new file name')
      } catch (error) { if (error?.code !== 'ENOENT') throw error }
      const target = await ctx.fs.authorizeModelAttachmentWrite(requested, initial.agent)
      const actual = canonicalModelTarget(ctx.fs.processPath(target))
      const current = sessionPolicy(ctx, execution, initial.checkDelegation, actual)
      if (!current.persistChanges || !insideModelWorkspace(root, actual)
        || !insideModelWorkspace(realpathSync(current.policy.workspaceRoot), actual)) {
        throw new Error('Linux export destination is outside the current session workspace or policy changed')
      }
      const result = await retainReceipt(execution, () => owner.exportFile(String(current.agent.session.id), {
        ...args, destination: relative(root, actual).split(sep).join('/'),
      }, execution.signal, { persistChanges: true }))
      return result.status === 'completed' && result.filePublished === true
        ? { ...result, file_path: actual } : result
    },
  })
}

/** Register real guest shell execution only after its packaged provider has passed device acceptance. */
export function registerLinuxVmTool(ctx, owner, available) {
  if (!available) return
  registerDefinition(ctx, {
    name: 'linux_exec',
    description: 'Execute a shell script in the local Linux VM. The guest has BusyBox shell and utilities, its own Linux kernel and a disk per conversation. Commands start in /workspace. The guest cannot access Android app data or phone files directly and has no network. Use linux_import for workspace files. timeoutMs includes boot and execution (1000–120000 ms). With read-only session policy all disk changes are discarded; writable policy persists changes only after successful guest shutdown. A confirmed cancelled or timed-out run discards changes; a cancellation request arriving after publication cannot undo it. Inspect exitCode, status, diskCommitted and cancelRequested before claiming success or retrying.',
    parameters: {
      command: { type: 'string', required: true },
      timeoutMs: { type: 'integer' },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }],
    },
    async execute(args, execution) {
      const { agent, persistChanges } = sessionPolicy(ctx, execution)
      return retainReceipt(execution, () => owner.execute(String(agent.session.id),
        prepareLinuxVmCommand(args), execution.signal, { persistChanges }))
    },
  })
}

/** Import only an authorized file from this Agent's workspace into its own persistent guest disk. */
export function registerLinuxImportTool(ctx, owner, available, workspaceRoot = process.cwd()) {
  if (!available) return
  const root = realpathSync(workspaceRoot)
  registerDefinition(ctx, { name: 'linux_import',
    description: 'Copy one file (up to 64 MiB) from the current Agent workspace into this conversation’s Linux VM /workspace directory. source is relative to the current Agent working directory; destination is relative to guest /workspace. Absolute paths and .. are rejected. Requires a writable session policy. Uploaded attachments must first be materialized into the App workspace. The guest has no direct Android file access. Inspect status, bytes, sha256, diskCommitted and cancelRequested. Confirmed cancelled or failed imports do not commit; cancellation requested after publication cannot undo a completed import.',
    parameters: { source: { type: 'string', required: true }, destination: { type: 'string', required: true }, timeoutMs: { type: 'integer' } },
    output: { schema: { type: 'json' }, render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }] },
    async execute(input, execution) {
      const args = prepareLinuxVmImport(input)
      const initial = sessionPolicy(ctx, execution)
      if (!initial.persistChanges) throw new Error('Linux import requires a writable session policy')
      const cwd = await ctx.workingDirectory.ensure(initial.agent, execution.signal)
      const denial = modelFileObservationDenial(root, cwd, 'read', { file_path: args.source })
      if (denial) throw new Error(denial)
      const target = await ctx.fs.resolve(args.source, { cwd })
      const info = await ctx.fs.stat(target, execution.signal)
      if (info?.type !== 'file' || !Number.isSafeInteger(info.size) || info.size < 0 || info.size > LINUX_VM_IMPORT_BYTES) {
        throw new Error('Linux import requires a regular workspace file no larger than 64 MiB')
      }
      const actual = realpathSync(ctx.fs.processPath(target))
      const current = sessionPolicy(ctx, execution, initial.checkDelegation, actual)
      if (!current.persistChanges || !insideModelWorkspace(root, actual)
        || !insideModelWorkspace(realpathSync(current.policy.workspaceRoot), actual)) {
        throw new Error('Linux import source is outside the current session workspace or policy changed')
      }
      const source = relative(root, actual).split(sep).join('/')
      return retainReceipt(execution, () => owner.importFile(String(current.agent.session.id),
        { ...args, source }, execution.signal, { persistChanges: true }))
    },
  })
}
