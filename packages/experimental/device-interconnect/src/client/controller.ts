/**
 * Browser-side state of the Device Interconnect Settings page: the last
 * snapshot the Host bridge served, a staged copy of the editable
 * configuration, the polling driver, and one action per page control.
 *
 * The controller is the page's only holder of a timer. `open` and `close` are
 * called by the mounted page, so no timer survives a closed Settings panel, and
 * polling pauses while the window is hidden.
 * @module @deepseek-ai/dsh-device-interconnect/client/controller
 */

import { createSnapshotStore, type SnapshotStore } from '@deepseek-ai/dsh-client-store'
import {
  BRIDGE_HEADER, BRIDGE_HEADER_VALUE, CONFIG_ROUTE, DELETE_ROUTE, ENABLED_ROUTE, PAIR_ROUTE, PROVISION_ROUTE,
  REVOKE_ROUTE, STATE_ROUTE, TUNNEL_ROUTE,
} from '../api.ts'
import type {
  DeviceInterconnectConfigInput, DeviceInterconnectView, Diagnostic, PairingView, ProvisionStep, RemoteDevice,
  RemoteHostFacts, RemoteHostMode, RuntimeChildState, RuntimeState, TunnelAccount, TunnelFrpcInfo, TunnelInfo,
  TunnelNodeInfo, TunnelProvider, TunnelProvisionState, TunnelState,
} from '../types.ts'

/** Configuration text staged by the page until the user saves it. */
export interface ConfigDraft {
  /** Listen port text. */
  port: string
  /** Listen address text. */
  listenHost: string
  /** Advertised host name or address text. */
  publicHost: string
  /** Announced pairing origin text. */
  publicOrigin: string
  /** Whether UDP LAN discovery is on. */
  discoveryEnabled: boolean
  /** Discovery port text. */
  discoveryPort: string
  /** Whether the loopback pairing page is on. */
  pagesEnabled: boolean
  /** Pairing page port text. */
  pagesPort: string
  /** Whether long-term pairing is on. */
  longTerm: boolean
  /** Remote-host mode staged by the page. */
  mode: RemoteHostMode
  /** Node.js executable path text. */
  nodePath: string
  /** `pnpm.mjs` path text. */
  pnpmPath: string
  /** Repository directory text. */
  repoDir: string
  /** DSH profile text. */
  profile: string
  /** Extra patch path text. */
  patchPath: string
  /** Child `DSH_HOME` text. */
  dshHome: string
  /** Selected tunnel provider. */
  tunnelProvider: TunnelProvider
  /** frpc executable path text. */
  frpcPath: string
  /** Staged replacement access key; empty keeps the stored one. */
  tunnelToken: string
  /** SakuraFrp tunnel ids text. */
  tunnelIds: string
  /** Public `<node-domain>:<port>` text. */
  publicAddress: string
  /** Custom `frpc.ini` path text. */
  tunnelIniPath: string
  /** Extra frpc arguments text. */
  tunnelExtraArgs: string
  /** Whether the automatic provision mode is on. */
  autoProvision: boolean
  /** Whether frpc may be downloaded when provisioning needs it. */
  frpcAutoDownload: boolean
  /** Pinned node id text; empty lets the plugin choose. */
  nodeId: string
  /** Tunnel name the automatic provision reuses or creates. */
  tunnelName: string
}

/** One actionable message the page shows after an operation. */
export interface Notice {
  /** Whether the operation succeeded. */
  kind: 'success' | 'error'
  /** Either a dictionary key (success) or a Host diagnostic (failure). */
  text: { key: 'saved' | 'regenerated' | 'revoked' | 'deleted' | 'tunnelStarted' | 'tunnelStopped' | 'tunnelProvisioned' } | { diagnostic: Diagnostic }
}

/** What the page renders. */
export interface SectionSnapshot {
  /** Load state of the first snapshot. */
  phase: 'idle' | 'loading' | 'ready' | 'error'
  /** Last snapshot the Host served. */
  state?: RuntimeState
  /** Why the last read failed, when it did. */
  error?: Diagnostic
  /** Whether one page action is in flight. */
  busy: boolean
  /** The latest operation outcome, until dismissed or replaced. */
  notice?: Notice
  /** Staged configuration; present once a snapshot arrived. */
  draft?: ConfigDraft
}

/** The editable field names of {@link ConfigDraft}. */
export type DraftField =
  | 'port' | 'listenHost' | 'publicHost' | 'publicOrigin' | 'discoveryPort' | 'pagesPort'
  | 'mode' | 'nodePath' | 'pnpmPath' | 'repoDir' | 'profile' | 'patchPath' | 'dshHome'
  | 'frpcPath' | 'tunnelToken' | 'tunnelIds' | 'publicAddress' | 'tunnelIniPath' | 'tunnelExtraArgs'
  | 'nodeId' | 'tunnelName'

