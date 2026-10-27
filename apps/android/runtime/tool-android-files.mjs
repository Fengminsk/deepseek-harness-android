import { randomUUID } from 'node:crypto'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { readAuthorizedDocument } from './document-read.mjs'
import { readAuthorizedImage, renderAuthorizedImage } from './authorized-image.mjs'

const firstPartyDefinitions = new WeakMap()

/** Attest the live definition and Agent registry identity, never just a tool name. */
export function isFirstPartyAndroidFilesDefinition(definition, agent) {
  const ctx = firstPartyDefinitions.get(definition)
  return Boolean(ctx && agent?.id && ctx.tools.get('android_files') === definition
    && ctx.get('agents')?.get(agent.id) === agent)
}

export const ANDROID_FILES_DESCRIPTION = 'Access documents explicitly authorized through Android file selection. First call action="roots". For all other actions set root to the exact opaque id from that result, NEVER its display name (Download/MT2/etc.) or a content URI. path is relative to that root: use "" for its top level, "folder/file.txt" for a child, never "/" or an absolute path. Actions: list, read (paged UTF-8 text), read_image (PNG/JPEG/WebP/GIF), search (bounded literal text). For read pages after offset 0, pass the returned version. Uploaded chat attachments use android_attachments instead.'

/** Validate the public carrier before forwarding opaque ids to the native SAF owner. */
export function validateAndroidFileArguments(args) {
  if (!args || !['roots', 'list', 'read', 'read_image', 'search'].includes(args.action)) {
    throw new Error('action 必须是 roots、list、read、read_image 或 search。')
  }
  if (args.action === 'roots') return args
  if (typeof args.root !== 'string' || !args.root.trim() || args.root.includes('://')) {
    throw new Error('请先调用 action="roots"，然后把返回的 id 原样填入 root；不能使用目录名称或 URI。')
  }
  const path = args.path ?? ''
  if (typeof path !== 'string' || /^[\\/]|^[a-z][a-z0-9+.-]*:/iu.test(path)
    || path.split(/[\\/]/u).includes('..') || /[\0-\x1f]/u.test(path)) {
    throw new Error('path 必须是授权根目录内的相对路径；根目录用空字符串 ""，不能用 "/"、URI 或 ..。')
  }
  return { ...args, path }
}

export function registerAndroidFilesTool(ctx, transport, documentSearch) {
  const definition = defineTool({
    name: 'android_files', description: ANDROID_FILES_DESCRIPTION,
    parameters: {
      action: { type: 'string', required: true, description: 'roots | list | read | read_image | search' },
      root: { type: 'string', description: 'Exact opaque id returned by roots, not the display name.' },
      path: { type: 'string', description: 'Relative child path; empty string selects the root directory.' },
      offset: { type: 'integer' }, version: { type: 'string' }, query: { type: 'string' }, caseSensitive: { type: 'boolean' },
    },
    output: { schema: { type: 'json' }, render: renderAuthorizedImage },
    async execute(input, execution) {
      const args = validateAndroidFileArguments(input)
      if (args.action === 'roots') return transport.request('native.documents.roots', {})
      // Resolve against the current grant list on every operation. A display-name
      // mistake and a genuinely revoked id now have actionable, distinct errors.
      const roots = await transport.request('native.documents.roots', {})
      execution.signal.throwIfAborted()
      const entries = Array.isArray(roots) ? roots : roots?.roots
      if (!Array.isArray(entries)) throw new Error('无法读取当前文件授权，请重新选择授权目录。')
      if (!entries.some(root => root.id === args.root)) {
        const byName = entries.filter(root => root.name === args.root || root.displayName === args.root)
        if (byName.length) throw new Error('root 使用了显示名称；请调用 roots 并传入对应条目的 id。')
        throw new Error('root 不在当前授权中；请调用 roots 重新选择 id，或在文件页面重新授权。')
      }
      if (args.action === 'search') {
        if (!execution.agent) throw new Error('File search requires an Agent session')
        return documentSearch.run({ requestId: randomUUID(), root: args.root, path: args.path,
          query: args.query, caseSensitive: args.caseSensitive ?? false },
        { owner: `tool:${execution.agent.session.id}:${execution.callId}`, signal: execution.signal })
      }
      if (args.action === 'read_image') return readAuthorizedImage(ctx, transport, args, execution)
      if (args.action === 'read') return readAuthorizedDocument(request => transport.request('native.documents.read', request), args, true)
      return transport.request('native.documents.list', { root: args.root, path: args.path })
    },
  })
  ctx.effect(() => {
    const dispose = ctx.tools.register(definition)
    firstPartyDefinitions.set(definition, ctx)
    return () => { firstPartyDefinitions.delete(definition); return dispose() }
  })
}
