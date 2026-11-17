/**
 * Client of the SakuraFrp API v4, restricted to the calls the one-click tunnel
 * provision makes: account validation, node lookup, tunnel listing, creation,
 * and editing.
 *
 * The access key travels only in the `Authorization` header; it is never put in
 * a URL, a log line, or an error message. Fetch, base URL, and timeout are
 * injectable so tests never call the real service.
 * @module @deepseek-ai/dsh-device-interconnect/host/sakurafrp-api
 */

/** Production base URL of the SakuraFrp API v4. */
export const DEFAULT_SAKURA_API_BASE = 'https://api.natfrp.com/v4'

/** Default request deadline of one SakuraFrp API call. */
export const DEFAULT_SAKURA_API_TIMEOUT_MS = 15_000

/** Stable failure codes of the SakuraFrp API client. */
export type SakuraFrpApiErrorCode =
  | 'sakura-unauthorized'
  | 'sakura-rate-limited'
  | 'sakura-network'
  | 'sakura-timeout'
  | 'sakura-bad-response'
  | 'sakura-api-error'

/** A structured failure of one SakuraFrp API call. */
export class SakuraFrpApiError extends Error {
  /** Stable code the bridge maps onto its locale dictionary. */
  readonly code: SakuraFrpApiErrorCode
  /** HTTP status of the failed call, when one arrived. */
  readonly status: number | undefined

  /**
   * @param code - stable failure code.
   * @param message - Chinese message usable as-is as a fallback.
   * @param status - HTTP status, when the service answered.
   */
  constructor(code: SakuraFrpApiErrorCode, message: string, status?: number) {
    super(message)
    this.name = 'SakuraFrpApiError'
    this.code = code
    this.status = status
  }
}

/** The account facts the provision needs from `GET /user/info`. */
export interface SakuraFrpUserInfo {
  /** Account id. */
  readonly id: number
  /** Account name. */
  readonly name: string
  /** Bandwidth limit in Mbit/s. */
  readonly speed?: number
  /** Maximum number of tunnels the account may own. */
  readonly tunnels?: number
  /** Real-name verification state; absent means the service did not report it. */
  readonly realname?: boolean | number | string
  /** Traffic tuple: `[consumed today, remaining total]` in the provider's unit. */
  readonly traffic?: readonly number[]
  /** Whether the account is frozen. */
  readonly frozen: boolean
  /** Why the account is frozen, when it is. */
  readonly frozenReason?: string
}

/** One SakuraFrp node from `GET /nodes`. */
export interface SakuraFrpNode {
  /** Node id. */
  readonly id: number
  /** Node display name. */
  readonly name: string
  /** Node domain used in public addresses. */
  readonly host: string
  /** 1 for a VIP-only node. */
  readonly vip: number
  /** Capability bit field. */
  readonly flag: number
}

/** One SakuraFrp tunnel from `GET /tunnels`. */
export interface SakuraFrpTunnel {
  /** Tunnel id. */
  readonly id: number
  /** Tunnel name. */
  readonly name: string
  /** Tunnel type; only `tcp` is usable for the fixed-CA remote host. */
  readonly type: string
  /** Node id the tunnel runs on. */
  readonly node: number
  /** Local address the tunnel forwards to. */
  readonly localIp: string
  /** Local port the tunnel forwards to. */
  readonly localPort: number
  /** Provider-side remote port or address. */
  readonly remote: string
}

/** One `POST /tunnels` request. */
export interface CreateTunnelRequest {
  /** Tunnel name. */
  readonly name: string
  /** Node id to create the tunnel on. */
  readonly nodeId: number
  /** Local address the tunnel forwards to. */
  readonly localIp: string
  /** Local port the tunnel forwards to. */
  readonly localPort: number
}

/** The answer of a successful `POST /tunnels`. */
export interface SakuraFrpCreatedTunnel {
  /** New tunnel id. */
  readonly id: number
  /** Tunnel name. */
  readonly name: string
  /** Provider-side remote port assigned by the service, when returned. */
  readonly remote?: string
  /** Provider warning that must be shown to the user, when returned. */
  readonly warning?: string
}