/** The page's action surface, passed to the component through the inject face. */
export interface DeviceInterconnectActions {
  /** Start polling; called when the page mounts. */
  open(): void
  /** Stop polling; called when the page unmounts. */
  close(): void
  /** Read the Host snapshot once. */
  refresh(): Promise<void>
  /** Switch the supervised child on or off. */
  setEnabled(enabled: boolean): Promise<void>
  /** Start or stop the managed tunnel. */
  setTunnelEnabled(enabled: boolean): Promise<void>
  /** Stage one editable field. */
  edit(field: DraftField, value: string): void
  /** Stage one boolean toggle. */
  toggle(field: 'discoveryEnabled' | 'pagesEnabled' | 'longTerm' | 'autoProvision' | 'frpcAutoDownload', value: boolean): void
  /** Stage the tunnel provider selection. */
  selectTunnelProvider(provider: TunnelProvider): void
  /** Validate the access key and create or reuse the SakuraFrp tunnel. */
  provision(): Promise<void>
  /** Validate and persist the staged configuration. */
  save(): Promise<void>
  /** Reopen the pairing window. */
  regeneratePairing(): Promise<void>
  /** Revoke one paired device. */
  revokeDevice(deviceId: string): Promise<void>
  /** Permanently delete one paired device record. */
  deleteDevice(deviceId: string): Promise<void>
  /** Clear the last operation message. */
  dismissNotice(): void
}

/** Options of one controller. */
export interface ControllerOptions {
  /** Fetch implementation; defaults to the global one. */
  readonly fetch?: typeof fetch
  /** Polling interval; defaults to 2000 ms. */
  readonly intervalMs?: number
  /** Document whose visibility pauses polling; defaults to the global document. */
  readonly document?: Document
}

/** Default polling interval of the open page. */
export const POLL_INTERVAL_MS = 2_000

/** A failed bridge call whose body carried a structured diagnostic. */
class BridgeCallError extends Error {
  /** The Host diagnostic. */
  readonly diagnostic: Diagnostic

  /** @param diagnostic - the Host's structured failure. */
  constructor(diagnostic: Diagnostic) {
    super(diagnostic.message)
    this.name = 'BridgeCallError'
    this.diagnostic = diagnostic
  }
}

/** The page controller. */
export class DeviceInterconnectController {
  /** Bare observable source the renderer binds to `useDeviceInterconnect`. */
  readonly store: SnapshotStore<SectionSnapshot>
  /** Every page action. */
  readonly actions: DeviceInterconnectActions
  private readonly fetchImplementation: typeof fetch
  private readonly intervalMs: number
  private readonly document: Document | undefined
  private readonly onVisibilityChange = (): void => {
    if (this.document?.visibilityState === 'hidden') return
    void this.actions.refresh()
  }
  private timer: ReturnType<typeof setInterval> | undefined
  private inFlight: Promise<void> | undefined
  private draftDirty = false

  /** @param options - fetch, polling interval, and visibility document seams. */
  constructor(options: ControllerOptions = {}) {
    this.fetchImplementation = options.fetch ?? ((input, init) => fetch(input, init))
    this.intervalMs = options.intervalMs ?? POLL_INTERVAL_MS
    this.document = options.document ?? (typeof document === 'undefined' ? undefined : document)
    this.store = createSnapshotStore<SectionSnapshot>({ phase: 'idle', busy: false })
    this.actions = {
      open: () => { this.open() },
      close: () => { this.close() },
      refresh: () => this.refresh(),
      setEnabled: enabled => this.setEnabled(enabled),
      setTunnelEnabled: enabled => this.setTunnelEnabled(enabled),
      edit: (field, value) => { this.edit(field, value) },
      toggle: (field, value) => { this.toggle(field, value) },
      selectTunnelProvider: provider => { this.selectTunnelProvider(provider) },
      provision: () => this.provision(),
      save: () => this.save(),
      regeneratePairing: () => this.regeneratePairing(),
      revokeDevice: deviceId => this.revokeDevice(deviceId),
      deleteDevice: deviceId => this.deleteDevice(deviceId),
      dismissNotice: () => { this.dismissNotice() },
    }
  }

  /** Start polling and read the snapshot immediately; idempotent. */
  open(): void {
    if (this.timer !== undefined) return
    this.document?.addEventListener('visibilitychange', this.onVisibilityChange)
    this.timer = setInterval(() => {
      if (this.document?.visibilityState === 'hidden') return
      void this.actions.refresh()
    }, this.intervalMs)
    void this.actions.refresh()
  }

  /** Stop polling and release the visibility listener; idempotent. */
  close(): void {
    this.dismissNotice()
    if (this.timer === undefined) return
    clearInterval(this.timer)
    this.timer = undefined
    this.document?.removeEventListener('visibilitychange', this.onVisibilityChange)
  }

