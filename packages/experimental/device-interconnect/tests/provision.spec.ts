/**
 * The one-click SakuraFrp provision: node selection, public-address derivation,
 * reuse versus creation, frpc preparation, and the step-based failure results.
 */

import { describe, expect, it } from 'vitest'
import { SakuraFrpApiError, type CreateTunnelRequest, type EditTunnelRequest, type SakuraFrpApi, type SakuraFrpCreatedTunnel, type SakuraFrpNode, type SakuraFrpTunnel, type SakuraFrpUserInfo } from '../src/host/sakurafrp-api.ts'
import {
  NODE_FLAG_BETA, NODE_FLAG_CREATABLE, NODE_FLAG_OFFLINE, isNodeUsable, provisionSakuraFrpTunnel, rankNodesByLatency,
  sakuraPublicAddress, selectSakuraFrpNode, toTunnelAccount,
} from '../src/host/provision.ts'
import type { LatencySample, LatencyTarget } from '../src/host/node-latency.ts'
import { TunnelProvisionError } from '../src/host/tunnel.ts'
import type { TunnelSettings } from '../src/types.ts'

/** One complete tunnel configuration. */
function tunnel(overrides: Partial<TunnelSettings> = {}): TunnelSettings {
  return {
    provider: 'sakurafrp',
    frpcPath: 'C:\\frpc\\frpc.exe',
    token: 'access-key',
    tunnelIds: '',
    publicAddress: '',
    iniPath: '',
    extraArgs: '',
    autoProvision: true,
    frpcAutoDownload: true,
    nodeId: null,
    tunnelName: 'DSH 设备互联',
    tunnelId: null,
    ...overrides,
  }
}

/** One service node. */
function node(overrides: Partial<SakuraFrpNode> = {}): SakuraFrpNode {
  return { id: 11, name: '节点 A', host: 'a.natfrp.cloud', vip: 0, flag: NODE_FLAG_CREATABLE, ...overrides }
}

/** One tunnel as the service reports it. */
function serviceTunnel(overrides: Partial<SakuraFrpTunnel> = {}): SakuraFrpTunnel {
  return {
    id: 5,
    name: 'DSH 设备互联',
    type: 'tcp',
    node: 11,
    localIp: '127.0.0.1',
    localPort: 4_777,
    remote: '12345',
    ...overrides,
  }
}

/** A scripted SakuraFrp API double. */
class FakeApi implements SakuraFrpApi {
  readonly calls: string[] = []
  user: SakuraFrpUserInfo = { id: 7, name: 'alice', frozen: false, tunnels: 2, traffic: [0, 100] }
  nodes: readonly SakuraFrpNode[] = [node()]
  tunnels: readonly SakuraFrpTunnel[] = []
  created: SakuraFrpCreatedTunnel | undefined
  fail: SakuraFrpApiError | undefined

  /** @returns the scripted account. */
  async userInfo(): Promise<SakuraFrpUserInfo> {
    this.calls.push('userInfo')
    if (this.fail !== undefined) throw this.fail
    return this.user
  }

  /** @returns the scripted nodes. */
  async listNodes(): Promise<readonly SakuraFrpNode[]> {
    this.calls.push('listNodes')
    return this.nodes
  }

  /** @returns the scripted tunnels. */
  async listTunnels(): Promise<readonly SakuraFrpTunnel[]> {
    this.calls.push('listTunnels')
    return this.tunnels
  }

  /**
   * Record and answer a creation.
   * @param request - creation request.
   * @returns the scripted created tunnel.
   */
  async createTunnel(request: CreateTunnelRequest): Promise<SakuraFrpCreatedTunnel> {
    this.calls.push('createTunnel')
    this.created = {
      id: 99,
      name: request.name,
      remote: '23456',
    }
    this.tunnels = [...this.tunnels, serviceTunnel({ id: 99, name: request.name, node: request.nodeId, remote: '23456' })]
    return this.created
  }

  /**
   * Record an edit.
   * @param request - edit request.
   * @returns completion.
   */
  async editTunnel(request: EditTunnelRequest): Promise<void> {
    this.calls.push(`editTunnel:${String(request.id)}`)
  }
}

