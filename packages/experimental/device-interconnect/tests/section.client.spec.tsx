// @vitest-environment jsdom
/**
 * The Settings page as it renders: status and switch, long-term pairing card,
 * listener settings, paired devices with their confirmation, runner problems,
 * and the child output — plus the polling lifecycle the page drives.
 */

import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createSnapshotStore } from '@deepseek-ai/dsh-client-store'
import { bindSnapshotSelector } from '@deepseek-ai/dsh-client-test-runtime'
import {
  DeviceInterconnectSection, type DeviceInterconnectSectionProps,
} from '../src/client/DeviceInterconnectSection.tsx'
import type { DeviceInterconnectActions, SectionSnapshot } from '../src/client/controller.ts'
import { en } from '../src/client/locales.ts'
import type { DeviceInterconnectView, RuntimeState, TunnelState } from '../src/types.ts'

afterEach(cleanup)

/** English copy with placeholder interpolation, as the locale service resolves it. */
const COPY: Readonly<Record<string, string>> = en
const t: DeviceInterconnectSectionProps['t'] = (key, params) =>
  (COPY[key] ?? key).replace(/\{(\w+)\}/gu, (match: string, name: string) =>
    params !== undefined && name in params ? String(params[name]) : match)

/** One complete configuration document. */
function config(overrides: Partial<DeviceInterconnectView> = {}): DeviceInterconnectView {
  return {
    enabled: true,
    runner: { nodePath: 'C:\\node\\node.exe', pnpmPath: 'C:\\pnpm\\pnpm.mjs', repoDir: 'D:\\repo', profile: 'remote-host', patchPath: '', dshHome: '' },
    host: {
      port: 4_777, host: '0.0.0.0', publicHost: '', publicOrigin: '',
      discoveryEnabled: true, discoveryPort: 4_778, pagesEnabled: true, pagesPort: 4_780,
    },
    pairing: { longTerm: true, pairingTtlMs: 2_592_000_000 },
    tunnel: {
      provider: 'sakurafrp',
      frpcPath: 'C:\\frpc\\frpc.exe',
      tunnelIds: '114514',
      publicAddress: 'cn-xx.natfrp.cloud:12345',
      iniPath: '',
      extraArgs: '',
      tokenConfigured: true,
      autoProvision: true,
      frpcAutoDownload: true,
      nodeId: null,
      tunnelName: 'DSH 设备互联',
      tunnelId: 114514,
    },
    ...overrides,
  }
}

/** One tunnel runtime state. */
function tunnelState(overrides: Partial<TunnelState> = {}): TunnelState {
  return {
    provider: 'sakurafrp',
    running: false,
    ready: true,
    problems: [],
    derivedPublicOrigin: 'wss://cn-xx.natfrp.cloud:12345',
    logsTail: '',
    ...overrides,
  }
}

/** One open long-term pairing window over one paired device. */
function runtime(overrides: Partial<RuntimeState> = {}): RuntimeState {
  return {
    config: config(),
    child: { running: true, pid: 42, startedAt: 1, logsTail: 'remote host listening on 4777\n' },
    tunnel: tunnelState(),
    controlPlane: {
      reachable: true,
      host: {
        name: 'PC', instanceId: 'a'.repeat(64), origin: 'wss://192.168.1.20:4777', port: 4_777,
        discovery: { enabled: true, port: 4_778 }, listening: true,
      },
    },
    pairing: {
      open: true,
      expiresAt: 1_900_000_000_000,
      pairUrl: 'wss://192.168.1.20:4777#token=t',
      usbPairUrl: 'wss://127.0.0.1:4777#token=t',
      longTerm: true,
      qrSvgUrl: '/device-interconnect/api/qr.svg?v=1900000000000',
    },
    devices: [
      { id: '0123456789abcdef0123456789abcdef', label: 'Pixel', createdAt: 1, lastSeenAt: 2, expiresAt: 1_900_000_000_000 },
    ],
    runner: { ready: true, problems: [] },
    problems: [],
    ...overrides,
  }
}

