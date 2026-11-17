/**
 * One-click SakuraFrp tunnel provision: validate the access key, pick a node,
 * reuse or create a TCP tunnel, derive the public address, prepare frpc, and
 * hand the updated settings back to the bridge, which persists them, restarts
 * the remote host with the new origin, and starts frpc.
 *
 * The flow is deterministic and re-runnable: every step reports its outcome,
 * a failure keeps the saved configuration intact, and a retry continues with
 * the same reusable tunnel instead of creating another one.
 * @module @deepseek-ai/dsh-device-interconnect/host/provision
 */

import type {
  ProvisionStep, TunnelAccount, TunnelInfo, TunnelNodeInfo, TunnelSettings,
} from '../types.ts'
import {
  type SakuraFrpApi, type SakuraFrpCreatedTunnel, type SakuraFrpNode, type SakuraFrpTunnel,
  type SakuraFrpUserInfo,
} from './sakurafrp-api.ts'
import { TunnelProvisionError, isTunnelPublicAddress } from './tunnel.ts'

/** Node flag bit: the node currently accepts new tunnels. */
export const NODE_FLAG_CREATABLE = 1 << 2

/** Node flag bit: the node is offline. */
export const NODE_FLAG_OFFLINE = 1 << 9

/** Node flag bit: the node is in BETA. */
export const NODE_FLAG_BETA = 1 << 10

/** Every step id of one provision attempt, in execution order. */
export const PROVISION_STEP_IDS = [
  'verify-token',
  'select-node',
  'ensure-tunnel',
  'resolve-address',
  'prepare-frpc',
  'start-tunnel',
] as const

/** One step id of {@link PROVISION_STEP_IDS}. */
export type ProvisionStepId = typeof PROVISION_STEP_IDS[number]

/** One selected node and the reason it was selected. */
export interface NodeSelection {
  /** The selected node. */
  readonly node: SakuraFrpNode
  /** Chinese explanation shown in the step result. */
  readonly reason: string
}

/**
 * Whether one node can host a new tunnel for this account.
 * @param node - node facts from the service.
 * @returns true when the node accepts new tunnels and is not offline, BETA, or VIP-only.
 */
export function isNodeUsable(node: SakuraFrpNode): boolean {
  return (node.flag & NODE_FLAG_CREATABLE) !== 0
    && (node.flag & NODE_FLAG_OFFLINE) === 0
    && (node.flag & NODE_FLAG_BETA) === 0
    && node.vip === 0
}

/** Chinese reason one node cannot host a new tunnel. */
function nodeIssue(node: SakuraFrpNode): string {
  const issues: string[] = []
  if ((node.flag & NODE_FLAG_CREATABLE) === 0) issues.push('当前满载或不允许创建隧道')
  if ((node.flag & NODE_FLAG_OFFLINE) !== 0) issues.push('已离线')
  if ((node.flag & NODE_FLAG_BETA) !== 0) issues.push('BETA 节点')
  if (node.vip !== 0) issues.push('VIP 专用节点')
  return issues.length === 0 ? '不可用' : issues.join('、')
}

/**
 * Select the node the automatic provision creates the tunnel on.
 * @param nodes - nodes as the service lists them, in preference order.
 * @param preferredId - pinned node id; `null` or `0` selects automatically.
 * @returns the selected node and the reason, or undefined when none is usable.
 * @throws {TunnelProvisionError} when a pinned node is missing or unusable.
 */
export function selectSakuraFrpNode(
  nodes: readonly SakuraFrpNode[],
  preferredId: number | null,
): NodeSelection | undefined {
  if (preferredId !== null && preferredId > 0) {
    const preferred = nodes.find(node => node.id === preferredId)
    if (preferred === undefined) {
      throw new TunnelProvisionError('sakura-node-missing', `指定节点 ${String(preferredId)} 不存在或当前账号不可见，请改为自动选择。`, [])
    }
    if (!isNodeUsable(preferred)) {
      throw new TunnelProvisionError(
        'sakura-node-unavailable',
        `指定节点 ${preferred.name} 当前不可用（${nodeIssue(preferred)}），请改为自动选择。`,
        [],
      )
    }
    return { node: preferred, reason: `使用指定节点 ${preferred.name}（${preferred.host}）` }
  }
  const selected = nodes.find(node => isNodeUsable(node))
  if (selected === undefined) return undefined
  return {
    node: selected,
    reason: `自动选择节点 ${selected.name}（${selected.host}）：可创建隧道、非离线、非 VIP、非 BETA`,
  }
}

