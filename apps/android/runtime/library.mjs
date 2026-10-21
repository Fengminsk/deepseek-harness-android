function failure(code, message, details) {
  return Object.assign(new Error(message), { code, ...(details === undefined ? {} : { details }) })
}

function badRequest(message) {
  return failure('gateway/bad-request', message)
}

function identity(value, label) {
  if (typeof value !== 'string' || !value.trim() || value.length > 512) {
    throw badRequest(`${label} must be a non-empty string of at most 512 characters`)
  }
  return value
}

function string(value, label) {
  if (typeof value !== 'string') throw badRequest(`${label} must be a string`)
  return value
}

function boolean(value, label) {
  if (typeof value !== 'boolean') throw badRequest(`${label} must be a boolean`)
  return value
}

/** App management carrier. The original registry and controllers own every write. */
export class AppLibrary {
  constructor(ctx, { invoke, follow, closeTimeoutMs = () => 5000 }) {
    this.ctx = ctx
    this.invoke = invoke
    this.follow = follow
    this.closeTimeoutMs = closeTimeoutMs
    this.reads = new Map()
    this.pending = new Set()
    this.closed = false
  }

  /** Android has an existing private workspace, not a system Documents resolver. */
  initialize() {
    return this.operation(async () => {
      const workspace = await this.ctx.workspaceRegistry.initializeDefault(async () => process.cwd())
      return { workspaceId: workspace?.id ?? null }
    })
  }

  checkOpen() {
    if (this.closed) throw failure('gateway/cancelled', 'Library service has closed')
  }

  async operation(run) {
    this.checkOpen()
    const done = Promise.withResolvers()
    this.pending.add(done.promise)
    try {
      return await run()
    } finally {
      this.pending.delete(done.promise)
      done.resolve()
    }
  }

  mutate(namespace, method, args) {
    // A completed preflight read must not dispatch a new write after close began.
    this.checkOpen()
    return this.invoke(namespace, method, args)
  }

  async read(operation) {
    this.checkOpen()
    const lifetime = new AbortController()
    const done = Promise.withResolvers()
    this.reads.set(lifetime, done.promise)
    try {
      return await operation(lifetime.signal)
    } finally {
      lifetime.abort()
      this.reads.delete(lifetime)
      done.resolve()
    }
  }

  async baseline(signal) {
    const iterable = await this.follow(signal)
    const iterator = iterable[Symbol.asyncIterator]()
    try {
      const first = await iterator.next()
      if (first.done || first.value?.type !== 'baseline') {
        throw new Error('Workspace follow did not provide an opening baseline')
      }
      return first.value.value
    } finally {
      await iterator.return?.()
    }
  }

  /** Two original read cuts; this is not an atomic cross-controller version. */
  catalog() {
    return this.read(async signal => {
      const [baseline, sessions] = await Promise.all([
        this.baseline(signal),
        this.invoke('session', 'list', { _request: {} }, signal),
      ])
      return {
        workspaces: baseline.items,
        sessions: sessions.items.filter(item => item.origin !== 'subagent'),
        archivedSessionIds: baseline.archivedSessionIds,
        pinnedSessionIds: baseline.pinnedSessionIds,
        defaultDirectory: process.cwd(),
        capabilities: { crossWorkspaceMove: false },
      }
    })
  }

  async sidebar() {
    const catalog = await this.catalog()
    const archived = new Set(catalog.archivedSessionIds)
    const pinOrder = new Map(catalog.pinnedSessionIds.map((id, index) => [id, index]))
    return catalog.sessions.filter(session => !archived.has(session.sessionId))
      .sort((left, right) => (pinOrder.get(left.sessionId) ?? Infinity) - (pinOrder.get(right.sessionId) ?? Infinity))
      .map(session => ({
        ...session,
        header: {
          id: session.sessionId,
          ...(session.cwd === undefined ? {} : { cwd: session.cwd }),
          ...(session.origin === undefined ? {} : { origin: session.origin }),
          ...(session.parentSessionId === undefined ? {} : { parentSessionId: session.parentSessionId }),
        },
        title: typeof session.projections?.values?.title === 'string' ? session.projections.values.title : null,
        pinned: pinOrder.has(session.sessionId),
        archived: false,
      }))
  }

  /** Reject child identities without resolving, resuming, or reading their log. */
  async ordinary(sessionId, { optional = false } = {}) {
    const listed = await this.read(signal => this.invoke('session', 'list', { _request: {} }, signal))
    const session = listed.items.find(item => item.sessionId === sessionId)
    if (!session) {
      if (optional) return
      throw failure('session/not-found', `session "${sessionId}" not found`, { sessionId })
    }
    const parent = session.parentSessionId === undefined ? undefined : this.ctx.agents?.get(session.parentSessionId)
    if (session.origin === 'subagent'
      || parent && this.ctx.agents.isOwnedBy(sessionId, parent)) {
      throw failure('session/agent-busy', `session "${sessionId}" is owned by subagent routing`,
        { reason: 'use subagent delivery for this child session' })
    }
  }

