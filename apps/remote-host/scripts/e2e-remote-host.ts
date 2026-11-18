/**
 * Independent end-to-end client for a live PC remote-DSH host.
 *
 * The script plays the App side of `apps/android/docs/remote-dsh/protocol.md` v1 against an
 * already-running host (no stub facade): real HTTPS pairing, real certificate pinning, a real
 * `wss://…/app` JSON-RPC connection, real session reads, and real stream window acknowledgements.
 *
 * Numbered checks, in order: pair-link parse, CA fingerprint, `/pair`, pairing-token single use,
 * wss upgrade, `protocol.hello`, readiness + `runtime.info` + `sessions.list`, `api.call`
 * `session.modelCatalog`, `session.readWindow`, `workspace.files.list` at the host workspace root,
 * `workspace.files.read` of `AGENTS.md`, `workspaceChanges.summary` capability probe,
 * `terminal.shells` discovery, error translation for a missing terminal, `terminal.create` + write
 * + screen evidence, `terminal.resize` + list + rename + close, `attachments.prepare` file receipt
 * with the host's paged `native.attachments.read` pulls, not-found draft error translation,
 * `session.send` with `attachmentIds`, `session.follow` subscription, optional `session.send` with
 * assistant streaming evidence, locally-answered `native.*` interception, cleanup. The workspace
 * checks cover the remote file browser and workspace-diff surfaces. The summary probe is strict
 * when the read window announces a `workspace/changes` event and degrades to a note when it does
 * not, because snapshots are process-local. The terminal checks prove the frozen v1 `terminal.*`
 * request/response methods against the real `terminal-controller`; cleanup closes any terminal
 * they created on every path. The attachment checks play the App side of the design §3.4 reverse
 * pull (`native.attachments.read`), then reference the receipt from `session.send`; cleanup
 * releases the drafts on every path. The send check also observes the protocol §8 system
 * notification line: once the page-line `task.completed` fires, the mapped `remote.taskCompleted`
 * must arrive and satisfy §8.2, and cleanup revalidates every observed `remote.*` frame. That
 * observation degrades to a SKIP note when the runtime suppresses `task.completed` (for example
 * while a goal is active), so the existing check semantics stay unchanged. The §8.5 title mapping
 * (`session/title` → `remote.sessionChanged`) is covered keylessly by
 * `notification-selfcheck.ts`; this E2E validates every `remote.sessionChanged` it does observe.
 * The cleanup check runs on every path.
 *
 * Usage:
 * `node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url "<pair-url>"`
 * `[--session <id>] [--send "<text>"] [--timeout-ms 180000] [--json]`
 *
 * Exit codes: 0 when every check passes, 1 when any check fails, 2 for an invalid command line.
 * Device tokens and pairing tokens never reach the output.
 *
 * @module @deepseek-ai/dsh-remote-host/scripts/e2e-remote-host
 */

import { createHash, randomUUID, X509Certificate } from 'node:crypto'
import type { ClientRequest, IncomingHttpHeaders, IncomingMessage } from 'node:http'
import { request as httpsRequest } from 'node:https'
import { isAbsolute } from 'node:path'
import WebSocket, { type RawData } from 'ws'

/** Default overall run budget. */
const DEFAULT_TIMEOUT_MS = 180_000

/** App build string reported in `protocol.hello` and in the pairing request. */
const APP_VERSION = '0.1.0+e2e'

/** Device display name reported in `protocol.hello` and in the pairing request. */
const DEVICE_LABEL = 'E2E 主机验收'

/** Exact `Origin` required by protocol §2.1 (byte-for-byte). */
const REMOTE_ORIGIN = 'https://pocket-harness.local'

/** Protocol version negotiated by `protocol.hello` (§3.3). */
const PROTOCOL_VERSION = 1

/** Upper bound for the `/pair` request body (§2: 64 KiB). */
const MAX_PAIR_REQUEST_BYTES = 64 * 1024

/** Pairing-token wire form: 43 base64url characters. */
const PAIRING_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u

/** Device-token wire form: 43 base64url characters. */
const DEVICE_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/u

/** Pair-link instanceId form: 64 lowercase hex characters (SHA-256 of the CA DER). */
const INSTANCE_ID_PATTERN = /^[0-9a-f]{64}$/u

/** `methods` entries the host must answer for this E2E (§10.1 coverage syntax). */
const REQUIRED_METHODS: readonly string[] = [
  'runtime.info',
  'sessions.list',
  'session.readWindow',
  'session.send',
  'api.subscribe',
  'api.ack',
  'api.unsubscribe',
  // Frozen v1 terminal surface (protocol §4.2); the terminal checks below exercise every name.
  'terminal.list',
  'terminal.shells',
  'terminal.create',
  'terminal.read',
  'terminal.write',
  'terminal.resize',
  'terminal.rename',
  'terminal.close',
]

/** Root entries the remote file browser must list (the host workspace root is the repository). */
const WORKSPACE_ROOT_ENTRIES: readonly string[] = ['apps', 'packages']

/** File read through the remote file browser; it proves the text page carries real content. */
const WORKSPACE_READ_PATH = 'AGENTS.md'

/** First line of {@link WORKSPACE_READ_PATH}, which the read page must start with. */
const WORKSPACE_READ_PREFIX = '# AGENTS.md'

/** Whether `workspaceChanges.summary` accepts seqs whose snapshot the running host no longer holds. */
const WORKSPACE_CHANGES_UNAVAILABLE = 'workspace-changes/unavailable'

/** Command typed into the host terminal; `echo` exists in cmd, pwsh, and POSIX shells. */
const TERMINAL_MARKER_COMMAND = 'echo E2E-TERMINAL-OK\r'

/** Output text polled from `terminal.read` after {@link TERMINAL_MARKER_COMMAND}. */
const TERMINAL_MARKER = 'E2E-TERMINAL-OK'

/** Geometry requested from `terminal.create` (App default viewport, §2.2). */
const TERMINAL_CREATE_COLS = 80
const TERMINAL_CREATE_ROWS = 24

/** Geometry requested from `terminal.resize` and asserted through `terminal.list`. */
const TERMINAL_RESIZE_COLS = 100
const TERMINAL_RESIZE_ROWS = 30

/** Delay between `terminal.read` polls while waiting for output evidence. */
const TERMINAL_READ_POLL_MS = 200

/** Upper bound for the written marker to reach the terminal screen. */
const TERMINAL_SCREEN_WAIT_MS = 20_000

/** Upper bound for one unary `terminal.*` request. */
const TERMINAL_REQUEST_CAP_MS = 10_000

/** The one §5.2 reverse method the design routes to the App: paged reads of a phone attachment draft (§3.4). */
const ATTACHMENT_READ_METHOD = 'native.attachments.read'

/** Fixed size of the fake App's attachment draft; 64 pages exercise large-file pagination. */
const ATTACHMENT_FIXTURE_BYTES = 16 * 1024 * 1024

/** Host page size for `native.attachments.read` (design §3.4.2: 1–262144 bytes). */
const ATTACHMENT_PAGE_BYTES = 262_144

/** Draft display name and media type sent to `attachments.prepare`. */
const ATTACHMENT_FILE_NAME = 'e2e-attachment.txt'
const ATTACHMENT_MEDIA_TYPE = 'text/plain'

/** Prompt text of the `session.send` that carries the prepared attachment receipt. */
const ATTACHMENT_SEND_TEXT = '请只回复：收到附件'

/** Upper bound for one `attachments.*` request (includes the host's paged reverse pulls). */
const ATTACHMENT_REQUEST_CAP_MS = 30_000

/**
 * `native.*` methods protocol §5.2 assigns to the Host, so no reverse request frame for them may
 * ever reach the device. This fake App answers every reverse request with `-32601`, which is how
 * a forwarded method would surface: the facade would fail instead of being answered locally.
 * `native.attachments.read` is deliberately absent: design §3.4.1 appends it as a method the Host
 * forwards to the App, and {@link AttachmentFixture} answers it.
 */
const HOST_LOCAL_NATIVE_METHODS: readonly string[] = [
  'native.storage.root',
  'native.attachments.directory',
  'native.exports.directory',
  'native.attachmentFiles.directory',
  'native.web.preferences',
  'native.web.save',
  'native.network.addresses',
  'native.scheduleWakeup.begin',
  'native.scheduleWakeup.update',
]

/** Window-ack pacing required by §6.2: acknowledge every 32 frames or every 200 ms. */
const ACK_FRAME_BUDGET = 32

/** Window-ack pacing required by §6.2. */
const ACK_INTERVAL_MS = 200

/** Upper bound for one HTTP request; the remaining run budget can lower it. */
const HTTP_CAP_MS = 20_000

/** Upper bound for one WebSocket upgrade; the remaining run budget can lower it. */
const WS_OPEN_CAP_MS = 30_000

/** Upper bound for one `api.ack` request. */
const ACK_REQUEST_CAP_MS = 5_000

/** Observation window for unhandled async failures before the cleanup check reports. */
const ASYNC_SETTLE_MS = 150

/**
 * Upper bound for observing the §8 push line after the assistant turn. The page line
 * `task.completed` is the trigger; once it fires the mapped `remote.taskCompleted` follows within
 * this window, so a short window keeps the run bounded when the runtime suppresses the trigger.
 */
const REMOTE_NOTIFICATION_WAIT_MS = 20_000

/**
 * Frozen protocol §8 limits, asserted so a host can never send a longer field or frame.
 * Kept as literals here instead of importing `src/notifications.ts`: the E2E validates the wire
 * contract (the App's view), not the host implementation that writes it.
 */
const REMOTE_FRAME_LIMIT_BYTES: Readonly<Record<string, number>> = {
  'remote.taskCompleted': 8 * 1024,
  'remote.approvalPending': 16 * 1024,
  'remote.deviceRevoked': 1 * 1024,
  'remote.sessionChanged': 4 * 1024,
}

/** Protocol §8.2/§8.3 field character limits. */
const REMOTE_FIELD_LIMITS = {
  id: 128,
  title: 200,
  taskSummary: 512,
  approvalSummary: 1024,
} as const

/** Protocol §8.2 `status` enum. */
const REMOTE_TASK_STATUSES: readonly string[] = ['completed', 'failed', 'cancelled']

/** Protocol §8.3 `kind` enum. */
const REMOTE_APPROVAL_KINDS: readonly string[] = ['approval', 'question', 'plan']

/** Protocol §8.4 `reason` enum. */
const REMOTE_REVOKE_REASONS: readonly string[] = ['user-revoked', 'expired']


/** Human-readable JSON-RPC/WebSocket values are truncated to this length in failures. */
const VALUE_PREVIEW_CHARS = 160

/** A parsed JSON object frame. Unknown members are ignored (§0 hard rule 4). */
type JsonObject = Record<string, unknown>

/** Uncaught/unhandled failures observed while the run is in progress. */
const asyncFailures: string[] = []

process.on('unhandledRejection', (reason: unknown) => {
  asyncFailures.push(`unhandledRejection ${describeError(reason)}`)
})
process.on('uncaughtException', (error: Error) => {
  asyncFailures.push(`uncaughtException ${describeError(error)}`)
})

// ---------------------------------------------------------------------------- command line

/** Parsed command line. */
interface CliOptions {
  /** Pair link printed by the host: `wss|https://<host>:<port>#instance=…&token=…`. */
  readonly pairUrl: string
  /** Session to exercise; `undefined` selects the first `sessions.list` row. */
  readonly sessionId: string | undefined
  /** Prompt to send; `undefined` skips the send check. */
  readonly sendText: string | undefined
  /** Overall run budget in milliseconds. */
  readonly timeoutMs: number
  /** Emit one JSON object instead of numbered human checks. */
  readonly json: boolean
}

/** Result of command-line parsing. */
type ParsedArgs =
  | { readonly kind: 'run'; readonly options: CliOptions }
  | { readonly kind: 'help' }
  | { readonly kind: 'error'; readonly message: string }

/** Command usage text. `--help` must print it and exit 0 without connecting. */
function usageText(): string {
  return [
    'Usage:',
    '  node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url "<pair-url>" [options]',
    '',
    'Options:',
    '  --pair-url <url>    Pair link printed by the host: wss:// or https:// with #instance=<64hex>&token=<43chars>',
    '  --session <id>      Session id to exercise; defaults to the first sessions.list row',
    '  --send "<text>"     Send a prompt and wait for assistant streaming evidence',
    `  --timeout-ms <ms>   Overall run budget in milliseconds (default ${DEFAULT_TIMEOUT_MS})`,
    '  --json              Print one JSON object instead of numbered checks',
    '  --help, -h          Print this help and exit',
    '',
  ].join('\n')
}

/**
 * Parse the fixed CLI surface.
 * @param argv - Arguments after the script path.
 * @returns run options, help request, or a usage error.
 */
function parseArgs(argv: readonly string[]): ParsedArgs {
  let pairUrl: string | undefined
  let sessionId: string | undefined
  let sendText: string | undefined
  let timeoutRaw = String(DEFAULT_TIMEOUT_MS)
  let json = false
  let index = 0
  while (index < argv.length) {
    const argument = argv[index]
    index += 1
    if (argument === undefined) continue
    if (argument === '--help' || argument === '-h') return { kind: 'help' }
    const separator = argument.indexOf('=')
    const flag = separator < 0 ? argument : argument.slice(0, separator)
    let inlineValue = separator < 0 ? undefined : argument.slice(separator + 1)
    const takeValue = (): string | undefined => {
      if (inlineValue !== undefined) return inlineValue
      const next = argv[index]
      if (next === undefined) return undefined
      index += 1
      inlineValue = undefined
      return next
    }
    switch (flag) {
      case '--json':
        if (inlineValue !== undefined) return { kind: 'error', message: '--json does not take a value' }
        json = true
        break
      case '--pair-url': {
        const value = takeValue()
        if (value === undefined) return { kind: 'error', message: '--pair-url requires a value' }
        pairUrl = value
        break
      }
      case '--session': {
        const value = takeValue()
        if (value === undefined) return { kind: 'error', message: '--session requires a value' }
        if (value.length === 0) return { kind: 'error', message: '--session must not be empty' }
        sessionId = value
        break
      }
      case '--send': {
        const value = takeValue()
        if (value === undefined) return { kind: 'error', message: '--send requires a value' }
        sendText = value
        break
      }
      case '--timeout-ms': {
        const value = takeValue()
        if (value === undefined) return { kind: 'error', message: '--timeout-ms requires a value' }
        timeoutRaw = value
        break
      }
      default:
        if (flag.startsWith('-')) return { kind: 'error', message: `unknown option ${flag}` }
        return { kind: 'error', message: `unexpected argument ${argument}` }
    }
  }
  if (pairUrl === undefined) return { kind: 'error', message: '--pair-url is required' }
  const timeoutMs = Number(timeoutRaw)
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    return { kind: 'error', message: `--timeout-ms must be a positive integer, received ${JSON.stringify(timeoutRaw)}` }
  }
  return {
    kind: 'run',
    options: {
      pairUrl,
      sessionId,
      sendText,
      timeoutMs,
      json,
    },
  }
}

// ---------------------------------------------------------------------------- shared types and helpers

/** A parsed pair link. */
interface PairLink {
  /** `wss://<host>:<port>[/prefix]/app`; the query and fragment are gone. */
  readonly appUrl: string
  /** Base for the pairing HTTP calls: `https://<host>:<port>[/prefix]/`. */
  readonly httpBase: URL
  /** `host[:port]` for messages; never contains credentials or the fragment. */
  readonly hostLabel: string
  /** Expected SHA-256 (hex) of the CA DER. */
  readonly instanceId: string
  /** One-shot pairing token; never printed. */
  readonly token: string
}

/** One HTTPS response. */
interface HttpResult {
  readonly status: number
  readonly headers: IncomingHttpHeaders
  readonly body: Buffer
}

/** A WebSocket close fact. */
interface CloseFact {
  readonly code: number
  readonly reason: string
}

/** One JSON-RPC error object read from a frame. */
interface FrameErrorInfo {
  readonly code: number | undefined
  readonly message: string
  readonly data: JsonObject
}

/** One row of `sessions.list`. */
interface SessionSummary {
  readonly id: string
  readonly cwd: string | undefined
}

/** One shell offered by `terminal.shells`; `id` is the host shell path and `label` its name (§2.2). */
interface TerminalShellSummary {
  readonly id: string
  readonly label: string
}

/** One reverse request the host sends to the device (§5). */
interface ReverseRequest {
  readonly id: string | number
  readonly method: string
  readonly params: JsonObject
}

/** Answers one reverse request; returns whether it wrote the response frame. */
type ReverseRequestHandler = (request: ReverseRequest) => boolean

/** One `native.attachments.read` page the fake App served (design §3.4.2). */
interface AttachmentPageRequest {
  readonly id: string
  readonly offset: number
  readonly length: number
  readonly returnedBytes: number
  readonly nextOffset: number
  readonly eof: boolean
}

/** Evidence from `attachments.prepare`: the receipt the App would reference from `session.send`. */
interface AttachmentProbe {
  readonly id: string
  readonly receiptId: string
  readonly bytes: number
  readonly pages: number
}

/** Timeouts raised by this script's own waits. */
class E2ETimeoutError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'E2ETimeoutError'
  }
}

/** A JSON-RPC `error` response or a connection-level error. */
class RpcError extends Error {
  readonly code: number | undefined
  readonly data: JsonObject

  constructor(code: number | undefined, message: string, data: JsonObject) {
    super(message)
    this.name = 'RpcError'
    this.code = code
    this.data = data
  }
}

/**
 * Wait for a delay.
 * @param ms - Milliseconds.
 * @returns Fulfilled after the delay.
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

/**
 * Render any thrown value as one line.
 * @param error - Thrown value.
 * @returns `name: message`; non-errors are stringified.
 */
function describeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`
  return String(error)
}

/**
 * Truncate text with an ellipsis.
 * @param text - Input text.
 * @param limit - Maximum character count.
 * @returns Input when short enough, otherwise a truncated preview.
 */
function truncate(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit)}…`
}

/**
 * Render an unknown wire value for a failure message, bounded in length.
 * @param value - Value read from a frame.
 * @returns JSON text or a primitive rendering, at most {@link VALUE_PREVIEW_CHARS} characters.
 */