  /**
   * Read the Host snapshot once. Concurrent callers share one request.
   * @returns completion once the snapshot or the failure was stored.
   */
  refresh(): Promise<void> {
    const existing = this.inFlight
    if (existing !== undefined) return existing
    const run = this.readState().finally(() => { this.inFlight = undefined })
    this.inFlight = run
    return run
  }

  /**
   * Switch the supervised child on or off.
   * @param enabled - the requested switch position.
   * @returns completion once the Host answered.
   */
  async setEnabled(enabled: boolean): Promise<void> {
    await this.runAction(async () => {
      this.applyState(await this.actionState(ENABLED_ROUTE, { enabled }))
    })
  }

  /**
   * Start or stop the managed tunnel.
   * @param enabled - whether the frpc child should run.
   * @returns completion once the Host answered.
   */
  async setTunnelEnabled(enabled: boolean): Promise<void> {
    await this.runAction(async () => {
      this.applyState(await this.actionState(TUNNEL_ROUTE, { enabled }))
      this.store.update((snapshot) => {
        snapshot.notice = { kind: 'success', text: { key: enabled ? 'tunnelStarted' : 'tunnelStopped' } }
      })
    })
  }

  /**
   * Stage the tunnel provider selection.
   * @param provider - the selected provider.
   */
  selectTunnelProvider(provider: TunnelProvider): void {
    const draft = this.store.getSnapshot().draft
    if (draft === undefined) return
    this.draftDirty = true
    this.store.update((state) => { state.draft = { ...draft, tunnelProvider: provider } })
  }

  /**
   * Validate the access key and create or reuse the SakuraFrp tunnel.
   * @returns completion once the Host answered; the snapshot carries the steps.
   */
  async provision(): Promise<void> {
    const current = this.store.getSnapshot()
    const draft = current.draft
    if (draft === undefined) return
    await this.runAction(async () => {
      const token = draft.tunnelToken.trim()
      const nodeId = draft.nodeId.trim()
      const frpcPath = draft.frpcPath.trim()
      const state = await this.actionState(PROVISION_ROUTE, {
        ...(token === '' ? {} : { token }),
        ...(frpcPath === '' ? {} : { frpcPath }),
        frpcAutoDownload: draft.frpcAutoDownload,
        ...(nodeId === '' ? {} : { nodeId: Number(nodeId) }),
        tunnelName: draft.tunnelName,
      })
      // An unsaved draft keeps its staged values; only the access key that was
      // just submitted is cleared, so the field falls back to the saved mask.
      this.applyState(state)
      this.store.update((snapshot) => {
        if (snapshot.draft !== undefined) {
          snapshot.draft = { ...snapshot.draft, tunnelToken: '' }
        }
        const error = state.tunnel.provision?.lastError
        snapshot.notice = error === undefined
          ? { kind: 'success', text: { key: 'tunnelProvisioned' } }
          : { kind: 'error', text: { diagnostic: error } }
      })
    })
  }

  /**
   * Stage one editable text field.
   * @param field - field name.
   * @param value - new text.
   */
  edit(field: DraftField, value: string): void {
    const draft = this.store.getSnapshot().draft
    if (draft === undefined) return
    this.draftDirty = true
    const next = { ...draft }
    if (field === 'mode') {
      next.mode = value === 'embedded' ? 'embedded' : 'child'
    } else {
      next[field] = value
    }
    this.store.update((state) => { state.draft = next })
  }

  /**
   * Stage one boolean toggle.
   * @param field - toggle name.
   * @param value - new position.
   */
  toggle(field: 'discoveryEnabled' | 'pagesEnabled' | 'longTerm' | 'autoProvision' | 'frpcAutoDownload', value: boolean): void {
    const draft = this.store.getSnapshot().draft
    if (draft === undefined) return
    this.draftDirty = true
    const next = { ...draft }
    next[field] = value
    this.store.update((state) => { state.draft = next })
  }

  /**
   * Validate and persist the staged configuration.
   * @returns completion once the Host accepted or rejected it.
   */
  async save(): Promise<void> {
    const current = this.store.getSnapshot()
    const base = current.state?.config
    const draft = current.draft
    if (base === undefined || draft === undefined) return
    await this.runAction(async () => {
      const state = await this.actionState(CONFIG_ROUTE, { config: configOf(base, draft) })
      this.draftDirty = false
      this.applyState(state)
      this.store.update((snapshot) => { snapshot.notice = { kind: 'success', text: { key: 'saved' } } })
    })
  }

  /**
   * Reopen the pairing window.
   * @returns completion once the Host answered.
   */
  async regeneratePairing(): Promise<void> {
    await this.runAction(async () => {
      this.applyState(await this.actionState(PAIR_ROUTE))
      this.store.update((snapshot) => { snapshot.notice = { kind: 'success', text: { key: 'regenerated' } } })
    })
  }

