/**
 * Client of the remote host's loopback pairing-control HTTP API.
 *
 * The remote host is a separate process, so its JSON is a process boundary:
 * every response is parsed and validated here, and failures stay structured so
 * the Settings page can say what is wrong instead of rendering a broken card.
 * @module @deepseek-ai/dsh-device-interconnect/host/control-plane
 */

import type { ControlPlaneState, PairingWindow, RemoteDevice, RemoteHostFacts } from '../types.ts'

/** Paths under the remote host's pairing page the control client uses. */
const STATE_PATH = '/api/state'
const PAIR_PATH = '/api/pair'
const REVOKE_PATH = '/api/devices/revoke'
const QR_PATH = '/qr.svg'

/** Header that marks an action as coming from the local pairing control. */
const CONTROL_HEADER = 'x-dsh-pairing-control'

/** Default request deadline; a loopback HTTP call answers far faster. */
export const CONTROL_PLANE_TIMEOUT_MS = 3_000

/** A structured failure from the loopback control API. */
export class ControlPlaneError extends Error {
  /** Stable machine-readable code the Client maps onto its locale dictionary. */
  readonly code: string

  /**
   * @param code - stable failure code.
   * @param message - Chinese message usable as-is as a fallback.
   */
  constructor(code: string, message: string) {
    super(message)
    this.name = 'ControlPlaneError'
    this.code = code
  }
}

/** The loopback control API of one remote host. */
export interface ControlPlane {
  /** @returns the current pairing window, host facts, and paired devices. */
  state(): Promise<ControlPlaneState>
  /** @returns the state after reopening the pairing window. */
  pair(): Promise<ControlPlaneState>
  /**
   * Revoke one device.
   * @param deviceId - 32 lowercase hexadecimal device id.
   * @returns the state after the revocation.
   */
  revoke(deviceId: string): Promise<ControlPlaneState>
  /** @returns the QR SVG of the currently open window. */
  qrSvg(): Promise<string>
}

/** Options of one control client. */
export interface ControlPlaneOptions {
  /** Loopback base URL of the pairing page, for example `http://127.0.0.1:4780`. */
  readonly baseUrl: string
  /** Fetch implementation; defaults to the global one. */
  readonly fetch?: typeof fetch
  /** Request deadline; defaults to {@link CONTROL_PLANE_TIMEOUT_MS}. */
  readonly timeoutMs?: number
}

/**
 * Create the control client for one loopback pairing page.
 * @param options - base URL, fetch seam, and deadline.
 * @returns the control client.
 */
export function createControlPlane(options: ControlPlaneOptions): ControlPlane {
  const fetchImplementation = options.fetch ?? ((input, init) => fetch(input, init))
  const timeoutMs = options.timeoutMs ?? CONTROL_PLANE_TIMEOUT_MS
  const origin = options.baseUrl.replace(/\/+$/u, '')

  const request = async (path: string, init: RequestInit): Promise<Response> => {
    let response: Response
    try {
      response = await fetchImplementation(`${origin}${path}`, {
        ...init,
        signal: AbortSignal.timeout(timeoutMs),
      })
    } catch (error) {
      throw new ControlPlaneError('control-unreachable', `无法连接本机配对控制面（${origin}${path}）：${describeError(error)}`)
    }
    return response
  }

  const readState = async (response: Response): Promise<ControlPlaneState> => {
    const body = await readJson(response)
    if (!response.ok) throw errorFromBody(body, 'control-rejected', `本机配对控制面拒绝了请求（HTTP ${String(response.status)}）。`)
    const state = parseControlPlaneState(body)
    if (state === undefined) throw new ControlPlaneError('control-bad-response', '本机配对控制面返回的状态不是预期格式。')
    return state
  }

  return {
    async state() {
      return readState(await request(STATE_PATH, { method: 'GET', cache: 'no-store' }))
    },
    async pair() {
      return readState(await request(PAIR_PATH, {
        method: 'POST',
        cache: 'no-store',
        headers: { [CONTROL_HEADER]: '1' },
      }))
    },
    async revoke(deviceId: string) {
      return readState(await request(REVOKE_PATH, {
        method: 'POST',
        cache: 'no-store',
        headers: { [CONTROL_HEADER]: '1', 'content-type': 'application/json' },
        body: JSON.stringify({ deviceId }),
      }))
    },
    async qrSvg() {
      const response = await request(QR_PATH, { method: 'GET', cache: 'no-store' })
      const text = await response.text()
      if (!response.ok) throw new ControlPlaneError('qr-unavailable', '本机配对控制面还没有打开配对二维码。')
      return text
    },
  }
}