function describeValue(value: unknown): string {
  if (value === undefined) return 'undefined'
  if (typeof value === 'string') return truncate(JSON.stringify(value), VALUE_PREVIEW_CHARS)
  if (typeof value === 'bigint') return `${value.toString()}n`
  try {
    const text = JSON.stringify(value)
    return text === undefined ? String(value) : truncate(text, VALUE_PREVIEW_CHARS)
  } catch {
    return truncate(String(value), VALUE_PREVIEW_CHARS)
  }
}

/**
 * Narrow a value to a non-array object.
 * @param value - Candidate value.
 * @returns The object, or `undefined`.
 */
function asObject(value: unknown): JsonObject | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  return value as JsonObject
}

/**
 * Require a non-empty string.
 * @param value - Candidate value.
 * @param label - Field name used in the failure message.
 * @returns The string.
 * @throws When the value is not a non-empty string.
 */
function requireString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${label}: expected a non-empty string, received ${describeValue(value)}`)
  }
  return value
}

/**
 * Require a safe integer.
 * @param value - Candidate value.
 * @param label - Field name used in the failure message.
 * @returns The integer.
 * @throws When the value is not a safe integer.
 */
function requireInteger(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw new Error(`${label}: expected a safe integer, received ${describeValue(value)}`)
  }
  return value
}

/**
 * Require an array.
 * @param value - Candidate value.
 * @param label - Field name used in the failure message.
 * @returns The array as `unknown[]` (each member still needs narrowing).
 * @throws When the value is not an array.
 */
function requireArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${label}: expected an array, received ${describeValue(value)}`)
  }
  return value
}

/**
 * Require a JSON object.
 * @param value - Candidate value.
 * @param label - Field name used in the failure message.
 * @returns The object.
 * @throws When the value is not a JSON object.
 */
function requireObject(value: unknown, label: string): JsonObject {
  const record = asObject(value)
  if (record === undefined) {
    throw new Error(`${label}: expected a JSON object, received ${describeValue(value)}`)
  }
  return record
}

/**
 * Require a value produced by an earlier check.
 * @param value - Value from run state.
 * @param label - What is missing.
 * @returns The defined value.
 * @throws When the value is `undefined` (a prerequisite check did not pass).
 */
function requireState<T>(value: T | undefined, label: string): T {
  if (value === undefined) throw new Error(`missing ${label} from an earlier check`)
  return value
}

/**
 * Unwrap a facade result: business failures travel as `result._pocket_error` (§4.1).
 * @param result - JSON-RPC `result`.
 * @param label - Call name for the failure message.
 * @returns The original result when no business error is present.
 * @throws When the result carries `_pocket_error`.
 */
function unwrapPocketError(result: unknown, label: string): unknown {
  const record = asObject(result)
  const pocket = record === undefined ? undefined : asObject(record['_pocket_error'])
  if (pocket !== undefined) {
    const code = typeof pocket['code'] === 'string' ? pocket['code'] : 'gateway/internal'
    const message = typeof pocket['message'] === 'string' ? pocket['message'] : 'no message'
    throw new Error(`${label} failed with ${code}: ${message}`)
  }
  return result
}

/**
 * Read the error object of a JSON-RPC error frame.
 * @param frame - Already parsed frame.
 * @returns Error fields, or `undefined` for a non-error frame.
 */
function readFrameError(frame: JsonObject): FrameErrorInfo | undefined {
  const record = asObject(frame['error'])
  if (record === undefined) return undefined
  return {
    code: typeof record['code'] === 'number' ? record['code'] : undefined,
    message: typeof record['message'] === 'string' ? record['message'] : 'JSON-RPC error without a message',
    data: asObject(record['data']) ?? {},
  }
}

/**
 * Render a frame error for an assertion message.
 * @param info - Parsed error object.
 * @returns One line including code and any protocol `data.code` / `data.detail`.
 */
function formatFrameError(info: FrameErrorInfo): string {
  const extras: string[] = []
  if (typeof info.data['code'] === 'string') extras.push(`data.code=${info.data['code']}`)
  if (typeof info.data['detail'] === 'string') extras.push(`detail=${info.data['detail']}`)
  if (typeof info.data['method'] === 'string') extras.push(`method=${info.data['method']}`)
  const suffix = extras.length === 0 ? '' : ` (${extras.join(', ')})`
  const code = info.code === undefined ? '' : ` ${String(info.code)}`
  return `JSON-RPC error${code}: ${info.message}${suffix}`
}

/**
 * Map a protocol close code to a short explanation (§1.4).
 * @param code - WebSocket close code.
 * @returns Human-readable meaning.
 */
function describeCloseCode(code: number): string {
  switch (code) {
    case 1000:
      return 'normal closure'
    case 1001:
      return 'host going away'
    case 1002:
      return 'protocol error'
    case 1009:
      return 'frame too large'
    case 4000:
      return 'auth-failed: device token rejected, re-pair the device'
    case 4001:
      return 'auth-revoked: the device was revoked'
    case 4002:
      return 'protocol-mismatch: handshake or protocol version rejected'
    case 4003:
      return 'rate-limited'
    default:
      return 'unexpected close code'
  }
}

/**
 * Build the error used when a wait observes the connection closing.
 * @param fact - Close code and reason.
 * @returns A message naming the code and its protocol meaning.
 */
function connectionClosedError(fact: CloseFact): Error {
  const reason = fact.reason.length === 0 ? '' : `, reason=${JSON.stringify(fact.reason)}`
  return new Error(`connection closed with code ${fact.code} (${describeCloseCode(fact.code)}${reason})`)
}

/**
 * Compute the lowercase hex SHA-256 of a buffer.
 * @param value - Bytes to hash.
 * @returns 64 lowercase hex characters.
 */
function sha256Hex(value: Buffer): string {
  return createHash('sha256').update(value).digest('hex')
}

/**
 * `methods` / `unsupported` coverage (§10.1): an exact entry or a trailing `.*` wildcard.
 * @param entries - Method table entries.
 * @param method - Method to look up.
 * @returns `true` when the table covers the method.
 */
function methodsCover(entries: readonly string[], method: string): boolean {
  for (const entry of entries) {
    if (entry === method) return true
    if (entry.endsWith('.*') && method.startsWith(entry.slice(0, -1))) return true
  }
  return false
}

// ---------------------------------------------------------------------------- HTTP

/**
 * Run one HTTPS request with TLS verification disabled.
 *
 * Only `/ca.cer` (TOFU bootstrap) and `/pair` are ever fetched this way; the wss connection
 * that follows is verified against the pinned CA instead.
 * @param url - Absolute request URL.
 * @param options - Method, optional headers/body, and timeout.
 * @returns Status, headers, and the raw response body.
 */
async function httpsRequestWith(url: URL, options: {
  readonly method: 'GET' | 'POST'
  readonly headers?: Readonly<Record<string, string>>
  readonly body?: string
  readonly timeoutMs: number
}): Promise<HttpResult> {
  return await new Promise<HttpResult>((resolve, reject) => {
    let settled = false
    let outgoing: ClientRequest | undefined
    const finish = (action: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      action()
    }
    const timer = setTimeout(() => {
      finish(() => {
        outgoing?.destroy()
        reject(new E2ETimeoutError(`HTTPS ${options.method} ${url.pathname} timed out after ${options.timeoutMs} ms`))
      })
    }, options.timeoutMs)
    outgoing = httpsRequest({
      hostname: url.hostname.replace(/^\[|\]$/gu, ''),
      port: url.port === '' ? 443 : Number(url.port),
      path: `${url.pathname}${url.search}`,
      method: options.method,
      // The CA is fetched before it is pinned; the server certificate is self-signed.
      rejectUnauthorized: false,
      ...(options.headers === undefined ? {} : { headers: { ...options.headers } }),
    }, (response: IncomingMessage) => {
      const chunks: Buffer[] = []
      response.on('data', (chunk: Buffer) => {
        chunks.push(chunk)
      })
      response.once('end', () => {
        finish(() => {
          resolve({
            status: response.statusCode ?? 0,
            headers: response.headers,
            body: Buffer.concat(chunks),
          })
        })
      })
      response.once('error', (error: Error) => {
        finish(() => {
          reject(new Error(`HTTPS ${options.method} ${url.pathname} response failed: ${describeError(error)}`))
        })
      })
    })
    outgoing.once('error', (error: Error) => {
      finish(() => {
        reject(new Error(`HTTPS ${options.method} ${url.pathname} failed: ${describeError(error)}`))
      })
    })
    if (options.body !== undefined) outgoing.write(options.body)
    outgoing.end()
  })
}

// ---------------------------------------------------------------------------- pair link

/**
 * Parse and validate the host pair link.
 *
 * Accepted schemes are `wss://` (protocol form) and `https://` (a reverse proxy may hand out the
 * HTTP origin instead). The fragment must carry exactly one `instance` and one `token`.
 * @param raw - `--pair-url` value.
 * @returns Endpoint, expected CA fingerprint, and the one-shot pairing token.
 * @throws When the link is malformed or not TLS.
 */
function parsePairLink(raw: string): PairLink {
  let url: URL
  try {
    url = new URL(raw)
  } catch (error) {
    throw new Error(`--pair-url is not a valid URL: ${describeError(error)}`)
  }
  if (url.protocol !== 'wss:' && url.protocol !== 'https:') {
    throw new Error(`--pair-url must use wss:// or https:// (protocol v1 is TLS-only), received ${url.protocol}`)
  }
  if (url.username !== '' || url.password !== '') {
    throw new Error('--pair-url must not carry credentials')
  }
  if (url.search !== '') {
    throw new Error('--pair-url must not carry a query string; the instance and token live in the fragment')
  }
  const fragment = url.hash.startsWith('#') ? url.hash.slice(1) : ''
  if (fragment.length === 0) {
    throw new Error('--pair-url is missing the #instance=<64hex>&token=<43chars> fragment')
  }
  const parameters = new URLSearchParams(fragment)
  if (parameters.getAll('instance').length !== 1) {
    throw new Error('--pair-url fragment must contain exactly one instance parameter')
  }
  if (parameters.getAll('token').length !== 1) {
    throw new Error('--pair-url fragment must contain exactly one token parameter')
  }
  const instanceId = parameters.get('instance')
  if (instanceId === null || !INSTANCE_ID_PATTERN.test(instanceId)) {
    throw new Error('--pair-url instance must be 64 lowercase hex characters (SHA-256 of the CA DER)')
  }
  const token = parameters.get('token')
  if (token === null || !PAIRING_TOKEN_PATTERN.test(token)) {
    throw new Error('--pair-url token must be 43 base64url characters')
  }
  const pathname = url.pathname.replace(/\/+$/u, '')
  const hostLabel = url.host
  return {
    appUrl: `wss://${hostLabel}${pathname}/app`,
    httpBase: new URL(`https://${hostLabel}${pathname}/`),
    hostLabel,
    instanceId,
    token,
  }
}

// ---------------------------------------------------------------------------- JSON-RPC over WebSocket

/**
 * Split a ws `RawData` payload into UTF-8 text.
 * @param data - Text-frame payload.
 * @returns Decoded text.
 */
function rawDataToText(data: RawData): string {
  if (Buffer.isBuffer(data)) return data.toString('utf8')
  if (Array.isArray(data)) return Buffer.concat(data).toString('utf8')
  return Buffer.from(data).toString('utf8')
}

/** A notification waiter registered on the client. */
interface NotificationWaiter {
  readonly index: number
  readonly resolve: (value: { readonly frame: JsonObject; readonly index: number }) => void
  readonly reject: (error: Error) => void
  readonly timer: NodeJS.Timeout
}

/** One in-flight JSON-RPC request. */
interface PendingRequest {
  readonly resolve: (value: unknown) => void
  readonly reject: (error: Error) => void
  readonly timer: NodeJS.Timeout
}

/**
 * The client half of a single remote-DSH wss connection.
 *
 * Routes inbound frames per protocol §1.2: requests from the host first go to the installed
 * {@link ReverseRequestHandler} (the attachment fixture answers `native.attachments.read`) and
 * otherwise get `-32601`, which is how a forwarded host-local method surfaces; notifications are
 * buffered for waiting and observation; responses settle the matching pending request; and
 * `id: null` errors are connection-level failures. Cleanup and step assertions read the buffered
 * notifications; JSON-RPC requests are bounded by the run's overall deadline.
 */
class RemoteClient {
  private readonly socket: WebSocket
  private readonly notifications: JsonObject[] = []
  private readonly notificationHandlers = new Set<(frame: JsonObject) => void>()
  private readonly waiters: NotificationWaiter[] = []
  private readonly pending = new Map<string, PendingRequest>()
  private readonly unsupportedReverseRequests = new Set<string>()
  private readonly answeredMethods = new Set<string>()
  private closingFact: CloseFact | undefined
  private connectionFailure: Error | undefined
  private protocolViolation: Error | undefined
  private handlerFailure: Error | undefined
  private reverseHandler: ReverseRequestHandler | undefined
  private sentRequests = 0
  private reverseRequestCount = 0
  private answeredReverseRequestCount = 0

  /** @param socket - An already-open WebSocket. */
  constructor(socket: WebSocket) {
    this.socket = socket
    socket.on('message', this.onMessage)
    socket.on('close', this.onClose)
    socket.on('error', this.onError)
  }

  /** @returns Whether the underlying socket is open. */
  get isOpen(): boolean {
    return this.socket.readyState === WebSocket.OPEN
  }

  /** @returns Number of JSON-RPC requests sent so far. */
  get sentRequestCount(): number {
    return this.sentRequests
  }

  /** @returns Number of `native.*` reverse requests the host sent (all answered `-32601`). */
  get reverseRequests(): number {
    return this.reverseRequestCount
  }

  /** @returns The `native.*` methods the host attempted to forward to this device. */
  get reverseRequestMethods(): readonly string[] {
    return [...this.unsupportedReverseRequests]
  }

  /** @returns Number of reverse requests answered by the installed {@link ReverseRequestHandler}. */
  get answeredReverseRequests(): number {
    return this.answeredReverseRequestCount
  }

  /** @returns Methods answered by the installed handler; anything else reaches the `-32601` path. */
  get answeredReverseMethods(): readonly string[] {
    return [...this.answeredMethods]
  }

  /**
   * Install the handler that answers reverse requests this fake App can serve.
   *
   * Returning `false` keeps the default `-32601` answer, so methods outside the handler's contract
   * still surface as forwarded requests (§5.3).
   * @param handler - Called synchronously for each host request.
   */
  setReverseHandler(handler: ReverseRequestHandler): void {
    this.reverseHandler = handler
  }

  /**
   * Write one reverse-request success response.
   * @param id - Request id received from the host, echoed verbatim (§5.1).
   * @param result - JSON result payload.
   */
  answerReverseResult(id: string | number, result: JsonObject): void {
    this.sendFrame({ jsonrpc: '2.0', id, result })
  }

  /**
   * Write one reverse-request error response (§5.3: numeric JSON-RPC code plus structured `data`).
   * @param id - Request id received from the host, echoed verbatim.
   * @param code - Numeric JSON-RPC error code.
   * @param message - Human-readable failure message.
   * @param data - Structured payload carrying the protocol-level code.
   */
  answerReverseError(id: string | number, code: number, message: string, data: JsonObject): void {
    this.sendFrame({ jsonrpc: '2.0', id, error: { code, message, data } })
  }

  /** @returns A frame that violated protocol §1.2, when one arrived. */
  get violation(): Error | undefined {
    return this.protocolViolation
  }

  /** @returns The first notification handler failure, when one happened. */
  get notificationFailure(): Error | undefined {
    return this.handlerFailure
  }

  /** @returns Number of buffered notifications. */
  get notificationCount(): number {
    return this.notifications.length
  }

  /**
   * Read a buffered notification.
   * @param index - Zero-based position.
   * @returns The frame, or `undefined` past the end.
   */
  notificationAt(index: number): JsonObject | undefined {
    return this.notifications[index]
  }

  /**
   * Install a handler called for every inbound notification.
   * @param handler - Called synchronously in arrival order.
   * @returns Disposer removing the handler.
   */
  onNotification(handler: (frame: JsonObject) => void): () => void {
    this.notificationHandlers.add(handler)
    return () => {
      this.notificationHandlers.delete(handler)
    }
  }

