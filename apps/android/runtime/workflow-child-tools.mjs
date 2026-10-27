/** Host-owned, in-process grants for one admitted workflow's reserved children. */
import { Service } from '@deepseek-ai/cordis'
import { realpathSync } from 'node:fs'
import { isFirstPartyReadDefinition, isFirstPartyWriteDefinition,
  isFirstPartyEditDefinition } from '@deepseek-ai/dsh-tool-fs'
import { isFirstPartyGlobDefinition, isFirstPartyGrepDefinition } from '@deepseek-ai/dsh-tool-fs-search'
import { isFirstPartyWebSearchDefinition, isFirstPartyWebFetchDefinition } from '@deepseek-ai/dsh-tool-web'
import { modelFileObservationDenial } from './model-file-read-guard.mjs'

const REVIEWED = new Map([
  ['read', isFirstPartyReadDefinition], ['glob', isFirstPartyGlobDefinition],
  ['grep', isFirstPartyGrepDefinition], ['write', isFirstPartyWriteDefinition],
  ['edit', isFirstPartyEditDefinition], ['web_search', isFirstPartyWebSearchDefinition],
  ['web_fetch', isFirstPartyWebFetchDefinition],
])
const FILES = new Set(['read', 'glob', 'grep', 'write', 'edit'])
const WRITES = new Set(['write', 'edit'])
const WRITABLE = new Set(['workspace-write', 'danger-full-access'])
const DENIED = 'Workflow child tool is not authorized by its current parent and child policies'

/**
 * One Host owns the grants; preset names and persisted lineage never restore
 * them. The preset listener consumes a reservation only for the exact live
 * child created by the original subagent manager under the captured parent.
 */
export class WorkflowChildTools extends Service {
  static inject = ['agents', 'tools']
  #grants = new Map()
  #structured = new WeakMap()