/**
 * Derive the public `<host>:<port>` address from a node host and the tunnel's
 * provider-side remote value.
 * @param host - node host from the node list.
 * @param remote - provider-side remote port, or a complete address.
 * @returns the public address, or undefined when the pair cannot form one.
 */
export function sakuraPublicAddress(host: string, remote: string): string | undefined {
  const trimmed = remote.trim()
  if (trimmed === '') return undefined
  const address = /^\d+$/u.test(trimmed) ? `${host}:${trimmed}` : trimmed.includes(':') ? trimmed : `${host}:${trimmed}`
  return isTunnelPublicAddress(address) ? address : undefined
}

/** Dependencies of one provision attempt. */
export interface ProvisionDependencies {
  /** API client already authenticated with the effective access key. */
  readonly api: SakuraFrpApi
  /** Remote host port the tunnel must forward to. */
  readonly localPort: number
  /** Reuse an existing tunnel instead of creating one; defaults to true. */
  readonly reuseExisting?: boolean
  /** Resolve the frpc executable that already exists locally; empty for none. */
  readonly resolveFrpcPath: () => string
  /** Download and version-check frpc; called only when no executable exists. */
  readonly downloadFrpc: () => Promise<{ readonly path: string; readonly version: string }>
  /** Observer of every recorded step, for progress display. */
  readonly onStep?: (step: ProvisionStep) => void
}

/** The result of one successful provision. */
export interface ProvisionResult {
  /** Settings with the provisioned ids, address, and executable filled in. */
  readonly settings: TunnelSettings
  /** Every step of the attempt, in execution order. */
  readonly steps: readonly ProvisionStep[]
  /** Account facts for display. */
  readonly account: TunnelAccount
  /** Selected node. */
  readonly node: TunnelNodeInfo
  /** Created or reused tunnel. */
  readonly tunnel: TunnelInfo
  /** Resolved frpc executable. */
  readonly frpc: { readonly path: string; readonly downloaded: boolean; readonly version?: string }
  /** Provider warning that must be surfaced to the user, when returned. */
  readonly warning?: string
}

/** The default name of a tunnel created by the automatic provision. */
const DEFAULT_TUNNEL_NAME = 'DSH 设备互联'

/**
 * Run the one-click provision.
 * @param tunnel - saved tunnel settings that seed the attempt.
 * @param deps - API client, local target, and frpc preparation seams.
 * @returns the provisioned settings and every step result.
 * @throws {TunnelProvisionError} when one step fails, carrying the steps reached so far.
 */
