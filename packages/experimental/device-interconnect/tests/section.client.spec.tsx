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
import type { DeviceInterconnectConfig, RuntimeState } from '../src/types.ts'

afterEach(cleanup)

/** English copy with placeholder interpolation, as the locale service resolves it. */
const COPY: Readonly<Record<string, string>> = en
const t: DeviceInterconnectSectionProps['t'] = (key, params) =>
  (COPY[key] ?? key).replace(/\{(\w+)\}/gu, (match: string, name: string) =>
    params !== undefined && name in params ? String(params[name]) : match)

/** One complete configuration document. */
function config(overrides: Partial<DeviceInterconnectConfig> = {}): DeviceInterconnectConfig {
  return {
    enabled: true,
    runner: { nodePath: 'C:\\node\\node.exe', pnpmPath: 'C:\\pnpm\\pnpm.mjs', repoDir: 'D:\\repo', profile: 'remote-host', patchPath: '', dshHome: '' },
    host: {
      port: 4_777, host: '0.0.0.0', publicHost: '', publicOrigin: '',
      discoveryEnabled: true, discoveryPort: 4_778, pagesEnabled: true, pagesPort: 4_780,
    },
    pairing: { longTerm: true, pairingTtlMs: 2_592_000_000 },
    ...overrides,
  }
}

/** One open long-term pairing window over one paired device. */
function runtime(overrides: Partial<RuntimeState> = {}): RuntimeState {
  return {
    config: config(),
    child: { running: true, pid: 42, startedAt: 1, logsTail: 'remote host listening on 4777\n' },
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
  }
}

/** One action surface whose calls the test inspects. */
function stubActions(overrides: Partial<DeviceInterconnectActions> = {}): DeviceInterconnectActions {
  return {
    open: vi.fn(),
    close: vi.fn(),
    refresh: vi.fn(async () => {}),
    setEnabled: vi.fn(async () => {}),
    edit: vi.fn(),
    toggle: vi.fn(),
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