  /** Preserve original failure vocabulary, including partial creation receipts. */
  async call(method, params = {}) {
    try {
      this.checkOpen()
      if (!params || typeof params !== 'object' || Array.isArray(params)) throw badRequest('params must be an object')
      return await this.operation(() => this.dispatch(method, params))
    } catch (error) {
      return { _pocket_error: {
        code: typeof error?.code === 'string' ? error.code : 'gateway/internal',
        message: String(error?.message ?? error),
        ...(error?.details === undefined ? {} : { details: error.details }),
      } }
    }
  }

  async dispatch(method, params) {
    switch (method) {
      case 'catalog': return this.catalog()
      case 'directoryList': return this.read(signal => this.invoke('directoryPicker', 'list', {
        path: params.path === undefined ? process.cwd() : string(params.path, 'path'),
      }, signal))
      case 'directoryCreate': return {
        path: await this.mutate('directoryPicker', 'createDirectory', {
          path: string(params.path, 'path'), name: string(params.name, 'name'),
        }),
      }
      case 'workspaceCreate': return this.mutate('workspace', 'create', { request: { path: string(params.path, 'path') } })
      case 'workspaceRename': return this.mutate('workspace', 'rename', { request: {
        workspaceId: identity(params.workspaceId, 'workspaceId'), title: string(params.title, 'title'),
      } })
      case 'workspaceReorder': return this.mutate('workspace', 'insertBefore', { request: {
        workspaceId: identity(params.workspaceId, 'workspaceId'),
        ...(params.beforeWorkspaceId === undefined ? {} : { beforeWorkspaceId: identity(params.beforeWorkspaceId, 'beforeWorkspaceId') }),
      } })
      case 'sessionCreate': {
        const workspaceId = identity(params.workspaceId, 'workspaceId')
        const sessionId = params.sessionId === undefined ? undefined : identity(params.sessionId, 'sessionId')
        const agentPreset = params.agentPreset === undefined ? undefined : string(params.agentPreset, 'agentPreset')
        if (agentPreset !== undefined && !agentPreset.trim()) throw badRequest('agentPreset must not be empty')
        if (sessionId !== undefined) await this.ordinary(sessionId, { optional: true })
        // The original may reuse a blank session or return a different new id.
        return this.mutate('session', 'create', { request: {
          workspaceId, ...(sessionId === undefined ? {} : { sessionId }),
          ...(agentPreset === undefined ? {} : { agentPreset }),
        } })
      }
      case 'sessionRename':
      case 'sessionPin':
      case 'sessionArchive':
      case 'sessionReorder':
      case 'sessionFork': return this.sessionOperation(method, params)
      default: throw badRequest('Unknown library operation')
    }
  }

  async sessionOperation(method, params) {
    const sessionId = identity(params.sessionId, 'sessionId')
    await this.ordinary(sessionId)
    switch (method) {
      case 'sessionRename': return this.mutate('session', 'rename', { request: {
        sessionId, title: string(params.title, 'title'),
      } })
      case 'sessionPin': return this.mutate('workspace', boolean(params.pinned, 'pinned') ? 'pinSession' : 'unpinSession',
        { request: { sessionId } })
      case 'sessionArchive': {
        const archived = boolean(params.archived, 'archived')
        if (params.stopActivity !== undefined) boolean(params.stopActivity, 'stopActivity')
        if (!archived && params.stopActivity === true) throw badRequest('Unarchiving cannot stop activity')
        return this.mutate('workspace', archived ? 'archiveSession' : 'unarchiveSession', { request: {
          sessionId, ...(archived && params.stopActivity === true ? { stopActivity: true } : {}),
        } })
      }
      case 'sessionReorder': {
        const workspaceId = identity(params.workspaceId, 'workspaceId')
        const beforeSessionId = params.beforeSessionId === undefined ? undefined : identity(params.beforeSessionId, 'beforeSessionId')
        if (beforeSessionId !== undefined) await this.ordinary(beforeSessionId)
        return this.mutate('workspace', 'insertSessionBefore', { request: {
          workspaceId, sessionId, ...(beforeSessionId === undefined ? {} : { beforeSessionId }),
        } })
      }
      case 'sessionFork':
        if (params.atSeq !== undefined && (!Number.isSafeInteger(params.atSeq) || params.atSeq < 0)) {
          throw badRequest('atSeq must be a non-negative safe integer')
        }
        if (params.allowMigration !== undefined) boolean(params.allowMigration, 'allowMigration')
        // No inferred cursor, generated request id, or automatic retry: fork is not idempotent.
        return this.mutate('session', 'fork', { request: {
          sessionId, ...(params.atSeq === undefined ? {} : { atSeq: params.atSeq }),
          ...(params.allowMigration === undefined ? {} : { allowMigration: params.allowMigration }),
        } })
    }
  }

  async close() {
    this.closed = true
    const reads = [...this.reads.entries()]
    for (const [lifetime] of reads) lifetime.abort()
    const timeout = this.closeTimeoutMs()
    if (!Number.isSafeInteger(timeout) || timeout < 1) throw new TypeError('Invalid library close timeout')
    let timer
    try {
      // Original unary writes do not end with peer disposal. Never cancel them
      // or manufacture failure; retain their receipt and drain before the peer.
      await Promise.race([
        Promise.all([...this.pending, ...reads.map(([, done]) => done)]),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(failure('library/close-timeout',
            'Library operations are still settling; shutdown is not confirmed complete.')), timeout)
        }),
      ])
    } finally { clearTimeout(timer) }
  }
}
