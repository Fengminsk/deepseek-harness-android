import Schema from '@deepseek-ai/schemastery'
import { randomUUID } from 'node:crypto'
import { createRequire } from 'node:module'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { establishAttachmentHome } from '@deepseek-ai/dsh-attachment-local'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { AndroidCredentials } from './credentials.mjs'
import { registerAndroidShell } from './tool-android-shell.mjs'
import AndroidShell from './android-shell.mjs'
import { WebAccess } from './web-access.mjs'
import { AppSessions } from './sessions.mjs'
import { AppSessionHistory } from './session-history.mjs'
import { AppLiveState, presentSessionEvent } from './live-state.mjs'
import { AppInteractions } from './interactions.mjs'
import { InteractionReceipts } from './interaction-receipts.mjs'
import { AppStreams } from './streams.mjs'
import { AppExports } from './exports.mjs'
import { AppAttachmentFiles } from './attachment-files.mjs'
import AndroidAccountCallback from './account-callback.mjs'
import { AppAttachments } from './attachments.mjs'
import { createRuntimeTransport } from './transport.mjs'
import { AppDocumentSearch } from './document-search.mjs'
import { AppDocumentPreview, PRIVATE_WORKSPACE_SCOPE } from './document-preview.mjs'
import { AppReferenceDiscovery } from './reference-discovery.mjs'
import { AppWorkspaceChanges } from './workspace-changes.mjs'
import { maskUserText } from './user-text-mask.mjs'
import { AppTasks } from './tasks.mjs'
import { AppTaskCompletion } from './task-completion.mjs'
import { AppPackageOperations } from './package-operations.mjs'
import { AppConfigurationTransfers } from './configuration-transfer.mjs'
import { AppSubagents } from './subagents.mjs'
import { AppLibrary } from './library.mjs'
import { AppWorkspaceFiles } from './workspace-files.mjs'
import { AppTerminals } from './terminals.mjs'
import { describeAndroidSettings } from './settings-presentation.mjs'

export const name = 'android-runtime'
export const inject = ['agents', 'sessions', 'workingDirectory', 'settings', 'tools', 'appReady', 'sessionPersistence']
export const Config = Schema.object({
  shellTimeoutMs: Schema.natural().min(1).max(3600000).default(60000).volatile(),
  shellOutputLimit: Schema.natural().min(1024).max(1048576).default(65536).volatile(),
  appStreamMaxSubscriptions: Schema.natural().min(1).max(128).default(32).volatile(),
  appStreamMaxFrameBytes: Schema.natural().min(4096).max(16777216).default(16777216).volatile(),
  streamPublishMs: Schema.natural().min(16).max(250).default(50).volatile(),
  documentSearchFileBytes: Schema.natural().min(1024).max(67108864).default(8388608).volatile(),
  documentSearchTotalBytes: Schema.natural().min(1024).max(268435456).default(67108864).volatile(),
  documentSearchMaxEntries: Schema.natural().min(1).max(10000).default(2000).volatile(),
  documentSearchMaxFiles: Schema.natural().min(1).max(10000).default(1000).volatile(),
  documentSearchMaxDepth: Schema.natural().min(1).max(64).default(32).volatile(),
  documentSearchMaxMatches: Schema.natural().min(1).max(1000).default(200).volatile(),
  documentSearchPreviewChars: Schema.natural().min(512).max(2000).default(600).volatile(),
  documentSearchMaxDurationMs: Schema.natural().min(100).max(300000).default(30000).volatile(),
  documentSearchMaxRequests: Schema.natural().min(1).max(4).default(4).volatile(),
  documentPreviewMaxRequests: Schema.natural().min(1).max(32).default(8).volatile(),
  documentPreviewMaxOwnerRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  documentPreviewMaxLeaseBytes: Schema.natural().min(1024).max(268435456).default(67108864).volatile(),
  documentPreviewMaxLeases: Schema.natural().min(1).max(128).default(32).volatile(),
  documentPreviewLeaseTimeoutMs: Schema.natural().min(1000).max(600000).default(120000).volatile(),
  documentPreviewRequestTimeoutMs: Schema.natural().min(100).max(300000).default(90000).volatile(),
  documentPreviewCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  referenceMaxRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  referenceRequestTimeoutMs: Schema.natural().min(100).max(300000).default(15000).volatile(),
  referenceCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  workspaceChangesMaxRequests: Schema.natural().min(1).max(32).default(8).volatile(),
  workspaceChangesMaxOwnerRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  workspaceChangesRequestTimeoutMs: Schema.natural().min(100).max(300000).default(90000).volatile(),
  workspaceChangesCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  workspaceReadPageBytes: Schema.natural().min(1024).max(1048576).default(65536).volatile(),
  workspacePreviewMaxFileBytes: Schema.natural().min(1024).max(104857600).default(33554432).volatile(),
  workspacePreviewWindowBytes: Schema.natural().min(1024).max(2097152).default(2097152).volatile(),
  workspacePreviewOfficeInputBytes: Schema.natural().min(1024).max(104857600).default(52428800).volatile(),
  workspaceDirectoryMaxEntries: Schema.natural().min(1).max(10000).default(5000).volatile(),
  workspaceDirectoryPageSize: Schema.natural().min(1).max(500).default(100).volatile(),
  attachmentFileMaxBytes: Schema.natural().min(1024).max(2147483648).default(268435456).volatile(),
  attachmentFileReadPageBytes: Schema.natural().min(1024).max(1048576).default(65536).volatile(),
  attachmentFileMaxRequests: Schema.natural().min(1).max(16).default(4).volatile(),
  workspaceFilesCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
  libraryCloseTimeoutMs: Schema.natural().min(100).max(30000).default(5000).volatile(),
})

