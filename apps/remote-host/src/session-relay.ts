/**
 * Relay decision for `session.send`: try the child's own facade first and only
 * call the desktop relay when the local write is rejected by the desktop DSH
 * write handle. This keeps the normal path unchanged and prevents double sends.
 *
 * The decision is a pure function so the selfcheck can prove:
 * - a successful local send never calls the relay;
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
 * @returns the text-only relay request, or undefined when it cannot be relayed.
 */
export function relaySendRequest(params: Record<string, unknown>): DesktopRelaySendRequest | undefined {
  const sessionId = params['sessionId']
  const text = params['text']
  const attachmentIds = params['attachmentIds']
  if (typeof sessionId !== 'string' || sessionId.trim() === '') return undefined
  if (typeof text !== 'string' || text.trim() === '') return undefined
  if (Array.isArray(attachmentIds) && attachmentIds.length > 0) return undefined
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
 * @throws the original local error when the relay is absent, unsupported, or fails.
 */
export async function dispatchWithSessionRelay(options: SessionRelayOptions): Promise<unknown> {
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