/** Run one provision over the fake API with a resolved local frpc. */
function bench(overrides: {
  api?: FakeApi
  tunnel?: TunnelSettings
  frpcPath?: string
  downloadFrpc?: () => Promise<{ path: string; version: string }>
  reuseExisting?: boolean
  explicitNodeId?: number | null
  probeLatency?: (targets: readonly LatencyTarget[]) => Promise<readonly LatencySample[]>
  resolved?: (resolved: { readonly id: number; readonly nodeId: number; readonly name: string; readonly created: boolean }) => void
} = {}) {
  const api = overrides.api ?? new FakeApi()
  const downloads: boolean[] = []
  return {
    api,
    downloads,
    run: () => provisionSakuraFrpTunnel(overrides.tunnel ?? tunnel(), {
      api,
      localPort: 5_001,
      ...(overrides.reuseExisting === undefined ? {} : { reuseExisting: overrides.reuseExisting }),
      ...(overrides.explicitNodeId === undefined ? {} : { explicitNodeId: overrides.explicitNodeId }),
      probeLatency: overrides.probeLatency
        ?? (async targets => targets.map(target => ({ ...target, ms: 100 }))),
      ...(overrides.resolved === undefined ? {} : { onTunnelResolved: overrides.resolved }),
      resolveFrpcPath: () => overrides.frpcPath ?? 'C:\\frpc\\frpc.exe',
      downloadFrpc: () => {
        downloads.push(true)
        return (overrides.downloadFrpc ?? (async () => ({ path: 'C:\\managed\\frpc.exe', version: '0.51' })))()
      },
    }),
  }
}