export async function provisionSakuraFrpTunnel(
  tunnel: TunnelSettings,
  deps: ProvisionDependencies,
): Promise<ProvisionResult> {
  const steps: ProvisionStep[] = []
  const record = (id: ProvisionStepId, status: ProvisionStep['status'], message: string): void => {
    const step: ProvisionStep = { id, status, message }
    steps.push(step)
    deps.onStep?.(step)
  }
  const failError = (id: ProvisionStepId, code: string, message: string): TunnelProvisionError =>
    new TunnelProvisionError(code, message, withPendingSteps(steps, id, message))

  let account: SakuraFrpUserInfo
  try {
    account = await deps.api.userInfo()
  } catch (error) {
    return rethrowAsProvisionFailure(error, 'verify-token', steps)
  }
  if (account.frozen) throw failError('verify-token', 'sakura-account-frozen', account.frozenReason ?? 'SakuraFrp 账号已被冻结。')
  if (account.realname === false || account.realname === 0) {
    throw failError('verify-token', 'sakura-realname-required', 'SakuraFrp 账号未完成实名认证，无法创建隧道。')
  }
  record('verify-token', 'done', `已校验账号 ${account.name}`)

  let selection: NodeSelection | undefined
  try {
    selection = selectSakuraFrpNode(await deps.api.listNodes(), tunnel.nodeId)
  } catch (error) {
    return rethrowAsProvisionFailure(error, 'select-node', steps)
  }
  if (selection === undefined) {
    throw failError('select-node', 'sakura-node-unavailable', '没有可用于创建隧道的节点（全部离线、VIP、BETA 或满载），请稍后重试。')
  }
  record('select-node', 'done', selection.reason)

  let tunnels: readonly SakuraFrpTunnel[]
  try {
    tunnels = await deps.api.listTunnels()
  } catch (error) {
    return rethrowAsProvisionFailure(error, 'ensure-tunnel', steps)
  }
  const reusable = deps.reuseExisting === false ? undefined : findReusableTunnel(tunnels, tunnel)
  let tunnelId: number
  let created: SakuraFrpCreatedTunnel | undefined
  let warning: string | undefined
  try {
    if (reusable !== undefined) {
      tunnelId = reusable.id
      await deps.api.editTunnel({ id: reusable.id, localPort: deps.localPort })
      record('ensure-tunnel', 'done', `已复用隧道 ${String(reusable.id)}（${reusable.name}），本地目标对齐到 127.0.0.1:${String(deps.localPort)}`)
    } else {
      const limit = account.tunnels
      if (limit !== undefined && tunnels.length >= limit) {
        throw failError(
          'ensure-tunnel',
          'sakura-quota-exceeded',
          `隧道额度已满（${String(tunnels.length)}/${String(limit)}）：请删除不用的隧道，或在高级选项中复用手动隧道。`,
        )
      }
      created = await deps.api.createTunnel({
        name: tunnel.tunnelName.trim() === '' ? DEFAULT_TUNNEL_NAME : tunnel.tunnelName.trim(),
        nodeId: selection.node.id,
        localIp: '127.0.0.1',
        localPort: deps.localPort,
      })
      tunnelId = created.id
      if (created.warning !== undefined) warning = created.warning
      record('ensure-tunnel', 'done', `已创建 TCP 隧道 ${String(created.id)}（${created.name}）`)
    }
  } catch (error) {
    return rethrowAsProvisionFailure(error, 'ensure-tunnel', steps)
  }

  let resolvedAddress: { readonly address: string; readonly node: SakuraFrpNode; readonly tunnel: SakuraFrpTunnel }
  try {
    const after = await deps.api.listTunnels()
    const resolved = after.find(candidate => candidate.id === tunnelId)
    if (resolved === undefined) {
      throw failError('resolve-address', 'sakura-bad-response', `隧道创建后未出现在隧道列表中（id ${String(tunnelId)}）。`)
    }
    const node = (await deps.api.listNodes()).find(candidate => candidate.id === resolved.node)
    if (node === undefined) {
      throw failError('resolve-address', 'sakura-bad-response', `隧道 ${String(tunnelId)} 所在节点 ${String(resolved.node)} 不在节点列表中。`)
    }
    const address = sakuraPublicAddress(node.host, resolved.remote)
    if (address === undefined) {
      throw failError('resolve-address', 'sakura-bad-response', `无法从节点 ${node.host} 与远程端口 ${resolved.remote} 推导公网地址。`)
    }
    resolvedAddress = { address, node, tunnel: resolved }
  } catch (error) {
    return rethrowAsProvisionFailure(error, 'resolve-address', steps)
  }
  record('resolve-address', 'done', `公网地址 ${resolvedAddress.address}，对外地址 wss://${resolvedAddress.address}`)

  let frpcPath = deps.resolveFrpcPath()
  let downloaded = false
  let version: string | undefined
  if (frpcPath === '') {
    if (!tunnel.frpcAutoDownload) {
      throw failError('prepare-frpc', 'frpc-missing', '未找到 frpc 可执行文件，且自动下载已关闭：请手动填写 frpc 路径后重试。')
    }
    try {
      const downloadedFrpc = await deps.downloadFrpc()
      frpcPath = downloadedFrpc.path
      version = downloadedFrpc.version
      downloaded = true
    } catch (error) {
      return rethrowAsProvisionFailure(error, 'prepare-frpc', steps)
    }
    record('prepare-frpc', 'done', `已下载并校验 frpc（${version ?? '未知版本'}）`)
  } else {
    record('prepare-frpc', 'skipped', `使用已有的 frpc：${frpcPath}`)
  }

  const tunnelCount = reusable === undefined ? tunnels.length + 1 : tunnels.length
  return {
    settings: {
      ...tunnel,
      provider: 'sakurafrp',
      autoProvision: true,
      nodeId: resolvedAddress.node.id,
      tunnelId,
      tunnelIds: String(tunnelId),
      publicAddress: resolvedAddress.address,
      frpcPath,
    },
    steps,
    account: toTunnelAccount(account, tunnelCount),
    node: {
      id: resolvedAddress.node.id,
      name: resolvedAddress.node.name,
      host: resolvedAddress.node.host,
    },
    tunnel: {
      id: resolvedAddress.tunnel.id,
      name: resolvedAddress.tunnel.name,
      remote: resolvedAddress.tunnel.remote,
    },
    frpc: {
      path: frpcPath,
      downloaded,
      ...(version === undefined ? {} : { version }),
    },
    ...(warning === undefined ? {} : { warning }),
  }
}