  /**
   * Send a JSON-RPC request and await its result.
   * @param method - Method name.
   * @param params - `params` object.
   * @param timeoutMs - Response wait bound.
   * @param requestId - Optional explicit id (the hello frame uses `a-hello`).
   * @returns The response `result`; an error frame rejects with {@link RpcError}.
   */
  async request(method: string, params: JsonObject, timeoutMs: number, requestId: string = `a-${randomUUID()}`): Promise<unknown> {
    if (this.protocolViolation !== undefined) throw this.protocolViolation
    if (this.connectionFailure !== undefined) throw this.connectionFailure
    if (this.closingFact !== undefined) throw connectionClosedError(this.closingFact)
    if (this.socket.readyState !== WebSocket.OPEN) {
      throw new Error(`cannot send ${method}: connection is not open (readyState=${this.socket.readyState})`)
    }
    this.sentRequests += 1
    return await new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId)
        reject(new E2ETimeoutError(`${method}: no response within ${timeoutMs} ms`))
      }, timeoutMs)
      this.pending.set(requestId, {
        resolve: (value: unknown) => {
          clearTimeout(timer)
          resolve(value)
        },
        reject: (error: Error) => {
          clearTimeout(timer)
          reject(error)
        },
        timer,
      })
      try {
        this.sendFrame({ jsonrpc: '2.0', id: requestId, method, params })
      } catch (error) {
        this.pending.delete(requestId)
        clearTimeout(timer)
        reject(error instanceof Error ? error : new Error(String(error)))
      }
    })
  }

  /**
   * Wait for the next buffered notification at or after an index.
   * @param fromIndex - First buffer position to consider.
   * @param timeoutMs - Wait bound.
   * @param label - Wait description used in timeout messages.
   * @returns The notification and its buffer index.
   */
  async waitForNotification(
    fromIndex: number,
    timeoutMs: number,
    label: string,
  ): Promise<{ readonly frame: JsonObject; readonly index: number }> {
    if (this.protocolViolation !== undefined) throw this.protocolViolation
    // Frames already received stay readable even if the connection failed right after them.
    if (fromIndex < this.notifications.length) {
      const frame = this.notifications[fromIndex]
      if (frame !== undefined) return { frame, index: fromIndex }
    }
    if (this.connectionFailure !== undefined) throw this.connectionFailure
    if (this.closingFact !== undefined) throw connectionClosedError(this.closingFact)
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.removeWaiter(waiter)
        reject(new E2ETimeoutError(`timed out after ${timeoutMs} ms waiting for ${label}`))
      }, timeoutMs)
      const waiter: NotificationWaiter = { index: fromIndex, resolve, reject, timer }
      this.waiters.push(waiter)
    })
  }

  /**
   * Close the connection with a normal close code.
   * @param code - Close code to send.
   * @param reason - Short close reason.
   * @param timeoutMs - Close-handshake bound; the socket is terminated afterwards.
   * @returns The observed close fact.
   */
  async close(code: number, reason: string, timeoutMs: number): Promise<CloseFact> {
    const existing = this.closingFact
    if (existing !== undefined) return existing
    if (this.socket.readyState === WebSocket.CONNECTING) {
      this.socket.terminate()
      return { code: 1006, reason: 'aborted while connecting' }
    }
    const closed = new Promise<CloseFact>((resolve) => {
      const timer = setTimeout(() => {
        this.socket.terminate()
        resolve(this.closingFact ?? { code: 1006, reason: 'close handshake timed out' })
      }, timeoutMs)
      this.socket.once('close', () => {
        clearTimeout(timer)
        resolve(this.closingFact ?? { code: 1006, reason: 'closed without a close frame' })
      })
    })
    if (this.socket.readyState === WebSocket.OPEN) this.socket.close(code, reason)
    // CLOSING: the peer already started the close handshake; wait for it or for the bound.
    return await closed
  }

  /**
   * Write one newline-terminated JSON frame.
   * @param frame - JSON-RPC frame object.
   */
  private sendFrame(frame: JsonObject): void {
    if (this.socket.readyState !== WebSocket.OPEN) {
      throw new Error(`cannot write frame ${describeValue(frame['method'])}: connection is not open`)
    }
    this.socket.send(`${JSON.stringify(frame)}\n`, (error?: Error) => {
      if (error !== undefined && error !== null) {
        this.failEverything(new Error(`frame write failed: ${describeError(error)}`))
      }
    })
  }

  /**
   * Route one parsed inbound frame (§1.2).
   * @param frame - Parsed JSON object.
   */
  private accept(frame: JsonObject): void {
    if (frame['jsonrpc'] !== '2.0') {
      this.markViolation(`received a frame without "jsonrpc":"2.0": ${describeValue(frame)}`)
      return
    }
    const method = frame['method']
    const id = frame['id']
    if (typeof method === 'string') {
      if (typeof id === 'string' || typeof id === 'number') {
        const request: ReverseRequest = { id, method, params: asObject(frame['params']) ?? {} }
        if (this.reverseHandler !== undefined) {
          let handled: boolean
          try {
            handled = this.reverseHandler(request) === true
          } catch (error) {
            this.markViolation(`reverse request handler failed for ${method}: ${describeError(error)}`)
            return
          }
          if (handled) {
            this.answeredReverseRequestCount += 1
            this.answeredMethods.add(method)
            return
          }
        }
        this.answerUnsupported(id, method)
        return
      }
      this.notifications.push(frame)
      for (const handler of this.notificationHandlers) {
        try {
          handler(frame)
        } catch (error) {
          this.handlerFailure ??= error instanceof Error ? error : new Error(String(error))
        }
      }
      this.flushWaiters()
      return
    }
    if (id === null) {
      const info = readFrameError(frame)
      if (info === undefined) {
        this.markViolation('received a frame with id:null but no error object')
        return
      }
      this.failEverything(new RpcError(info.code, `connection-level ${formatFrameError(info)}`, info.data))
      return
    }
    if (typeof id === 'string') this.settle(id, frame)
    // A numeric response id cannot match this client's `a-<uuid>` request ids; unknown ids are
    // dropped without closing the connection (§1.2). No method and no usable id is not a
    // protocol frame either, so it is ignored as well.
  }

  /**
   * Settle one pending request with its response frame.
   * @param id - Response id.
   * @param frame - Response frame.
   */
  private settle(id: string, frame: JsonObject): void {
    const pending = this.pending.get(id)
    if (pending === undefined) return
    this.pending.delete(id)
    clearTimeout(pending.timer)
    const info = readFrameError(frame)
    if (info !== undefined) {
      pending.reject(new RpcError(info.code, formatFrameError(info), info.data))
      return
    }
    pending.resolve(frame['result'])
  }

  /**
   * Answer a reverse request the fake App cannot serve. §5.3 requires an explicit `-32601`
   * rather than a silent drop, which is also how a forwarded host-local method surfaces.
   * @param id - Request id.
   * @param method - Requested `native.*` method.
   */
  private answerUnsupported(id: string | number, method: string): void {
    this.reverseRequestCount += 1
    this.unsupportedReverseRequests.add(method)
    try {
      this.sendFrame({
        jsonrpc: '2.0',
        id,
        error: {
          code: -32601,
          message: `当前设备不支持 ${method}。`,
          data: { code: 'unsupported-method', method },
        },
      })
    } catch (error) {
      this.markViolation(`could not answer reverse request ${method}: ${describeError(error)}`)
    }
  }

  /**
   * Resolve every waiter whose index is now buffered.
   */
  private flushWaiters(): void {
    for (const waiter of [...this.waiters]) {
      if (waiter.index >= this.notifications.length) continue
      const frame = this.notifications[waiter.index]
      if (frame === undefined) continue
      this.removeWaiter(waiter)
      waiter.resolve({ frame, index: waiter.index })
    }
  }

  /**
   * Remove one waiter and clear its timer.
   * @param waiter - Waiter to remove.
   */
  private removeWaiter(waiter: NotificationWaiter): void {
    clearTimeout(waiter.timer)
    const index = this.waiters.indexOf(waiter)
    if (index >= 0) this.waiters.splice(index, 1)
  }

  /**
   * Fail pending requests, notification waiters, and future calls.
   * @param error - Failure to surface.
   */
  private failEverything(error: Error): void {
    this.connectionFailure ??= error
    for (const [id, pending] of [...this.pending]) {
      this.pending.delete(id)
      clearTimeout(pending.timer)
      pending.reject(error)
    }
    for (const waiter of this.waiters.splice(0, this.waiters.length)) {
      clearTimeout(waiter.timer)
      waiter.reject(error)
    }
  }

  /**
   * Record a host protocol violation and fail everything waiting on the connection.
   * @param message - What is wrong with the frame.
   */
  private markViolation(message: string): void {
    const error = new Error(`host protocol violation: ${message}`)
    this.protocolViolation ??= error
    this.failEverything(error)
  }

  private readonly onMessage = (data: RawData, isBinary: boolean): void => {
    if (isBinary) {
      this.markViolation('received a binary frame; protocol v1 only defines text frames')
      return
    }
    const text = rawDataToText(data)
    for (const line of text.split('\n')) {
      const trimmed = line.trim()
      if (trimmed.length === 0) continue
      let parsed: unknown
      try {
        parsed = JSON.parse(trimmed)
      } catch {
        this.markViolation(`received an unparseable line (${trimmed.length} characters)`)
        return
      }
      const frame = asObject(parsed)
      if (frame === undefined) {
        this.markViolation('received a line that is not a JSON object')
        return
      }
      this.accept(frame)
    }
  }

  private readonly onClose = (code: number, reason: Buffer): void => {
    this.closingFact = { code, reason: reason.toString('utf8') }
    this.failEverything(connectionClosedError(this.closingFact))
  }

  private readonly onError = (error: Error): void => {
    this.connectionFailure ??= new Error(`WebSocket error: ${describeError(error)}`)
    this.failEverything(this.connectionFailure)
  }
}

/**
 * Build the fake App's deterministic attachment draft bytes.
 *
 * ASCII lines keep `Buffer.byteLength(text) === text.length`, so truncating the joined lines to
 * `size` produces exactly the declared draft size the host reconciles the receipt against.
 * @param size - Exact draft size in bytes.
 * @returns Deterministic draft contents.
 */
function createAttachmentFixture(size: number): Buffer {
  const lines: string[] = []
  let length = 0
  let index = 0
  while (length < size) {
    const line = `E2E-ATTACHMENT-${String(index).padStart(4, '0')}\n`
    lines.push(line)
    length += line.length
    index += 1
  }
  return Buffer.from(lines.join(''), 'utf8').subarray(0, size)
}

/**
 * In-memory attachment drafts the fake App serves through the host-forwarded reverse request
 * `native.attachments.read` (protocol §5.2, design §3.4.2).
 *
 * Only registered draft ids are served. Any other id answers the `-32603` +
 * `data.code='attachment-file/not-found'` failure the host translates to
 * `_pocket_error.code='attachment-file/not-found'`. Requests for other methods return `false`,
 * so the default `-32601` path keeps its meaning for every other reverse request.
 */
class AttachmentFixture {
  private readonly drafts = new Map<string, Buffer>()
  private readonly servedPages: AttachmentPageRequest[] = []
  private readonly missingIds: string[] = []
  private answeredCount = 0

  /** @returns Every page served so far, in request order. */
  get pages(): readonly AttachmentPageRequest[] {
    return this.servedPages
  }

  /** @returns Draft ids the host requested without a registered draft. */
  get missingDraftIds(): readonly string[] {
    return this.missingIds
  }

  /** @returns Number of reverse requests answered with a result or an attachment error. */
  get answered(): number {
    return this.answeredCount
  }

  /**
   * Register the bytes of one draft.
   * @param id - uuid v4 the App would have produced with `attachment.pick`.
   * @param bytes - Draft contents.
   */
  register(id: string, bytes: Buffer): void {
    this.drafts.set(id, bytes)
  }

  /**
   * Forget one draft after the host released it.
   * @param id - Draft identity.
   */
  unregister(id: string): void {
    this.drafts.delete(id)
  }

  /**
   * Answer one reverse request when it is `native.attachments.read`.
   * @param request - Reverse request received from the host.
   * @param client - Connection that received it.
   * @returns `true` when this fixture wrote the response frame.
   */
  handle(request: ReverseRequest, client: RemoteClient): boolean {
    if (request.method !== ATTACHMENT_READ_METHOD) return false
    const id = request.params['id']
    const draft = typeof id === 'string' ? this.drafts.get(id) : undefined
    if (typeof id !== 'string' || draft === undefined) {
      if (typeof id === 'string') this.missingIds.push(id)
      this.answeredCount += 1
      client.answerReverseError(request.id, -32603, '手机上没有这个附件草稿。', {
        code: 'attachment-file/not-found',
      })
      return true
    }
    const offset = request.params['offset']
    const length = request.params['length']
    if (typeof offset !== 'number' || !Number.isSafeInteger(offset) || offset < 0 || offset > draft.length
      || typeof length !== 'number' || !Number.isSafeInteger(length)
      || length < 1 || length > ATTACHMENT_PAGE_BYTES) {
      this.answeredCount += 1
      client.answerReverseError(request.id, -32603, '附件读取请求无效。', {
        code: 'attachment-file/invalid-request',
      })
      return true
    }
    const end = Math.min(draft.length, offset + length)
    const page = draft.subarray(offset, end)
    const nextOffset = end
    const eof = nextOffset === draft.length
    this.servedPages.push({ id, offset, length, returnedBytes: page.length, nextOffset, eof })
    this.answeredCount += 1
    client.answerReverseResult(request.id, {
      data: page.toString('base64'),
      nextOffset,
      size: draft.length,
      eof,
    })
    return true
  }
}

/**
 * Open the wss endpoint with the pinned CA (§2.1: upgrade headers, §1.1: `/app`).
 * @param pair - Parsed pair link.
 * @param caPem - Pinned CA certificate PEM.
 * @param deviceToken - Device token from `/pair`.
 * @param timeoutMs - Upgrade bound.
 * @returns The open client.
 * @throws With the HTTP status when the host rejects the upgrade.
 */
async function connectRemoteClient(
  pair: PairLink,
  caPem: string,
  deviceToken: string,
  timeoutMs: number,
): Promise<RemoteClient> {
  return await new Promise<RemoteClient>((resolve, reject) => {
    const socket = new WebSocket(pair.appUrl, {
      // Pinning: only certificates signed by the CA fetched in the fingerprint step are accepted.
      ca: [caPem],
      headers: {
        Authorization: `Bearer ${deviceToken}`,
        Origin: REMOTE_ORIGIN,
      },
      // Protocol §1.1: no compression in v1.
      perMessageDeflate: false,
      handshakeTimeout: timeoutMs,
    })
    // ws emits 'error' as an EventEmitter event; always keep a listener so a late socket error
    // cannot surface as an uncaught exception after the connect promise settled.
    socket.on('error', () => {})
    let settled = false
    const finish = (action: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.off('open', onOpen)
      socket.off('unexpected-response', onUnexpectedResponse)
      action()
    }
    const timer = setTimeout(() => {
      finish(() => {
        socket.terminate()
        reject(new E2ETimeoutError(`wss upgrade to ${pair.appUrl} timed out after ${timeoutMs} ms`))
      })
    }, timeoutMs)
    function onOpen(): void {
      finish(() => {
        resolve(new RemoteClient(socket))
      })
    }
    function onUnexpectedResponse(request: ClientRequest, response: IncomingMessage): void {
      const status = response.statusCode ?? 0
      const settleRejection = (): void => {
        finish(() => {
          socket.terminate()
          // The rejection body is not echoed: an intermediary page could contain secret material.
          reject(new Error(`wss upgrade to ${pair.appUrl} rejected with HTTP ${status}`))
        })
      }
      response.once('end', settleRejection)
      response.once('close', settleRejection)
      response.once('error', settleRejection)
      response.resume()
      void request
    }
    socket.once('open', onOpen)
    socket.once('unexpected-response', onUnexpectedResponse)
    socket.once('error', (error: Error) => {
      finish(() => {
        reject(new Error(`wss upgrade to ${pair.appUrl} failed: ${describeError(error)}`))
      })
    })
  })
}

// ---------------------------------------------------------------------------- streams

/** Max outcome of one `api.stream` frame, reduced to what the checks need. */
interface StreamErrorInfo {
  readonly code: string
  readonly message: string
}

/**
 * Tracks one `api.subscribe` stream for window acknowledgements (§6.2).
 *
 * Every received item is acknowledged cumulatively at least every 32 frames or 200 ms, and never
 * ahead of the last received sequence. While the checks drive one frame at a time (subscription
 * setup) each frame is acknowledged immediately; the send check switches to the window cadence.
 */
class StreamTracker {
  readonly streamId: string
  private readonly client: RemoteClient
  private readonly budget: () => number
  private readonly unregister: () => void
  private maxReceivedSequence = 0
  private ackedThroughSequence = 0
  private framesSinceAck = 0
  private lastAckAt = 0
  private immediateAck = true
  private ackTimer: NodeJS.Timeout | undefined
  private readonly ackRequests = new Set<Promise<void>>()
  private ackFailure: Error | undefined
  private itemCount = 0
  private eventItemCount = 0
  private snapshotCount = 0
  private ended = false
  private streamError: StreamErrorInfo | undefined

  /**
   * @param client - Connection that receives the stream frames.
   * @param streamId - Client-generated stream id, unique per subscription attempt (§6.1).
   * @param budget - Remaining run budget in milliseconds.
   */
  constructor(client: RemoteClient, streamId: string, budget: () => number) {
    this.client = client
    this.streamId = streamId
    this.budget = budget
    this.unregister = client.onNotification((frame: JsonObject) => {
      if (frame['method'] !== 'api.stream') return
      const params = asObject(frame['params'])
      if (params === undefined || params['streamId'] !== streamId) return
      this.observe(params)
    })
  }

  /** @returns Highest sequence confirmed by the server. */
  get ackedThrough(): number {
    return this.ackedThroughSequence
  }

  /** @returns Highest sequence received from the server. */
  get receivedThrough(): number {
    return this.maxReceivedSequence
  }

  /** @returns Number of `item` frames for this stream. */
  get items(): number {
    return this.itemCount
  }

  /** @returns Number of `item` frames that carried a follow event. */
  get eventItems(): number {
    return this.eventItemCount
  }

  /** @returns Number of opening snapshots observed. */
  get snapshots(): number {
    return this.snapshotCount
  }

  /** @returns The acknowledgement failure, when one happened. */
  get failure(): Error | undefined {
    return this.ackFailure
  }

  /** @returns A description of an abnormal stream terminator, when one arrived. */
  get problem(): string | undefined {
    if (this.streamError !== undefined) {
      return `api.stream error ${this.streamError.code}: ${this.streamError.message}`
    }
    if (this.ended) return 'api.stream sent type=end before the expected evidence'
    return undefined
  }

  /** Switch from per-frame acknowledgements to the window cadence used by the send check. */
  useWindowAcknowledgement(): void {
    this.immediateAck = false
  }

  /** Send a final acknowledgement for every received sequence and wait for it to settle. */
  async finalAck(): Promise<void> {
    this.flushAck()
    await this.settle()
  }

  /** Wait for in-flight acknowledgements (bounded; the client request itself is time-boxed). */
  async settle(): Promise<void> {
    for (let round = 0; round < 4; round += 1) {
      const pending = [...this.ackRequests]
      if (pending.length === 0) return
      await Promise.allSettled(pending)
    }
  }

  /** Stop observing frames and clear the pacing timer. */
  dispose(): void {
    this.unregister()
    if (this.ackTimer !== undefined) {
      clearTimeout(this.ackTimer)
      this.ackTimer = undefined
    }
  }

  /**
   * Reduce one `api.stream` notification for this stream.
   * @param params - `params` object of the notification.
   */
  private observe(params: JsonObject): void {
    const sequence = params['sequence']
    if (typeof sequence !== 'number' || !Number.isSafeInteger(sequence) || sequence < 1) {
      this.ackFailure ??= new Error(`api.stream frame carries an invalid sequence: ${describeValue(sequence)}`)
      return
    }
    if (sequence > this.maxReceivedSequence) this.maxReceivedSequence = sequence
    this.framesSinceAck += 1
    const type = params['type']
    if (type === 'item') {
      this.itemCount += 1
      const value = asObject(params['value'])
      const valueType = value?.['type']
      if (valueType === 'snapshot') this.snapshotCount += 1
      else if (valueType === 'event') this.eventItemCount += 1
    } else if (type === 'end') {
      this.ended = true
    } else if (type === 'error') {
      const error = asObject(params['error'])
      this.streamError = {
        code: typeof error?.['code'] === 'string' ? error['code'] : 'app-stream/failed',
        message: typeof error?.['message'] === 'string' ? error['message'] : 'stream terminated without a message',
      }
    }
    this.maybeAck()
  }

