import { lstatSync, realpathSync, statSync } from 'node:fs'
import { isAbsolute, relative, resolve, sep, dirname, basename } from 'node:path'
import { AsyncLocalStorage } from 'node:async_hooks'

// These are the original model tools which can reveal host file content or names.
// App RPCs for SAF grants are deliberately separate and never turn a content URI
// into a path accepted here.
const FILE_TOOLS = new Set(['read', 'read_image', 'glob', 'grep', 'write', 'edit', 'str_replace_editor', 'present'])
const DENIAL = 'Android file tools require a path inside the App workspace. Use android_files for user-authorized documents.'
export const modelFileExecutionScope = new AsyncLocalStorage()

export function insideModelWorkspace(root, target) {
  const rel = relative(root, target)
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
}

export function canonicalModelTarget(path) {
  // Existing files (including symlink leaves) must resolve to their actual
  // target. For a create/missing search root, resolve the nearest existing
  // ancestor, without lexical parent traversal changing symlink semantics.
  let cursor = path
  const missing = []
  while (true) {
    try { return resolve(realpathSync(cursor), ...missing.reverse()) }
    catch (error) {
      if (error?.code !== 'ENOENT') throw error
      // A dangling symlink has no realpath but must never be treated as a
      // missing ordinary file under its lexical parent.
      try { if (lstatSync(cursor).isSymbolicLink()) throw new Error('dangling symlink') }
      catch (entryError) { if (entryError?.code !== 'ENOENT') throw entryError }
      const parent = dirname(cursor)
      if (parent === cursor) throw error
      missing.push(basename(cursor))
      cursor = parent
    }
  }
}

function pathArgument(name, args) {
  if (args === null || typeof args !== 'object' || Array.isArray(args)) return undefined
  if (name === 'glob' || name === 'grep') {
    if (typeof args.pattern !== 'string' || args.pattern.length === 0) return undefined
    // rg globs are filters under a search root, never alternative roots. Deny
    // absolute/parent-looking glob forms instead of relying on that detail.
    const filter = name === 'glob' ? args.pattern : args.include
    if (filter !== undefined && (typeof filter !== 'string' || filter.startsWith('/')
      || filter.startsWith('\\') || filter.includes('..'))) return undefined
    return args.path === undefined ? '.' : typeof args.path === 'string' ? args.path : undefined
  }
  if (name === 'str_replace_editor') {
    if (!['view', 'create', 'str_replace', 'insert'].includes(args.command)) return undefined
    return typeof args.path === 'string' && isAbsolute(args.path) ? args.path : undefined
  }
  return typeof args.file_path === 'string' ? args.file_path : undefined
}

/** Synchronous, monotonic check used immediately before the model tool body. */
export function modelFileObservationDenial(workspaceRoot, cwd, name, args) {
  if (!FILE_TOOLS.has(name)) return undefined
  const requestedPaths = name === 'present'
    ? (Array.isArray(args?.files) && args.files.length > 0
      ? args.files.map(file => file?.path) : [])
    : [pathArgument(name, args)]
  if (requestedPaths.length === 0 || requestedPaths.some(path => typeof path !== 'string' || path.length === 0)
    || typeof cwd !== 'string' || !isAbsolute(cwd)) return DENIAL
  try {
    // Registration passes the boot-pinned canonical root. Never recanonicalize
    // it here: replacing the directory with a symlink must not broaden access.
    const root = resolve(workspaceRoot)
    const actualCwd = realpathSync(cwd)
    if (!insideModelWorkspace(root, actualCwd)) return DENIAL
    for (const requested of requestedPaths) {
      if (!isAbsolute(requested) && /^[a-z][a-z0-9+.-]*:/i.test(requested)) return DENIAL
      // Missing paths containing '..' are ambiguous around symlinks. Existing
      // paths are resolved physically below; reject parent traversal uniformly.
      if (requested.split(/[\\/]/u).includes('..')) return DENIAL
      const absolute = resolve(actualCwd, requested)
      if (!insideModelWorkspace(root, canonicalModelTarget(absolute))) return DENIAL
      // The original str_replace_editor recursively lists a viewed directory
      // and follows its child symlinks through ctx.fs.listDir(). Checking only
      // the selected root cannot confine those later, model-visible names.
      // Until the provider can anchor every recursive read, allow file view only.
      // AndroidFileSystem.listDir repeats this refusal at the actual operation
      // if a checked file becomes a directory before the tool body runs.
      if (name === 'str_replace_editor' && args.command === 'view'
        && statSync(absolute).isDirectory()) return DENIAL
    }
    return undefined
  } catch { return DENIAL }
}