/** One staged configuration draft matching {@link runtime}. */
function draft(): NonNullable<SectionSnapshot['draft']> {
  return {
    port: '4777', listenHost: '0.0.0.0', publicHost: '', publicOrigin: '',
    discoveryEnabled: true, discoveryPort: '4778', pagesEnabled: true, pagesPort: '4780',
    longTerm: true, nodePath: 'C:\\node\\node.exe', pnpmPath: 'C:\\pnpm\\pnpm.mjs',
    repoDir: 'D:\\repo', profile: 'remote-host', patchPath: '', dshHome: '',
    tunnelProvider: 'sakurafrp', frpcPath: 'C:\\frpc\\frpc.exe', tunnelToken: '',
    tunnelIds: '114514', publicAddress: 'cn-xx.natfrp.cloud:12345', tunnelIniPath: '', tunnelExtraArgs: '',
    autoProvision: true, frpcAutoDownload: true, nodeId: '', tunnelName: 'DSH 设备互联',
  }
}

/** The staged draft of the manual (advanced) tunnel mode. */
function manualDraft(): NonNullable<SectionSnapshot['draft']> {
  return { ...draft(), autoProvision: false }
}

/** One action surface whose calls the test inspects. */
function stubActions(overrides: Partial<DeviceInterconnectActions> = {}): DeviceInterconnectActions {
  return {
    open: vi.fn(),
    close: vi.fn(),
    refresh: vi.fn(async () => {}),
    setEnabled: vi.fn(async () => {}),
    setTunnelEnabled: vi.fn(async () => {}),
    edit: vi.fn(),
    toggle: vi.fn(),
    selectTunnelProvider: vi.fn(),
    provision: vi.fn(async () => {}),
    save: vi.fn(async () => {}),
    regeneratePairing: vi.fn(async () => {}),
    revokeDevice: vi.fn(async () => {}),
    dismissNotice: vi.fn(),
    ...overrides,
  }
}

/** Render the page over one snapshot and one action surface. */
function renderPage(snapshot: Partial<SectionSnapshot> = {}, overrides: Partial<DeviceInterconnectActions> = {}) {
  const store = createSnapshotStore<SectionSnapshot>({
    phase: 'ready',
    busy: false,
    state: runtime(),
    draft: draft(),
    ...snapshot,
  })
  const actions = stubActions(overrides)
  const props = {
    close: vi.fn(),
    t,
    useDeviceInterconnect: bindSnapshotSelector(store),
    actions,
  } as DeviceInterconnectSectionProps
  return { ...render(<DeviceInterconnectSection {...props} />), store, actions }
}