  /** Acknowledge now when the cadence requires it, otherwise schedule the next flush. */
  private maybeAck(): void {
    if (this.ended || this.streamError !== undefined) return
    const now = Date.now()
    if (this.immediateAck || this.framesSinceAck >= ACK_FRAME_BUDGET || now - this.lastAckAt >= ACK_INTERVAL_MS) {
      this.flushAck()
      return
    }
    if (this.ackTimer !== undefined) return
    this.ackTimer = setTimeout(() => {
      this.ackTimer = undefined
      this.flushAck()
    }, ACK_INTERVAL_MS)
    this.ackTimer.unref()
  }

  /** Send one cumulative acknowledgement for the highest received sequence, if it is new. */
  private flushAck(): void {
    if (this.ackTimer !== undefined) {
      clearTimeout(this.ackTimer)
      this.ackTimer = undefined
    }
    if (this.ended || this.streamError !== undefined) return
    if (this.maxReceivedSequence <= this.ackedThroughSequence) return
    const upTo = this.maxReceivedSequence
    this.lastAckAt = Date.now()
    this.framesSinceAck = 0
    const timeoutMs = Math.max(500, Math.min(this.budget(), ACK_REQUEST_CAP_MS))
    let tracked: Promise<void> | undefined
    const run = async (): Promise<void> => {
      try {
        const result = await this.client.request('api.ack', { streamId: this.streamId, upTo }, timeoutMs)
        const record = asObject(result)
        if (record === undefined) {
          this.ackFailure ??= new Error(`api.ack returned a non-object result: ${describeValue(result)}`)
          return
        }
        if (record['accepted'] === true) {
          const confirmed = typeof record['upTo'] === 'number' && Number.isSafeInteger(record['upTo']) ? record['upTo'] : upTo
          if (confirmed > this.ackedThroughSequence) this.ackedThroughSequence = confirmed
          return
        }
        if (record['accepted'] === false) {
          // The stream is already gone (ended or terminated); nothing left to acknowledge.
          return
        }
        this.ackFailure ??= new Error(`api.ack returned an unexpected result: ${describeValue(record)}`)
      } catch (error) {
        this.ackFailure ??= error instanceof Error ? error : new Error(String(error))
      } finally {
        if (tracked !== undefined) this.ackRequests.delete(tracked)
      }
    }
    tracked = run()
    this.ackRequests.add(tracked)
  }
}

// ---------------------------------------------------------------------------- session helpers

/** One message-shaped `assistant/message` event's text content, if any. */
interface AssistantEventText {
  readonly text: string
  readonly seq: number | undefined
}

/**
 * Extract the text content of an `assistant/message` session event.
 *
 * The wire event is `{type, seq, time, data}` with `data.message.content` holding blocks; older
 * or flattened presentations may carry `content` or `text` directly, so both are accepted.
 * @param event - Session event object from a follow frame or `session.event` notification.
 * @returns Concatenated non-empty text, or `undefined` when the event has no text.
 */
function assistantEventText(event: JsonObject): AssistantEventText | undefined {
  const seq = typeof event['seq'] === 'number' && Number.isSafeInteger(event['seq']) ? event['seq'] : undefined
  const data = asObject(event['data'])
  const candidates: unknown[] = [data?.['message'], event['message'], data, event]
  for (const candidate of candidates) {
    const record = asObject(candidate)
    if (record === undefined) continue
    const content = record['content']
    if (Array.isArray(content)) {
      const parts: string[] = []
      for (const block of content) {
        const blockRecord = asObject(block)
        if (blockRecord === undefined) continue
        const text = blockRecord['text']
        if (blockRecord['type'] === 'text' && typeof text === 'string' && text.trim() !== '') parts.push(text)
      }
      if (parts.length > 0) return { text: parts.join(''), seq }
      continue
    }
    const text = record['text']
    if (typeof text === 'string' && text.trim() !== '') return { text, seq }
  }
  return undefined
}

/**
 * Read the value of an `api.stream` item frame for one stream.
 * @param frame - Notification frame.
 * @param streamId - Expected stream id.
 * @returns The `params.value` object when the frame is an `item` for the stream.
 */
function streamItemValue(frame: JsonObject, streamId: string): JsonObject | undefined {
  if (frame['method'] !== 'api.stream') return undefined
  const params = asObject(frame['params'])
  if (params === undefined || params['streamId'] !== streamId) return undefined
  if (params['type'] !== 'item') return undefined
  return asObject(params['value'])
}

/**
 * Read one session row's identity: `header.id` first, then a top-level `sessionId`.
 * @param row - `sessions.list` row.
 * @returns Session id when present.
 */
function sessionIdOf(row: JsonObject): string | undefined {
  const header = asObject(row['header'])
  const headerId = header?.['id']
  if (typeof headerId === 'string' && headerId.length > 0) return headerId
  const sessionId = row['sessionId']
  return typeof sessionId === 'string' && sessionId.length > 0 ? sessionId : undefined
}

/**
 * Read one session row's working directory: `header.cwd` first, then a top-level `cwd`.
 * @param row - `sessions.list` row.
 * @returns Working directory when reported.
 */
function cwdOf(row: JsonObject): string | undefined {
  const header = asObject(row['header'])
  const headerCwd = header?.['cwd']
  if (typeof headerCwd === 'string' && headerCwd.length > 0) return headerCwd
  const cwd = row['cwd']
  return typeof cwd === 'string' && cwd.length > 0 ? cwd : undefined
}

/**
 * Derive a project name from a host working directory.
 * @param cwd - Host working directory, in either separator style.
 * @returns Last path segment, or the original text for a root directory.
 */
function projectNameOf(cwd: string): string {
  const parts = cwd.replace(/[\\/]+$/u, '').split(/[\\/]/u)
  const last = parts[parts.length - 1]
  return last !== undefined && last.length > 0 ? last : cwd
}

/**
 * Flatten the structured `terminal.read` view into plain text.
 *
 * `view.lines[*].runs[*].text` is the bounded styled projection App-side code parses
 * (`apps/android/lib/terminal_screen.dart`); the terminal checks only need its visible text.
 * @param view - `terminal.read result.view` value.
 * @returns Joined line text, or an empty string for a value without lines/runs.
 */
function terminalViewText(view: unknown): string {
  const record = asObject(view)
  const lines = record?.['lines']
  if (!Array.isArray(lines)) return ''
  const text: string[] = []
  for (const line of lines) {
    const lineRecord = asObject(line)
    const runs = lineRecord?.['runs']
    if (!Array.isArray(runs)) continue
    let rendered = ''
    for (const run of runs) {
      const runRecord = asObject(run)
      if (typeof runRecord?.['text'] === 'string') rendered += runRecord['text']
    }
    text.push(rendered)
  }
  return text.join('\n')
}

/**
 * Assert one App-facing terminal row reports the expected identity and geometry.
 * @param row - `terminal.resize` result or `terminal.list` row.
 * @param id - Expected terminal identity.
 * @param cols - Expected columns.
 * @param rows - Expected rows.
 * @param label - Failure label naming the method that produced the row.
 * @throws When the id, cols, or rows differ.
 */
function assertTerminalGeometry(row: JsonObject, id: string, cols: number, rows: number, label: string): void {
  const receivedId = requireString(row['id'], `${label}.id`)
  if (receivedId !== id) throw new Error(`${label}.id: expected ${id}, received ${receivedId}`)
  const receivedCols = requireInteger(row['cols'], `${label}.cols`)
  const receivedRows = requireInteger(row['rows'], `${label}.rows`)
  if (receivedCols !== cols || receivedRows !== rows) {
    throw new Error(`${label}: expected ${cols}x${rows}, received ${receivedCols}x${receivedRows}`)
  }
}

/**
 * Close one host terminal and classify the answer.
 *
 * `terminal/unavailable` is the cleanup path's expected no-op: a terminal the controller already
 * dropped (for example when the check that created it failed before the close) needs no cleanup.
 * @param client - Open connection.
 * @param sessionId - Session owning the terminal.
 * @param id - Terminal identity returned by `terminal.create`.
 * @param timeoutMs - Response wait bound.
 * @returns `'closed'` after a `{closed:true}` result, `'already-gone'` for terminal/unavailable.
 * @throws On any other business error or when the result is not `{closed:true}`.
 */
async function closeHostTerminal(
  client: RemoteClient,
  sessionId: string,
  id: string,
  timeoutMs: number,
): Promise<'closed' | 'already-gone'> {
  const result = await client.request('terminal.close', { sessionId, id }, timeoutMs)
  const record = asObject(result)
  const pocket = record === undefined ? undefined : asObject(record['_pocket_error'])
  if (pocket !== undefined) {
    const code = typeof pocket['code'] === 'string' ? pocket['code'] : 'gateway/internal'
    const message = typeof pocket['message'] === 'string' ? pocket['message'] : 'no message'
    if (code === 'terminal/unavailable') return 'already-gone'
    throw new Error(`terminal.close failed with ${code}: ${message}`)
  }
  if (record?.['closed'] !== true) {
    throw new Error(`terminal.close result: expected {closed:true}, received ${describeValue(result)}`)
  }
  return 'closed'
}

/**
 * Release one prepared attachment draft on the host (§3.4.4: records only, no copy to delete).
 *
 * `attachments.release` is idempotent, so the cleanup path may call it even when the prepare
 * failed halfway or a later check failed.
 * @param client - Open connection.
 * @param sessionId - Session owning the draft.
 * @param id - Draft identity used in `attachments.prepare`.
 * @param timeoutMs - Response wait bound.
 * @throws On a business error or when the result is not `{released:true}`.
 */
async function releaseHostAttachment(
  client: RemoteClient,
  sessionId: string,
  id: string,
  timeoutMs: number,
): Promise<void> {
  const result = unwrapPocketError(
    await client.request('attachments.release', { sessionId, id }, timeoutMs),
    'attachments.release',
  )
  const record = requireObject(result, 'attachments.release result')
  if (record['released'] !== true) {
    throw new Error(`attachments.release result: expected {released:true}, received ${describeValue(result)}`)
  }
}

// ---------------------------------------------------------------------------- run state and checks

/** `workspaceChanges.summary` outcome: a live snapshot, or the expected degraded capability pass. */
interface WorkspaceChangesProbe {
  /** Whether the host no longer retained the probed snapshot (process-local retention). */
  readonly degraded: boolean
  /** One-line explanation carried into the human and JSON reports. */
  readonly note: string
}

/** Mutable state shared by the numbered checks. */
interface RunState {
  readonly options: CliOptions
  readonly deadline: number
  pair: PairLink | undefined
  caPem: string | undefined
  deviceId: string | undefined
  deviceToken: string | undefined
  client: RemoteClient | undefined
  tracker: StreamTracker | undefined
  hostName: string | undefined
  hostPlatform: string | undefined
  readinessSource: string | undefined
  sessions: readonly SessionSummary[]
  sessionId: string | undefined
  methods: readonly string[]
  throughSeq: number | undefined
  workspaceChangesSeq: number | undefined
  workspaceRoot: string | undefined
  workspaceChanges: WorkspaceChangesProbe | undefined
  terminalShell: TerminalShellSummary | undefined
  terminalId: string | undefined
  terminalClosed: boolean
  attachment: AttachmentProbe | undefined
  attachmentUnavailableId: string | undefined
  attachmentReleased: boolean
}

/** Stable check identity used for dependency blocking and the JSON report. */
type CheckId =
  | 'parse-link'
  | 'ca-fingerprint'
  | 'pair'
  | 'pair-single-use'
  | 'ws-upgrade'
  | 'hello'
  | 'host-ready'
  | 'model-catalog'
  | 'read-window'
  | 'workspace-files-list'
  | 'workspace-files-read'
  | 'workspace-changes-summary'
  | 'terminal-shells'
  | 'terminal-error-translation'
  | 'terminal-create-write-read'
  | 'terminal-resize-list-rename-close'
  | 'attachments-prepare-file'
  | 'attachments-error-not-found'
  | 'attachments-send'
  | 'subscribe'
  | 'send'
  | 'native-local'
  | 'cleanup'

/** One check in the run plan. */
interface CheckDefinition {
  readonly id: CheckId
  readonly name: string
  readonly requires: readonly CheckId[]
  readonly run: () => Promise<string>
}

/** One finished check. */
interface CheckResult {
  readonly id: CheckId
  readonly index: number
  readonly total: number
  readonly name: string
  readonly status: 'PASS' | 'FAIL'
  readonly detail: string
  readonly durationMs: number
}

/**
 * Remaining run budget.
 * @param state - Run state.
 * @returns Milliseconds left, never negative.
 */
function remainingMs(state: RunState): number {
  return Math.max(0, state.deadline - Date.now())
}

/**
 * Remaining run budget, or a timeout failure when the whole run is out of time.
 * @param state - Run state.
 * @param action - What the budget is for.
 * @returns Milliseconds left.
 * @throws {@link E2ETimeoutError} when the overall deadline has passed.
 */
function requireBudget(state: RunState, action: string): number {
  const remaining = remainingMs(state)
  if (remaining <= 0) {
    throw new E2ETimeoutError(`overall timeout (${state.options.timeoutMs} ms) reached before ${action}`)
  }
  return remaining
}

/**
 * Read the host's default model route from `settings.describe` (§3.5).
 *
 * `session.send` requires an explicit provider/model pair; both the send check and the
 * attachment-send check reuse the host default route so the E2E never hardcodes a provider.
 * @param client - Open connection.
 * @param state - Run state.
 * @returns Provider and model names.
 * @throws When the form is absent or malformed.
 */
async function readDefaultModelRoute(
  client: RemoteClient,
  state: RunState,
): Promise<{ readonly provider: string; readonly model: string }> {
  const forms = requireArray(
    unwrapPocketError(
      await client.request('settings.describe', {}, requireBudget(state, 'settings.describe')),
      'settings.describe',
    ),
    'settings.describe result',
  )
  for (const form of forms) {
    const record = asObject(form)
    if (record?.['ns'] !== 'agent-default-model') continue
    const value = requireObject(record['value'], 'settings.describe agent-default-model form.value')
    return {
      provider: requireString(value['provider'], 'settings.describe agent-default-model value.provider'),
      model: requireString(value['model'], 'settings.describe agent-default-model value.model'),
    }
  }
  throw new Error('settings.describe: no agent-default-model form with a provider/model route (required by session.send)')
}

/**
 * Wait for the host readiness notification (§3.4).
 *
 * The host replays its last `runtime.status` on every new connection and translates the facade's
 * `runtime.ready` signal into `runtime.status {phase:"ready"}`; both are accepted here.
 * @param client - Open connection.
 * @param state - Run state.
 * @returns Which notification proved readiness.
 */
async function waitForReadiness(client: RemoteClient, state: RunState): Promise<string> {
  let cursor = 0
  let lastPhase = 'none'
  for (;;) {
    let next: { readonly frame: JsonObject; readonly index: number }
    try {
      next = await client.waitForNotification(
        cursor,
        requireBudget(state, 'host readiness'),
        'runtime.status phase=ready',
      )
    } catch (error) {
      if (error instanceof E2ETimeoutError) {
        throw new E2ETimeoutError(`${error.message}; last observed runtime.status phase=${lastPhase}`)
      }
      throw error
    }
    cursor = next.index + 1
    const method = next.frame['method']
    const params = asObject(next.frame['params'])
    if (method === 'runtime.status') {
      const phase = params?.['phase']
      lastPhase = typeof phase === 'string' ? phase : 'malformed'
      if (phase === 'ready') return 'runtime.status phase=ready'
      if (phase === 'failed') {
        const reason = typeof params?.['error'] === 'string' ? params['error'] : 'no error detail'
        throw new Error(`host reported runtime.status phase=failed: ${reason}`)
      }
      continue
    }
    if (method === 'runtime.ready') return 'runtime.ready notification'
  }
}

/**
 * Subscribe to the session follow stream, tolerating both wire `args` shapes.
 *
 * `apps/android/runtime/index.mjs` dispatches `session.follow` through the typert gateway, whose
 * generated namespace takes the method parameter as `args.request` (the App sends
 * `{request:{address}}`). A host revision that unwraps the request may instead accept
 * `{address}` directly, so the flat shape is retried once with a fresh stream id (§6.1: a stream
 * id is never reused) when the first shape is rejected.
 * @param client - Open connection.
 * @param sessionId - Session to follow.
 * @param state - Run state.
 * @returns The tracker, chosen stream id, generation, and the accepted `args` shape.
 */
async function subscribeSessionFollow(
  client: RemoteClient,
  sessionId: string,
  state: RunState,
): Promise<{
  readonly tracker: StreamTracker
  readonly streamId: string
  readonly generation: string
  readonly argumentShape: 'request' | 'flat'
}> {
  const attempts: readonly { readonly shape: 'request' | 'flat'; readonly args: JsonObject }[] = [
    { shape: 'request', args: { request: { address: { kind: 'session', sessionId }, activate: true } } },
    { shape: 'flat', args: { address: { kind: 'session', sessionId } } },
  ]
  const failures: string[] = []
  for (const [position, attempt] of attempts.entries()) {
    const streamId = `stream-e2e-${randomUUID().replaceAll('-', '')}`
    const tracker = new StreamTracker(client, streamId, () => remainingMs(state))
    try {
      const result = unwrapPocketError(
        await client.request(
          'api.subscribe',
          { streamId, namespace: 'session', method: 'follow', args: attempt.args },
          requireBudget(state, 'api.subscribe'),
        ),
        'api.subscribe',
      )
      const record = requireObject(result, 'api.subscribe result')
      const returnedStreamId = requireString(record['streamId'], 'api.subscribe result.streamId')
      if (returnedStreamId !== streamId) {
        throw new Error(`api.subscribe result.streamId: expected ${streamId}, received ${returnedStreamId}`)
      }
      const generation = requireString(record['generation'], 'api.subscribe result.generation')
      return { tracker, streamId, generation, argumentShape: attempt.shape }
    } catch (error) {
      tracker.dispose()
      failures.push(`${attempt.shape} args: ${describeError(error)}`)
      const lastAttempt = position === attempts.length - 1
      // A rejected request may mean the host wants the other wire shape; anything else
      // (connection loss, timeout, malformed success result) is not worth a second stream.
      if (lastAttempt || !(error instanceof RpcError)) {
        throw new Error(`api.subscribe (session.follow) failed: ${failures.join(' | ')}`)
      }
    }
  }
  throw new Error(`api.subscribe (session.follow) failed: ${failures.join(' | ')}`)
}