function validateSearchSpawn(root, scope, spec) {
  if (!spec || !Array.isArray(spec.argv) || spec.argv.length < 3
    || spec.argv[1] !== '--no-config' || typeof spec.cwd !== 'string') throw new Error(DENIAL)
  if (realpathSync(spec.cwd) !== scope.cwd) throw new Error(DENIAL)
  const separator = spec.argv.lastIndexOf('--')
  if (separator >= 0 && separator !== spec.argv.length - 2) throw new Error(DENIAL)
  const searchPath = separator >= 0 ? spec.argv[separator + 1] : '.'
  if (typeof searchPath !== 'string' || !insideModelWorkspace(root,
    canonicalModelTarget(resolve(scope.cwd, searchPath)))) throw new Error(DENIAL)
  // The original search tools do not follow directory links. Reject an
  // unexpected command change before it reaches the shared subprocess seam.
  if (spec.argv.some(argument => argument === '--follow' || argument === '-L'
    || argument === '--search-zip' || argument.startsWith('--pre='))) throw new Error(DENIAL)
}

/** Guard only model tool dispatch. Internal App services still use ctx.fs. */
export function registerModelFileReadGuard(ctx, workspaceRoot = process.cwd()) {
  // Fail boot if the protected root itself is not a real App-owned directory.
  const root = realpathSync(workspaceRoot)
  const prepared = new Map()
  const directory = ctx.workingDirectory
  const originalEnsure = directory.ensure
  const scopedEnsure = function (agent, signal) {
    const scope = modelFileExecutionScope.getStore()
    if (scope && scope.agent === agent) {
      signal?.throwIfAborted()
      return Promise.resolve(scope.cwd)
    }
    return originalEnsure.call(this, agent, signal)
  }
  directory.ensure = scopedEnsure
  let guardedSubprocess, originalSpawn, scopedSpawn
  function ensureSearchBoundary() {
    const service = ctx.get?.('subprocess') ?? ctx.subprocess
    if (!service || typeof service.spawn !== 'function') return false
    if (service === guardedSubprocess && service.spawn === scopedSpawn) return true
    if (guardedSubprocess) return false
    originalSpawn = service.spawn
    scopedSpawn = function (spec) {
      const scope = modelFileExecutionScope.getStore()
      if (scope && (scope.name === 'glob' || scope.name === 'grep')) {
        validateSearchSpawn(root, scope, spec)
      }
      return originalSpawn.call(this, spec)
    }
    service.spawn = scopedSpawn
    guardedSubprocess = service
    return service.spawn === scopedSpawn
  }
  ctx.on('tools/pre-execute', async (execution, next) => {
    const decision = await next()
    if (!FILE_TOOLS.has(execution.name) || !['allow', 'ask'].includes(decision.kind)) return decision
    try {
      if (!execution.agent) return { kind: 'deny', reason: DENIAL }
      const cwd = await ctx.workingDirectory.ensure(execution.agent, execution.signal)
      execution.signal.throwIfAborted()
      const reason = modelFileObservationDenial(root, cwd, execution.name, execution.arguments)
      if (reason !== undefined) return { kind: 'deny', reason }
      if ((execution.name === 'glob' || execution.name === 'grep') && !ensureSearchBoundary()) {
        return { kind: 'deny', reason: DENIAL }
      }
      prepared.set(execution.token, { cwd: realpathSync(cwd), agent: execution.agent })
    } catch { return { kind: 'deny', reason: DENIAL } }
    return decision
  })
  ctx.on('tools/execute', (execution, next) => {
    if (!FILE_TOOLS.has(execution.name)) return next()
    const scope = prepared.get(execution.token)
    if (!scope) throw new Error(DENIAL)
    return modelFileExecutionScope.run({ ...scope, name: execution.name, root }, () => next())
  })
  ctx.on('tools/result', execution => { prepared.delete(execution.token) })
  ctx.effect(() => () => {
    prepared.clear()
    if (directory.ensure === scopedEnsure) directory.ensure = originalEnsure
    if (guardedSubprocess?.spawn === scopedSpawn) guardedSubprocess.spawn = originalSpawn
  })
  ctx.effect(() => ctx.tools.guard(execution => {
    if (!FILE_TOOLS.has(execution.name)) return undefined
    return modelFileObservationDenial(root, prepared.get(execution.token)?.cwd, execution.name, execution.arguments)
  }))
}