  constructor(ctx) {
    super(ctx, 'androidWorkflowChildTools')
    ctx.effect(() => () => { this.#grants.clear(); this.#structured = new WeakMap() })
  }

  reserve = async (parent, childId, signal) => {
    signal.throwIfAborted()
    if (this.#grants.has(childId)) throw new Error('Workflow child already has a tool reservation')
    const definitions = new Map()
    const policy = this.ctx.get('sandboxPolicy')
    let root
    for (const [name, owns] of REVIEWED) {
      const definition = this.ctx.tools.get(name, parent)
      const registration = this.ctx.tools.registrationIdentity(name, parent)
      if (!definition || !registration || !owns(definition, parent)) continue
      if (FILES.has(name)) {
        if (!policy || !this.ctx.get('workingDirectory')) continue
        if (root === undefined) root = realpathSync(await this.ctx.get('workingDirectory').ensure(parent, signal))
        if (WRITES.has(name) && !WRITABLE.has(policy.resolve({ session: parent.session }).mode)) continue
      }
      definitions.set(name, { definition, registration, owns })
    }
    signal.throwIfAborted()
    if (this.ctx.agents.get(parent.id) !== parent) throw new Error('Workflow parent has retired')
    if (this.#grants.has(childId)) throw new Error('Workflow child already has a tool reservation')
    const grant = { parent, childId, signal, definitions, root, child: undefined }
    this.#grants.set(childId, grant)
    return () => { if (this.#grants.get(childId) === grant) this.#grants.delete(childId) }
  }

  attach = (child, structured) => {
    const grant = this.#grants.get(child.id)
    if (structured) {
      // The original manager attaches this child-local result tool during
      // setup, before agent/created. Inherited names are masked by the preset.
      const definition = this.ctx.tools.get('structured_output', child)
      const registration = this.ctx.tools.registrationIdentity('structured_output', child)
      if (this.ctx.agents.get(child.id) !== child || !definition || !registration
        || this.#structured.has(child)) throw new Error(DENIED)
      this.#structured.set(child, { definition, registration, execute: definition.execute, grant })
      child.ctx.effect(() => () => this.#structured.delete(child))
    }
    // Reopening a persisted child is intentionally model-only: no live grant
    // can be reconstructed from its preset, Session log or public child ID.
    if (!grant) return
    if (grant.child || grant.signal.aborted || this.ctx.agents.get(child.id) !== child
      || this.ctx.agents.get(grant.parent.id) !== grant.parent
      || !this.ctx.agents.isOwnedBy(child.id, grant.parent)) throw new Error(DENIED)
    grant.child = child
    for (const [name, entry] of grant.definitions) {
      if (!this.#parentOwns(grant, name, entry)) throw new Error(DENIED)
      child.ctx.tools.register(entry.definition)
      entry.childRegistration = this.ctx.tools.registrationIdentity(name, child)
    }
    child.ctx.effect(() => () => {
      if (this.#grants.get(child.id) === grant) this.#grants.delete(child.id)
    })
  }

  #parentOwns(grant, name, entry) {
    return this.ctx.agents.get(grant.parent.id) === grant.parent
      && this.ctx.tools.get(name, grant.parent) === entry.definition
      && this.ctx.tools.registrationIdentity(name, grant.parent) === entry.registration
      && entry.owns(entry.definition, grant.parent)
  }

  structuredDenial = (exec) => {
    const child = exec.agent
    const result = child && this.#structured.get(child)
    if (!result || exec.signal.aborted || this.ctx.agents.get(child.id) !== child
      || this.ctx.tools.get(exec.name, child) !== result.definition
      || this.ctx.tools.registrationIdentity(exec.name, child) !== result.registration
      || result.definition.execute !== result.execute) return DENIED
    const grant = result.grant
    if (grant && (this.#grants.get(child.id) !== grant || grant.signal.aborted
      || this.ctx.agents.get(grant.parent.id) !== grant.parent)) return DENIED
    return undefined
  }

  denial = (exec) => {
    const child = exec.agent
    const grant = child && this.#grants.get(child.id)
    const entry = grant?.definitions.get(exec.name)
    if (!grant || grant.child !== child || grant.signal.aborted || exec.signal.aborted
      || this.ctx.agents.get(child.id) !== child || !this.ctx.agents.isOwnedBy(child.id, grant.parent)
      || !entry || !this.#parentOwns(grant, exec.name, entry)
      || this.ctx.tools.get(exec.name, child) !== entry.definition
      || this.ctx.tools.registrationIdentity(exec.name, child) !== entry.childRegistration
      || !entry.owns(entry.definition, child)) return DENIED
    if (exec.arguments?.sandbox_permissions !== undefined
      && exec.arguments.sandbox_permissions !== 'use_default') return DENIED
    if (!FILES.has(exec.name)) return undefined
    const policy = this.ctx.get('sandboxPolicy')
    const directory = this.ctx.get('workingDirectory')
    if (!policy || !directory || !grant.root) return DENIED
    const parentPolicy = policy.resolve({ session: grant.parent.session })
    const childPolicy = policy.resolve({ session: child.session })
    if (WRITES.has(exec.name) && (!WRITABLE.has(parentPolicy.mode) || !WRITABLE.has(childPolicy.mode))) return DENIED
    const childDirectory = directory.get(child.session)
    // A parent may cd outside its immutable permission root. Spawning there
    // must not turn the child's newly selected directory into a wider grant.
    if (WRITES.has(exec.name) && [parentPolicy, childPolicy].some(current => current.mode === 'workspace-write'
      && modelFileObservationDenial(current.workspaceRoot, childDirectory, exec.name, exec.arguments))) return DENIED
    // Both working directories stay inside the activation-pinned parent root;
    // danger-full-access cannot widen this delegated file boundary.
    if (modelFileObservationDenial(grant.root, directory.get(grant.parent.session), exec.name, exec.arguments)
      || modelFileObservationDenial(grant.root, childDirectory, exec.name, exec.arguments)) return DENIED
    return undefined
  }
}

/** Install restrictions on a shared child preset, then bind each live child. */
export function applyWorkflowChildTools(ctx, { structured = false } = {}) {
  const owner = ctx.get('androidWorkflowChildTools')
  if (!(owner instanceof WorkflowChildTools)) throw new Error('Workflow child tool owner is missing')
  ctx.tools.presentAs('native')
  ctx.tools.restrict({ allow: [] })
  ctx.on('agent/created', ({ agent }) => { owner.attach(agent, structured) })
  // Scope-local tools bypass visibility filters. The final guard still rejects
  // additions, replacement registrations, revoked parents and cancelled grants.
  ctx.tools.guard(exec => structured && exec.name === 'structured_output'
    ? owner.structuredDenial(exec) : owner.denial(exec))
}