/**
 * Collect assistant streaming evidence after `session.send` (§4.1 frames, follow stream, notifications).
 *
 * Waits until both an assistant message and an earlier incremental signal were observed, then
 * reports what proved the round trip. Timeout failures name the missing evidence and the signals
 * that were observed.
 * @param client - Open connection.
 * @param tracker - Follow stream tracker.
 * @param sessionId - Session that was prompted.
 * @param fromIndex - Notification index captured right before `session.send`.
 * @param state - Run state.
 * @returns Evidence counters for the check detail.
 */
async function collectAssistantEvidence(
  client: RemoteClient,
  tracker: StreamTracker,
  sessionId: string,
  fromIndex: number,
  state: RunState,
): Promise<{
  readonly assistantSource: 'api.stream' | 'session.event'
  readonly assistantTextLength: number
  readonly streamUserMessages: number
  readonly sessionEventNotifications: number
  readonly sessionLiveNotifications: number
  readonly incrementalSignals: number
}> {
  let cursor = fromIndex
  let incremental = 0
  let streamUserMessages = 0
  let sessionEvents = 0
  let sessionLive = 0
  let assistantSource: 'api.stream' | 'session.event' | undefined
  let assistantTextLength = 0
  let incrementalBeforeAssistant = false
  const startedAt = Date.now()
  while (assistantSource === undefined || !incrementalBeforeAssistant) {
    let next: { readonly frame: JsonObject; readonly index: number }
    try {
      next = await client.waitForNotification(
        cursor,
        requireBudget(state, 'assistant streaming evidence'),
        'assistant message after session.send',
      )
    } catch (error) {
      const observed = [
        `api.stream items=${tracker.items} (event items=${tracker.eventItems})`,
        `session.event notifications=${sessionEvents}`,
        `session.live notifications=${sessionLive}`,
        `incremental signals=${incremental}`,
      ].join(', ')
      const problem = tracker.problem
      const suffix = problem === undefined ? '' : `; follow stream problem: ${problem}`
      if (error instanceof E2ETimeoutError) {
        const missing = assistantSource !== undefined
          ? 'an incremental signal before the assistant message (stream user/message, session.event, or session.live)'
          : 'an assistant/message evidence frame (api.stream item or session.event)'
        throw new E2ETimeoutError(
          `timed out after ${Date.now() - startedAt} ms waiting for ${missing}; observed ${observed}${suffix}`,
        )
      }
      throw error
    }
    cursor = next.index + 1
    const frame = next.frame
    const method = frame['method']
    if (method === 'api.stream') {
      const value = streamItemValue(frame, tracker.streamId)
      const event = value?.['type'] === 'event' ? asObject(value['event']) : undefined
      const eventType = event?.['type']
      if (eventType === 'user/message') {
        incremental += 1
        streamUserMessages += 1
        continue
      }
      if (eventType === 'assistant/message') {
        const text = assistantEventText(event ?? {})
        if (text === undefined || assistantSource !== undefined) continue
        assistantSource = 'api.stream'
        assistantTextLength = text.text.length
        incrementalBeforeAssistant = incremental > 0
      }
      continue
    }
    if (method === 'session.event') {
      const params = asObject(frame['params'])
      if (params === undefined || params['sessionId'] !== sessionId) continue
      const event = asObject(params['event'])
      if (event === undefined) continue
      const eventType = event['type']
      // The assistant evidence is evaluated before this frame contributes its own incremental
      // signal, so "at least one incremental signal before the final assistant message" holds.
      if (eventType === 'assistant/message' && assistantSource === undefined) {
        assistantSource = 'session.event'
        assistantTextLength = assistantEventText(event)?.text.length ?? 0
        incrementalBeforeAssistant = incremental > 0
      }
      incremental += 1
      sessionEvents += 1
      continue
    }
    if (method === 'session.live') {
      const params = asObject(frame['params'])
      if (params === undefined || params['sessionId'] !== sessionId) continue
      incremental += 1
      sessionLive += 1
    }
  }
  return {
    assistantSource: assistantSource ?? 'session.event',
    assistantTextLength,
    streamUserMessages,
    sessionEventNotifications: sessionEvents,
    sessionLiveNotifications: sessionLive,
    incrementalSignals: incremental,
  }
}

/** One notification read from the client buffer with its buffer index. */
interface BufferedNotification {
  /** Parsed JSON-RPC notification frame. */
  readonly frame: JsonObject
  /** Zero-based position in the client's notification buffer. */
  readonly index: number
}

/**
 * Recompute one frame's wire size with the §1.3 counting rule.
 * @param frame - Parsed frame.
 * @returns UTF-8 byte count of `JSON.stringify(frame)`, including `jsonrpc`/`method`/`params`.
 */
function frameWireBytes(frame: JsonObject): number {
  return Buffer.byteLength(JSON.stringify(frame), 'utf8')
}

/**
 * Read the first buffered notification at or after an index matching a predicate.
 * @param client - Open connection.
 * @param fromIndex - First buffer position to consider.
 * @param predicate - Frame test.
 * @returns The matching frame and index, or `undefined`.
 */
function findBufferedNotification(
  client: RemoteClient,
  fromIndex: number,
  predicate: (frame: JsonObject) => boolean,
): BufferedNotification | undefined {
  for (let index = fromIndex; index < client.notificationCount; index += 1) {
    const frame = client.notificationAt(index)
    if (frame !== undefined && predicate(frame)) return { frame, index }
  }
  return undefined
}

/**
 * Wait for the next buffered notification matching a predicate, bounded by its own deadline.
 *
 * Unlike {@link RemoteClient.waitForNotification} this reports a timeout as `undefined` instead of
 * throwing, because the §8 push observation degrades to a SKIP note when its trigger never fires.
 * @param client - Open connection.
 * @param fromIndex - First buffer position to consider.
 * @param timeoutMs - Wait bound.
 * @param label - Wait description used only in the internal `waitForNotification` call.
 * @param predicate - Frame test.
 * @returns The matching frame and index, or `undefined` on timeout.
 */
async function waitForBufferedNotification(
  client: RemoteClient,
  fromIndex: number,
  timeoutMs: number,
  label: string,
  predicate: (frame: JsonObject) => boolean,
): Promise<BufferedNotification | undefined> {
  const deadline = Date.now() + Math.max(0, timeoutMs)
  let cursor = fromIndex
  for (;;) {
    const remaining = deadline - Date.now()
    if (remaining <= 0) return undefined
    let next: { readonly frame: JsonObject; readonly index: number }
    try {
      next = await client.waitForNotification(cursor, remaining, label)
    } catch (error) {
      if (error instanceof E2ETimeoutError) return undefined
      throw error
    }
    cursor = next.index + 1
    if (predicate(next.frame)) return { frame: next.frame, index: next.index }
  }
}

/**
 * Validate one optional string field of a §8 notification.
 * @param params - Notification `params`.
 * @param key - Field name.
 * @param maxChars - Protocol character limit.
 * @param required - Whether the field is mandatory.
 * @param label - Notification method name used in failures.
 * @param problems - Collector for failure descriptions.
 */
function validateRemoteString(
  params: JsonObject,
  key: string,
  maxChars: number,
  required: boolean,
  label: string,
  problems: string[],
): void {
  const value = params[key]
  if (value === undefined) {
    if (required) problems.push(`${label}: missing required "${key}"`)
    return
  }
  if (typeof value !== 'string' || value.length === 0) {
    problems.push(`${label}.${key}: expected a non-empty string, received ${describeValue(value)}`)
    return
  }
  const characters = [...value].length
  if (characters > maxChars) problems.push(`${label}.${key}: ${characters} characters, over the ${maxChars}-character limit`)
  if (/[\r\n]/u.test(value)) problems.push(`${label}.${key}: must be a single line`)
}

/**
 * Validate one optional integer field of a §8 notification.
 * @param params - Notification `params`.
 * @param key - Field name.
 * @param minimum - Smallest accepted value.
 * @param required - Whether the field is mandatory.
 * @param label - Notification method name used in failures.
 * @param problems - Collector for failure descriptions.
 */
function validateRemoteInteger(
  params: JsonObject,
  key: string,
  minimum: number,
  required: boolean,
  label: string,
  problems: string[],
): void {
  const value = params[key]
  if (value === undefined) {
    if (required) problems.push(`${label}: missing required "${key}"`)
    return
  }
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < minimum) {
    problems.push(`${label}.${key}: expected a safe integer >= ${minimum}, received ${describeValue(value)}`)
  }
}

/**
 * Validate one optional boolean field of a §8 notification.
 * @param params - Notification `params`.
 * @param key - Field name.
 * @param label - Notification method name used in failures.
 * @param problems - Collector for failure descriptions.
 */
function validateRemoteBoolean(params: JsonObject, key: string, label: string, problems: string[]): void {
  const value = params[key]
  if (value !== undefined && typeof value !== 'boolean') {
    problems.push(`${label}.${key}: expected a boolean, received ${describeValue(value)}`)
  }
}

/**
 * Validate one inbound `remote.*` notification against the frozen §8 field tables.
 *
 * The check mirrors the App's minimum requirements: notification frames carry no `id`; every field
 * is bounded; enums only take their frozen values; and the whole frame stays inside its §8 byte
 * limit. Unknown `remote.*` methods fail because v1 lists exactly four (§8.2–§8.5).
 * @param frame - Buffered notification frame.
 * @returns Problems; empty when the frame is a valid §8 notification.
 */
function validateRemoteNotification(frame: JsonObject): string[] {
  const problems: string[] = []
  const method = frame['method']
  if (typeof method !== 'string') return ['notification frame without a string method']
  if (frame['jsonrpc'] !== '2.0') problems.push(`${method}: expected jsonrpc "2.0"`)
  if (frame['id'] !== undefined) problems.push(`${method}: a notification frame must not carry an id (§8.1)`)
  const params = asObject(frame['params'])
  if (params === undefined) {
    problems.push(`${method}: expected an object params`)
    return problems
  }
  const limit = REMOTE_FRAME_LIMIT_BYTES[method]
  if (limit === undefined) {
    problems.push(`${method}: not one of the protocol §8 notification methods`)
    return problems
  }
  const bytes = frameWireBytes(frame)
  if (bytes > limit) problems.push(`${method}: frame is ${bytes} bytes, over the ${limit}-byte limit`)
  switch (method) {
    case 'remote.taskCompleted':
      validateRemoteString(params, 'taskId', REMOTE_FIELD_LIMITS.id, true, method, problems)
      validateRemoteString(params, 'sessionId', REMOTE_FIELD_LIMITS.id, true, method, problems)
      validateRemoteString(params, 'workspaceId', REMOTE_FIELD_LIMITS.id, false, method, problems)
      validateRemoteString(params, 'title', REMOTE_FIELD_LIMITS.title, true, method, problems)
      validateRemoteString(params, 'summary', REMOTE_FIELD_LIMITS.taskSummary, false, method, problems)
      validateRemoteInteger(params, 'turn', 0, false, method, problems)
      validateRemoteInteger(params, 'completedAt', 1, true, method, problems)
      validateRemoteBoolean(params, 'truncated', method, problems)
      if (typeof params['status'] !== 'string' || !REMOTE_TASK_STATUSES.includes(params['status'])) {
        problems.push(`${method}.status: expected one of ${REMOTE_TASK_STATUSES.join('/')}, received ${describeValue(params['status'])}`)
      }
      break
    case 'remote.approvalPending':
      validateRemoteString(params, 'interactionId', REMOTE_FIELD_LIMITS.id, true, method, problems)
      validateRemoteString(params, 'sessionId', REMOTE_FIELD_LIMITS.id, true, method, problems)
      validateRemoteString(params, 'title', REMOTE_FIELD_LIMITS.title, true, method, problems)
      validateRemoteString(params, 'summary', REMOTE_FIELD_LIMITS.approvalSummary, false, method, problems)
      validateRemoteString(params, 'toolName', REMOTE_FIELD_LIMITS.id, false, method, problems)
      validateRemoteInteger(params, 'createdAt', 1, true, method, problems)
      validateRemoteBoolean(params, 'truncated', method, problems)
      if (typeof params['kind'] !== 'string' || !REMOTE_APPROVAL_KINDS.includes(params['kind'])) {
        problems.push(`${method}.kind: expected one of ${REMOTE_APPROVAL_KINDS.join('/')}, received ${describeValue(params['kind'])}`)
      }
      break
    case 'remote.deviceRevoked':
      validateRemoteString(params, 'deviceId', REMOTE_FIELD_LIMITS.id, true, method, problems)
      validateRemoteString(params, 'deviceLabel', REMOTE_FIELD_LIMITS.id, false, method, problems)
      validateRemoteInteger(params, 'revokedAt', 1, true, method, problems)
      if (typeof params['reason'] !== 'string' || !REMOTE_REVOKE_REASONS.includes(params['reason'])) {
        problems.push(`${method}.reason: expected one of ${REMOTE_REVOKE_REASONS.join('/')}, received ${describeValue(params['reason'])}`)
      }
      break
    case 'remote.sessionChanged':
      validateRemoteString(params, 'sessionId', REMOTE_FIELD_LIMITS.id, true, method, problems)
      validateRemoteString(params, 'workspaceId', REMOTE_FIELD_LIMITS.id, false, method, problems)
      validateRemoteString(params, 'title', REMOTE_FIELD_LIMITS.title, false, method, problems)
      validateRemoteInteger(params, 'revision', 0, true, method, problems)
      validateRemoteInteger(params, 'updatedAt', 1, true, method, problems)
      validateRemoteBoolean(params, 'archived', method, problems)
      validateRemoteBoolean(params, 'removed', method, problems)
      break
    default:
      break
  }
  return problems
}

/**
 * Observe and validate the §8 system-notification line caused by the send check.
 *
 * The page line `task.completed` is the trigger for the mapped `remote.taskCompleted`; once it is
 * observed the mapped frame is required and validated strictly. When the runtime never emits the
 * trigger (it suppresses completion notices for turns it cannot confirm as completed, for example
 * while a goal is active) the observation degrades to a SKIP note instead of failing the run;
 * `§8.2` field mapping itself is covered keylessly by `notification-selfcheck.ts`.
 * @param client - Open connection.
 * @param sessionId - Session that was prompted.
 * @param fromIndex - Notification index captured right before `session.send`.
 * @param timeoutMs - Observation bound.
 * @returns One detail line for the check report.
 */
async function observeRemoteTaskCompleted(
  client: RemoteClient,
  sessionId: string,
  fromIndex: number,
  timeoutMs: number,
): Promise<string> {
  const isTrigger = (frame: JsonObject): boolean =>
    frame['method'] === 'task.completed' && asObject(frame['params'])?.['sessionId'] === sessionId
  const isPush = (frame: JsonObject): boolean =>
    frame['method'] === 'remote.taskCompleted' && asObject(frame['params'])?.['sessionId'] === sessionId
  const deadline = Date.now() + Math.max(1_000, timeoutMs)
  let cursor = fromIndex
  let triggerSeen = false
  for (;;) {
    const remaining = deadline - Date.now()
    if (remaining <= 0) break
    const next = await waitForBufferedNotification(
      client,
      cursor,
      remaining,
      'task.completed / remote.taskCompleted',
      frame => isTrigger(frame) || isPush(frame),
    )
    if (next === undefined) break
    cursor = next.index + 1
    if (isTrigger(next.frame)) {
      triggerSeen = true
      continue
    }
    const problems = validateRemoteNotification(next.frame)
    if (problems.length > 0) {
      throw new Error(`remote.taskCompleted violates protocol §8.2: ${problems.join('; ')}`)
    }
    if (!triggerSeen && findBufferedNotification(client, fromIndex, isTrigger) === undefined) {
      throw new Error('remote.taskCompleted arrived without a page-line task.completed trigger')
    }
    const params = asObject(next.frame['params']) ?? {}
    const title = requireString(params['title'], 'remote.taskCompleted.title')
    const bytes = frameWireBytes(next.frame)
    const truncated = params['truncated'] === true
    return `remote.taskCompleted matches §8.2 (${bytes} bytes, title=${[...title].length} chars, `
      + `turn=${describeValue(params['turn'])}, truncated=${truncated}); page line task.completed observed`
  }
  if (triggerSeen) {
    throw new Error(
      `page line task.completed was observed but the mapped remote.taskCompleted did not follow within ${timeoutMs} ms`,
    )
  }
  return `SKIP remote.taskCompleted: page line task.completed for session ${sessionId} not observed within ${timeoutMs} ms `
    + '(the runtime suppresses it for turns it cannot confirm as completed, e.g. an active goal); '
    + '§8.2 field mapping is covered by notification-selfcheck.ts'
}


/**
 * Run one check, converting failures and blocked prerequisites into a result.
 * @param check - Check definition.
 * @param index - One-based position in the plan.
 * @param total - Plan length.
 * @param completed - Results already finished, by id.
 * @returns The check result.
 */
async function runCheck(
  check: CheckDefinition,
  index: number,
  total: number,
  completed: ReadonlyMap<CheckId, CheckResult>,
): Promise<CheckResult> {
  const startedAt = Date.now()
  const blocked: CheckResult[] = []
  for (const requirement of check.requires) {
    const result = completed.get(requirement)
    if (result !== undefined && result.status !== 'PASS') blocked.push(result)
  }
  if (blocked.length > 0) {
    const blocker = blocked[0]
    let detail = 'blocked by an earlier check'
    if (blocker !== undefined) {
      // Name the failing prerequisite; only carry its detail when it is the original failure,
      // so a single root cause does not repeat through every dependent check.
      detail = `blocked by check ${blocker.index} (${blocker.name})`
      if (!blocker.detail.startsWith('blocked by ')) detail += `: ${truncate(blocker.detail, 240)}`
    }
    return {
      id: check.id,
      index,
      total,
      name: check.name,
      status: 'FAIL',
      detail,
      durationMs: Date.now() - startedAt,
    }
  }
  try {
    const detail = await check.run()
    return { id: check.id, index, total, name: check.name, status: 'PASS', detail, durationMs: Date.now() - startedAt }
  } catch (error) {
    return {
      id: check.id,
      index,
      total,
      name: check.name,
      status: 'FAIL',
      detail: describeError(error),
      durationMs: Date.now() - startedAt,
    }
  }
}

// ---------------------------------------------------------------------------- checks