describe('node selection', () => {
  it('filters nodes by capability flags and the account VIP level', () => {
    expect(isNodeUsable(node({ vip: 3 }), 3)).toBe(true)
    expect(isNodeUsable(node({ vip: 4 }), 3)).toBe(false)
    expect(isNodeUsable(node({ vip: 1 }), 0)).toBe(false)
    expect(isNodeUsable(node({ flag: NODE_FLAG_CREATABLE | NODE_FLAG_OFFLINE }), 3)).toBe(false)
    expect(isNodeUsable(node({ flag: NODE_FLAG_CREATABLE | NODE_FLAG_BETA }), 3)).toBe(false)
    expect(isNodeUsable(node({ flag: 0 }), 3)).toBe(false)
  })

  it('ranks reachable nodes by latency, preferring ordinary nodes on a tie', () => {
    const nodes = [
      node({ id: 1 }),
      node({ id: 2, vip: 3 }),
      node({ id: 3, vip: 1 }),
      node({ id: 4, vip: 0 }),
    ]
    const ranked = rankNodesByLatency(nodes, [
      { nodeId: 1, host: 'far', ms: 480 },
      { nodeId: 2, host: 'b', ms: 140 },
      { nodeId: 3, host: 'c', ms: 140 },
      { nodeId: 4, host: 'd', ms: 140 },
    ])
    expect(ranked.map(entry => entry.node.id)).toEqual([4, 2, 3, 1])
    expect(ranked[0]?.latencyMs).toBe(140)
  })

  it('selects the nearest reachable node automatically with a readable reason', async () => {
    const nodes = [
      node({ id: 1, name: '远节点', host: 'far.natfrp.cloud' }),
      node({ id: 2, name: '天津联通PLUS1', host: 'frp-act.com', vip: 0 }),
      node({ id: 3, name: '不可达节点', host: 'dead.natfrp.cloud' }),
    ]
    const selected = await selectSakuraFrpNode(nodes, {
      maxVip: 3,
      probeLatency: async targets => targets.map((target) => {
        if (target.nodeId === 3) return { nodeId: target.nodeId, host: target.host }
        return { nodeId: target.nodeId, host: target.host, ms: target.nodeId === 2 ? 140 : 480 }
      }),
    })
    expect(selected?.node.id).toBe(2)
    expect(selected?.latencyMs).toBe(140)
    expect(selected?.reason).toContain('天津联通PLUS1')
    expect(selected?.reason).toContain('普通节点')
    expect(selected?.reason).toContain('140 ms')
  })

  it('allows VIP nodes within the account group level only', async () => {
    const nodes = [node({ id: 1, name: 'VIP 节点', vip: 3, host: 'vip.natfrp.cloud' }), node({ id: 2, name: '普通节点', vip: 0 })]
    const level3 = await selectSakuraFrpNode(nodes, {
      maxVip: 3,
      probeLatency: async targets => targets.map(target => ({ ...target, ms: target.nodeId === 1 ? 100 : 200 })),
    })
    expect(level3?.node.id).toBe(1)
    const level0 = await selectSakuraFrpNode(nodes, {
      maxVip: 0,
      probeLatency: async targets => targets.map(target => ({ ...target, ms: 100 })),
    })
    expect(level0?.node.id).toBe(2)
  })

  it('falls back to the saved node when every probe fails, then to list order', async () => {
    const nodes = [node({ id: 1 }), node({ id: 2 }), node({ id: 3 })]
    const unreachable = async (targets: readonly LatencyTarget[]): Promise<readonly LatencySample[]> =>
      targets.map(target => ({ nodeId: target.nodeId, host: target.host }))
    const saved = await selectSakuraFrpNode(nodes, { maxVip: 0, probeLatency: unreachable, fallbackNodeId: 2 })
    expect(saved?.node.id).toBe(2)
    expect(saved?.reason).toContain('延迟探测全部失败')
    expect(saved?.reason).toContain('已保存节点')
    const ordered = await selectSakuraFrpNode(nodes, { maxVip: 0, probeLatency: unreachable })
    expect(ordered?.node.id).toBe(1)
    expect(ordered?.reason).toContain('按节点列表顺序回退')
  })

  it('respects an explicitly requested node without probing it', async () => {
    const probes: number[] = []
    const nodes = [node({ id: 1, name: '远节点' }), node({ id: 2, name: '指定节点' })]
    const selected = await selectSakuraFrpNode(nodes, {
      preferredId: 2,
      maxVip: 0,
      probeLatency: async (targets) => {
        probes.push(targets.length)
        return targets.map(target => ({ ...target, ms: 10 }))
      },
    })
    expect(selected?.node.id).toBe(2)
    expect(selected?.reason).toContain('使用指定节点')
    expect(probes).toEqual([])
  })

  it('rejects a pinned node that is missing or above the account VIP level', async () => {
    await expect(selectSakuraFrpNode([node({ id: 11 })], { preferredId: 12 }))
      .rejects.toThrow(/指定节点 12 不存在/)
    await expect(selectSakuraFrpNode([node({ id: 11, vip: 3 })], { preferredId: 11, maxVip: 0 }))
      .rejects.toThrow(/指定节点 节点 A 当前不可用/)
  })

  it('derives the public address from the node host and the remote value', () => {
    expect(sakuraPublicAddress('a.natfrp.cloud', '12345')).toBe('a.natfrp.cloud:12345')
    expect(sakuraPublicAddress('a.natfrp.cloud', 'a.natfrp.cloud:40000')).toBe('a.natfrp.cloud:40000')
    expect(sakuraPublicAddress('a.natfrp.cloud', '')).toBeUndefined()
    expect(sakuraPublicAddress('a.natfrp.cloud', 'not-a-port')).toBeUndefined()
  })

  it('projects the account facts', () => {
    expect(toTunnelAccount({ id: 7, name: 'alice', speed: 10, tunnels: 2, traffic: [0, 42], frozen: false }, 1))
      .toEqual({ name: 'alice', uid: 7, speed: 10, tunnelLimit: 2, tunnelCount: 1, trafficRemaining: 42 })
  })
})

