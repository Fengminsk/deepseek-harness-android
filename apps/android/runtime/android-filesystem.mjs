import { SandboxedFileSystem } from '@deepseek-ai/dsh-fs-sandbox'
import { FsError } from '@deepseek-ai/dsh-fs'
import { AsyncLocalStorage } from 'node:async_hooks'
import { open, lstat, realpath } from 'node:fs/promises'
import { isAbsolute, relative, resolve, sep } from 'node:path'
import { publishImmutableFile } from './immutable-file-publisher.mjs'
import { canonicalModelTarget, insideModelWorkspace, modelFileExecutionScope } from './model-file-read-guard.mjs'

const protectedNames = new Set(['.git', '.agents', '.codex', '.aws'])
const mutationPolicy = new AsyncLocalStorage()

function containedRelative(root, candidate) {
  const path = relative(root, candidate)
  return path === '' || (path !== '..' && !path.startsWith(`..${sep}`) && !isAbsolute(path)) ? path : null
}

function protectedEntry(root, candidate) {
  const path = containedRelative(root, candidate)
  if (path === null || path === '') return false
  const first = path.split(sep)[0]
  return protectedNames.has(process.platform === 'win32' ? first.toLowerCase() : first)
}

function denyProtected(path) {
  throw new FsError(`cannot write "${path}": protected workspace metadata under workspace-write mode`, 'FS_SANDBOX_DENIED')
}

// A linked worktree stores only a gitdir pointer at <workspace>/.git. Protect
// its resolved target too, including when it falls under another writable root.
async function gitDirectory(root, displayPath) {
  const dotGit = resolve(root, '.git')
  let info
  try { info = await lstat(dotGit) } catch (error) {
    if (error?.code === 'ENOENT') return null
    denyProtected(displayPath)
  }
  if (info.isDirectory() || info.isSymbolicLink()) {
    try {
      const actual = await realpath(dotGit)
      if ((await lstat(actual)).isDirectory()) return actual
    } catch { denyProtected(displayPath) }
  }
  if (!info.isFile() && !info.isSymbolicLink()) return null
  if (info.size > 4096) return null
  let handle
  try {
    handle = await open(dotGit, 'r')
    const buffer = Buffer.alloc(4097)
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0)
    if (bytesRead > 4096) return null
    const match = /^gitdir: ([^\r\n]+)\r?\n?$/i.exec(buffer.toString('utf8', 0, bytesRead))
    if (!match) return null
    const pointer = resolve(root, match[1])
    try { return await realpath(pointer) } catch (error) {
      if (error?.code !== 'ENOENT') denyProtected(displayPath)
      // A missing gitdir is still a protected name if it is created later.
      return pointer
    }
  } catch (error) {
    if (error?.code === 'FS_SANDBOX_DENIED') throw error
    denyProtected(displayPath)
  } finally {
    await handle?.close()
  }
}

/** Keep the original policy, observation, lock and atomic-write owner intact. */
export default class AndroidFileSystem extends SandboxedFileSystem {
  constructor(ctx, config) {
    super(ctx, config)
    // App storage may reject hard links. The original publication boundary
    // expects an exclusive complete target and a retained source; our existing
    // Android publisher supplies both with copy + renameat2(RENAME_NOREPLACE).
    // fs-local still owns cancellation before publication and temp-dir cleanup.
    this.internals.linkFile = publishImmutableFile
  }

  // The parent sandbox calls this.resolve() immediately before delegating the
  // exact returned target to its atomic writer. Enforce here so aliases are
  // checked after canonicalization, rather than inspecting an earlier string.
  async resolve(path, opts) {
    const modelScope = modelFileExecutionScope.getStore()
    const target = await super.resolve(path, modelScope ? { ...opts, cwd: modelScope.cwd } : opts)
    if (modelScope && (!insideModelWorkspace(modelScope.root, canonicalModelTarget(target.displayPath))
      || !insideModelWorkspace(modelScope.root, canonicalModelTarget(String(target.targetKey))))) {
      throw new FsError(`cannot access "${target.displayPath}": outside the App workspace`, 'FS_SANDBOX_DENIED')
    }
    const policy = mutationPolicy.getStore()
    if (policy?.mode !== 'workspace-write') return target
    const root = resolve(policy.workspaceRoot)
    let canonicalRoot
    try { canonicalRoot = await realpath(root) } catch { denyProtected(target.displayPath) }
    if (protectedEntry(root, target.displayPath) || protectedEntry(canonicalRoot, String(target.targetKey))) {
      denyProtected(target.displayPath)
    }
    const gitdir = await gitDirectory(canonicalRoot, target.displayPath)
    if (gitdir && (containedRelative(gitdir, target.displayPath) !== null
      || containedRelative(gitdir, String(target.targetKey)) !== null)) denyProtected(target.displayPath)
    return target
  }

  // An original tool can retain a resolved FsTarget across awaits. Re-resolve
  // its display path at the observation call to reject a parent symlink that
  // was already replaced. This narrows
  // the race; only descriptor-relative kernel operations could close the
  // remaining interval between this check and the filesystem syscall.
  async modelObservationTarget(target) {
    const scope = modelFileExecutionScope.getStore()
    return scope ? this.resolve(target.displayPath, { cwd: scope.cwd }) : target
  }

  async stat(target, signal) {
    return super.stat(await this.modelObservationTarget(target), signal)
  }

  async readText(target, signal) {
    return super.readText(await this.modelObservationTarget(target), signal)
  }

  async streamText(target, signal) {
    const scope = modelFileExecutionScope.getStore()
    if (!scope) return super.streamText(target, signal)
    // fs-local opens its stream on iteration. Check at that point rather than
    // when the async iterable is requested, which may precede an await.
    const source = async fresh => super.streamText(fresh, signal)
    const filesystem = this
    return (async function* () {
      const fresh = await modelFileExecutionScope.run(scope,
        () => filesystem.modelObservationTarget(target))
      yield* await source(fresh)
    })()
  }

  async readBytes(target, signal, maxBytes) {
    return super.readBytes(await this.modelObservationTarget(target), signal, maxBytes)
  }

  async readByteRange(target, range, signal) {
    return super.readByteRange(await this.modelObservationTarget(target), range, signal)
  }

  async listDir(target, signal) {
    // str_replace_editor can change a checked file into a directory between
    // model pre-execute and its body. Deny at the provider operation too: its
    // original two-level walk follows child links after the initial check.
    if (modelFileExecutionScope.getStore()) {
      throw new FsError(`cannot list "${target.displayPath}": model directory view is unavailable`, 'FS_SANDBOX_DENIED')
    }
    return super.listDir(target, signal)
  }

  async writeText(target, content, expected, signal, sandboxPolicy) {
    const policy = sandboxPolicy ?? this.ctx.sandboxPolicy.resolve()
    return mutationPolicy.run(policy, () => super.writeText(target, content, expected, signal, policy))
  }

  async editText(target, edit, expected, signal, sandboxPolicy) {
    const policy = sandboxPolicy ?? this.ctx.sandboxPolicy.resolve()
    return mutationPolicy.run(policy, () => super.editText(target, edit, expected, signal, policy))
  }
}