/**
 * Build the ordered check plan for this run.
 * @param state - Shared run state.
 * @returns The checks; the send check exists only when `--send` was supplied.
 */
function buildChecks(state: RunState): CheckDefinition[] {
  const options = state.options
  // The fake App's draft store: attachment checks register deterministic bytes, the reverse
  // handler serves them page by page, and cleanup releases the host-side records.
  const attachmentFixture = new AttachmentFixture()
  const parseLink: CheckDefinition = {
    id: 'parse-link',
    name: 'Parse pair link',
    requires: [],
    run: async () => {
      const pair = parsePairLink(options.pairUrl)
      state.pair = pair
      return `pair link parsed: ${pair.appUrl} (host ${pair.hostLabel}), instance ${pair.instanceId.slice(0, 12)}…, token 43 chars`
    },
  }
  const caFingerprint: CheckDefinition = {
    id: 'ca-fingerprint',
    name: 'GET /ca.cer CA fingerprint',
    requires: ['parse-link'],
    run: async () => {
      const pair = requireState(state.pair, 'pair link')
      const url = new URL('ca.cer', pair.httpBase)
      const response = await httpsRequestWith(url, {
        method: 'GET',
        timeoutMs: Math.min(requireBudget(state, 'GET /ca.cer'), HTTP_CAP_MS),
      })
      if (response.status !== 200) {
        throw new Error(`GET /ca.cer: expected HTTP 200, received ${response.status}`)
      }
      let certificate: X509Certificate
      try {
        certificate = new X509Certificate(response.body)
      } catch (error) {
        throw new Error(`GET /ca.cer: body is not a valid X.509 certificate (${describeError(error)})`)
      }
      const looksPem = response.body.toString('utf8').includes('-----BEGIN CERTIFICATE-----')
      const der = certificate.raw
      const fingerprint = sha256Hex(der)
      if (fingerprint !== pair.instanceId) {
        throw new Error(
          `GET /ca.cer: SHA-256 expected ${pair.instanceId}, received ${fingerprint} (${looksPem ? 'PEM' : 'DER'} ${der.length} bytes)`,
        )
      }
      state.caPem = certificate.toString()
      const contentType = String(response.headers['content-type'] ?? '')
      const source = looksPem ? 'PEM-parsed' : 'DER'
      return `HTTP 200${contentType === '' ? '' : ` (${contentType})`}, ${der.length}-byte ${source} certificate, `
        + `sha256=${fingerprint.slice(0, 16)}… matches instanceId`
    },
  }
  const pair: CheckDefinition = {
    id: 'pair',
    name: 'POST /pair device pairing',
    requires: ['parse-link'],
    run: async () => {
      const link = requireState(state.pair, 'pair link')
      const requestPayload = JSON.stringify({ token: link.token, deviceLabel: DEVICE_LABEL, appVersion: APP_VERSION })
      const requestBytes = Buffer.byteLength(requestPayload, 'utf8')
      if (requestBytes >= MAX_PAIR_REQUEST_BYTES) {
        throw new Error(`POST /pair: request body must stay under 64 KiB, built ${requestBytes} bytes`)
      }
      const response = await httpsRequestWith(new URL('pair', link.httpBase), {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'content-length': String(requestBytes),
        },
        body: requestPayload,
        timeoutMs: Math.min(requireBudget(state, 'POST /pair'), HTTP_CAP_MS),
      })
      if (response.status !== 200) {
        throw new Error(`POST /pair: expected HTTP 200, received ${response.status}`)
      }
      let parsedBody: unknown
      try {
        parsedBody = JSON.parse(response.body.toString('utf8'))
      } catch {
        // Deliberately does not echo the body: a broken response could contain secret material.
        throw new Error('POST /pair: response is not valid JSON')
      }
      const parsed = asObject(parsedBody)
      if (parsed === undefined) throw new Error('POST /pair: response is not a JSON object')
      const deviceId = requireString(parsed['deviceId'], 'POST /pair response.deviceId')
      // The device token is a secret: validate it without ever echoing its value.
      const tokenValue = parsed['deviceToken']
      if (typeof tokenValue !== 'string') {
        throw new Error('POST /pair response.deviceToken: expected a string')
      }
      if (!DEVICE_TOKEN_PATTERN.test(tokenValue)) {
        throw new Error(`POST /pair response.deviceToken: expected 43 base64url characters, received ${tokenValue.length} characters`)
      }
      const deviceToken = tokenValue
      const expiresAt = requireInteger(parsed['expiresAt'], 'POST /pair response.expiresAt')
      if (expiresAt <= Date.now()) {
        throw new Error(`POST /pair response.expiresAt: expected a future timestamp, received ${new Date(expiresAt).toISOString()}`)
      }
      state.deviceId = deviceId
      state.deviceToken = deviceToken
      return `HTTP 200, deviceId=${deviceId}, deviceToken 43 chars, expiresAt=${new Date(expiresAt).toISOString()}`
    },
  }
  const pairSingleUse: CheckDefinition = {
    id: 'pair-single-use',
    name: 'Pairing token single use',
    requires: ['pair'],
    run: async () => {
      const link = requireState(state.pair, 'pair link')
      const requestPayload = JSON.stringify({ token: link.token, deviceLabel: DEVICE_LABEL, appVersion: APP_VERSION })
      const response = await httpsRequestWith(new URL('pair', link.httpBase), {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'content-length': String(Buffer.byteLength(requestPayload, 'utf8')),
        },
        body: requestPayload,
        timeoutMs: Math.min(requireBudget(state, 'pairing-token reuse'), HTTP_CAP_MS),
      })
      if (response.status !== 401 && response.status !== 403) {
        throw new Error(`POST /pair with the already-used token: expected HTTP 401 or 403, received ${response.status}`)
      }
      return `second POST /pair rejected with HTTP ${response.status} (single-use enforced)`
    },
  }
  const wsUpgrade: CheckDefinition = {
    id: 'ws-upgrade',
    name: 'wss /app upgrade with pinned CA',
    requires: ['pair', 'ca-fingerprint'],
    run: async () => {
      const link = requireState(state.pair, 'pair link')
      const caPem = requireState(state.caPem, 'pinned CA certificate')
      const deviceToken = requireState(state.deviceToken, 'device token')
      const timeoutMs = Math.min(requireBudget(state, 'wss upgrade'), WS_OPEN_CAP_MS)
      const client = await connectRemoteClient(link, caPem, deviceToken, timeoutMs)
      // The fake App answers the design's forwarded attachment-read method; every other reverse
      // request keeps the §5.3 default `-32601` answer.
      client.setReverseHandler(request => attachmentFixture.handle(request, client))
      state.client = client
      return `wss ${link.appUrl} upgraded; certificate chain verified against the pinned CA; Origin and Bearer accepted`
    },
  }
  const hello: CheckDefinition = {
    id: 'hello',
    name: 'protocol.hello handshake',
    requires: ['ws-upgrade'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      if (client.sentRequestCount !== 0) {
        throw new Error(`protocol.hello must be the connection's first frame, but ${client.sentRequestCount} request(s) were already sent`)
      }
      const result = unwrapPocketError(
        await client.request(
          'protocol.hello',
          {
            protocolVersion: PROTOCOL_VERSION,
            appVersion: APP_VERSION,
            deviceLabel: DEVICE_LABEL,
            capabilities: ['window-ack'],
          },
          requireBudget(state, 'protocol.hello'),
          'a-hello',
        ),
        'protocol.hello',
      )
      const record = requireObject(result, 'protocol.hello result')
      const version = record['protocolVersion']
      if (version !== PROTOCOL_VERSION) {
        throw new Error(`protocol.hello result.protocolVersion: expected ${PROTOCOL_VERSION}, received ${describeValue(version)}`)
      }
      const host = requireObject(record['host'], 'protocol.hello result.host')
      const hostName = requireString(host['name'], 'protocol.hello result.host.name')
      const hostPlatform = requireString(host['platform'], 'protocol.hello result.host.platform')
      const methods = requireArray(record['methods'], 'protocol.hello result.methods')
        .map(entry => requireString(entry, 'protocol.hello result.methods entry'))
      if (methods.length === 0) {
        throw new Error('protocol.hello result.methods: expected a non-empty array, received []')
      }
      // The client cannot tell a facade-declared table from the host fallback (the host logs
      // `methods-fallback` instead); these names are the §4.2 surface every declaration covers.
      for (const required of REQUIRED_METHODS) {
        if (!methodsCover(methods, required)) {
          throw new Error(`protocol.hello result.methods: missing coverage for ${required} (${methods.length} entries)`)
        }
      }
      state.methods = methods
      const unsupported = requireArray(record['unsupported'], 'protocol.hello result.unsupported')
        .map(entry => requireString(entry, 'protocol.hello result.unsupported entry'))
      if (!unsupported.includes('documents.*')) {
        throw new Error(`protocol.hello result.unsupported: expected to include documents.*, received ${describeValue(unsupported)}`)
      }
      const capabilities = requireArray(record['capabilities'], 'protocol.hello result.capabilities')
        .map(entry => requireString(entry, 'protocol.hello result.capabilities entry'))
      if (!capabilities.includes('window-ack')) {
        throw new Error(`protocol.hello result.capabilities: expected to include window-ack, received ${describeValue(capabilities)}`)
      }
      state.hostName = hostName
      state.hostPlatform = hostPlatform
      return [
        'protocolVersion=1',
        `host=${hostName} (${hostPlatform})`,
        `methods=${methods.length} covering all ${REQUIRED_METHODS.length} required names`,
        'unsupported includes documents.*',
        'capabilities includes window-ack',
      ].join('; ')
    },
  }
  const hostReady: CheckDefinition = {
    id: 'host-ready',
    name: 'Host readiness, runtime.info, sessions.list',
    requires: ['hello'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const readiness = await waitForReadiness(client, state)
      state.readinessSource = readiness
      const info = requireObject(
        unwrapPocketError(await client.request('runtime.info', {}, requireBudget(state, 'runtime.info')), 'runtime.info'),
        'runtime.info result',
      )
      const node = requireString(info['node'], 'runtime.info.result.node')
      const platform = requireString(info['platform'], 'runtime.info.result.platform')
      const listed = unwrapPocketError(
        await client.request('sessions.list', {}, requireBudget(state, 'sessions.list')),
        'sessions.list',
      )
      const rows = requireArray(listed, 'sessions.list result')
      const sessions: SessionSummary[] = []
      for (const [position, row] of rows.entries()) {
        const record = requireObject(row, `sessions.list[${position}]`)
        const id = sessionIdOf(record)
        if (id === undefined) {
          throw new Error(`sessions.list[${position}]: expected header.id or sessionId, received ${describeValue(record)}`)
        }
        sessions.push({ id, cwd: cwdOf(record) })
      }
      state.sessions = sessions
      const cwds = sessions.flatMap(summary => summary.cwd === undefined ? [] : [summary.cwd])
      const uniqueCwds = new Set(cwds)
      const projectNames: string[] = []
      for (const cwd of uniqueCwds) {
        const name = projectNameOf(cwd)
        if (!projectNames.includes(name)) projectNames.push(name)
      }
      const shown = projectNames.slice(0, 5)
      const more = projectNames.length - shown.length
      const projectText = shown.length === 0
        ? 'no cwd reported'
        : `projects: ${shown.join(', ')}${more > 0 ? ` (+${more} more)` : ''}`
      return `ready via ${readiness}; runtime.info node=${node} platform=${platform}; sessions.list=${sessions.length} session(s); ${projectText}`
    },
  }
  const modelCatalog: CheckDefinition = {
    id: 'model-catalog',
    name: 'api.call session.modelCatalog',
    requires: ['host-ready'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const result = unwrapPocketError(
        await client.request(
          'api.call',
          { namespace: 'session', method: 'modelCatalog', args: {} },
          requireBudget(state, 'api.call session.modelCatalog'),
        ),
        'api.call session.modelCatalog',
      )
      const record = requireObject(result, 'api.call session.modelCatalog result')
      const groups = requireArray(record['groups'], 'api.call session.modelCatalog result.groups')
      const providerIds = groups.map((group, position) => {
        const entry = requireObject(group, `api.call session.modelCatalog result.groups[${position}]`)
        return requireString(entry['id'], `api.call session.modelCatalog result.groups[${position}].id`)
      })
      const failures = record['failures'] === undefined
        ? 0
        : requireArray(record['failures'], 'api.call session.modelCatalog result.failures').length
      const shown = providerIds.length > 4 ? `${providerIds.slice(0, 4).join(', ')}…` : providerIds.join(', ')
      return `groups=${groups.length}${shown === '' ? '' : ` (${shown})`}; provider failures=${failures}`
    },
  }
  const readWindow: CheckDefinition = {
    id: 'read-window',
    name: 'session.readWindow',
    requires: ['host-ready'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      let sessionId: string
      if (options.sessionId !== undefined) {
        if (!state.sessions.some(session => session.id === options.sessionId)) {
          throw new Error(
            `--session ${options.sessionId}: not present in sessions.list (${state.sessions.length} sessions)`,
          )
        }
        sessionId = options.sessionId
      } else {
        const first = state.sessions[0]
        if (first === undefined) {
          throw new Error('sessions.list is empty; pass --session <sessionId> to pick a session explicitly')
        }
        sessionId = first.id
      }
      const result = unwrapPocketError(
        await client.request('session.readWindow', { sessionId }, requireBudget(state, 'session.readWindow')),
        'session.readWindow',
      )
      const record = requireObject(result, 'session.readWindow result')
      const events = requireArray(record['events'], 'session.readWindow result.events')
      const throughSeq = requireInteger(record['throughSeq'], 'session.readWindow result.throughSeq')
      // A `workspace/changes` event announces the one turn seq whose snapshot the host serves
      // (the summary is recorded for that event only). Later events in the window supersede it.
      let workspaceChangesSeq: number | undefined
      for (const [position, event] of events.entries()) {
        const eventRecord = requireObject(event, `session.readWindow result.events[${position}]`)
        if (eventRecord['type'] !== 'workspace/changes') continue
        workspaceChangesSeq = requireInteger(
          eventRecord['seq'],
          `session.readWindow result.events[${position}].seq (workspace/changes)`,
        )
      }
      state.sessionId = sessionId
      state.throughSeq = throughSeq
      state.workspaceChangesSeq = workspaceChangesSeq
      const announcement = workspaceChangesSeq === undefined ? 'no workspace/changes event' : `workspace/changes at seq=${workspaceChangesSeq}`
      return `session=${sessionId}; events=${events.length}; throughSeq=${throughSeq}; ${announcement}`
    },
  }
  const workspaceFilesList: CheckDefinition = {
    id: 'workspace-files-list',
    name: 'workspace.files.list host workspace root',
    requires: ['host-ready'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const result = unwrapPocketError(
        await client.request('workspace.files.list', { path: '' }, requireBudget(state, 'workspace.files.list')),
        'workspace.files.list',
      )
      const record = requireObject(result, 'workspace.files.list result')
      const root = requireString(record['root'], 'workspace.files.list result.root')
      if (!isAbsolute(root)) {
        throw new Error(`workspace.files.list result.root: expected an absolute host path, received ${JSON.stringify(root)}`)
      }
      const entries = requireArray(record['entries'], 'workspace.files.list result.entries')
      const listed = new Map<string, JsonObject>()
      for (const [position, entry] of entries.entries()) {
        const entryRecord = requireObject(entry, `workspace.files.list result.entries[${position}]`)
        const name = requireString(
          entryRecord['name'],
          `workspace.files.list result.entries[${position}].name`,
        )
        listed.set(name, entryRecord)
      }
      const missing = WORKSPACE_ROOT_ENTRIES.filter(name => !listed.has(name))
      if (missing.length > 0) {
        throw new Error(
          `workspace.files.list result.entries: missing ${missing.join(', ')} under ${root} (${listed.size} entries)`,
        )
      }
      for (const name of WORKSPACE_ROOT_ENTRIES) {
        const entry = listed.get(name)
        if (entry !== undefined && entry['kind'] !== 'directory') {
          throw new Error(
            `workspace.files.list result.entries: expected ${name} to be kind=directory, received ${describeValue(entry['kind'])}`,
          )
        }
      }
      state.workspaceRoot = root
      return `root=${root} (absolute); entries=${listed.size} including ${WORKSPACE_ROOT_ENTRIES.join(', ')} as directories`
    },
  }
  const workspaceFilesRead: CheckDefinition = {
    id: 'workspace-files-read',
    name: 'workspace.files.read AGENTS.md',
    requires: ['host-ready'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const result = unwrapPocketError(
        await client.request(
          'workspace.files.read',
          { path: WORKSPACE_READ_PATH },
          requireBudget(state, 'workspace.files.read'),
        ),
        'workspace.files.read',
      )
      const record = requireObject(result, 'workspace.files.read result')
      const text = requireString(record['text'], 'workspace.files.read result.text')
      if (!text.startsWith(WORKSPACE_READ_PREFIX)) {
        throw new Error(
          `workspace.files.read result.text: expected it to start with ${JSON.stringify(WORKSPACE_READ_PREFIX)}, received ${describeValue(text.slice(0, 80))}`,
        )
      }
      const bytes = requireInteger(record['bytes'], 'workspace.files.read result.bytes')
      if (bytes <= 0) {
        throw new Error(`workspace.files.read result.bytes: expected a positive file size, received ${bytes}`)
      }
      if (record['eof'] !== true) {
        throw new Error(
          `workspace.files.read result.eof: expected true for the complete ${bytes}-byte file, received ${describeValue(record['eof'])}`,
        )
      }
      return `${WORKSPACE_READ_PATH}: ${bytes} bytes, ${text.length} characters, eof=true, starts ${JSON.stringify(WORKSPACE_READ_PREFIX)}`
    },
  }
  const workspaceChangesSummary: CheckDefinition = {
    id: 'workspace-changes-summary',
    name: 'workspaceChanges.summary capability probe',
    requires: ['hello', 'read-window'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const methods = requireState(state.methods, 'hello method table')
      if (!methodsCover(methods, 'workspaceChanges.summary')) {
        throw new Error(
          `protocol.hello result.methods: missing coverage for workspaceChanges.summary (${methods.length} entries)`,
        )
      }
      const sessionId = requireState(state.sessionId, 'session id')
      const announcedSeq = state.workspaceChangesSeq
      // The host serves a snapshot only for the seq announced by a `workspace/changes` event.
      // Without one (no file-tool edits in the selected window), the same call still exercises the
      // capability by asking for the window end, which no host process retains.
      const seq = announcedSeq ?? requireState(state.throughSeq, 'session throughSeq')
      const result = await client.request(
        'workspaceChanges.summary',
        { owner: randomUUID(), requestId: randomUUID(), sessionId, seq },
        requireBudget(state, 'workspaceChanges.summary'),
      )
      const record = requireObject(result, 'workspaceChanges.summary result')
      const ok = record['ok']
      if (typeof ok !== 'boolean') {
        throw new Error(
          `workspaceChanges.summary result.ok: expected a boolean, received ${describeValue(ok)} (${describeValue(record)})`,
        )
      }
      if (ok) {
        const value = requireObject(record['value'], 'workspaceChanges.summary result.value')
        const files = requireArray(value['files'], 'workspaceChanges.summary result.value.files')
        state.workspaceChanges = {
          degraded: false,
          note: `live snapshot at seq ${seq}: ${files.length} changed file(s)`,
        }
        return `ok=true value.files=${files.length} at seq=${seq} (${announcedSeq === undefined ? 'window-end probe' : 'announced snapshot'}); session=${sessionId}`
      }
      const error = requireObject(record['error'], 'workspaceChanges.summary result.error')
      const code = requireString(error['code'], 'workspaceChanges.summary result.error.code')
      const message = typeof error['message'] === 'string' ? error['message'] : 'no message'
      if (code !== WORKSPACE_CHANGES_UNAVAILABLE) {
        throw new Error(`workspaceChanges.summary failed with ${code}: ${message} (session=${sessionId} seq=${seq})`)
      }
      // Snapshot retention is process-local: a session log can announce a `workspace/changes` turn
      // recorded by an earlier host process, and this process legitimately cannot serve it.
      // Treat both announced-and-expired and absent cases as degraded passes so the check
      // stays repeatable across host restarts; only an unexpected error code fails.
      state.workspaceChanges = {
        degraded: true,
        note: announcedSeq === undefined
          ? `degraded PASS: no workspace/changes event in the read window; seq ${seq} has no snapshot (${code})`
          : `degraded PASS: announced seq ${announcedSeq} belongs to an earlier host process, so its snapshot is gone (${code})`,
      }
      return announcedSeq === undefined
        ? `degraded PASS: the read window has no workspace/changes event, so seq=${seq} (throughSeq) has no snapshot; `
          + `${code} is expected for a session without file-tool edits`
        : `degraded PASS: session=${sessionId} announces seq=${announcedSeq} via workspace/changes, but the snapshot `
          + `was recorded by an earlier host process; ${code} is expected after a host restart`
    },
  }
  const terminalShells: CheckDefinition = {
    id: 'terminal-shells',
    name: 'terminal.shells discovery',
    requires: ['read-window'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const result = unwrapPocketError(
        await client.request(
          'terminal.shells',
          { sessionId },
          Math.min(requireBudget(state, 'terminal.shells'), TERMINAL_REQUEST_CAP_MS),
        ),
        'terminal.shells',
      )
      const rows = requireArray(result, 'terminal.shells result')
      if (rows.length === 0) throw new Error('terminal.shells result: expected at least one shell, received []')
      const shells = rows.map((row, position): TerminalShellSummary => {
        const record = requireObject(row, `terminal.shells[${position}]`)
        return {
          id: requireString(record['id'], `terminal.shells[${position}].id`),
          label: requireString(record['label'], `terminal.shells[${position}].label`),
        }
      })
      const first = shells[0]
      if (first === undefined) throw new Error('terminal.shells result: expected a first shell after validation')
      state.terminalShell = first
      const labels = shells.slice(0, 4).map(shell => shell.label).join(', ')
      return `shells=${shells.length} (${labels}); first id=${truncate(first.id, 96)}`
    },
  }
  const terminalErrorTranslation: CheckDefinition = {
    id: 'terminal-error-translation',
    name: 'terminal.read missing terminal error translation',
    requires: ['read-window'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const missingId = `e2e-missing-${randomUUID()}`
      const result = await client.request(
        'terminal.read',
        { sessionId, id: missingId },
        Math.min(requireBudget(state, 'terminal.read (missing id)'), TERMINAL_REQUEST_CAP_MS),
      )
      const record = requireObject(result, 'terminal.read (missing id) result')
      const pocket = asObject(record['_pocket_error'])
      if (pocket === undefined) {
        throw new Error(
          `terminal.read for a missing terminal: expected result._pocket_error, received ${describeValue(record)}`,
        )
      }
      const code = requireString(pocket['code'], 'terminal.read (missing id) _pocket_error.code')
      if (code !== 'terminal/unavailable') {
        throw new Error(
          'terminal.read for a missing terminal: expected _pocket_error.code terminal/unavailable, '
          + `received ${code} (${describeValue(pocket)})`,
        )
      }
      const message = typeof pocket['message'] === 'string' ? truncate(pocket['message'], 120) : 'no message'
      return `missing terminal read rejected with result._pocket_error.code=${code}: ${message}`
    },
  }
  const terminalCreateWriteRead: CheckDefinition = {
    id: 'terminal-create-write-read',
    name: 'terminal.create + write + read screen',
    requires: ['terminal-shells'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const shell = requireState(state.terminalShell, 'discovered terminal shell')
      const id = `e2e-${randomUUID()}`
      state.terminalId = id
      const created = requireObject(
        unwrapPocketError(
          await client.request(
            'terminal.create',
            { sessionId, id, cols: TERMINAL_CREATE_COLS, rows: TERMINAL_CREATE_ROWS, shellId: shell.id },
            Math.min(requireBudget(state, 'terminal.create'), TERMINAL_REQUEST_CAP_MS),
          ),
          'terminal.create',
        ),
        'terminal.create result',
      )
      const createdId = requireString(created['id'], 'terminal.create result.id')
      if (createdId !== id) throw new Error(`terminal.create result.id: expected ${id}, received ${createdId}`)
      if (created['state'] !== 'running') {
        throw new Error(`terminal.create result.state: expected running, received ${describeValue(created['state'])}`)
      }
      const writeResult = requireObject(
        unwrapPocketError(
          await client.request(
            'terminal.write',
            { sessionId, id, data: TERMINAL_MARKER_COMMAND },
            Math.min(requireBudget(state, 'terminal.write'), TERMINAL_REQUEST_CAP_MS),
          ),
          'terminal.write',
        ),
        'terminal.write result',
      )
      if (writeResult['accepted'] !== true) {
        throw new Error(`terminal.write result: expected {accepted:true}, received ${describeValue(writeResult)}`)
      }
      const startedAt = Date.now()
      const waitUntil = Math.min(startedAt + TERMINAL_SCREEN_WAIT_MS, state.deadline)
      let attempts = 0
      let lastDisplay = ''
      let evidence: {
        readonly source: 'display' | 'view'
        readonly revision: number
        readonly screenLength: number
        readonly displayLength: number
        readonly viewLines: number
      } | undefined
      while (Date.now() < waitUntil) {
        attempts += 1
        const read = requireObject(
          unwrapPocketError(
            await client.request(
              'terminal.read',
              { sessionId, id },
              Math.max(500, Math.min(requireBudget(state, 'terminal.read'), TERMINAL_REQUEST_CAP_MS)),
            ),
            'terminal.read',
          ),
          'terminal.read result',
        )
        const revision = requireInteger(read['revision'], 'terminal.read result.revision')
        // §2.2: every read carries the serialized screen, the plain display, and the structured view.
        const screenText = read['screen']
        if (typeof screenText !== 'string') {
          throw new Error(`terminal.read result.screen: expected a string, received ${describeValue(screenText)}`)
        }
        const displayText = read['display']
        if (typeof displayText !== 'string') {
          throw new Error(`terminal.read result.display: expected a string, received ${describeValue(displayText)}`)
        }
        const view = requireObject(read['view'], 'terminal.read result.view')
        lastDisplay = displayText
        if (displayText.includes(TERMINAL_MARKER) || terminalViewText(view).includes(TERMINAL_MARKER)) {
          evidence = {
            source: displayText.includes(TERMINAL_MARKER) ? 'display' : 'view',
            revision,
            screenLength: screenText.length,
            displayLength: displayText.length,
            viewLines: requireArray(view['lines'], 'terminal.read result.view.lines').length,
          }
          break
        }
        await sleep(Math.min(TERMINAL_READ_POLL_MS, Math.max(0, waitUntil - Date.now())))
      }
      if (evidence === undefined) {
        throw new Error(
          `terminal.read never showed ${TERMINAL_MARKER} within ${TERMINAL_SCREEN_WAIT_MS} ms `
          + `(${attempts} read(s)); last display: ${describeValue(truncate(lastDisplay, 240))}`,
        )
      }
      return `id=${id} shell=${shell.label}; write accepted; marker observed via ${evidence.source} after `
        + `${attempts} read(s) (${Date.now() - startedAt} ms); revision=${evidence.revision}, `
        + `screen=${evidence.screenLength} chars, display=${evidence.displayLength} chars, view.lines=${evidence.viewLines}`
    },
  }
  const terminalResizeListRenameClose: CheckDefinition = {
    id: 'terminal-resize-list-rename-close',
    name: 'terminal.resize + list + rename + close',
    requires: ['terminal-create-write-read'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const id = requireState(state.terminalId, 'created terminal id')
      const resized = requireObject(
        unwrapPocketError(
          await client.request(
            'terminal.resize',
            { sessionId, id, cols: TERMINAL_RESIZE_COLS, rows: TERMINAL_RESIZE_ROWS },
            Math.min(requireBudget(state, 'terminal.resize'), TERMINAL_REQUEST_CAP_MS),
          ),
          'terminal.resize',
        ),
        'terminal.resize result',
      )
      assertTerminalGeometry(resized, id, TERMINAL_RESIZE_COLS, TERMINAL_RESIZE_ROWS, 'terminal.resize result')
      const listed = requireArray(
        unwrapPocketError(
          await client.request(
            'terminal.list',
            { sessionId },
            Math.min(requireBudget(state, 'terminal.list'), TERMINAL_REQUEST_CAP_MS),
          ),
          'terminal.list',
        ),
        'terminal.list result',
      )
      const listedRow = listed
        .map((row, position) => requireObject(row, `terminal.list[${position}]`))
        .find(row => row['id'] === id)
      if (listedRow === undefined) {
        throw new Error(`terminal.list result: created terminal ${id} is missing (${listed.length} row(s))`)
      }
      assertTerminalGeometry(listedRow, id, TERMINAL_RESIZE_COLS, TERMINAL_RESIZE_ROWS, 'terminal.list row')
      const name = `e2e-shell-${randomUUID().slice(0, 8)}`
      const renamed = requireObject(
        unwrapPocketError(
          await client.request(
            'terminal.rename',
            { sessionId, id, name },
            Math.min(requireBudget(state, 'terminal.rename'), TERMINAL_REQUEST_CAP_MS),
          ),
          'terminal.rename',
        ),
        'terminal.rename result',
      )
      if (renamed['name'] !== name) {
        throw new Error(`terminal.rename result.name: expected ${JSON.stringify(name)}, received ${describeValue(renamed['name'])}`)
      }
      const closeOutcome = await closeHostTerminal(
        client,
        sessionId,
        id,
        Math.max(1_000, Math.min(requireBudget(state, 'terminal.close'), 5_000)),
      )
      state.terminalClosed = true
      if (closeOutcome !== 'closed') {
        throw new Error(`terminal.close result: expected {closed:true}, controller answered ${closeOutcome}`)
      }
      const afterClose = requireArray(
        unwrapPocketError(
          await client.request(
            'terminal.list',
            { sessionId },
            Math.min(requireBudget(state, 'terminal.list after close'), TERMINAL_REQUEST_CAP_MS),
          ),
          'terminal.list after close',
        ),
        'terminal.list result after close',
      )
      for (const [position, row] of afterClose.entries()) {
        const record = requireObject(row, `terminal.list[${position}] after close`)
        if (record['id'] === id) {
          throw new Error(`terminal.list after close: closed terminal ${id} is still listed (${afterClose.length} row(s))`)
        }
      }
      return `resize ${TERMINAL_RESIZE_COLS}x${TERMINAL_RESIZE_ROWS} reflected in resize result and list; `
        + `rename name=${JSON.stringify(name)}; close closed=true; `
        + `list after close=${afterClose.length} row(s) without ${id}`
    },
  }
  const attachmentsPrepareFile: CheckDefinition = {
    id: 'attachments-prepare-file',
    name: 'attachments.prepare file receipt + paged native.attachments.read',
    requires: ['read-window'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const id = randomUUID()
      attachmentFixture.register(id, createAttachmentFixture(ATTACHMENT_FIXTURE_BYTES))
      state.attachment = undefined
      state.attachmentReleased = false
      const result = unwrapPocketError(
        await client.request(
          'attachments.prepare',
          {
            sessionId,
            id,
            name: ATTACHMENT_FILE_NAME,
            mediaType: ATTACHMENT_MEDIA_TYPE,
            bytes: ATTACHMENT_FIXTURE_BYTES,
          },
          Math.min(requireBudget(state, 'attachments.prepare'), ATTACHMENT_REQUEST_CAP_MS),
        ),
        'attachments.prepare',
      )
      const record = requireObject(result, 'attachments.prepare result')
      const createdId = requireString(record['id'], 'attachments.prepare result.id')
      if (createdId !== id) throw new Error(`attachments.prepare result.id: expected ${id}, received ${createdId}`)
      if (record['kind'] !== 'file') {
        throw new Error(`attachments.prepare result.kind: expected file, received ${describeValue(record['kind'])}`)
      }
      const receiptId = requireString(record['receiptId'], 'attachments.prepare result.receiptId')
      const bytes = requireInteger(record['bytes'], 'attachments.prepare result.bytes')
      if (bytes !== ATTACHMENT_FIXTURE_BYTES) {
        throw new Error(`attachments.prepare result.bytes: expected ${ATTACHMENT_FIXTURE_BYTES}, received ${bytes}`)
      }
      const pages = attachmentFixture.pages.filter(page => page.id === id)
      if (pages.length === 0) {
        throw new Error('attachments.prepare: the host never requested native.attachments.read for the draft')
      }
      if (pages.length < 2) {
        throw new Error('attachments.prepare: expected multiple native.attachments.read pages for '
          + `${ATTACHMENT_FIXTURE_BYTES} bytes, received ${pages.length}`)
      }
      let expectedOffset = 0
      for (const [position, page] of pages.entries()) {
        const label = `native.attachments.read page ${position}`
        if (page.offset !== expectedOffset) {
          throw new Error(`${label}: expected offset ${expectedOffset}, received ${page.offset}`)
        }
        if (page.length < 1 || page.length > ATTACHMENT_PAGE_BYTES) {
          throw new Error(`${label}: requested length ${page.length} outside 1–${ATTACHMENT_PAGE_BYTES}`)
        }
        if (page.returnedBytes < 1 || page.returnedBytes > page.length) {
          throw new Error(`${label}: returned ${page.returnedBytes} bytes for a ${page.length}-byte request`)
        }
        if (page.nextOffset !== page.offset + page.returnedBytes) {
          throw new Error(`${label}: nextOffset ${page.nextOffset} does not advance by `
            + `${page.returnedBytes} from ${page.offset}`)
        }
        const last = position === pages.length - 1
        if (page.eof !== last) {
          throw new Error(`${label}: expected eof=${last}, received ${page.eof}`)
        }
        expectedOffset = page.nextOffset
      }
      const lastPage = pages[pages.length - 1]
      if (lastPage === undefined || lastPage.nextOffset !== ATTACHMENT_FIXTURE_BYTES) {
        throw new Error(`native.attachments.read: pages end at offset ${lastPage?.nextOffset}, `
          + `expected the declared ${ATTACHMENT_FIXTURE_BYTES} bytes`)
      }
      state.attachment = { id, receiptId, bytes, pages: pages.length }
      const pageSizes = pages.map(page => page.returnedBytes).join('+')
      return `id=${id} kind=file receiptId=${receiptId.slice(0, 8)}… bytes=${bytes}; `
        + `native.attachments.read pages=${pages.length} (${pageSizes}), offsets 0→${lastPage.nextOffset} with eof`
    },
  }
  const attachmentsErrorNotFound: CheckDefinition = {
    id: 'attachments-error-not-found',
    name: 'attachments.prepare missing draft error translation',
    requires: ['read-window'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const id = randomUUID()
      state.attachmentUnavailableId = id
      const result = await client.request(
        'attachments.prepare',
        { sessionId, id, name: 'e2e-missing-attachment.txt', mediaType: ATTACHMENT_MEDIA_TYPE, bytes: 32 },
        Math.min(requireBudget(state, 'attachments.prepare (missing draft)'), ATTACHMENT_REQUEST_CAP_MS),
      )
      const record = requireObject(result, 'attachments.prepare (missing draft) result')
      const pocket = asObject(record['_pocket_error'])
      if (pocket === undefined) {
        throw new Error(
          `attachments.prepare for a missing draft: expected result._pocket_error, received ${describeValue(record)}`,
        )
      }
      const code = requireString(pocket['code'], 'attachments.prepare (missing draft) _pocket_error.code')
      if (code !== 'attachment-file/not-found') {
        // Design §3.4.3 requires the App-visible code. A `session/attachment-invalid` +
        // `ATTACHMENT_WRITE_FAILED` envelope means the host's paged-read failure was masked by
        // the file-upload store instead of reaching `remoteFailure` with its protocol code.
        throw new Error(
          'attachments.prepare for a missing draft: expected _pocket_error.code attachment-file/not-found, '
          + `received ${code} (${describeValue(pocket)})`,
        )
      }
      if (!attachmentFixture.missingDraftIds.includes(id)) {
        throw new Error(`attachments.prepare for a missing draft: the host never asked native.attachments.read for ${id}`)
      }
      const message = typeof pocket['message'] === 'string' ? truncate(pocket['message'], 120) : 'no message'
      return `missing draft prepare rejected with result._pocket_error.code=${code}: ${message}`
    },
  }
  const attachmentsSend: CheckDefinition = {
    id: 'attachments-send',
    name: 'session.send with attachmentIds accepted',
    requires: ['attachments-prepare-file'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const attachment = requireState(state.attachment, 'prepared attachment receipt')
      const route = await readDefaultModelRoute(client, state)
      const requestId = randomUUID()
      // No App stream is open yet (the follow stream starts in the next check), so "no error in
      // the stream" here means an error-free request envelope: `client.request` rejects on a
      // JSON-RPC error frame and `unwrapPocketError` rejects on `_pocket_error`.
      const result = requireObject(
        unwrapPocketError(
          await client.request(
            'session.send',
            {
              sessionId,
              requestId,
              text: ATTACHMENT_SEND_TEXT,
              provider: route.provider,
              model: route.model,
              selectModel: false,
              attachmentIds: [attachment.id],
            },
            Math.min(requireBudget(state, 'session.send with attachment'), ATTACHMENT_REQUEST_CAP_MS),
          ),
          'session.send with attachment',
        ),
        'session.send with attachment result',
      )
      if (result['accepted'] !== true) {
        throw new Error(`session.send with attachment result: expected {accepted:true}, received ${describeValue(result)}`)
      }
      if (client.violation !== undefined) throw new Error(`host protocol violation: ${describeError(client.violation)}`)
      const detail = `attachmentIds=[${attachment.id}] receiptId=${attachment.receiptId.slice(0, 8)}… accepted; `
        + `provider=${route.provider} model=${route.model}; requestId=${requestId}`
      return detail
    },
  }
  const subscribe: CheckDefinition = {
    id: 'subscribe',
    name: 'session.follow subscription',
    requires: ['read-window'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const sessionId = requireState(state.sessionId, 'session id')
      const fromIndex = client.notificationCount
      const subscription = await subscribeSessionFollow(client, sessionId, state)
      state.tracker = subscription.tracker
      let cursor = fromIndex
      let snapshot: JsonObject | undefined
      for (;;) {
        const problem = subscription.tracker.problem
        if (problem !== undefined) throw new Error(`session.follow terminated before its opening snapshot: ${problem}`)
        let next: { readonly frame: JsonObject; readonly index: number }
        try {
          next = await client.waitForNotification(
            cursor,
            requireBudget(state, 'session.follow opening snapshot'),
            'session.follow opening snapshot',
          )
        } catch (error) {
          if (error instanceof E2ETimeoutError) {
            const observed = `api.stream sequences received through ${subscription.tracker.receivedThrough}`
            throw new E2ETimeoutError(`${error.message}; observed ${observed}`)
          }
          throw error
        }
        cursor = next.index + 1
        const value = streamItemValue(next.frame, subscription.streamId)
        if (value === undefined || value['type'] !== 'snapshot') continue
        snapshot = value
        break
      }
      const records = requireArray(snapshot['records'], 'session.follow snapshot.records')
      await subscription.tracker.settle()
      const acked = subscription.tracker.ackedThrough
      const prefix = `streamId=${subscription.streamId} generation=${subscription.generation.slice(0, 8)}…`
      return `${prefix} args=${subscription.argumentShape}; snapshot records=${records.length} `
        + `(snapshots=${subscription.tracker.snapshots}); ackedThrough=${acked}`
    },
  }
  const sendCheck: CheckDefinition = {
    id: 'send',
    name: 'session.send + assistant streaming evidence',
    requires: ['subscribe', 'host-ready'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      const tracker = requireState(state.tracker, 'session.follow stream')
      const sessionId = requireState(state.sessionId, 'session id')
      const text = options.sendText
      if (text === undefined) throw new Error('session.send check requires --send')
      tracker.useWindowAcknowledgement()
      const route = await readDefaultModelRoute(client, state)
      const requestId = `e2e-${randomUUID()}`
      const evidenceIndex = client.notificationCount
      const sendResult = requireObject(
        unwrapPocketError(
          await client.request(
            'session.send',
            {
              sessionId,
              requestId,
              text,
              provider: route.provider,
              model: route.model,
              selectModel: false,
            },
            requireBudget(state, 'session.send'),
          ),
          'session.send',
        ),
        'session.send result',
      )
      if (sendResult['accepted'] !== true) {
        throw new Error(`session.send result: expected {accepted:true}, received ${describeValue(sendResult)}`)
      }
      const evidence = await collectAssistantEvidence(client, tracker, sessionId, evidenceIndex, state)
      const problem = tracker.problem
      if (problem !== undefined) throw new Error(`session.follow stream failed during the send step: ${problem}`)
      if (tracker.failure !== undefined) {
        throw new Error(`stream acknowledgement failed: ${describeError(tracker.failure)}`)
      }
      // §8 系统通知线：页面线 task.completed 之后必须跟着映射出的 remote.taskCompleted。
      const pushDetail = await observeRemoteTaskCompleted(
        client,
        sessionId,
        evidenceIndex,
        Math.min(REMOTE_NOTIFICATION_WAIT_MS, Math.max(1_000, remainingMs(state) - 1_000)),
      )
      await tracker.settle()
      return [
        `provider=${route.provider} model=${route.model}`,
        'session.send accepted',
        `assistant/message via ${evidence.assistantSource} (${evidence.assistantTextLength} text chars)`,
        `incremental signals=${evidence.incrementalSignals}`
        + ` (stream user/message=${evidence.streamUserMessages}, session.event=${evidence.sessionEventNotifications}`
        + `, session.live=${evidence.sessionLiveNotifications})`,
        `ackedThrough=${tracker.ackedThrough}`,
        pushDetail,
      ].join('; ')
    },
  }
  const nativeLocal: CheckDefinition = {
    id: 'native-local',
    name: 'native.* answered by the host locally',
    requires: ['host-ready'],
    run: async () => {
      const client = requireState(state.client, 'open connection')
      // `native.attachments.read` is the one §5.2 method the design forwards to the App
      // (attachment upload, design §3.4.1), so its arrival is expected and not a missing
      // host-local answer. Every pre-existing §5.2 method must still be answered on the host.
      const unsupported = client.reverseRequestMethods
      const forwardedLocal = unsupported.filter(method => HOST_LOCAL_NATIVE_METHODS.includes(method))
      if (forwardedLocal.length > 0) {
        throw new Error(
          `host forwarded native.* method(s) that must be answered locally: ${forwardedLocal.join(', ')} `
          + `(reverse requests answered with -32601: ${client.reverseRequests})`,
        )
      }
      const answered = client.answeredReverseMethods
      const unexpectedAnswered = answered.filter(method => method !== ATTACHMENT_READ_METHOD)
      if (unexpectedAnswered.length > 0) {
        throw new Error(`fake App answered unexpected forwarded method(s): ${unexpectedAnswered.join(', ')}`)
      }
      // The client cannot see a local answer; the proof is the absence of a forwarded request.
      const others = unsupported.filter(method => !HOST_LOCAL_NATIVE_METHODS.includes(method))
      const suffix = others.length === 0 ? '' : `; unexpected forwarded methods: ${others.join(', ')}`
      return 'no §5.2 host-local native.* method reached the device '
        + `(${HOST_LOCAL_NATIVE_METHODS.length} covered, answered -32601: ${client.reverseRequests}); `
        + `design-allowed forwarded: ${answered.length === 0 ? 'none' : answered.join(', ')} `
        + `(${client.answeredReverseRequests} request(s))${suffix}`
    },
  }
  const cleanup: CheckDefinition = {
    id: 'cleanup',
    name: 'Cleanup (terminal, attachments, unsubscribe, close, acknowledgements)',
    requires: [],
    run: async () => {
      const problems: string[] = []
      const parts: string[] = []
      const client = state.client
      const tracker = state.tracker
      // §8 推送线：整轮观察到的每一帧 remote.* 都必须满足冻结字段表、枚举与帧上限。
      if (client !== undefined) {
        const remoteCounts = new Map<string, number>()
        for (let index = 0; index < client.notificationCount; index += 1) {
          const frame = client.notificationAt(index)
          if (frame === undefined) continue
          const method = frame['method']
          if (typeof method !== 'string' || !method.startsWith('remote.')) continue
          remoteCounts.set(method, (remoteCounts.get(method) ?? 0) + 1)
          for (const problem of validateRemoteNotification(frame)) problems.push(`remote.* violation: ${problem}`)
        }
        if (remoteCounts.size > 0) {
          const summary = [...remoteCounts].map(([method, count]) => `${method}×${count}`).join(', ')
          parts.push(`remote.* frames observed and validated: ${summary}`)
        }
      }
      try {
        // A terminal check may fail after `terminal.create` succeeded; the host terminal process
        // must not outlive the run. `terminal/unavailable` means the controller already dropped it.
        if (client !== undefined && client.isOpen && !state.terminalClosed
          && state.terminalId !== undefined && state.sessionId !== undefined) {
          try {
            const outcome = await closeHostTerminal(
              client,
              state.sessionId,
              state.terminalId,
              Math.max(1_000, Math.min(remainingMs(state), 5_000)),
            )
            state.terminalClosed = true
            parts.push(`terminal ${state.terminalId} cleanup ${outcome === 'closed' ? 'closed' : 'already gone'}`)
          } catch (error) {
            problems.push(`terminal cleanup failed: ${describeError(error)}`)
          }
        }
        // Attachment drafts are host records plus App-side caches: release both on every path.
        if (client !== undefined && client.isOpen && state.sessionId !== undefined) {
          const drafts = [state.attachment?.id, state.attachmentUnavailableId]
            .filter((id): id is string => typeof id === 'string')
          for (const id of drafts) {
            try {
              await releaseHostAttachment(
                client,
                state.sessionId,
                id,
                Math.max(1_000, Math.min(remainingMs(state), 5_000)),
              )
              attachmentFixture.unregister(id)
              state.attachmentReleased = true
              parts.push(`attachment ${id} released (released=true)`)
            } catch (error) {
              problems.push(`attachment release failed for ${id}: ${describeError(error)}`)
            }
          }
        }
        if (tracker !== undefined && client !== undefined && client.isOpen) {
          try {
            await tracker.finalAck()
          } catch (error) {
            problems.push(`final acknowledgement failed: ${describeError(error)}`)
          }
          if (tracker.failure !== undefined) {
            problems.push(`window acknowledgements failed: ${describeError(tracker.failure)}`)
          }
          try {
            const result = requireObject(
              unwrapPocketError(
                await client.request(
                  'api.unsubscribe',
                  { streamId: tracker.streamId },
                  Math.max(1_000, remainingMs(state)),
                ),
                'api.unsubscribe',
              ),
              'api.unsubscribe result',
            )
            if (result['closed'] !== true) {
              problems.push(`api.unsubscribe result: expected {closed:true}, received ${describeValue(result)}`)
            } else {
              parts.push('unsubscribed (closed=true)')
            }
          } catch (error) {
            problems.push(`api.unsubscribe failed: ${describeError(error)}`)
          }
        } else if (tracker !== undefined) {
          parts.push('subscription already gone; unsubscribe skipped')
        }
        if (client !== undefined) {
          try {
            const closeBudget = Math.max(1_000, Math.min(remainingMs(state), 5_000))
            const closeFact = await client.close(1000, 'e2e-done', closeBudget)
            parts.push(`socket closed (code=${closeFact.code}${closeFact.reason === '' ? '' : `, reason=${JSON.stringify(closeFact.reason)}`})`)
          } catch (error) {
            problems.push(`socket close failed: ${describeError(error)}`)
          }
          if (client.notificationFailure !== undefined) {
            problems.push(`notification handler failed: ${describeError(client.notificationFailure)}`)
          }
          if (client.violation !== undefined) {
            problems.push(`host protocol violation: ${describeError(client.violation)}`)
          }
        }
        await sleep(ASYNC_SETTLE_MS)
        if (asyncFailures.length > 0) {
          problems.push(`unhandled async failure: ${asyncFailures.join('; ')}`)
        }
        parts.push(`ackedThrough=${tracker?.ackedThrough ?? 0}`)
        if (client !== undefined && client.reverseRequests > 0) {
          parts.push(`answered ${client.reverseRequests} reverse request(s) with -32601: ${client.reverseRequestMethods.join(', ')}`)
        }
        if (client !== undefined && client.answeredReverseRequests > 0) {
          parts.push(`served ${client.answeredReverseRequests} forwarded ${client.answeredReverseMethods.join(', ')} request(s)`)
        }
        if (problems.length > 0) throw new Error(problems.join('; '))
        parts.push('no unhandled rejections')
        return parts.join('; ')
      } finally {
        tracker?.dispose()
      }
    },
  }
  const checks: CheckDefinition[] = [
    parseLink,
    caFingerprint,
    pair,
    pairSingleUse,
    wsUpgrade,
    hello,
    hostReady,
    modelCatalog,
    readWindow,
    workspaceFilesList,
    workspaceFilesRead,
    workspaceChangesSummary,
    terminalShells,
    terminalErrorTranslation,
    terminalCreateWriteRead,
    terminalResizeListRenameClose,
    attachmentsPrepareFile,
    attachmentsErrorNotFound,
    attachmentsSend,
    subscribe,
  ]
  if (options.sendText !== undefined) checks.push(sendCheck)
  checks.push(nativeLocal, cleanup)
  return checks
}