describe('provision flow', () => {
  it('creates a tunnel, derives the address, and reuses the local frpc', async () => {
    const fake = new FakeApi()
    const { run } = bench({ api: fake })
    const result = await run()
    expect(fake.calls).toEqual(['userInfo', 'listNodes', 'listTunnels', 'createTunnel', 'listTunnels', 'listNodes'])
    expect(result.settings).toMatchObject({
      provider: 'sakurafrp',
      autoProvision: true,
      nodeId: 11,
      tunnelId: 99,
      tunnelIds: '99',
      publicAddress: 'a.natfrp.cloud:23456',
      frpcPath: 'C:\\frpc\\frpc.exe',
    })
    expect(result.tunnel).toMatchObject({ id: 99, remote: '23456' })
    expect(result.node).toMatchObject({ id: 11, host: 'a.natfrp.cloud' })
    expect(result.account).toMatchObject({ name: 'alice', tunnelCount: 1 })
    expect(result.frpc).toEqual({ path: 'C:\\frpc\\frpc.exe', downloaded: false })
    expect(result.steps.map(step => step.status)).toEqual(['done', 'done', 'done', 'done', 'skipped'])
  })

  it('reuses the same-name TCP tunnel and aligns its local port', async () => {
    const fake = new FakeApi()
    fake.tunnels = [serviceTunnel()]
    const result = await bench({ api: fake }).run()
    expect(fake.calls).toContain('editTunnel:5')
    expect(fake.calls).not.toContain('createTunnel')
    expect(result.settings.tunnelId).toBe(5)
    expect(result.steps[2]?.status).toBe('done')
  })

  it('creates a new tunnel when reuse is disabled', async () => {
    const fake = new FakeApi()
    fake.tunnels = [serviceTunnel()]
    await bench({ api: fake, reuseExisting: false }).run()
    expect(fake.calls).toContain('createTunnel')
  })

  it('refuses a frozen account with the failed step', async () => {
    const fake = new FakeApi()
    fake.user = { id: 7, name: 'alice', frozen: true, frozenReason: '账号已被冻结：违规' }
    const error = await bench({ api: fake }).run().catch((caught: unknown) => caught)
    expect(error).toBeInstanceOf(TunnelProvisionError)
    expect(error).toMatchObject({ code: 'sakura-account-frozen', message: '账号已被冻结：违规' })
    expect((error as TunnelProvisionError).steps[0]).toMatchObject({ id: 'verify-token', status: 'failed' })
    expect((error as TunnelProvisionError).steps.at(-1)).toMatchObject({ id: 'start-tunnel', status: 'pending' })
  })

  it('refuses an unverified account', async () => {
    const fake = new FakeApi()
    fake.user = { id: 7, name: 'alice', frozen: false, realname: 0 }
    await expect(bench({ api: fake }).run()).rejects.toMatchObject({ code: 'sakura-realname-required' })
  })

  it('reports a full tunnel quota when no tunnel can be reused', async () => {
    const fake = new FakeApi()
    fake.user = { id: 7, name: 'alice', frozen: false, tunnels: 1 }
    fake.tunnels = [serviceTunnel({ id: 8, name: '别的隧道', type: 'http' })]
    const error = await bench({ api: fake }).run().catch((caught: unknown) => caught)
    expect(error).toMatchObject({ code: 'sakura-quota-exceeded' })
    expect((error as TunnelProvisionError).steps[2]).toMatchObject({ id: 'ensure-tunnel', status: 'failed' })
  })

  it('maps an API failure onto a provision failure with the reached steps', async () => {
    const fake = new FakeApi()
    fake.fail = new SakuraFrpApiError('sakura-unauthorized', 'SakuraFrp 访问密钥无效。', 401)
    const error = await bench({ api: fake }).run().catch((caught: unknown) => caught)
    expect(error).toMatchObject({ code: 'sakura-unauthorized' })
    expect((error as TunnelProvisionError).steps[0]?.status).toBe('failed')
  })

  it('downloads frpc when it is missing and downloading is allowed', async () => {
    const { run, downloads } = bench({ frpcPath: '' })
    const result = await run()
    expect(downloads).toHaveLength(1)
    expect(result.frpc).toEqual({ path: 'C:\\managed\\frpc.exe', downloaded: true, version: '0.51' })
    expect(result.settings.frpcPath).toBe('C:\\managed\\frpc.exe')
    expect(result.steps[4]?.status).toBe('done')
  })

  it('refuses to start when frpc is missing and downloading is off', async () => {
    const error = await bench({ tunnel: tunnel({ frpcAutoDownload: false }), frpcPath: '' }).run()
      .catch((caught: unknown) => caught)
    expect(error).toMatchObject({ code: 'frpc-missing' })
    expect((error as TunnelProvisionError).steps[4]).toMatchObject({ id: 'prepare-frpc', status: 'failed' })
  })

  it('refuses when the created tunnel never appears in the list', async () => {
    const fake = new FakeApi()
    fake.createTunnel = async () => ({ id: 99, name: 'DSH' })
    const error = await bench({ api: fake }).run().catch((caught: unknown) => caught)
    expect(error).toMatchObject({ code: 'sakura-bad-response' })
  })
})

