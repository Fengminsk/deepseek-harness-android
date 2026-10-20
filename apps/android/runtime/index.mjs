import Schema from '@deepseek-ai/schemastery'
import { randomUUID } from 'node:crypto'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { SessionId } from '@deepseek-ai/dsh-session'
import { establishAttachmentHome } from '@deepseek-ai/dsh-attachment-local'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { AndroidCredentials } from './credentials.mjs'
import { registerAndroidShell } from './tool-android-shell.mjs'
import AndroidShell from './android-shell.mjs'
import { WebAccess } from './web-access.mjs'
import { AppSessions } from './sessions.mjs'
import { AppLiveState } from './live-state.mjs'
import { AppInteractions } from './interactions.mjs'
import { AppStreams } from './streams.mjs'
import { AppExports } from './exports.mjs'
import AndroidAccountCallback from './account-callback.mjs'
import { AppAttachments } from './attachments.mjs'
import { createRuntimeTransport } from './transport.mjs'
import { AppDocumentSearch } from './document-search.mjs'

export const name = 'android-runtime'
export const inject = ['agents', 'sessions', 'workingDirectory', 'settings', 'tools', 'appReady', 'sessionPersistence']
export const Config = Schema.object({
  shellTimeoutMs: Schema.natural().min(1).max(3600000).default(60000).volatile(),
  shellOutputLimit: Schema.natural().min(1024).max(1048576).default(65536).volatile(),
  appStreamMaxSubscriptions: Schema.natural().min(1).max(128).default(32).volatile(),
  appStreamMaxFrameBytes: Schema.natural().min(4096).max(16777216).default(16777216).volatile(),
  documentSearchFileBytes: Schema.natural().min(1024).max(67108864).default(8388608).volatile(),
  documentSearchTotalBytes: Schema.natural().min(1024).max(268435456).default(67108864).volatile(),
  documentSearchMaxEntries: Schema.natural().min(1).max(10000).default(2000).volatile(),
  documentSearchMaxFiles: Schema.natural().min(1).max(10000).default(1000).volatile(),
  documentSearchMaxDepth: Schema.natural().min(1).max(64).default(32).volatile(),
  documentSearchMaxMatches: Schema.natural().min(1).max(1000).default(200).volatile(),
  documentSearchPreviewChars: Schema.natural().min(512).max(2000).default(600).volatile(),
  documentSearchMaxDurationMs: Schema.natural().min(100).max(300000).default(30000).volatile(),
  documentSearchMaxRequests: Schema.natural().min(1).max(4).default(4).volatile(),
})