// ---------------------------------------------------------------------------- reporting

/**
 * Format one check result for the human-readable output.
 * @param result - Finished check.
 * @returns `[n/N] name → PASS|FAIL: detail`.
 */
function formatCheckLine(result: CheckResult): string {
  return `[${result.index}/${result.total}] ${result.name} → ${result.status}: ${result.detail}`
}

/**
 * Build the single JSON object printed by `--json`.
 * @param results - Finished checks.
 * @param state - Run state.
 * @returns Serializable report without any secret material.
 */
function buildJsonReport(results: readonly CheckResult[], state: RunState): JsonObject {
  const failed = results.filter(result => result.status === 'FAIL')
  const passed = results.length - failed.length
  return {
    tool: 'remote-dsh-e2e',
    ok: failed.length === 0 && asyncFailures.length === 0,
    pairHost: state.pair?.hostLabel ?? null,
    instanceId: state.pair?.instanceId ?? null,
    deviceId: state.deviceId ?? null,
    sessionId: state.sessionId ?? null,
    streamId: state.tracker?.streamId ?? null,
    host: state.hostName === undefined
      ? null
      : { name: state.hostName, platform: state.hostPlatform ?? null },
    readiness: state.readinessSource ?? null,
    workspaceRoot: state.workspaceRoot ?? null,
    workspaceChangesSeq: state.workspaceChangesSeq ?? null,
    workspaceChanges: state.workspaceChanges ?? null,
    terminal: state.terminalId === undefined
      ? null
      : { id: state.terminalId, shell: state.terminalShell?.id ?? null, closed: state.terminalClosed },
    attachment: state.attachment === undefined
      ? null
      : {
        id: state.attachment.id,
        receiptId: state.attachment.receiptId,
        bytes: state.attachment.bytes,
        pages: state.attachment.pages,
        released: state.attachmentReleased,
      },
    sendRequested: state.options.sendText !== undefined,
    ackedThrough: state.tracker?.ackedThrough ?? 0,
    reverseRequests: state.client?.reverseRequests ?? 0,
    total: results.length,
    passed,
    failed: failed.length,
    asyncFailures: [...asyncFailures],
    checks: results.map(result => ({
      id: result.id,
      index: result.index,
      total: result.total,
      name: result.name,
      status: result.status,
      detail: result.detail,
      durationMs: result.durationMs,
    })),
  }
}