/** Find the saved tunnel or the same-name TCP tunnel to reuse. */
function findReusableTunnel(tunnels: readonly SakuraFrpTunnel[], tunnel: TunnelSettings): SakuraFrpTunnel | undefined {
  if (tunnel.tunnelId !== null) {
    const saved = tunnels.find(candidate => candidate.id === tunnel.tunnelId)
    if (saved !== undefined) return saved
  }
  return tunnels.find(candidate => candidate.type === 'tcp' && candidate.name === tunnel.tunnelName)
}

/**
 * Project the API account facts onto the page's account block.
 * @param account - account facts from the API client.
 * @param tunnelCount - tunnels the account owns after the provision.
 * @returns the page's account block.
 */
export function toTunnelAccount(account: SakuraFrpUserInfo, tunnelCount: number): TunnelAccount {
  const remaining = account.traffic?.[1]
  return {
    name: account.name,
    uid: account.id,
    ...(account.speed === undefined ? {} : { speed: account.speed }),
    ...(account.tunnels === undefined ? {} : { tunnelLimit: account.tunnels }),
    tunnelCount,
    ...(remaining === undefined ? {} : { trafficRemaining: remaining }),
  }
}

/**
 * Mark the failed step and fill the remaining steps as pending.
 * @param recorded - steps already reported.
 * @param failedId - step that failed.
 * @param message - failure message for the failed step.
 * @returns the complete step list.
 */
export function withPendingSteps(
  recorded: readonly ProvisionStep[],
  failedId: ProvisionStepId,
  message: string,
): readonly ProvisionStep[] {
  const byId = new Map(recorded.map(step => [step.id, step]))
  byId.set(failedId, { id: failedId, status: 'failed', message })
  return PROVISION_STEP_IDS.map(id => byId.get(id) ?? { id, status: 'pending', message: '等待上一步完成。' })
}

/**
 * Rebuild a caught API failure as a provision failure carrying the steps reached.
 * @param error - caught failure.
 * @param failedId - step that failed.
 * @param recorded - steps already reported.
 * @returns never; it throws the rebuilt failure.
 */
function rethrowAsProvisionFailure(
  error: unknown,
  failedId: ProvisionStepId,
  recorded: readonly ProvisionStep[],
): never {
  if (error instanceof TunnelProvisionError) throw error
  const code = typeof error === 'object' && error !== null && 'code' in error
    ? String((error as { readonly code?: unknown }).code)
    : 'sakura-api-error'
  const message = error instanceof Error ? error.message : String(error)
  throw new TunnelProvisionError(code, message, withPendingSteps(recorded, failedId, message))
}