/** One `POST /tunnel/edit` request. */
export interface EditTunnelRequest {
  /** Tunnel id to edit. */
  readonly id: number
  /** New local port. */
  readonly localPort: number
}

/** The SakuraFrp API calls the one-click provision uses. */
export interface SakuraFrpApi {
  /** @returns the account facts. */
  userInfo(): Promise<SakuraFrpUserInfo>
  /** @returns every node the account can see, in service order. */
  listNodes(): Promise<readonly SakuraFrpNode[]>
  /** @returns the account's tunnels. */
  listTunnels(): Promise<readonly SakuraFrpTunnel[]>
  /**
   * Create one TCP tunnel.
   * @param request - name, node, and local target.
   * @returns the created tunnel.
   */
  createTunnel(request: CreateTunnelRequest): Promise<SakuraFrpCreatedTunnel>
  /**
   * Align the local target of one tunnel.
   * @param request - tunnel id and new local port.
   * @returns completion once the service accepted the edit.
   */
  editTunnel(request: EditTunnelRequest): Promise<void>
}

/** Options of one API client. */
export interface SakuraFrpApiOptions {
  /** Access key; sent only as the bearer token. */
  readonly token: string
  /** Fetch implementation; defaults to the global one. */
  readonly fetch?: typeof fetch
  /** API root; defaults to {@link DEFAULT_SAKURA_API_BASE}. */
  readonly baseUrl?: string
  /** Request deadline; defaults to {@link DEFAULT_SAKURA_API_TIMEOUT_MS}. */
  readonly timeoutMs?: number
}

/**
 * Create the SakuraFrp API client of one access key.
 * @param options - access key, fetch seam, base URL, and deadline.
 * @returns the API client.
 */
export function createSakuraFrpApi(options: SakuraFrpApiOptions): SakuraFrpApi {
  const fetchImplementation = options.fetch ?? ((input, init) => fetch(input, init))
  const baseUrl = (options.baseUrl ?? DEFAULT_SAKURA_API_BASE).replace(/\/+$/u, '')
  const timeoutMs = options.timeoutMs ?? DEFAULT_SAKURA_API_TIMEOUT_MS

  const request = async (method: 'GET' | 'POST', path: string, body?: unknown): Promise<unknown> => {
    let response: Response
    try {
      response = await fetchImplementation(`${baseUrl}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${options.token}`,
          Accept: 'application/json',
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(timeoutMs),
      })
    } catch (error) {
      if (isAbortError(error)) throw new SakuraFrpApiError('sakura-timeout', `连接 SakuraFrp API 超时（${String(timeoutMs)} 毫秒）。`)
      throw new SakuraFrpApiError('sakura-network', `无法连接 SakuraFrp API：${describeError(error)}`)
    }
    const text = await response.text()
    const parsed = parseJson(text)
    if (response.status === 401 || response.status === 403) {
      throw new SakuraFrpApiError('sakura-unauthorized', 'SakuraFrp 访问密钥无效或没有权限，请在面板重新查看访问密钥。', response.status)
    }
    if (response.status === 429) {
      throw new SakuraFrpApiError('sakura-rate-limited', 'SakuraFrp API 请求过于频繁，请稍后重试。', response.status)
    }
    if (!response.ok) {
      throw new SakuraFrpApiError(
        'sakura-api-error',
        apiErrorMessage(parsed) ?? `SakuraFrp API 返回 HTTP ${String(response.status)}。`,
        response.status,
      )
    }
    if (parsed === undefined) {
      throw new SakuraFrpApiError('sakura-bad-response', 'SakuraFrp API 返回了无法解析的响应。', response.status)
    }
    return parsed
  }

  return {
    async userInfo() {
      const user = parseUserInfo(await request('GET', '/user/info'))
      if (user === undefined) throw new SakuraFrpApiError('sakura-bad-response', '无法解析 SakuraFrp 账号信息。')
      return user
    },
    async listNodes() {
      const nodes = parseNodes(await request('GET', '/nodes'))
      if (nodes === undefined) throw new SakuraFrpApiError('sakura-bad-response', '无法解析 SakuraFrp 节点列表。')
      return nodes
    },
    async listTunnels() {
      const tunnels = parseTunnels(await request('GET', '/tunnels'))
      if (tunnels === undefined) throw new SakuraFrpApiError('sakura-bad-response', '无法解析 SakuraFrp 隧道列表。')
      return tunnels
    },
    async createTunnel(requestBody: CreateTunnelRequest) {
      const created = parseCreatedTunnel(await request('POST', '/tunnels', {
        name: requestBody.name,
        type: 'tcp',
        node: requestBody.nodeId,
        local_ip: requestBody.localIp,
        local_port: requestBody.localPort,
      }))
      if (created === undefined) throw new SakuraFrpApiError('sakura-bad-response', '无法解析 SakuraFrp 新建隧道的响应。')
      return created
    },
    async editTunnel(requestBody: EditTunnelRequest) {
      await request('POST', '/tunnel/edit', {
        id: requestBody.id,
        local_ip: '127.0.0.1',
        local_port: requestBody.localPort,
      })
    },
  }
}

