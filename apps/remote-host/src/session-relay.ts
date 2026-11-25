/**
 * Relay decision for `session.send`: send desktop-owned sessions through their
 * owner directly. For sessions not reported by the desktop, try the child and
 * relay only if its write handle rejects the send.
 *
 * The decision is a pure function so the selfcheck can prove:
 * - a desktop-owned session never calls the child writer;
 * - a successful child send never calls the relay;
 * - unrelated failures keep the original error;
 * - only a write-handle conflict, with text and no attachments, is relayed;
 * - a relay failure falls back to the original error.
 * @module @deepseek-ai/dsh-remote-host/session-relay
 */

import type { DesktopRelayClient, DesktopRelaySendRequest } from './desktop-relay-client.ts'

/** Error text produced by the session persistence write-handle conflict. */
const WRITE_HANDLE_PATTERN = /already owned by an active write handle/i

/** Additional desktop-side write-conflict codes/messages the relay covers. */
const WRITE_CONFLICT_PATTERN = /write[- ]handle|session\/write-conflict|write-lock/i

/**
 * Whether one send failure is a desktop write-handle conflict.
 * @param error - thrown value from the local facade send.
 * @returns true when relaying to the desktop process may succeed.
 */
export function isWriteHandleConflict(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  if (WRITE_HANDLE_PATTERN.test(message) || WRITE_CONFLICT_PATTERN.test(message)) return true
  const code = typeof error === 'object' && error !== null
    ? (error as { code?: unknown }).code
    : undefined
  return code === 'session/write-conflict' || code === 'session/already-owned'
}

/**
 * Build the relay request from a facade `session.send` params object.
 * @param params - facade params.
 * @returns the relay request when every supplied draft has a desktop receipt.
 */
export function relaySendRequest(params: Record<string, unknown>, receiptIds?: readonly string[]): DesktopRelaySendRequest | undefined {
  const sessionId = params['sessionId']
  const text = params['text']
  const attachmentIds = params['attachmentIds']
  if (typeof sessionId !== 'string' || sessionId.trim() === '') return undefined
  if (typeof text !== 'string' || (!text.trim() && !receiptIds?.length)) return undefined
  if (Array.isArray(attachmentIds) && attachmentIds.length && receiptIds?.length !== attachmentIds.length) return undefined
  const optional = (key: string): string | undefined => {
    const value = params[key]
    return typeof value === 'string' && value !== '' ? value : undefined
  }
  const requestId = optional('requestId')
  const provider = optional('provider')
  const model = optional('model')
  return {
    sessionId,
    text,
    ...(receiptIds?.length ? { receiptIds } : {}),
    ...(requestId === undefined ? {} : { requestId }),
    ...(provider === undefined ? {} : { provider }),
    ...(model === undefined ? {} : { model }),
    ...(params['selectModel'] === true ? { selectModel: true } : {}),
  }
}

/** Options of {@link dispatchWithSessionRelay}. */
export interface SessionRelayOptions {
  /** Inbound facade method name. */
  readonly method: string
  /** Inbound facade params. */
  readonly params: Record<string, unknown>
  /** Runs the child's existing facade dispatch. */
  readonly local: () => unknown
  /** Desktop relay client; absent when the child has no descriptor. */
  readonly relay: DesktopRelayClient | undefined
}

/**
 * Dispatch one request, relaying only a desktop write-handle conflict on a
 * text send. Local success and all other failures are returned unchanged.
 * @param options - method, params, local dispatch, and relay client.
 * @returns the local or relayed result.
 * @throws a direct relay error for a desktop-owned session, or the original
 * child error when the fallback relay is absent, unsupported, or fails.
 */
export async function dispatchWithSessionRelay(options: SessionRelayOptions): Promise<unknown> {
  if (options.method === 'session.ensure' && options.relay) {
    const sessionId = options.params['sessionId']
    if (typeof sessionId === 'string' && (await options.relay.sessionStatus(sessionId)).status !== 'unknown') {
      return { sessionId, created: false }
    }
  }
  if (options.relay !== undefined && (
    options.method === 'interactions.list' || options.method === 'interactions.reply'
  )) {
    const sessionId = options.params['sessionId']
    if (typeof sessionId === 'string' && sessionId !== '') {
      const status = await options.relay.sessionStatus(sessionId)
      if (status.status !== 'unknown') {
        return options.method === 'interactions.list'
          ? options.relay.interactionsList(sessionId)
          : options.relay.interactionsReply(options.params)
      }
    }
  }
  if (options.method === 'api.call' && options.relay !== undefined) {
    const namespace = options.params['namespace']
    const method = options.params['method']
    if (namespace === 'commands' && method === 'list') {
      const args = options.params['args']
      const agentId = args && typeof args === 'object' ? (args as Record<string, unknown>)['agentId'] : undefined
      if (typeof agentId === 'string' && (await options.relay.sessionStatus(agentId)).status !== 'unknown') {
        return options.relay.commandCatalog(agentId)
      }
    }
    const kind = namespace === 'session' && method === 'modelCatalog'
      ? 'model'
      : namespace === 'permissionPresets' && method === 'catalog'
        ? 'permission'
        : undefined
    if (kind !== undefined) {
      try {
        return await options.relay.catalog(kind)
      } catch {
        // Older desktop plugins and disconnected desktops keep the child path.
        return options.local()
      }
    }
  }
  if (options.method === 'api.call' && options.relay !== undefined
    && options.params['namespace'] === 'session' && options.params['method'] === 'projections') {
    const args = options.params['args']
    const request = typeof args === 'object' && args !== null ? (args as Record<string, unknown>)['request'] : undefined
    const sessionId = typeof request === 'object' && request !== null
      ? (request as Record<string, unknown>)['sessionId'] : undefined
    if (typeof sessionId === 'string' && sessionId.trim() !== '') {
      try {
        const projection = await options.relay.projections(sessionId)
        if (projection !== null && projection !== undefined) return projection
      } catch {
        // A child-owned Session may not exist in the desktop controller.
      }
      return options.local()
    }
  }
  if (options.method === 'session.readWindow' && options.relay !== undefined) {
    try {
      return await options.relay.readWindow(options.params)
    } catch {
      // A missing desktop relay must not make child-owned Sessions unreadable.
      return options.local()
    }
  }
  if (options.method === 'session.send' && options.relay !== undefined) {
    const request = relaySendRequest(options.params)
    if (request !== undefined) {
      const status = await options.relay.sessionStatus(request.sessionId)
      // The desktop process owns the live Agent and its write handle. Sending
      // through the child first can wait for that handle before it fails.
      if (status.status !== 'unknown') return options.relay.send(request)
    }
  }
  try {
    return await options.local()
  } catch (error) {
    if (options.method !== 'session.send' || options.relay === undefined) throw error
    if (!isWriteHandleConflict(error)) throw error
    const request = relaySendRequest(options.params)
    if (request === undefined) throw error
    try {
      return await options.relay.send(request)
    } catch (relayError) {
      // The phone should keep the original, actionable write-handle error rather
      // than a relay infrastructure detail. The relay reason is attached for logs
      // without message content.
      if (relayError instanceof Error && error instanceof Error) {
        error.message = `${error.message}（桌面中继未完成：${relayError.message}）`
      }
      throw error
    }
  }
}