describe('Device Interconnect Settings page', () => {
  it('shows the running status, the switch, and the listener facts', () => {
    const { actions } = renderPage()
    expect(screen.getByText('Running')).toBeTruthy()
    expect(screen.getByText(/wss:\/\/192\.168\.1\.20:4777/u)).toBeTruthy()
    const toggle = screen.getByRole('switch', { name: 'Run remote host' })
    expect(toggle.getAttribute('aria-checked')).toBe('true')
    fireEvent.click(toggle)
    expect(actions.setEnabled).toHaveBeenCalledWith(false)
  })

  it('shows the switch as off and disabled while an action is in flight', () => {
    renderPage({ busy: true })
    const toggle = screen.getByRole('switch', { name: 'Run remote host' })
    expect((toggle as HTMLButtonElement).disabled).toBe(true)
  })

  it('renders the long-term pairing card with the QR image and link', () => {
    const { actions } = renderPage()
    expect(screen.getByText('Always available')).toBeTruthy()
    const qr = screen.getByAltText('Pairing QR code') as HTMLImageElement
    expect(qr.getAttribute('src')).toBe('/device-interconnect/api/qr.svg?v=1900000000000')
    expect((screen.getByLabelText('Pairing link') as HTMLInputElement).value).toBe('wss://192.168.1.20:4777#token=t')
    // Long-term pairing shows no countdown, only the window's fixed expiry time.
    expect(screen.queryByText(/\bseconds?\b/iu)).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'New pairing link' }))
    expect(actions.regeneratePairing).toHaveBeenCalled()
  })

  it('explains a closed pairing window instead of rendering an image', () => {
    renderPage({ state: runtime({ pairing: { open: false, longTerm: true } }) })
    expect(screen.getByText('No pairing window is open.')).toBeTruthy()
    expect(screen.queryByAltText('Pairing QR code')).toBeNull()
  })

  it('reveals the USB pairing link in a collapsible section', () => {
    renderPage()
    expect(screen.getByText('USB connection (phone and computer on different networks)')).toBeTruthy()
    expect(screen.getByLabelText('USB pairing link')).toBeTruthy()
  })

  it('lists paired devices and revokes one after confirmation', async () => {
    const { actions } = renderPage()
    expect(screen.getByText('Pixel')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }))
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByText('Revoke this device?')).toBeTruthy()
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'Revoke' }))
    })
    expect(actions.revokeDevice).toHaveBeenCalledWith('0123456789abcdef0123456789abcdef')
  })

  it('keeps the device when the confirmation is cancelled', () => {
    const { actions } = renderPage()
    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(actions.revokeDevice).not.toHaveBeenCalled()
  })

  it('stages listener edits and saves them', () => {
    const { actions } = renderPage()
    fireEvent.change(screen.getByLabelText('Listening port'), { target: { value: '5000' } })
    expect(actions.edit).toHaveBeenCalledWith('port', '5000')
    fireEvent.click(screen.getByRole('switch', { name: 'UDP LAN discovery' }))
    expect(actions.toggle).toHaveBeenCalledWith('discoveryEnabled', false)
    fireEvent.click(screen.getByRole('switch', { name: 'Long-term pairing' }))
    expect(actions.toggle).toHaveBeenCalledWith('longTerm', false)
    fireEvent.click(screen.getByRole('button', { name: 'Save settings' }))
    expect(actions.save).toHaveBeenCalled()
  })

  it('changes the runner paths from the advanced section', () => {
    const { actions } = renderPage()
    fireEvent.change(screen.getByLabelText('Node.js path'), { target: { value: 'C:\\other\\node.exe' } })
    expect(actions.edit).toHaveBeenCalledWith('nodePath', 'C:\\other\\node.exe')
  })

  it('reports runner problems and the child output', () => {
    renderPage({
      state: runtime({
        runner: {
          ready: false,
          problems: [{ code: 'runner-pnpm-missing', message: 'pnpm.mjs 不存在：C:\\pnpm\\pnpm.mjs' }],
        },
      }),
    })
    expect(screen.getByText(/The runner is incomplete/u)).toBeTruthy()
    fireEvent.click(screen.getByText('Child process output'))
    expect(screen.getByText(/remote host listening on 4777/u)).toBeTruthy()
  })

  it('shows the saved notice and lets it be dismissed', () => {
    const { actions } = renderPage({ notice: { kind: 'success', text: { key: 'saved' } } })
    expect(screen.getByText('Settings saved.')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }))
    expect(actions.dismissNotice).toHaveBeenCalled()
  })

  it('localizes a known failure code and falls back to the server message', () => {
    const { unmount } = renderPage({
      notice: { kind: 'error', text: { diagnostic: { code: 'control-unreachable', message: '连不上。' } } },
    })
    expect(screen.getByText('The local pairing control is unreachable. Check that the remote host is running.')).toBeTruthy()
    unmount()
    renderPage({
      notice: { kind: 'error', text: { diagnostic: { code: 'custom-code', message: '自定义说明' } } },
    })
    expect(screen.getByText('自定义说明')).toBeTruthy()
  })

  it('reports an unreachable control plane in the status card', () => {
    renderPage({
      state: runtime({
        controlPlane: { reachable: false, error: { code: 'control-unreachable', message: '连不上。' } },
        pairing: { open: false, longTerm: true },
      }),
    })
    expect(screen.getByText('The local pairing control is unreachable. Check that the remote host is running.')).toBeTruthy()
  })

  it('renders a localized failure when the first snapshot cannot be read', () => {
    const store = createSnapshotStore<SectionSnapshot>({
      phase: 'error',
      busy: false,
      error: { code: 'control-unreachable', message: '连不上。' },
    })
    const props = {
      close: vi.fn(),
      t,
      useDeviceInterconnect: bindSnapshotSelector(store),
      actions: stubActions(),
    } as DeviceInterconnectSectionProps
    render(<DeviceInterconnectSection {...props} />)
    expect(screen.getByRole('status').textContent).toBe('The local pairing control is unreachable. Check that the remote host is running.')
  })

  it('starts polling when the page mounts and stops when it unmounts', () => {
    const { actions, unmount } = renderPage()
    expect(actions.open).toHaveBeenCalledOnce()
    unmount()
    expect(actions.close).toHaveBeenCalledOnce()
  })
})

