/**
 * The one-click SakuraFrp provision: node selection, public-address derivation,
 * reuse versus creation, frpc preparation, and the step-based failure results.
 */

import { describe, expect, it } from 'vitest'
import { SakuraFrpApiError, type CreateTunnelRequest, type EditTunnelRequest, type SakuraFrpApi, type SakuraFrpCreatedTunnel, type SakuraFrpNode, type SakuraFrpTunnel, type SakuraFrpUserInfo } from '../src/host/sakurafrp-api.ts'
import {
  NODE_FLAG_BETA, NODE_FLAG_CREATABLE, NODE_FLAG_OFFLINE, isNodeUsable, provisionSakuraFrpTunnel,
  sakuraPublicAddress, selectSakuraFrpNode, toTunnelAccount,
} from '../src/host/provision.ts'
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
    this.tunnels = [...this.tunnels, serviceTunnel({ id: 99, name: request.name, remote: '23456' })]
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
      resolveFrpcPath: () => overrides.frpcPath ?? 'C:\\frpc\\frpc.exe',
      downloadFrpc: () => {
        downloads.push(true)
        return (overrides.downloadFrpc ?? (async () => ({ path: 'C:\\managed\\frpc.exe', version: '0.51' })))()
      },
    }),
  }
}

describe('node selection', () => {
  it('prefers the first node that can create tunnels, in service order', () => {
    const nodes = [
      node({ id: 1, flag: NODE_FLAG_CREATABLE | NODE_FLAG_OFFLINE }),
      node({ id: 2, vip: 1 }),
      node({ id: 3, flag: NODE_FLAG_CREATABLE | NODE_FLAG_BETA }),
      node({ id: 4, name: '可用节点' }),
    ]
    expect(isNodeUsable(nodes[0] as SakuraFrpNode)).toBe(false)
    const selected = selectSakuraFrpNode(nodes, null)
    expect(selected?.node.id).toBe(4)
    expect(selected?.reason).toContain('自动选择节点 可用节点')
    expect(selectSakuraFrpNode([node({ flag: 0 })], null)).toBeUndefined()
  })

  it('validates a pinned node', () => {
    expect(selectSakuraFrpNode([node({ id: 11 })], 11)?.reason).toContain('使用指定节点')
    expect(() => selectSakuraFrpNode([node({ id: 11, vip: 1 })], 11))
      .toThrowError(/指定节点 节点 A 当前不可用/)
    expect(() => selectSakuraFrpNode([node({ id: 11 })], 12))
      .toThrowError(/指定节点 12 不存在/)
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