/** Read a response body as JSON, tolerating a non-JSON error page. */
async function readJson(response: Response): Promise<unknown> {
  const text = await response.text()
  if (text === '') return undefined
  try {
    return JSON.parse(text)
  } catch (error) {
    // A non-JSON body is only a diagnostic fallback; the status still decides the failure.
    if (error instanceof SyntaxError) return undefined
    throw error
  }
}

/** Rebuild the structured control-plane error a JSON body carries. */
function errorFromBody(body: unknown, fallbackCode: string, fallbackMessage: string): ControlPlaneError {
  if (isRecord(body) && isRecord(body['error'])) {
    const code = body['error']['code']
    const message = body['error']['message']
    return new ControlPlaneError(
      typeof code === 'string' ? code : fallbackCode,
      typeof message === 'string' ? message : fallbackMessage,
    )
  }
  return new ControlPlaneError(fallbackCode, fallbackMessage)
}

/**
 * Validate the remote host's state JSON.
 * @param value - parsed JSON from `/api/state`.
 * @returns the validated state, or undefined when the document is not a state object.
 */
export function parseControlPlaneState(value: unknown): ControlPlaneState | undefined {
  if (!isRecord(value)) return undefined
  const pairing = parsePairingWindow(value['pairing'], value['usbPairUrl'])
  if (pairing === undefined) return undefined
  const devices = parseDevices(value['devices'])
  if (devices === undefined) return undefined
  const host = parseHost(value['host'])
  if (host === undefined && value['host'] !== undefined) return undefined
  const state: { -readonly [K in keyof ControlPlaneState]: ControlPlaneState[K] } = { pairing, devices }
  if (host !== undefined) state.host = host
  return state
}

/** Parse one pairing window. */
function parsePairingWindow(value: unknown, topLevelUsbPairUrl: unknown): PairingWindow | undefined {
  if (!isRecord(value)) return undefined
  const open = value['open']
  if (typeof open !== 'boolean') return undefined
  if (!open) return { open: false }
  const expiresAt = value['expiresAt']
  const pairUrl = value['pairUrl']
  const usbPairUrl = value['usbPairUrl'] !== undefined ? value['usbPairUrl'] : topLevelUsbPairUrl
  if (typeof expiresAt !== 'number' || !Number.isSafeInteger(expiresAt)) return undefined
  if (typeof pairUrl !== 'string') return undefined
  return {
    open: true,
    expiresAt,
    pairUrl,
    ...(typeof usbPairUrl === 'string' ? { usbPairUrl } : {}),
  }
}

/** Parse the paired-device list. */
function parseDevices(value: unknown): readonly RemoteDevice[] | undefined {
  if (!Array.isArray(value)) return undefined
  const devices: RemoteDevice[] = []
  for (const entry of value) {
    if (!isRecord(entry)) return undefined
    const id = entry['id']
    const label = entry['label']
    const createdAt = entry['createdAt']
    const lastSeenAt = entry['lastSeenAt']
    const expiresAt = entry['expiresAt']
    const revokedAt = entry['revokedAt']
    if (typeof id !== 'string' || typeof label !== 'string') return undefined
    if (typeof createdAt !== 'number' || typeof lastSeenAt !== 'number' || typeof expiresAt !== 'number') return undefined
    if (revokedAt !== undefined && (typeof revokedAt !== 'number' || !Number.isSafeInteger(revokedAt))) return undefined
    devices.push({
      id,
      label,
      createdAt,
      lastSeenAt,
      expiresAt,
      ...(typeof revokedAt === 'number' ? { revokedAt } : {}),
    })
  }
  return devices
}

/** Parse the remote host identity block. */
function parseHost(value: unknown): RemoteHostFacts | undefined {
  if (value === undefined) return undefined
  if (!isRecord(value)) return undefined
  const name = value['name']
  const instanceId = value['instanceId']
  const origin = value['origin']
  const port = value['port']
  const discovery = value['discovery']
  const listening = value['listening']
  if (typeof name !== 'string' || typeof instanceId !== 'string' || typeof origin !== 'string') return undefined
  if (typeof port !== 'number' || typeof listening !== 'boolean') return undefined
  if (!isRecord(discovery)) return undefined
  const enabled = discovery['enabled']
  const discoveryPort = discovery['port']
  if (typeof enabled !== 'boolean' || typeof discoveryPort !== 'number') return undefined
  return { name, instanceId, origin, port, listening, discovery: { enabled, port: discoveryPort } }
}

/** Whether one unknown value is a JSON object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