describe('dedup and nearest-node flow', () => {
  it('reports the resolved tunnel id before the remaining steps run', async () => {
    const fake = new FakeApi()
    const events: string[] = []
    const result = await bench({
      api: fake,
      resolved: (resolved) => { events.push(`resolved:${String(resolved.id)}:${String(resolved.nodeId)}:${String(resolved.created)}`) },
    }).run()
    expect(events).toEqual(['resolved:99:11:true'])
    expect(result.tunnel.id).toBe(99)
  })

  it('persists the created id when a later step fails so a retry can reuse it', async () => {
    const fake = new FakeApi()
    const persisted: number[] = []
    fake.createTunnel = async () => ({ id: 99, name: 'DSH' })
    const first = await bench({
      api: fake,
      resolved: (resolved) => { persisted.push(resolved.id) },
    }).run().catch((caught: unknown) => caught)
    expect(first).toBeInstanceOf(TunnelProvisionError)
    expect(persisted).toEqual([99])
  })

  it('hints without migrating when the reused tunnel sits on a farther node', async () => {
    const fake = new FakeApi()
    fake.tunnels = [serviceTunnel({ node: 2, remote: '23456' })]
    fake.nodes = [
      node({ id: 1, name: '天津联通PLUS1', host: 'frp-act.com' }),
      node({ id: 2, name: '长沙三线PLUS2', host: 'cs.natfrp.cloud', vip: 3 }),
    ]
    fake.user = { id: 7, name: 'alice', frozen: false, tunnels: 5, group: { name: '青铜VIP', level: 3 } }
    const result = await bench({
      api: fake,
      probeLatency: async targets => targets.map(target => ({
        ...target,
        ms: target.nodeId === 1 ? 140 : 480,
      })),
    }).run()
    expect(fake.calls).not.toContain('createTunnel')
    const hint = result.steps.find(step => step.id === 'node-distance')
    expect(hint?.message).toContain('提示')
    expect(hint?.message).toContain('未自动迁移')
    expect(hint?.message).toContain('长沙三线PLUS2')
    expect(hint?.message).toContain('天津联通PLUS1')
  })

  it('uses the reused tunnel node without a distance hint when it is nearest', async () => {
    const fake = new FakeApi()
    fake.tunnels = [serviceTunnel({ node: 11 })]
    const result = await bench({ api: fake }).run()
    expect(result.steps.some(step => step.id === 'node-distance')).toBe(false)
  })

  it('ignores the persisted node id in auto mode but honours an explicit one', async () => {
    const fake = new FakeApi()
    fake.nodes = [
      node({ id: 1, name: '近节点', host: 'near.natfrp.cloud' }),
      node({ id: 2, name: '保存节点', host: 'saved.natfrp.cloud' }),
    ]
    const auto = await bench({
      api: fake,
      tunnel: tunnel({ nodeId: 2 }),
      probeLatency: async targets => targets.map(target => ({ ...target, ms: target.nodeId === 1 ? 100 : 300 })),
    }).run()
    expect(auto.settings.nodeId).toBe(1)
    fake.calls.length = 0
    fake.tunnels = []
    const explicit = await bench({
      api: fake,
      explicitNodeId: 2,
      probeLatency: async targets => targets.map(target => ({ ...target, ms: target.nodeId === 1 ? 100 : 300 })),
    }).run()
    expect(explicit.settings.nodeId).toBe(2)
  })
})