describe('Device Interconnect tunnel card', () => {
  it('renders the provider, the frpc fields, the TCP-only warning, and the derived origin', () => {
    renderPage({ draft: manualDraft() })
    expect(screen.getByText('NAT traversal (SakuraFrp)')).toBeTruthy()
    expect(screen.getByText(/Use a TCP tunnel/u)).toBeTruthy()
    expect((screen.getByLabelText('Tunnel provider') as HTMLSelectElement).value).toBe('sakurafrp')
    expect((screen.getByLabelText('frpc executable') as HTMLInputElement).value).toBe('C:\\frpc\\frpc.exe')
    expect((screen.getByLabelText('Tunnel IDs') as HTMLInputElement).value).toBe('114514')
    expect((screen.getByLabelText('Public address') as HTMLInputElement).value).toBe('cn-xx.natfrp.cloud:12345')
    expect((screen.getByLabelText('Effective public origin') as HTMLInputElement).value)
      .toBe('wss://cn-xx.natfrp.cloud:12345')
  })

  it('keeps the access key write-only with a stored placeholder', () => {
    renderPage()
    const token = screen.getByLabelText('Access key') as HTMLInputElement
    expect(token.type).toBe('password')
    expect(token.value).toBe('')
    expect(token.placeholder).toBe('Stored - leave empty to keep it')
  })

  it('stages every tunnel field and saves the page', () => {
    const { actions } = renderPage({ draft: manualDraft() })
    fireEvent.change(screen.getByLabelText('frpc executable'), { target: { value: 'C:\\other\\frpc.exe' } })
    expect(actions.edit).toHaveBeenCalledWith('frpcPath', 'C:\\other\\frpc.exe')
    fireEvent.change(screen.getByLabelText('Access key'), { target: { value: 'new-key' } })
    expect(actions.edit).toHaveBeenCalledWith('tunnelToken', 'new-key')
    fireEvent.change(screen.getByLabelText('Tunnel IDs'), { target: { value: '114514,114516' } })
    expect(actions.edit).toHaveBeenCalledWith('tunnelIds', '114514,114516')
    fireEvent.change(screen.getByLabelText('Public address'), { target: { value: 'node.example.test:443' } })
    expect(actions.edit).toHaveBeenCalledWith('publicAddress', 'node.example.test:443')
    fireEvent.change(screen.getByLabelText('Custom frpc.ini (optional)'), { target: { value: 'C:\\frpc\\frpc.ini' } })
    expect(actions.edit).toHaveBeenCalledWith('tunnelIniPath', 'C:\\frpc\\frpc.ini')
    fireEvent.change(screen.getByLabelText('Extra frpc arguments'), { target: { value: '--log_level debug' } })
    expect(actions.edit).toHaveBeenCalledWith('tunnelExtraArgs', '--log_level debug')
    fireEvent.click(screen.getByRole('button', { name: 'Save tunnel settings' }))
    expect(actions.save).toHaveBeenCalled()
  })

  it('changes the provider selection', () => {
    const { actions } = renderPage()
    fireEvent.change(screen.getByLabelText('Tunnel provider'), { target: { value: 'none' } })
    expect(actions.selectTunnelProvider).toHaveBeenCalledWith('none')
  })

  it('hides the tunnel fields while the provider is off', () => {
    renderPage({ draft: { ...draft(), tunnelProvider: 'none' } })
    expect(screen.queryByLabelText('frpc executable')).toBeNull()
    expect(screen.queryByText(/Use a TCP tunnel/u)).toBeNull()
  })

  it('starts and stops the tunnel from the status row', () => {
    const idle = renderPage()
    fireEvent.click(screen.getByRole('button', { name: 'Start tunnel' }))
    expect(idle.actions.setTunnelEnabled).toHaveBeenCalledWith(true)
    cleanup()
    const running = renderPage({ state: runtime({ tunnel: tunnelState({ running: true, pid: 7, startedAt: 1 }) }) })
    fireEvent.click(screen.getByRole('button', { name: 'Stop tunnel' }))
    expect(running.actions.setTunnelEnabled).toHaveBeenCalledWith(false)
  })

  it('disables the start action while the settings are incomplete', () => {
    renderPage({
      state: runtime({
        tunnel: tunnelState({
          ready: false,
          problems: [{ code: 'tunnel-frpc-missing', message: 'frpc 可执行文件不存在：C:\\frpc\\frpc.exe' }],
        }),
      }),
    })
    expect(screen.getByText('Settings incomplete')).toBeTruthy()
    expect(screen.getByText(/The tunnel settings are incomplete/u)).toBeTruthy()
    const start = screen.getByRole('button', { name: 'Start tunnel' }) as HTMLButtonElement
    expect(start.disabled).toBe(true)
  })

  it('shows a failed tunnel and offers a retry', () => {
    const { actions } = renderPage({
      state: runtime({ tunnel: tunnelState({ running: false, error: 'frpc 隧道子进程退出（代码 1）' }) }),
    })
    expect(screen.getByText('Failed to start')).toBeTruthy()
    expect(screen.getByText('frpc 隧道子进程退出（代码 1）')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(actions.setTunnelEnabled).toHaveBeenCalledWith(true)
  })

  it('reveals the frpc output', () => {
    renderPage({ state: runtime({ tunnel: tunnelState({ running: true, logsTail: 'start proxy success\n' }) }) })
    fireEvent.click(screen.getByText('frpc output'))
    expect(screen.getByText(/start proxy success/u)).toBeTruthy()
  })

  it('offers the one-click action and asks for confirmation before creating a tunnel', async () => {
    const { actions } = renderPage()
    fireEvent.click(screen.getByRole('button', { name: 'Save and create tunnel' }))
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByText('Create a SakuraFrp tunnel?')).toBeTruthy()
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'Create and start' }))
    })
    expect(actions.provision).toHaveBeenCalled()
  })

  it('shows the account, node, tunnel, steps, failure, and provider warning', () => {
    renderPage({
      state: runtime({
        tunnel: tunnelState({
          ready: true,
          account: { name: 'alice', uid: 1, tunnelLimit: 2, tunnelCount: 1, trafficRemaining: 100 },
          node: { id: 11, name: 'Node A', host: 'cn-xx.natfrp.cloud' },
          tunnel: { id: 114514, name: 'DSH 设备互联', remote: '12345' },
          provision: {
            lastSteps: [
              { id: 'verify-token', status: 'done', message: '已校验账号 alice' },
              { id: 'start-tunnel', status: 'failed', message: '启动失败' },
            ],
            lastError: { code: 'sakura-timeout', message: '超时。' },
            warning: '请仅用于个人使用',
          },
        }),
      }),
    })
    expect(screen.getByText('SakuraFrp account alice · tunnels 1/2')).toBeTruthy()
    expect(screen.getByText('Node 11 Node A (cn-xx.natfrp.cloud)')).toBeTruthy()
    expect(screen.getByText('Tunnel #114514 DSH 设备互联')).toBeTruthy()
    expect(screen.getByText('Done')).toBeTruthy()
    expect(screen.getByText('Failed')).toBeTruthy()
    expect(screen.getByText('The SakuraFrp API timed out; retry.')).toBeTruthy()
    expect(screen.getByText('SakuraFrp notice: 请仅用于个人使用')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Retry automatic setup' })).toBeTruthy()
  })

  it('falls back to the pending-origin hint when no address is configured', () => {
    renderPage({
      state: runtime({
        config: config({ tunnel: { ...config().tunnel, publicAddress: '' } }),
        tunnel: tunnelState({ ready: false, problems: [], derivedPublicOrigin: '' }),
      }),
    })
    expect(screen.getByText(/Fill in the public address/u)).toBeTruthy()
  })
})