/**
 * Read one response body as JSON.
 * @param text - response text.
 * @returns the parsed value, or undefined for an empty or non-JSON body.
 */
function parseJson(text: string): unknown {
  if (text.trim() === '') return undefined
  try {
    return JSON.parse(text)
  } catch (error) {
    // A non-JSON page is reported by the caller as a bad response.
    if (error instanceof SyntaxError) return undefined
    throw error
  }
}

/**
 * Parse `GET /user/info`.
 * @param value - parsed JSON.
 * @returns the account facts, or undefined when the document is not one.
 */
export function parseUserInfo(value: unknown): SakuraFrpUserInfo | undefined {
  if (!isRecord(value)) return undefined
  const id = value['id']
  const name = value['name']
  if (typeof id !== 'number' || !Number.isSafeInteger(id) || typeof name !== 'string') return undefined
  const ban = value['ban']
  const frozen = ban !== null && ban !== undefined && (typeof ban !== 'object' || Object.keys(ban).length > 0)
  const speed = readNumber(value['speed'])
  const tunnels = readNumber(value['tunnels'])
  const realname = readRealname(value['realname'])
  const traffic = readNumberArray(value['traffic'])
  const frozenReason = frozen ? banReason(ban) : undefined
  return {
    id,
    name,
    frozen,
    ...(speed === undefined ? {} : { speed }),
    ...(tunnels === undefined ? {} : { tunnels }),
    ...(realname === undefined ? {} : { realname }),
    ...(traffic === undefined ? {} : { traffic }),
    ...(frozenReason === undefined ? {} : { frozenReason }),
  }
}

/**
 * Parse `GET /nodes`, whose body is a map from node id to node facts.
 * @param value - parsed JSON.
 * @returns the nodes in service order, or undefined when the document is not one.
 */
export function parseNodes(value: unknown): readonly SakuraFrpNode[] | undefined {
  if (!isRecord(value)) return undefined
  const nodes: SakuraFrpNode[] = []
  for (const [key, entry] of Object.entries(value)) {
    const id = Number(key)
    if (!Number.isSafeInteger(id) || !isRecord(entry)) return undefined
    const name = entry['name']
    const host = entry['host']
    if (typeof name !== 'string' || typeof host !== 'string') return undefined
    nodes.push({
      id,
      name,
      host,
      vip: readNumber(entry['vip']) ?? 0,
      flag: readNumber(entry['flag']) ?? 0,
    })
  }
  return nodes
}

/**
 * Parse `GET /tunnels`.
 * @param value - parsed JSON.
 * @returns the tunnels, or undefined when the document is not one.
 */