  /**
   * Revoke one paired device.
   * @param deviceId - device id from the page.
   * @returns completion once the Host answered.
   */
  async revokeDevice(deviceId: string): Promise<void> {
    await this.runAction(async () => {
      this.applyState(await this.actionState(REVOKE_ROUTE, { deviceId }))
      this.store.update((snapshot) => { snapshot.notice = { kind: 'success', text: { key: 'revoked' } } })
    })
  }

  /**
   * Permanently delete one paired device record.
   * @param deviceId - device id from the page.
   * @returns completion once the Host answered.
   */
  async deleteDevice(deviceId: string): Promise<void> {
    await this.runAction(async () => {
      this.applyState(await this.actionState(DELETE_ROUTE, { deviceId }))
      this.store.update((snapshot) => { snapshot.notice = { kind: 'success', text: { key: 'deleted' } } })
    })
  }

  /** Clear the last operation message. */
  dismissNotice(): void {
    this.store.update((snapshot) => {
      if (snapshot.notice !== undefined) delete snapshot.notice
    })
  }

  /** Read the Host state and store it, or the failure. */
  private async readState(): Promise<void> {
    if (this.store.getSnapshot().phase === 'idle') {
      this.store.update((snapshot) => { snapshot.phase = 'loading' })
    }
    try {
      const raw = await this.request(STATE_ROUTE, { method: 'GET' })
      const state = parseRuntimeState(raw)
      if (state === undefined) throw new BridgeCallError({ code: 'control-bad-response', message: '设备互联状态格式不正确。' })
      this.applyState(state)
    } catch (error) {
      const diagnostic = diagnosticOf(error)
      this.store.update((snapshot) => {
        snapshot.phase = 'error'
        snapshot.error = diagnostic
      })
    }
  }

  /** Store one Host snapshot, refreshing the staged draft when the user has not edited it. */
  private applyState(state: RuntimeState): void {
    this.store.update((snapshot) => {
      snapshot.phase = 'ready'
      delete snapshot.error
      snapshot.state = state
      if (!this.draftDirty) snapshot.draft = draftOf(state.config)
    })
  }

  /** Run one action with the busy flag and failure notice. */
  private async runAction(operation: () => Promise<void>): Promise<void> {
    this.store.update((snapshot) => {
      snapshot.busy = true
      delete snapshot.notice
    })
    try {
      await operation()
    } catch (error) {
      const diagnostic = diagnosticOf(error)
      this.store.update((snapshot) => { snapshot.notice = { kind: 'error', text: { diagnostic } } })
    } finally {
      this.store.update((snapshot) => { snapshot.busy = false })
    }
  }