/**
 * Print the human-readable check lines and the final `PASS k/k` / `FAIL k/k` summary.
 * @param results - Finished checks.
 */
function printHumanSummary(results: readonly CheckResult[]): void {
  const failed = results.filter(result => result.status === 'FAIL')
  const passed = results.length - failed.length
  console.log('')
  if (failed.length === 0) {
    console.log(`PASS ${passed}/${results.length}`)
    return
  }
  console.log(`FAIL ${passed}/${results.length}`)
  for (const result of failed) {
    console.log(`  - [${result.index}/${result.total}] ${result.name}: ${result.detail}`)
  }
}

// ---------------------------------------------------------------------------- entry point

/**
 * Run the whole E2E: build the plan, execute every check, report, and return the exit code.
 * @param options - Parsed command line.
 * @returns Process exit code: 0 when every check passed.
 */
async function main(options: CliOptions): Promise<number> {
  const state: RunState = {
    options,
    deadline: Date.now() + options.timeoutMs,
    pair: undefined,
    caPem: undefined,
    deviceId: undefined,
    deviceToken: undefined,
    client: undefined,
    tracker: undefined,
    hostName: undefined,
    hostPlatform: undefined,
    readinessSource: undefined,
    sessions: [],
    sessionId: undefined,
    methods: [],
    throughSeq: undefined,
    workspaceChangesSeq: undefined,
    workspaceRoot: undefined,
    workspaceChanges: undefined,
    terminalShell: undefined,
    terminalId: undefined,
    terminalClosed: false,
    attachment: undefined,
    attachmentUnavailableId: undefined,
    attachmentReleased: false,
  }
  // Backstop only: every wait is individually bounded by the overall deadline.
  const watchdog = setTimeout(() => {
    process.stderr.write(`e2e-remote-host: watchdog fired after ${options.timeoutMs + 60_000} ms; forcing exit.\n`)
    process.exit(1)
  }, options.timeoutMs + 60_000)
  watchdog.unref()
  try {
    const checks = buildChecks(state)
    if (!options.json) {
      console.log(`Remote DSH host E2E: ${checks.length} checks, timeout ${options.timeoutMs} ms`)
      console.log('')
    }
    const results: CheckResult[] = []
    const completed = new Map<CheckId, CheckResult>()
    for (const [position, check] of checks.entries()) {
      const result = await runCheck(check, position + 1, checks.length, completed)
      results.push(result)
      completed.set(result.id, result)
      if (!options.json) console.log(formatCheckLine(result))
    }
    if (options.json) {
      console.log(JSON.stringify(buildJsonReport(results, state)))
    } else {
      printHumanSummary(results)
    }
    return results.every(result => result.status === 'PASS') && asyncFailures.length === 0 ? 0 : 1
  } finally {
    clearTimeout(watchdog)
  }
}

const parsed = parseArgs(process.argv.slice(2))
if (parsed.kind === 'help') {
  process.stdout.write(usageText())
  process.exitCode = 0
} else if (parsed.kind === 'error') {
  process.stderr.write(`e2e-remote-host: ${parsed.message}\n\n${usageText()}`)
  process.exitCode = 2
} else {
  try {
    process.exitCode = await main(parsed.options)
  } catch (error) {
    const message = describeError(error)
    if (parsed.options.json) {
      console.log(JSON.stringify({ tool: 'remote-dsh-e2e', ok: false, error: message }))
    } else {
      console.error(`FAIL  e2e run crashed: ${message}`)
    }
    process.exitCode = 1
  }
}