export function parseTunnels(value: unknown): readonly SakuraFrpTunnel[] | undefined {
  if (!Array.isArray(value)) return undefined
  const tunnels: SakuraFrpTunnel[] = []
  for (const entry of value) {
    if (!isRecord(entry)) return undefined
    const id = readNumber(entry['id'])
    const name = entry['name']
    const type = entry['type']
    const node = readNumber(entry['node'])
    const remote = entry['remote']
    if (id === undefined || typeof name !== 'string' || typeof type !== 'string') return undefined
    if (node === undefined) return undefined
    if (typeof remote !== 'string' && typeof remote !== 'number') return undefined
    tunnels.push({
      id,
      name,
      type,
      node,
      localIp: typeof entry['local_ip'] === 'string' ? entry['local_ip'] : '',
      localPort: readNumber(entry['local_port']) ?? 0,
      remote: String(remote),
    })
  }
  return tunnels
}

/**
 * Parse the `POST /tunnels` answer.
 * @param value - parsed JSON.
 * @returns the created tunnel, or undefined when the document is not one.
 */
export function parseCreatedTunnel(value: unknown): SakuraFrpCreatedTunnel | undefined {
  if (!isRecord(value)) return undefined
  const id = readNumber(value['id'])
  const name = value['name']
  if (id === undefined || typeof name !== 'string') return undefined
  const remote = value['remote']
  const warning = readAiWarning(value)
  return {
    id,
    name,
    ...(typeof remote === 'string' || typeof remote === 'number' ? { remote: String(remote) } : {}),
    ...(warning === undefined ? {} : { warning }),
  }
}

/**
 * Read the provider warning the API asks the caller to surface to the user.
 * @param value - one response object.
 * @returns the warning text, or undefined.
 */
export function readAiWarning(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined
  return apiMessage({ message: value['important_warning_for_ai'] })
}

/** Extract a displayable message from one API error body. */
function apiErrorMessage(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined
  return apiMessage({
    message: value['message'],
    error: value['error'],
    reason: value['reason'],
    msg: value['msg'],
  })
}

/** Read the first non-empty string field of one message candidate map. */
function apiMessage(value: Readonly<Record<string, unknown>>): string | undefined {
  for (const key of ['message', 'error', 'reason', 'msg']) {
    const entry = value[key]
    if (typeof entry === 'string' && entry.trim() !== '') return entry.trim()
    if (isRecord(entry)) {
      const nested = entry['message'] ?? entry['reason'] ?? entry['msg']
      if (typeof nested === 'string' && nested.trim() !== '') return nested.trim()
    }
  }
  return undefined
}

/** Read a frozen-account reason from one `ban` object. */
function banReason(value: unknown): string {
  if (!isRecord(value)) return '账号已被 SakuraFrp 冻结。'
  for (const key of ['reason', 'message', 'text', 'note']) {
    const entry = value[key]
    if (typeof entry === 'string' && entry.trim() !== '') return `账号已被冻结：${entry.trim()}`
  }
  return '账号已被 SakuraFrp 冻结。'
}

/** Read one finite number. */
function readNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

/** Read a number array (the account traffic tuple). */
function readNumberArray(value: unknown): readonly number[] | undefined {
  if (!Array.isArray(value)) return undefined
  const numbers: number[] = []
  for (const entry of value) {
    if (typeof entry !== 'number' || !Number.isFinite(entry)) return undefined
    numbers.push(entry)
  }
  return numbers
}

/** Read the real-name flag, tolerating the service's boolean/number/string forms. */
function readRealname(value: unknown): boolean | number | string | undefined {
  if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') return value
  return undefined
}

/** Whether one caught value is an abort or timeout rejection. */
function isAbortError(error: unknown): boolean {
  return error instanceof Error && (error.name === 'AbortError' || error.name === 'TimeoutError')
}

/** Whether one unknown value is a JSON object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