  /** One JSON bridge call, parsed into one action's state answer. */
  private async actionState(route: string, body?: unknown): Promise<RuntimeState> {
    const raw = await this.request(route, { method: 'POST', ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
    const state = parseRuntimeState(raw)
    if (state === undefined) throw new BridgeCallError({ code: 'control-bad-response', message: '设备互联返回的状态格式不正确。' })
    return state
  }

  /** Send one bridge request and return its parsed JSON. */
  private async request(route: string, init: { readonly method: string; readonly body?: string }): Promise<unknown> {
    let response: Response
    try {
      response = await this.fetchImplementation(route, {
        method: init.method,
        cache: 'no-store',
        headers: {
          [BRIDGE_HEADER]: BRIDGE_HEADER_VALUE,
          ...(init.body === undefined ? {} : { 'content-type': 'application/json' }),
        },
        ...(init.body === undefined ? {} : { body: init.body }),
      })
    } catch (error) {
      throw new BridgeCallError({ code: 'control-unreachable', message: `无法连接设备互联接口：${describeError(error)}` })
    }
    const raw = await readJson(response)
    if (!response.ok) throw new BridgeCallError(errorOf(raw, response.status))
    return raw
  }
}

/**
 * Parse one Host state document; a malformed body is a wire-boundary failure.
 * @param value - parsed JSON from one bridge response.
 * @returns the validated snapshot, or undefined when the document is not one.
 */
export function parseRuntimeState(value: unknown): RuntimeState | undefined {
  if (!isRecord(value)) return undefined
  const config = parseConfig(value['config'])
  const child = parseChild(value['child'])
  const tunnel = parseTunnel(value['tunnel'])
  const pairing = parsePairing(value['pairing'])
  const controlPlane = parseControlPlane(value['controlPlane'])
  const devices = parseDevices(value['devices'])
  const runner = parseRunner(value['runner'])
  const problems = parseDiagnostics(value['problems'])
  if (config === undefined || child === undefined || tunnel === undefined || pairing === undefined) return undefined
  if (controlPlane === undefined || devices === undefined || runner === undefined || problems === undefined) return undefined
  return { config, child, tunnel, controlPlane, pairing, devices, runner, problems }
}

/** Parse the configuration document, including the write-only access-key flag. */
function parseConfig(value: unknown): DeviceInterconnectView | undefined {
  if (!isRecord(value)) return undefined
  const runner = value['runner']
  const host = value['host']
  const pairing = value['pairing']
  const tunnel = parseTunnelSettings(value['tunnel'])
  if (!isRecord(runner) || !isRecord(host) || !isRecord(pairing) || tunnel === undefined) return undefined
  const enabled = value['enabled']
  const bootstrap = (key: string): string | undefined => {
    const text = runner[key]
    return typeof text === 'string' ? text : undefined
  }
  const nodePath = bootstrap('nodePath')
  const pnpmPath = bootstrap('pnpmPath')
  const repoDir = bootstrap('repoDir')
  const profile = bootstrap('profile')
  const patchPath = bootstrap('patchPath')
  const dshHome = bootstrap('dshHome')
  const mode = runner['mode']
  const port = host['port']
  const listenHost = host['host']
  const publicHost = host['publicHost']
  const publicOrigin = host['publicOrigin']
  const discoveryEnabled = host['discoveryEnabled']
  const discoveryPort = host['discoveryPort']
  const pagesEnabled = host['pagesEnabled']
  const pagesPort = host['pagesPort']
  const longTerm = pairing['longTerm']
  const pairingTtlMs = pairing['pairingTtlMs']
  if (nodePath === undefined || pnpmPath === undefined || repoDir === undefined) return undefined
  if (profile === undefined || patchPath === undefined || dshHome === undefined) return undefined
  if (typeof enabled !== 'boolean') return undefined
  if (typeof port !== 'number' || typeof listenHost !== 'string' || typeof publicHost !== 'string') return undefined
  if (typeof publicOrigin !== 'string' || typeof discoveryEnabled !== 'boolean') return undefined
  if (typeof discoveryPort !== 'number' || typeof pagesEnabled !== 'boolean' || typeof pagesPort !== 'number') return undefined
  if (typeof longTerm !== 'boolean' || typeof pairingTtlMs !== 'number') return undefined
  const validatedMode = mode === undefined ? 'child' : mode
  if (validatedMode !== 'child' && validatedMode !== 'embedded') return undefined
  return {
    enabled,
    runner: { mode: validatedMode, nodePath, pnpmPath, repoDir, profile, patchPath, dshHome },
    host: { port, host: listenHost, publicHost, publicOrigin, discoveryEnabled, discoveryPort, pagesEnabled, pagesPort },
    pairing: { longTerm, pairingTtlMs },
    tunnel,
  }
}

/** Parse the tunnel settings block served by the Host. */
function parseTunnelSettings(value: unknown): DeviceInterconnectView['tunnel'] | undefined {
  if (!isRecord(value)) return undefined
  const provider = value['provider']
  const frpcPath = value['frpcPath']
  const tunnelIds = value['tunnelIds']
  const publicAddress = value['publicAddress']
  const iniPath = value['iniPath']
  const extraArgs = value['extraArgs']
  const tokenConfigured = value['tokenConfigured']
  const autoProvision = value['autoProvision']
  const frpcAutoDownload = value['frpcAutoDownload']
  const nodeId = value['nodeId']
  const tunnelName = value['tunnelName']
  const tunnelId = value['tunnelId']
  if (provider !== 'none' && provider !== 'sakurafrp') return undefined
  if (typeof frpcPath !== 'string' || typeof tunnelIds !== 'string' || typeof publicAddress !== 'string') return undefined
  if (typeof iniPath !== 'string' || typeof extraArgs !== 'string' || typeof tokenConfigured !== 'boolean') return undefined
  if (autoProvision !== undefined && typeof autoProvision !== 'boolean') return undefined
  if (frpcAutoDownload !== undefined && typeof frpcAutoDownload !== 'boolean') return undefined
  if (nodeId !== undefined && nodeId !== null && !isOptionalId(nodeId)) return undefined
  if (tunnelId !== undefined && tunnelId !== null && !isOptionalId(tunnelId)) return undefined
  if (tunnelName !== undefined && typeof tunnelName !== 'string') return undefined
  return {
    provider,
    frpcPath,
    tunnelIds,
    publicAddress,
    iniPath,
    extraArgs,
    tokenConfigured,
    autoProvision: autoProvision === true,
    frpcAutoDownload: frpcAutoDownload !== false,
    nodeId: typeof nodeId === 'number' && nodeId > 0 ? nodeId : null,
    tunnelName: typeof tunnelName === 'string' ? tunnelName : '',
    tunnelId: typeof tunnelId === 'number' && tunnelId > 0 ? tunnelId : null,
  }
}

/** Whether one unknown value is a non-negative safe-integer provider id. */
function isOptionalId(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

/** Parse the tunnel runtime block. */
function parseTunnel(value: unknown): TunnelState | undefined {
  if (!isRecord(value)) return undefined
  const child = parseChild(value)
  if (child === undefined) return undefined
  const provider = value['provider']
  const ready = value['ready']
  const derivedPublicOrigin = value['derivedPublicOrigin']
  const problems = parseDiagnostics(value['problems'])
  if ((provider !== 'none' && provider !== 'sakurafrp') || typeof ready !== 'boolean') return undefined
  if (typeof derivedPublicOrigin !== 'string' || problems === undefined) return undefined
  const account = parseTunnelAccount(value['account'])
  const provision = parseTunnelProvision(value['provision'])
  const node = parseTunnelNode(value['node'])
  const tunnel = parseTunnelInfo(value['tunnel'])
  const frpc = parseTunnelFrpc(value['frpc'])
  if (value['account'] !== undefined && account === undefined) return undefined
  if (value['provision'] !== undefined && provision === undefined) return undefined
  if (value['node'] !== undefined && node === undefined) return undefined
  if (value['tunnel'] !== undefined && tunnel === undefined) return undefined
  if (value['frpc'] !== undefined && frpc === undefined) return undefined
  return {
    ...child,
    provider,
    ready,
    problems,
    derivedPublicOrigin,
    ...(account === undefined ? {} : { account }),
    ...(provision === undefined ? {} : { provision }),
    ...(node === undefined ? {} : { node }),
    ...(tunnel === undefined ? {} : { tunnel }),
    ...(frpc === undefined ? {} : { frpc }),
  }
}

/** Parse the SakuraFrp account block. */
function parseTunnelAccount(value: unknown): TunnelAccount | undefined {
  if (!isRecord(value)) return undefined
  const account: { -readonly [K in keyof TunnelAccount]: TunnelAccount[K] } = {}
  if (typeof value['name'] === 'string') account.name = value['name']
  if (typeof value['uid'] === 'number') account.uid = value['uid']
  if (typeof value['speed'] === 'number') account.speed = value['speed']
  if (typeof value['tunnelLimit'] === 'number') account.tunnelLimit = value['tunnelLimit']
  if (typeof value['tunnelCount'] === 'number') account.tunnelCount = value['tunnelCount']
  if (typeof value['trafficRemaining'] === 'number') account.trafficRemaining = value['trafficRemaining']
  return account
}

/** Parse the last provision attempt. */
function parseTunnelProvision(value: unknown): TunnelProvisionState | undefined {
  if (!isRecord(value)) return undefined
  const lastSteps = parseProvisionSteps(value['lastSteps'])
  if (lastSteps === undefined) return undefined
  const lastError = parseDiagnostic(value['lastError'])
  const warning = value['warning']
  if (warning !== undefined && typeof warning !== 'string') return undefined
  return {
    lastSteps,
    ...(lastError === undefined ? {} : { lastError }),
    ...(typeof warning === 'string' ? { warning } : {}),
  }
}

/** Parse the provision step list. */
function parseProvisionSteps(value: unknown): readonly ProvisionStep[] | undefined {
  if (!Array.isArray(value)) return undefined
  const steps: ProvisionStep[] = []
  for (const entry of value) {
    if (!isRecord(entry)) return undefined
    const id = entry['id']
    const status = entry['status']
    const message = entry['message']
    if (typeof id !== 'string' || typeof message !== 'string') return undefined
    if (status !== 'pending' && status !== 'done' && status !== 'failed' && status !== 'skipped') return undefined
    steps.push({ id, status, message })
  }
  return steps
}

/** Parse the selected node block. */
function parseTunnelNode(value: unknown): TunnelNodeInfo | undefined {
  if (!isRecord(value)) return undefined
  const id = value['id']
  if (typeof id !== 'number') return undefined
  const name = value['name']
  const host = value['host']
  if (name !== undefined && typeof name !== 'string') return undefined
  if (host !== undefined && typeof host !== 'string') return undefined
  return {
    id,
    ...(typeof name === 'string' ? { name } : {}),
    ...(typeof host === 'string' ? { host } : {}),
  }
}

/** Parse the tunnel identity block. */
function parseTunnelInfo(value: unknown): TunnelInfo | undefined {
  if (!isRecord(value)) return undefined
  const id = value['id']
  if (typeof id !== 'number') return undefined
  const name = value['name']
  const remote = value['remote']
  if (name !== undefined && typeof name !== 'string') return undefined
  if (remote !== undefined && typeof remote !== 'string') return undefined
  return {
    id,
    ...(typeof name === 'string' ? { name } : {}),
    ...(typeof remote === 'string' ? { remote } : {}),
  }
}

/** Parse the frpc executable block. */
function parseTunnelFrpc(value: unknown): TunnelFrpcInfo | undefined {
  if (!isRecord(value)) return undefined
  const path = value['path']
  const downloaded = value['downloaded']
  const version = value['version']
  if (path !== undefined && typeof path !== 'string') return undefined
  if (downloaded !== undefined && typeof downloaded !== 'boolean') return undefined
  if (version !== undefined && typeof version !== 'string') return undefined
  return {
    ...(typeof path === 'string' ? { path } : {}),
    ...(typeof downloaded === 'boolean' ? { downloaded } : {}),
    ...(typeof version === 'string' ? { version } : {}),
  }
}

/** Parse the child-state block. */
function parseChild(value: unknown): RuntimeChildState | undefined {
  if (!isRecord(value)) return undefined
  const running = value['running']
  const logsTail = value['logsTail']
  if (typeof running !== 'boolean' || typeof logsTail !== 'string') return undefined
  const child: { -readonly [K in keyof RuntimeChildState]: RuntimeChildState[K] } = { running, logsTail }
  const pid = value['pid']
  const startedAt = value['startedAt']
  const exitCode = value['exitCode']
  const exitedAt = value['exitedAt']
  const error = value['error']
  if (typeof pid === 'number') child.pid = pid
  if (typeof startedAt === 'number') child.startedAt = startedAt
  if (typeof exitCode === 'number') child.exitCode = exitCode
  if (typeof exitedAt === 'number') child.exitedAt = exitedAt
  if (typeof error === 'string') child.error = error
  const mode = value['mode']
  if (mode === 'child' || mode === 'embedded') child.mode = mode
  const embedded = parseEmbedded(value['embedded'])
  if (embedded !== undefined) child.embedded = embedded
  return child
}

/** Parse the embedded-host facts the child card shows. */
function parseEmbedded(value: unknown): RuntimeChildState['embedded'] | undefined {
  if (!isRecord(value)) return undefined
  const loaded = value['loaded']
  const fallbackFromEmbedded = value['fallbackFromEmbedded']
  if (typeof loaded !== 'boolean' || typeof fallbackFromEmbedded !== 'boolean') return undefined
  const reason = value['reason']
  return {
    loaded,
    fallbackFromEmbedded,
    ...(typeof reason === 'string' ? { reason } : {}),
  }
}

/** Parse the pairing view. */
function parsePairing(value: unknown): PairingView | undefined {
  if (!isRecord(value)) return undefined
  const open = value['open']
  const longTerm = value['longTerm']
  if (typeof open !== 'boolean' || typeof longTerm !== 'boolean') return undefined
  const pairing: { -readonly [K in keyof PairingView]: PairingView[K] } = { open, longTerm }
  const expiresAt = value['expiresAt']
  const pairUrl = value['pairUrl']
  const usbPairUrl = value['usbPairUrl']
  const qrSvgUrl = value['qrSvgUrl']
  if (typeof expiresAt === 'number') pairing.expiresAt = expiresAt
  if (typeof pairUrl === 'string') pairing.pairUrl = pairUrl
  if (typeof usbPairUrl === 'string') pairing.usbPairUrl = usbPairUrl
  if (typeof qrSvgUrl === 'string') pairing.qrSvgUrl = qrSvgUrl
  return pairing
}

/** Parse the control-plane block. */
function parseControlPlane(value: unknown): RuntimeState['controlPlane'] | undefined {
  if (!isRecord(value)) return undefined
  const reachable = value['reachable']
  if (typeof reachable !== 'boolean') return undefined
  const host = parseHost(value['host'])
  const error = parseDiagnostic(value['error'])
  return {
    reachable,
    ...(host === undefined ? {} : { host }),
    ...(error === undefined ? {} : { error }),
  }
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
  if (typeof port !== 'number' || typeof listening !== 'boolean' || !isRecord(discovery)) return undefined
  const enabled = discovery['enabled']
  const discoveryPort = discovery['port']
  if (typeof enabled !== 'boolean' || typeof discoveryPort !== 'number') return undefined
  return { name, instanceId, origin, port, listening, discovery: { enabled, port: discoveryPort } }
}

/** Parse the device list. */
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
    if (revokedAt !== undefined && typeof revokedAt !== 'number') return undefined
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

/** Parse the runner-readiness block. */
function parseRunner(value: unknown): RuntimeState['runner'] | undefined {
  if (!isRecord(value)) return undefined
  const ready = value['ready']
  const problems = parseDiagnostics(value['problems'])
  if (typeof ready !== 'boolean' || problems === undefined) return undefined
  return { ready, problems }
}

/** Parse a diagnostic list. */
function parseDiagnostics(value: unknown): readonly Diagnostic[] | undefined {
  if (!Array.isArray(value)) return undefined
  const diagnostics: Diagnostic[] = []
  for (const entry of value) {
    const diagnostic = parseDiagnostic(entry)
    if (diagnostic === undefined) return undefined
    diagnostics.push(diagnostic)
  }
  return diagnostics
}

/** Parse one diagnostic. */
function parseDiagnostic(value: unknown): Diagnostic | undefined {
  if (!isRecord(value)) return undefined
  const code = value['code']
  const message = value['message']
  if (typeof code !== 'string' || typeof message !== 'string') return undefined
  return { code, message }
}

/** Build the configuration the Host persists from the staged draft. */
function configOf(base: DeviceInterconnectView, draft: ConfigDraft): DeviceInterconnectConfigInput {
  const token = draft.tunnelToken.trim()
  return {
    enabled: base.enabled,
    runner: {
      mode: draft.mode,
      nodePath: draft.nodePath,
      pnpmPath: draft.pnpmPath,
      repoDir: draft.repoDir,
      profile: draft.profile,
      patchPath: draft.patchPath,
      dshHome: draft.dshHome,
    },
    host: {
      port: Number(draft.port),
      host: draft.listenHost,
      publicHost: draft.publicHost,
      publicOrigin: draft.publicOrigin,
      discoveryEnabled: draft.discoveryEnabled,
      discoveryPort: Number(draft.discoveryPort),
      pagesEnabled: draft.pagesEnabled,
      pagesPort: Number(draft.pagesPort),
    },
    pairing: { longTerm: draft.longTerm, pairingTtlMs: base.pairing.pairingTtlMs },
    tunnel: {
      provider: draft.tunnelProvider,
      frpcPath: draft.frpcPath,
      tunnelIds: draft.tunnelIds,
      publicAddress: draft.publicAddress,
      iniPath: draft.tunnelIniPath,
      extraArgs: draft.tunnelExtraArgs,
      autoProvision: draft.autoProvision,
      frpcAutoDownload: draft.frpcAutoDownload,
      nodeId: draft.nodeId.trim() === '' ? null : Number(draft.nodeId),
      tunnelName: draft.tunnelName,
      // An empty field keeps the stored access key; the page never receives it.
      ...(token === '' ? {} : { token }),
    },
  }
}

/** Build the staged draft from one configuration. */
function draftOf(config: DeviceInterconnectView): ConfigDraft {
  return {
    port: String(config.host.port),
    listenHost: config.host.host,
    publicHost: config.host.publicHost,
    publicOrigin: config.host.publicOrigin,
    discoveryEnabled: config.host.discoveryEnabled,
    discoveryPort: String(config.host.discoveryPort),
    pagesEnabled: config.host.pagesEnabled,
    pagesPort: String(config.host.pagesPort),
    longTerm: config.pairing.longTerm,
    mode: config.runner.mode,
    nodePath: config.runner.nodePath,
    pnpmPath: config.runner.pnpmPath,
    repoDir: config.runner.repoDir,
    profile: config.runner.profile,
    patchPath: config.runner.patchPath,
    dshHome: config.runner.dshHome,
    tunnelProvider: config.tunnel.provider,
    frpcPath: config.tunnel.frpcPath,
    tunnelToken: '',
    tunnelIds: config.tunnel.tunnelIds,
    publicAddress: config.tunnel.publicAddress,
    tunnelIniPath: config.tunnel.iniPath,
    tunnelExtraArgs: config.tunnel.extraArgs,
    autoProvision: config.tunnel.autoProvision,
    frpcAutoDownload: config.tunnel.frpcAutoDownload,
    nodeId: config.tunnel.nodeId === null ? '' : String(config.tunnel.nodeId),
    tunnelName: config.tunnel.tunnelName,
  }
}

/** Read a response body as JSON, tolerating a non-JSON error page. */
async function readJson(response: Response): Promise<unknown> {
  const text = await response.text()
  if (text === '') return undefined
  try {
    return JSON.parse(text)
  } catch (error) {
    // A non-JSON body is answered with the status-derived diagnostic below.
    if (error instanceof SyntaxError) return undefined
    throw error
  }
}

/** Rebuild the structured diagnostic a JSON error body carries. */
function errorOf(body: unknown, status: number): Diagnostic {
  if (isRecord(body) && isRecord(body['error'])) {
    const code = body['error']['code']
    const message = body['error']['message']
    if (typeof code === 'string' && typeof message === 'string') return { code, message }
  }
  return { code: 'internal', message: `设备互联接口返回 HTTP ${String(status)}。` }
}

/** Convert one caught action failure into a diagnostic. */
function diagnosticOf(error: unknown): Diagnostic {
  if (error instanceof BridgeCallError) return error.diagnostic
  return { code: 'internal', message: describeError(error) }
}

/** Render one caught value's message. */
function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Whether one unknown value is a JSON object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