function requiredString(value, label) {
  if (typeof value !== 'string' || value.length === 0) throw new TypeError(`${label} must be a non-empty string`)
  return value
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
  ctx.inject(['sessionController', 'typertGateway', 'connection', 'accountCallback', 'fileUploads', 'pluginManager'], ctx => {
  // These Loader entries define the native carrier and App-controlled HTTP boundary.
  // The manager applies the same protection to App, Web, tools, and bundle overlays.
  const requiredEntries = new Set(['android-runtime', 'credentials', 'authorization', 'deepseek-account',
    'web-startup', 'webserver', 'web-runtime', 'connection', 'session-controller',
    'session-persistence-jsonl', 'android-session-persistence', 'settings', 'file-upload',
    'attachment-local', 'android-attachment-store', 'working-directory', 'agent-loop'])
  const loaderEntries = [...ctx.get('loader').entries()]
  ctx.pluginManager.protectModules(loaderEntries.filter(entry => requiredEntries.has(entry.options.id))
    .map(entry => entry.options.name))
  const web = new WebAccess(ctx, transport)
  let appPeer
  const peer = () => appPeer ??= ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'none' })
  const invoke = (namespace, method, args) => {
    return ctx.typertGateway.invoke({ namespace, method, args, peer: peer() })
  }
  let attachments
  const sessions = new AppSessions(ctx, (method, request) => invoke('session', method, { request }),
    (sessionId, ids) => attachments.content(sessionId, ids), {
      content: (sessionId, ids) => attachments.commandContent(sessionId, ids),
      execute: args => invoke('commands', 'execute', args),
    })
  attachments = new AppAttachments(ctx, {
    directory: () => transport.request('native.attachments.directory', {}),
    ensureSession: sessionId => sessions.ensure(sessionId),
  })
  const live = new AppLiveState(ctx, transport)
  const interactions = new AppInteractions(ctx, transport)
  const exports = new AppExports(ctx, { directory: () => transport.request('native.exports.directory', {}) })
  const documentSearch = new AppDocumentSearch(transport, {
    maxRequests: () => config.documentSearchMaxRequests.get(),
    limits: () => ({
      fileBytes: config.documentSearchFileBytes.get(), totalBytes: config.documentSearchTotalBytes.get(),
      maxEntries: config.documentSearchMaxEntries.get(), maxFiles: config.documentSearchMaxFiles.get(),
      maxDepth: config.documentSearchMaxDepth.get(), maxMatches: config.documentSearchMaxMatches.get(),
      previewChars: config.documentSearchPreviewChars.get(), maxDurationMs: config.documentSearchMaxDurationMs.get(),
    }),
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
      void streams.closeOwner(params.owner).catch(error => console.error('App stream cleanup failed:', error))
      void documentSearch.closeOwner(params.owner).catch(error => console.error('App file search cleanup failed:', error))
    }
  })
  const describe = () => ctx.settings.describe({ redactSecrets: true })
  transport.onRequest(async (method, params) => {
    switch (method) {
      case 'runtime.info': return { node: process.version, platform: process.platform, arch: process.arch,
        uid: process.getuid?.(), workspace: process.cwd(), profile: 'android' }
      case 'runtime.live': return live.snapshot()
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
      case 'interactions.wait': return interactions.wait(params)
      case 'web.status': return web.status()
      case 'web.configure': return web.configure(params)
      case 'web.rotate': return web.rotate()
      case 'api.call': return invoke(requiredString(params.namespace, 'namespace'),
        requiredString(params.method, 'method'), params.args ?? {})
      case 'api.subscribe': return streams.subscribe(params)
      case 'api.ack': return streams.ack(params)
      case 'api.unsubscribe': return streams.unsubscribe(params)
      case 'session.send': return sessions.send(params)
      case 'session.ensure': return sessions.ensure(params)
      case 'session.command': return sessions.command(params)
      case 'attachments.prepare': return attachments.prepare(params)
      case 'attachments.release': return attachments.release(params)
      case 'session.export.prepare': return exports.prepare(params)
      case 'session.export.cancel': return exports.cancel(params)
      case 'session.export.release': return exports.release(params)
      case 'settings.describe': return describe()
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
      case 'sessions.list': return ctx.sessionPersistence.list()
      case 'session.read': {
        const sessionId = SessionId(requiredString(params.sessionId, 'sessionId'))
        const offset = params.offset ?? 0
        if (!Number.isSafeInteger(offset) || offset < 0) throw new TypeError('offset must be a non-negative integer')
        // Standalone command events can precede the next persistence checkpoint.
        // The original controller owns the current attached Session observation.
        if (ctx.sessions.get(sessionId) !== undefined) {
          const inspection = await ctx.sessionController.inspect(sessionId)
          return { events: inspection.events.filter(event => event.seq >= offset).slice(0, 200) }
        }
        const handle = await ctx.sessionPersistence.open(sessionId, 'read')
        try { return await handle.read(offset, 200) } finally { await handle.close() }
      }
      case 'session.cancel': {
        const agent = ctx.agents.get(SessionId(requiredString(params.sessionId, 'sessionId')))
        if (agent === undefined) throw new Error('Session is not running')
        agent.cancel({ kind: 'user' })
        return { cancelled: true }
      }
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
    transport.notify('session.event', { sessionId: String(session.id), event })
  })
  ctx.on('session/created', () => transport.notify('sessions.changed', {}))
  ctx.on('settings/document-updated', () => transport.notify('settings.changed'))
  registerAndroidShell(ctx, config)
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
      void transport.request('native.storage.root', {}).then(root =>
        establishAttachmentHome(resolveDshHome(), requiredString(root, 'native storage root')),
      ).then(() => interactions.start()).then(() => {
        transport.notify('runtime.ready', { node: process.version })
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
        () => documentSearch.close(), () => attachments.close(), () => exports.close(),
        () => streams.close(), () => interactions.close(), () => web.close(),
      ].map(close => Promise.resolve().then(close)))
      // Stream and interaction owners release their peer before the shared API peer.
      results.push(...await Promise.allSettled([Promise.resolve().then(() => appPeer?.dispose())]))
      const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
      if (errors.length) throw new AggregateError(errors, 'Android runtime cleanup did not complete')
    }
  })
  })
}