function requiredString(value, label) {
  if (typeof value !== 'string' || value.length === 0) throw new TypeError(`${label} must be a non-empty string`)
  return value
}

// JSON-RPC line transport otherwise collapses thrown domain errors into -32603.
// Preserve the original Gateway result vocabulary for native conflict handling.
function remoteFailure(error) {
  return { _pocket_error: {
    code: typeof error?.code === 'string' ? error.code : error instanceof TypeError ? 'gateway/bad-request' : 'gateway/internal',
    message: String(error?.message ?? error),
    ...(error?.details === undefined ? {} : { details: error.details }),
  } }
}

/** Android is an additional carrier over the same DSH services and session log. */
export function apply(ctx, config) {
  const ipc = createRuntimeTransport()
  const { transport } = ipc
  const credentials = new AndroidCredentials(ctx, transport)
  ctx.plugin(AndroidShell)
  ctx.plugin(AndroidAccountCallback)
  ctx.effect(() => {
    transport.start()
    return () => ipc.close()
  })
  // Connection needs the Keystore provider before the shared Session controller can activate.
  ctx.inject(['sessionController', 'typertGateway', 'connection', 'accountCallback', 'fileUploads',
    'pluginManager', 'jobs', 'sessionProjections', 'subagents', 'workspaceRegistry'], ctx => {
  // These Loader entries define the native carrier and App-controlled HTTP boundary.
  // The manager applies the same protection to App, Web, tools, and bundle overlays.
  const requiredEntries = new Set(['android-runtime', 'credentials', 'authorization', 'deepseek-account',
    'web-startup', 'webserver', 'web-runtime', 'connection', 'session-controller',
    'session-persistence-jsonl', 'android-session-persistence', 'settings', 'file-upload',
    'attachment-local', 'android-attachment-store', 'working-directory', 'agent-loop',
    'workspace', 'workspace-controller', 'android-directory-picker', 'android-filesystem',
    // Disabled model-authored programs must remain disabled after boot too.
    // Android lacks the original per-run OS confinement for these modules.
    'ptc-runtime', 'workflow-ptc', 'tool-workflow'])
  const loaderEntries = [...ctx.get('loader').entries()]
  ctx.pluginManager.protectModules(loaderEntries.filter(entry => requiredEntries.has(entry.options.id))
    .map(entry => entry.options.name))
  const web = new WebAccess(ctx, transport)
  let appPeer
  const peer = () => appPeer ??= ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'none' })
  const invoke = (namespace, method, args, signal) => {
    return ctx.typertGateway.invoke({ namespace, method, args, peer: peer(), signal })
  }
  const references = new AppReferenceDiscovery({ invoke, limits: () => ({
    maxRequests: config.referenceMaxRequests.get(), requestTimeoutMs: config.referenceRequestTimeoutMs.get(),
    closeTimeoutMs: config.referenceCloseTimeoutMs.get(),
  }) })
  const changesHandler = ctx.connection.createSharedFetchHandler('/api')
  const workspaceChanges = new AppWorkspaceChanges({
    fetch: request => changesHandler.fetch(request, peer()),
    available: () => !!ctx.get('workspaceChanges'),
    limits: () => ({ maxRequests: config.workspaceChangesMaxRequests.get(),
      maxOwnerRequests: config.workspaceChangesMaxOwnerRequests.get(),
      requestTimeoutMs: config.workspaceChangesRequestTimeoutMs.get(),
      closeTimeoutMs: config.workspaceChangesCloseTimeoutMs.get() }),
  })
  const library = new AppLibrary(ctx, {
    invoke,
    closeTimeoutMs: () => config.libraryCloseTimeoutMs.get(),
    follow: signal => ctx.typertGateway.stream({
      namespace: 'workspace', method: 'follow', args: {}, peer: peer(), signal,
    }),
  })
  let attachments
  const sessions = new AppSessions(ctx, (method, request) => invoke('session', method, { request }),
    (sessionId, ids) => attachments.content(sessionId, ids), {
      content: (sessionId, ids) => attachments.commandContent(sessionId, ids),
      execute: args => invoke('commands', 'execute', args),
    }, (agentId, agentPreset) => invoke('agentPresets', 'select', { agentId, agentPreset }))
  attachments = new AppAttachments(ctx, {
    directory: () => transport.request('native.attachments.directory', {}),
    ensureSession: sessionId => sessions.ensure(sessionId),
  })
  const live = new AppLiveState(ctx, transport, { streamPublishMs: () => config.streamPublishMs.get() })
  const history = new AppSessionHistory(ctx.sessionController)
  const shell = registerAndroidShell(ctx, config)
  const interactionReceipts = new InteractionReceipts()
  let tasks
  const interactions = new AppInteractions(ctx, {
    notify(method, params) {
      transport.notify(method, params)
      if (method === 'interactions.changed') tasks?.interactionsChanged()
    },
  }, { shellContext: (sessionId, callId) => shell.context(sessionId, callId), receipts: interactionReceipts })
  tasks = new AppTasks(ctx, transport, { interactions: () => interactions.snapshot() })
  const taskCompletion = new AppTaskCompletion(ctx, transport)
  const packageOperations = new AppPackageOperations(ctx)
  const subagents = new AppSubagents(ctx, {
    invoke,
    follow: (request, signal) => ctx.typertGateway.stream({
      namespace: 'session', method: 'follow', args: { request }, peer: peer(), signal,
    }),
    taskSession: params => tasks.session(params),
    presentEvent: presentSessionEvent,
  })
  const configurationTransfers = new AppConfigurationTransfers(ctx, { protectedNamespaces: requiredEntries })
  const exports = new AppExports(ctx, { directory: () => transport.request('native.exports.directory', {}) })
  const attachmentFiles = new AppAttachmentFiles(ctx, {
    directory: () => transport.request('native.attachmentFiles.directory', {}),
    limits: () => ({ maxBytes: config.attachmentFileMaxBytes.get(),
      readPageBytes: config.attachmentFileReadPageBytes.get(), maxRequests: config.attachmentFileMaxRequests.get() }),
  })
  const searchLimits = () => ({
      fileBytes: config.documentSearchFileBytes.get(), totalBytes: config.documentSearchTotalBytes.get(),
      maxEntries: config.documentSearchMaxEntries.get(), maxFiles: config.documentSearchMaxFiles.get(),
      maxDepth: config.documentSearchMaxDepth.get(), maxMatches: config.documentSearchMaxMatches.get(),
      previewChars: config.documentSearchPreviewChars.get(), maxDurationMs: config.documentSearchMaxDurationMs.get(),
  })
  const documentSearch = new AppDocumentSearch(transport, {
    maxRequests: () => config.documentSearchMaxRequests.get(), limits: searchLimits,
  })
  // Resolve the original media route's MIME dependency from its owning package.
  const mediaMime = createRequire(import.meta.resolve('@deepseek-ai/dsh-api-session-controller/package.json'))('mime-types')
  const workspaceFiles = new AppWorkspaceFiles({
    root: process.cwd(),
    limits: () => ({
      readPageBytes: config.workspaceReadPageBytes.get(),
      maxDirectoryEntries: config.workspaceDirectoryMaxEntries.get(),
      listPageSize: config.workspaceDirectoryPageSize.get(),
      closeTimeoutMs: config.workspaceFilesCloseTimeoutMs.get(),
      maxSearches: config.documentSearchMaxRequests.get(), search: searchLimits(),
    }),
  })
  const privateDocument = async (namespace, method, args, signal) => {
    signal.throwIfAborted()
    if (namespace === 'workspaceFiles') {
      return workspaceFiles.document(method, args, signal, {
        maxFileBytes: config.workspacePreviewMaxFileBytes.get(),
        maxWindowBytes: config.workspacePreviewWindowBytes.get(),
      })
    }
    if (namespace === 'officeToPdf' && method === 'generation') {
      const service = ctx.get('officeToPdf')
      if (!service) throw new Error('Office renderer is unavailable')
      return service.getGeneration(signal)
    }
    if (namespace === 'officeToPdf' && method === 'render') {
      const source = await workspaceFiles.document('stat', { path: args.path }, signal, {
        maxFileBytes: config.workspacePreviewMaxFileBytes.get(), maxWindowBytes: config.workspacePreviewWindowBytes.get(),
      })
      const service = ctx.get('officeToPdf')
      if (!service) throw new Error('Office renderer is unavailable')
      const extension = args.path.split('.').at(-1)?.toLowerCase()
      if (!['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'].includes(extension)) {
        throw new TypeError('Unsupported Office document format')
      }
      const rendered = await service.convert({ extension, priority: args.priority,
        source: { key: JSON.stringify([PRIVATE_WORKSPACE_SCOPE, source.absolutePath]),
          version: source.version, bytes: source.bytes,
          read: async (readSignal, maxBytes) => {
            const current = await workspaceFiles.document('readBytes', { path: args.path }, readSignal, {
              maxFileBytes: Math.min(maxBytes, config.workspacePreviewOfficeInputBytes.get()),
              maxWindowBytes: config.workspacePreviewWindowBytes.get(),
            })
            if (current.version !== source.version || current.absolutePath !== source.absolutePath) {
              throw new Error('Office document changed during conversion')
            }
            return { bytes: current.data, version: current.version }
          } },
      }, signal)
      signal.throwIfAborted()
      const current = await workspaceFiles.document('stat', { path: args.path }, signal, {
        maxFileBytes: config.workspacePreviewMaxFileBytes.get(), maxWindowBytes: config.workspacePreviewWindowBytes.get(),
      })
      if (current.version !== source.version || current.absolutePath !== source.absolutePath) {
        throw new Error('Office document changed during conversion')
      }
      return { absolutePath: source.absolutePath, version: source.version,
        offset: 0, eof: true, bytes: rendered.pdf.byteLength, data: rendered.pdf,
        missingFonts: rendered.missingFonts, generation: rendered.generation }
    }
    throw new TypeError('Unsupported private document method')
  }
  const documentPreview = new AppDocumentPreview({ invoke, privateWorkspace: privateDocument,
    mediaPolicy: path => ({ maxBytes: ctx.get('attachments')?.imageLimits?.maxImageBytes,
      mimeType: mediaMime.lookup(path) || 'application/octet-stream' }), limits: () => ({
    maxRequests: config.documentPreviewMaxRequests.get(), maxOwnerRequests: config.documentPreviewMaxOwnerRequests.get(),
    maxLeaseBytes: config.documentPreviewMaxLeaseBytes.get(), maxLeases: config.documentPreviewMaxLeases.get(),
    leaseTimeoutMs: config.documentPreviewLeaseTimeoutMs.get(), requestTimeoutMs: config.documentPreviewRequestTimeoutMs.get(),
    closeTimeoutMs: config.documentPreviewCloseTimeoutMs.get(),
  }) })
  const terminals = new AppTerminals({
    resolveDirectory: async sessionId => {
      const found = await ctx.sessionController.resolveAgent(sessionId)
      if ('error' in found) throw found.error
      const directory = found.agent.ctx.get('workingDirectory')
      if (!directory) throw new Error('Session working directory is unavailable')
      return { cwd: await directory.ensure(found.agent), owner: found.agent.ctx }
    },
  })
  const streams = new AppStreams(ctx, transport, peer, {
    maxSubscriptions: () => config.appStreamMaxSubscriptions.get(),
    maxFrameBytes: () => config.appStreamMaxFrameBytes.get(),
  })
  transport.onNotification((method, params) => {
    if (method === 'native.networkChanged') {
      void web.refresh().catch(error => web.publish({ phase: 'failed', host: null, url: null, error: String(error) }))
    }
    if (method === 'native.appDisconnected') {
      history.releaseAll()
      void references.closeOwner(params.owner).catch(error => console.error('App reference cleanup failed:', error))
      void workspaceChanges.closeOwner(params.owner).catch(error => console.error('App change comparison cleanup failed:', error))
      void streams.closeOwner(params.owner).catch(error => console.error('App stream cleanup failed:', error))
      void documentSearch.closeOwner(params.owner).catch(error => console.error('App file search cleanup failed:', error))
      void documentPreview.closeOwner(params.owner).catch(error => console.error('App document preview cleanup failed:', error))
      void attachmentFiles.closeOwner(params.owner).catch(() => console.error('App attachment file cleanup failed'))
    }
  })
  const describe = () => describeAndroidSettings(ctx)
  transport.onRequest(async (method, params) => {
    if (method === 'userText.mask') return maskUserText(params)
    if (method.startsWith('workspaceChanges.')) return workspaceChanges.call(method.slice('workspaceChanges.'.length), params)
    if (method.startsWith('references.')) {
      try { return await references.call(method.slice('references.'.length), params) }
      catch (error) { return remoteFailure(error) }
    }
    if (method.startsWith('library.')) return library.call(method.slice('library.'.length), params)
    if (method.startsWith('workspace.files.')) return workspaceFiles.call(method.slice('workspace.files.'.length), params)
    if (method.startsWith('document.')) return documentPreview.call(method.slice('document.'.length), params)
    if (method.startsWith('terminal.')) {
      const action = method.slice('terminal.'.length)
      if (!['list', 'create', 'read', 'write', 'resize', 'close'].includes(action)) {
        throw new Error(`Unsupported terminal action: ${action}`)
      }
      return terminals[action](params)
    }
    switch (method) {
      case 'runtime.info': return { node: process.version, platform: process.platform, arch: process.arch,
        uid: process.getuid?.(), workspace: process.cwd(), profile: 'android' }
      case 'runtime.permissions': return {
        shell: shell.policy(),
        fileTools: { sandboxMode: ctx.get('fs')?.sandboxMode ?? null },
        presets: { available: !!ctx.get('permissionPresets') },
      }
      case 'runtime.live': return live.snapshot()
      case 'runtime.transition.reserve': return packageOperations.reserve(params)
      case 'runtime.transition.commit': return packageOperations.commit(params)
      case 'runtime.transition.release': return packageOperations.release(params)
      case 'tasks.summary': return tasks.summary()
      case 'tasks.list': return tasks.list(params)
      case 'tasks.session': return tasks.session(params)
      case 'tasks.cancel': return tasks.cancel(params)
      case 'tasks.removeQueued': return tasks.removeQueued(params)
      case 'subagents.catalog': return subagents.call('catalog', params)
      case 'subagents.inspect': return subagents.call('inspect', params)
      case 'subagents.page': return subagents.call('page', params)
      case 'subagents.send': return subagents.call('send', params)
      case 'subagents.interrupt': return subagents.call('interrupt', params)
      case 'account.signIn': {
        const client = params.client
        if (typeof client !== 'object' || client === null || typeof client.version !== 'string'
          || typeof client.locale !== 'string' || !Number.isSafeInteger(client.timezoneOffsetSeconds)) {
          throw new TypeError('Account client version, locale, and timezone are required')
        }
        return ctx.accountCallback.signIn(client)
      }
      case 'interactions.list': return interactions.snapshot()
      case 'interactions.reply': return interactions.reply(params)
      case 'interactions.dismiss': return interactions.dismiss(params)
      case 'interactions.wait': return interactions.wait(params)
      case 'web.status': return web.status()
      case 'web.configure': return web.configure(params)
      case 'web.rotate': return web.rotate()
      case 'api.call': {
        try {
          return await invoke(requiredString(params.namespace, 'namespace'),
            requiredString(params.method, 'method'), params.args ?? {})
        } catch (error) { return remoteFailure(error) }
      }
      case 'api.subscribe': return streams.subscribe(params)
      case 'api.ack': return streams.ack(params)
      case 'api.unsubscribe': return streams.unsubscribe(params)
      case 'session.send': return sessions.send(params)
      case 'session.ensure': return sessions.ensure(params)
      case 'session.selectPreset': {
        try { return await sessions.selectPreset(params) }
        catch (error) { return remoteFailure(error) }
      }
      case 'session.command': return sessions.command(params)
      case 'attachments.prepare': return attachments.prepare(params)
      case 'attachments.preview': return attachments.preview(params)
      case 'attachments.release': return attachments.release(params)
      case 'session.export.prepare': return exports.prepare(params)
      case 'session.export.cancel': return exports.cancel(params)
      case 'session.export.release': return exports.release(params)
      case 'session.attachmentFile.prepare': return attachmentFiles.prepare(params)
      case 'session.attachmentFile.info': return attachmentFiles.info(params)
      case 'session.attachmentFile.read': return attachmentFiles.read(params)
      case 'session.attachmentFile.cancel': return attachmentFiles.cancel(params)
      case 'session.attachmentFile.release': return attachmentFiles.release(params)
      case 'settings.describe': return describe()
      case 'configuration.transfer.export': return configurationTransfers.export()
      case 'configuration.transfer.preview': return configurationTransfers.preview(params)
      case 'configuration.transfer.apply': return configurationTransfers.apply(params)
      case 'configuration.transfer.release': return configurationTransfers.release(params)
      case 'settings.mutate': {
        requiredString(params.ns, 'ns')
        if (!Array.isArray(params.ops) || !Number.isSafeInteger(params.revision)) throw new TypeError('ops and revision are required')
        try {
          await ctx.settings.mutate(params.ns, params.ops, params.revision)
        } catch (error) {
          if (error.code !== 'SETTINGS_CONFLICT') throw error
          return { _pocket_error: { code: error.code, message: error.message,
            expectedRevision: error.expected, actualRevision: error.actual } }
        }
        return describe()
      }
      case 'credentials.describe': return credentials.describe(credentialRef(requiredString(params.ref, 'ref')))
      case 'credentials.set': {
        const value = requiredString(params.value, 'value').trim()
        if (!/^[\x21-\x7e]+$/.test(value)) throw new TypeError('API Key must contain printable ASCII without spaces')
        await credentials.set(credentialRef(requiredString(params.ref, 'ref')), value)
        return { configured: true }
      }
      case 'credentials.unset': {
        await credentials.unset(credentialRef(requiredString(params.ref, 'ref')))
        return { configured: false }
      }
      // Child transcripts require their durable parent address and belong to the subagent/task entry points.
      case 'sessions.list': return library.sidebar()
      case 'session.read': {
        try { return await history.read(params) }
        catch (error) { return remoteFailure(error) }
      }
      case 'session.read.release': return history.release(params)
      case 'session.cancel': return tasks.cancel(params)
      case 'documents.roots': return transport.request('native.documents.roots', {})
      case 'documents.list': return transport.request('native.documents.list', params)
      case 'documents.read': return transport.request('native.documents.read', params)
      case 'documents.revoke': return transport.request('native.documents.revoke', params)
      case 'documents.search': return documentSearch.run(params, { owner: params.owner })
      case 'documents.search.cancel': return documentSearch.cancel(params, { owner: params.owner })
      default: throw new Error(`Unsupported App method: ${method}`)
    }
  })
  ctx.on('session/event', (session, event) => {
    transport.notify('session.event', { sessionId: String(session.id), event: presentSessionEvent(event) })
    if (event.type === 'session/title') transport.notify('sessions.changed', {})
  })
  ctx.on('session/created', () => transport.notify('sessions.changed', {}))
  ctx.on('domain/changed', change => {
    if (change.domain === 'workspace') transport.notify('sessions.changed', {})
  })
  ctx.on('settings/document-updated', () => transport.notify('settings.changed'))
  ctx.effect(() => ctx.tools.register(defineTool({
    name: 'android_files', description: 'List authorized Android document roots, list a relative directory, read UTF-8 text in chunks, or search literal text below an authorized root. Search is bounded and reports skipped files and incomplete results. content:// URIs are not shell paths.',
    parameters: { action: { type: 'string', required: true }, root: { type: 'string' }, path: { type: 'string' }, offset: { type: 'integer' },
      query: { type: 'string' }, caseSensitive: { type: 'boolean' } },
    output: { schema: { type: 'json' }, render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }] },
    async execute(args, execution) {
      if (args.action === 'roots') return transport.request('native.documents.roots', {})
      if (args.action === 'search') {
        if (!execution.agent) throw new Error('File search requires an Agent session')
        return documentSearch.run({
          requestId: randomUUID(), root: args.root, path: args.path ?? '', query: args.query,
          caseSensitive: args.caseSensitive ?? false,
        }, { owner: `tool:${execution.agent.session.id}:${execution.callId}`, signal: execution.signal })
      }
      if (args.action !== 'list' && args.action !== 'read') throw new Error('action must be roots, list, read or search')
      requiredString(args.root, 'root')
      return transport.request(`native.documents.${args.action}`, { root: args.root, path: args.path ?? '', offset: args.offset ?? 0 })
    },
  })))
  ctx.effect(() => {
    const remove = ctx.appReady.onReady(() => {
      void transport.request('native.storage.root', {}).then(async root => {
        const privateRoot = requiredString(root, 'native storage root')
        await interactionReceipts.initialize(privateRoot)
        establishAttachmentHome(resolveDshHome(), privateRoot)
      }).then(() => library.initialize()).then(() => interactions.start()).then(() => {
        transport.notify('runtime.ready', { node: process.version })
        tasks.publish()
        return web.restore().catch(error =>
          transport.notify('web.changed', { ...web.status(), phase: 'failed', error: String(error) }),
        )
      }).catch(error => {
        transport.notify('runtime.status', { phase: 'failed', error: `运行时初始化失败：${error.message}` })
      })
    })
    return async () => {
      remove()
      const results = await Promise.allSettled([
        () => taskCompletion.close(),
        () => documentSearch.close(), () => attachments.close(), () => attachmentFiles.close(), () => exports.close(), () => tasks.close(),
        () => packageOperations.close(),
        () => configurationTransfers.close(), () => subagents.close(), () => workspaceFiles.close(), () => library.close(),
        () => terminals.dispose(),
        () => live.close(),
        () => history.close(),
        () => streams.close(), () => documentPreview.close(), () => references.close(), () => workspaceChanges.close(),
        () => interactions.close(), () => web.close(),
      ].map(close => Promise.resolve().then(close)))
      // Stream and interaction owners release their peer before the shared API peer.
      results.push(...await Promise.allSettled([Promise.resolve().then(() => appPeer?.dispose())]))
      const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
      if (errors.length) throw new AggregateError(errors, 'Android runtime cleanup did not complete')
    }
  })
  })
}
