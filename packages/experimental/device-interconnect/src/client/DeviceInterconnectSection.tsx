/**
 * The Device Interconnect Settings page: the supervised remote host's switch
 * and status, its long-term pairing QR code, the listener settings, the paired
 * devices, and the collapsible runner paths and child output.
 *
 * The page owns no subscription: the controller in the inject face holds the
 * polling driver and the staged configuration, and the renderer binds its store
 * to `useDeviceInterconnect`.
 */

import { useEffect, useId, useState } from 'react'
import type { SnapshotStore } from '@deepseek-ai/dsh-client-store'
import {
  Button, Input, Modal, Switch, Tag, useClipboardCopy,
} from '@deepseek-ai/dsh-client-ui-primitives'
import type { InjectFace, PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
import type { DeviceInterconnectActions, SectionSnapshot } from './controller.ts'
import { diagnosticText } from './locales.ts'
import type { Diagnostic, RemoteDevice, RuntimeState, TunnelProvider } from '../types.ts'
import styles from './DeviceInterconnectSection.module.css'

/** Registrant-private reactive facts plus the page's action surface. */
export interface DeviceInterconnectFace {
  /** Bare observable bound as `useDeviceInterconnect`. */
  readonly hooks: { readonly deviceInterconnect: SnapshotStore<SectionSnapshot> }
  /** Every page action. */
  readonly actions: DeviceInterconnectActions
}

/** Props the settings shell binds for the Device Interconnect section. */
export type DeviceInterconnectSectionProps =
  PropsRuntime<'settings.section'>
  & PropsLocale<'settings.deviceInterconnect'>
  & InjectFace<DeviceInterconnectFace>

type T = DeviceInterconnectSectionProps['t']

/**
 * Format one instant in the browser's locale.
 * @param value - Unix milliseconds.
 * @returns a localized date and time, or an em dash for an invalid value.
 */
function formatInstant(value: number): string {
  if (!Number.isFinite(value)) return '—'
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'short', timeStyle: 'short' }).format(new Date(value))
}

/**
 * Whether one device is usable right now.
 * @param device - device summary.
 * @param now - current Unix milliseconds.
 * @returns the device's lifecycle state.
 */
function deviceState(device: RemoteDevice, now: number): 'active' | 'revoked' | 'expired' {
  if (device.revokedAt !== undefined) return 'revoked'
  return device.expiresAt > now ? 'active' : 'expired'
}

/**
 * The section's child status line.
 * @param props - the child state and its copy.
 * @returns the status tag and detail text.
 */
function statusOf(props: {
  runtime: RuntimeState
  t: T
}): { readonly label: string; readonly tone: 'success' | 'danger' | 'neutral' | 'warning'; readonly detail: string } {
  const { child } = props.runtime
  const { t } = props
  if (child.running) return { label: t('statusRunning'), tone: 'success', detail: '' }
  if (child.error !== undefined) return { label: t('statusFailed'), tone: 'danger', detail: child.error }
  if (props.runtime.config.enabled) return { label: t('statusStarting'), tone: 'warning', detail: '' }
  return { label: t('statusStopped'), tone: 'neutral', detail: '' }
}

/**
 * Render one labelled text control.
 * @param props - the field label, value, hint, and edit callback.
 * @returns the labelled input row.
 */
function TextField(props: {
  label: string
  value: string
  hint?: string
  placeholder?: string
  password?: boolean
  numeric?: boolean
  disabled: boolean
  onEdit: (value: string) => void
}) {
  const id = useId()
  return (
    <div className={styles.field}>
      <label className={styles.fieldLabel} htmlFor={id}>{props.label}</label>
      <Input id={id} value={props.value} disabled={props.disabled}
        type={props.password === true ? 'password' : undefined}
        autoComplete={props.password === true ? 'off' : undefined}
        placeholder={props.placeholder}
        inputMode={props.numeric === true ? 'numeric' : undefined}
        onChange={(event) => { props.onEdit(event.currentTarget.value) }} />
      {props.hint !== undefined && <p className={styles.hint}>{props.hint}</p>}
    </div>
  )
}

/**
 * Render one labelled toggle row.
 * @param props - the label, checked state, and change callback.
 * @returns the switch row.
 */
function ToggleField(props: { label: string; checked: boolean; disabled: boolean; onChange: (next: boolean) => void }) {
  return (
    <div className={styles.switchRow}>
      <Switch checked={props.checked} disabled={props.disabled} label={props.label}
        onChange={(next) => { props.onChange(next) }} />
      <span className={styles.fieldLabel}>{props.label}</span>
    </div>
  )
}

/**
 * Render a copyable read-only text plus its copy button.
 * @param props - the visible label, the text, the copy-button copy, and the copied confirmation.
 * @returns the link field.
 */
function CopyField(props: { label: string; text: string; copyLabel: string; copiedLabel: string }) {
  const id = useId()
  const clipboard = useClipboardCopy(props.text)
  return (
    <div className={styles.field}>
      <label className={styles.fieldLabel} htmlFor={id}>{props.label}</label>
      <div className={styles.linkField}>
        <Input id={id} className={styles.linkInput ?? ''} readOnly value={props.text}
          onFocus={(event) => { event.currentTarget.select() }} />
        <Button variant="outline" size="sm" onClick={clipboard.onCopy}>
          {clipboard.copied ? props.copiedLabel : props.copyLabel}
        </Button>
      </div>
    </div>
  )
}

/**
 * Render one diagnostic message in the page's copy.
 * @param props - the diagnostic and the locale reader.
 * @returns the inline error text.
 */
function DiagnosticLine(props: { diagnostic: Diagnostic; t: T }) {
  return <p className={`${styles.hint} ${styles.danger}`}>{diagnosticText(props.t, props.diagnostic)}</p>
}

/**
 * The managed NAT-traversal card: the one-click automatic setup, its steps and
 * account facts, plus the manual fields kept as an advanced option.
 * @param props - the runtime snapshot, the staged configuration, and the page actions.
 * @returns the collapsible tunnel card.
 */
function TunnelCard(props: {
  runtime: RuntimeState
  draft: NonNullable<SectionSnapshot['draft']>
  actions: DeviceInterconnectActions
  busy: boolean
  t: T
}) {
  const { runtime, draft, actions, busy, t } = props
  const tunnel = runtime.tunnel
  const config = runtime.config
  const sakurafrp = draft.tunnelProvider === 'sakurafrp'
  const [confirmOpen, setConfirmOpen] = useState(false)
  const canStart = tunnel.ready && runtime.child.running
  const status = !sakurafrp
    ? { label: t('tunnelStatusOff'), tone: 'neutral' as const }
    : tunnel.running
      ? { label: t('statusRunning'), tone: 'success' as const }
      : tunnel.error !== undefined
        ? { label: t('statusFailed'), tone: 'danger' as const }
        : tunnel.ready
          ? { label: t('statusStopped'), tone: 'neutral' as const }
          : { label: t('tunnelStatusIncomplete'), tone: 'warning' as const }
  const actionLabel = tunnel.running ? t('tunnelStop') : tunnel.error !== undefined ? t('tunnelRetry') : t('tunnelStart')
  const providerOptions: readonly { value: TunnelProvider; label: string }[] = [
    { value: 'none', label: t('tunnelProviderNone') },
    { value: 'sakurafrp', label: t('tunnelProviderSakuraFrp') },
  ]
  const providerId = useId()
  const account = tunnel.account
  const provision = tunnel.provision
  const accountLine = account === undefined
    ? undefined
    : t('tunnelAccountLine', {
      name: account.name ?? t('tunnelUnknown'),
      tunnels: `${String(account.tunnelCount ?? 0)}/${String(account.tunnelLimit ?? '—')}`,
    })
  const stepTone = (status: string): 'success' | 'danger' | 'neutral' | 'warning' => {
    if (status === 'done') return 'success'
    if (status === 'failed') return 'danger'
    return 'neutral'
  }
  const stepLabel = (status: string): string => {
    if (status === 'done') return t('tunnelStepDone')
    if (status === 'failed') return t('tunnelStepFailed')
    if (status === 'skipped') return t('tunnelStepSkipped')
    return t('tunnelStepPending')
  }
  const provisionActionLabel = provision?.lastError !== undefined ? t('tunnelProvisionRetry') : t('tunnelProvisionAction')
  return (
    <section className={styles.card} aria-labelledby="device-interconnect-tunnel">
      <details>
        <summary id="device-interconnect-tunnel" className={styles.detailsSummary}>{t('tunnelTitle')}</summary>
        <div className={styles.detailsBody}>
          <p className={styles.hint}>{t('tunnelHint')}</p>
          <div className={styles.row}>
            <div className={styles.switchRow}>
              <label className={styles.fieldLabel} htmlFor={providerId}>{t('tunnelProvider')}</label>
              <select id={providerId} className={styles.select} value={draft.tunnelProvider} disabled={busy}
                onChange={(event) => { actions.selectTunnelProvider(event.currentTarget.value as TunnelProvider) }}>
                {providerOptions.map(option => (
                  <option key={option.value} value={option.value}>{option.label}</option>
                ))}
              </select>
            </div>
            {sakurafrp && (
              <div className={styles.actions}>
                <Tag tone={status.tone}>{status.label}</Tag>
                <Button variant="outline" size="sm" disabled={busy || (!tunnel.running && !canStart)}
                  onClick={() => { void actions.setTunnelEnabled(!tunnel.running) }}>
                  {actionLabel}
                </Button>
              </div>
            )}
          </div>
          {sakurafrp && <p className={styles.hint}>{t('tunnelTcpOnly')}</p>}
          {sakurafrp && (
            <>
              <ToggleField label={t('tunnelAutoMode')} checked={draft.autoProvision} disabled={busy}
                onChange={next => { actions.toggle('autoProvision', next) }} />
              <p className={styles.hint}>{draft.autoProvision ? t('tunnelAutoModeHint') : t('tunnelManualModeHint')}</p>
              <div className={styles.grid}>
                <TextField label={t('tunnelAccessKey')} value={draft.tunnelToken} password
                  hint={t('tunnelAccessKeyHint')} disabled={busy}
                  placeholder={config.tunnel.tokenConfigured ? t('tunnelAccessKeyStoredPlaceholder') : t('tunnelAccessKeyPlaceholder')}
                  onEdit={value => { actions.edit('tunnelToken', value) }} />
                {draft.autoProvision
                  ? (
                    <TextField label={t('tunnelTunnelName')} value={draft.tunnelName} hint={t('tunnelTunnelNameHint')}
                      disabled={busy} onEdit={value => { actions.edit('tunnelName', value) }} />
                  )
                  : (
                    <>
                      <TextField label={t('tunnelFrpcPath')} value={draft.frpcPath} hint={t('tunnelFrpcPathHint')}
                        disabled={busy} onEdit={value => { actions.edit('frpcPath', value) }} />
                      <TextField label={t('tunnelIds')} value={draft.tunnelIds} hint={t('tunnelIdsHint')}
                        disabled={busy} onEdit={value => { actions.edit('tunnelIds', value) }} />
                      <TextField label={t('tunnelPublicAddress')} value={draft.publicAddress}
                        hint={t('tunnelPublicAddressHint')} disabled={busy}
                        onEdit={value => { actions.edit('publicAddress', value) }} />
                    </>
                  )}
              </div>
              {draft.autoProvision && (
                <ToggleField label={t('tunnelAutoDownload')} checked={draft.frpcAutoDownload} disabled={busy}
                  onChange={next => { actions.toggle('frpcAutoDownload', next) }} />
              )}
              {accountLine !== undefined && <p className={styles.hint}>{accountLine}</p>}
              {tunnel.node !== undefined && (
                <p className={styles.hint}>
                  {t('tunnelNodeLine', { node: `${String(tunnel.node.id)}${tunnel.node.name === undefined ? '' : ` ${tunnel.node.name}`}${tunnel.node.host === undefined ? '' : ` (${tunnel.node.host})`}` })}
                </p>
              )}
              {tunnel.tunnel !== undefined && (
                <p className={styles.hint}>
                  {t('tunnelTunnelLine', { tunnel: `#${String(tunnel.tunnel.id)}${tunnel.tunnel.name === undefined ? '' : ` ${tunnel.tunnel.name}`}` })}
                </p>
              )}
              {provision !== undefined && provision.lastSteps.length > 0 && (
                <div className={styles.field}>
                  <span className={styles.fieldLabel}>{t('tunnelStepsTitle')}</span>
                  <ul className={styles.problemList}>
                    {provision.lastSteps.map(step => (
                      <li key={step.id}>
                        <Tag tone={stepTone(step.status)}>{stepLabel(step.status)}</Tag> {step.message}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              {provision?.lastError !== undefined && <DiagnosticLine diagnostic={provision.lastError} t={t} />}
              {provision?.warning !== undefined && (
                <p className={`${styles.hint} ${styles.danger}`}>
                  {t('tunnelProvisionWarning', { warning: provision.warning })}
                </p>
              )}
              {tunnel.derivedPublicOrigin !== ''
                ? (
                  <CopyField label={t('tunnelDerivedOrigin')} text={tunnel.derivedPublicOrigin}
                    copyLabel={t('copyLink')} copiedLabel={t('copied')} />
                )
                : <p className={styles.hint}>{t('tunnelDerivedOriginPending')}</p>}
              <p className={styles.hint}>{t('tunnelDerivedOriginHint')}</p>
              {tunnel.problems.length > 0 && (
                <p className={`${styles.hint} ${styles.danger}`}>
                  {t('tunnelNotReady', { problems: tunnel.problems.map(problem => problem.message).join(' / ') })}
                </p>
              )}
              {tunnel.error !== undefined && (
                <p className={`${styles.hint} ${styles.danger}`}>{tunnel.error}</p>
              )}
              <div className={styles.actions}>
                {draft.autoProvision
                  ? (
                    <>
                      <Button variant="primary" size="sm" disabled={busy} onClick={() => { setConfirmOpen(true) }}>
                        {provisionActionLabel}
                      </Button>
                      <Button variant="outline" size="sm" disabled={busy} onClick={() => { void actions.save() }}>
                        {busy ? t('saving') : t('tunnelSave')}
                      </Button>
                    </>
                  )
                  : (
                    <Button variant="primary" size="sm" disabled={busy} onClick={() => { void actions.save() }}>
                      {busy ? t('saving') : t('tunnelSave')}
                    </Button>
                  )}
              </div>
              <details className={styles.details}>
                <summary className={styles.detailsSummary}>{t('tunnelAdvanced')}</summary>
                <div className={styles.detailsBody}>
                  <div className={styles.grid}>
                    {draft.autoProvision && (
                      <TextField label={t('tunnelFrpcPath')} value={draft.frpcPath} hint={t('tunnelFrpcPathHint')}
                        disabled={busy} onEdit={value => { actions.edit('frpcPath', value) }} />
                    )}
                    {draft.autoProvision && (
                      <TextField label={t('tunnelNodeId')} value={draft.nodeId} numeric hint={t('tunnelNodeIdHint')}
                        disabled={busy} onEdit={value => { actions.edit('nodeId', value) }} />
                    )}
                    <TextField label={t('tunnelIniPath')} value={draft.tunnelIniPath} hint={t('tunnelIniPathHint')}
                      disabled={busy} onEdit={value => { actions.edit('tunnelIniPath', value) }} />
                    <TextField label={t('tunnelExtraArgs')} value={draft.tunnelExtraArgs} hint={t('tunnelExtraArgsHint')}
                      disabled={busy} onEdit={value => { actions.edit('tunnelExtraArgs', value) }} />
                  </div>
                </div>
              </details>
              <details className={styles.details}>
                <summary className={styles.detailsSummary}>{t('tunnelLogsTitle')}</summary>
                <div className={styles.detailsBody}>
                  {tunnel.logsTail === ''
                    ? <p className={styles.empty}>{t('tunnelLogsEmpty')}</p>
                    : <pre className={styles.logs}>{tunnel.logsTail}</pre>}
                </div>
              </details>
            </>
          )}
        </div>
      </details>
      <Modal
        open={confirmOpen}
        onClose={() => { setConfirmOpen(false) }}
        title={t('tunnelProvisionConfirmTitle')}
        tone="warning"
        closeLabel={t('close')}
        description={t('tunnelProvisionConfirmBody')}
        footer={(
          <div className={styles.actions}>
            <Button variant="outline" size="sm" onClick={() => { setConfirmOpen(false) }}>{t('cancel')}</Button>
            <Button variant="primary" size="sm" disabled={busy}
              onClick={() => {
                setConfirmOpen(false)
                void actions.provision()
              }}>{t('tunnelProvisionConfirm')}</Button>
          </div>
        )}
      />
    </section>
  )
}

/**
 * The page body once a snapshot arrived.
 * @param props - the snapshot, the staged configuration, and the page actions.
 * @returns the full card stack.
 */
function LoadedPage(props: {
  snapshot: SectionSnapshot
  runtime: RuntimeState
  draft: NonNullable<SectionSnapshot['draft']>
  actions: DeviceInterconnectActions
  t: T
}) {
  const { snapshot, runtime, draft, actions, t } = props
  const [pendingRevoke, setPendingRevoke] = useState<RemoteDevice | undefined>(undefined)
  const busy = snapshot.busy
  const status = statusOf({ runtime, t })
  const now = Date.now()
  const config = runtime.config
  const setDraft = (field: Parameters<DeviceInterconnectActions['edit']>[0], value: string): void => {
    actions.edit(field, value)
  }
  const controlPageUrl = config.host.pagesEnabled
    ? `http://127.0.0.1:${String(config.host.pagesPort)}/`
    : undefined
  const notice = snapshot.notice
  const noticeText = notice === undefined
    ? undefined
    : 'key' in notice.text ? t(notice.text.key) : diagnosticText(t, notice.text.diagnostic)
  return (
    <>
      <h2 className={styles.pageTitle}>{t('title')}</h2>
      <p className={styles.pageDescription}>{t('description')}</p>
      {notice !== undefined && noticeText !== undefined && (
        <div className={`${styles.notice} ${notice.kind === 'error' ? styles.noticeError : styles.noticeSuccess}`}
          role="status">
          <span>{noticeText}</span>
          <Button variant="ghost" size="sm" onClick={actions.dismissNotice}>{t('dismiss')}</Button>
        </div>
      )}
      <section className={styles.card} aria-labelledby="device-interconnect-status">
        <div className={styles.row}>
          <h3 id="device-interconnect-status" className={styles.cardTitle}>{t('status')}</h3>
          <div className={styles.switchRow}>
            <span className={styles.fieldLabel}>{t('enable')}</span>
            <Switch checked={config.enabled} label={t('enable')} disabled={busy}
              onChange={(next) => { void actions.setEnabled(next) }} />
          </div>
        </div>
        <div className={styles.row}>
          <span className={styles.statusValue}>
            <Tag tone={status.tone}>{status.label}</Tag>
          </span>
          <span className={styles.statusDetail}>
            {t('statusPort')} {String(config.host.port)} · {t('statusOrigin')} {runtime.controlPlane.host?.origin ?? '—'}
          </span>
        </div>
        {status.detail !== '' && <p className={`${styles.hint} ${status.tone === 'danger' ? styles.danger : ''}`}>{status.detail}</p>}
        <p className={styles.hint}>{t('enableHint')}</p>
        {!runtime.runner.ready && config.enabled && (
          <p className={`${styles.hint} ${styles.danger}`}>
            {t('runnerNotReady', { problems: runtime.runner.problems.map(problem => problem.message).join(' / ') })}
          </p>
        )}
        {!runtime.controlPlane.reachable && runtime.controlPlane.error !== undefined && (
          <DiagnosticLine diagnostic={runtime.controlPlane.error} t={t} />
        )}
        {runtime.problems.length > 0 && (
          <ul className={styles.problemList}>
            {runtime.problems.map(problem => <li key={problem.code}>{problem.message}</li>)}
          </ul>
        )}
        <div className={styles.actions}>
          <Button variant="outline" size="sm" disabled={busy} onClick={() => { void actions.refresh() }}>{t('refresh')}</Button>
          {controlPageUrl !== undefined && (
            <a className={styles.hint} href={controlPageUrl} target="_blank" rel="noopener noreferrer">
              {t('openControlPage')}
            </a>
          )}
        </div>
      </section>
      <section className={styles.card} aria-labelledby="device-interconnect-pairing">
        <div className={styles.row}>
          <h3 id="device-interconnect-pairing" className={styles.cardTitle}>{t('pairingTitle')}</h3>
          {runtime.pairing.longTerm && <Tag tone="success">{t('pairingLongTerm')}</Tag>}
        </div>
        <p className={styles.hint}>{t('pairingHint')}</p>
        {runtime.pairing.open
          ? (
            <div className={styles.pairing}>
              {runtime.pairing.qrSvgUrl !== undefined && (
                <img className={styles.qr} src={runtime.pairing.qrSvgUrl} alt={t('qrAlt')} width={216} height={216} />
              )}
              <div className={styles.pairingBody}>
                {runtime.pairing.pairUrl !== undefined && (
                  <CopyField label={t('pairLink')} text={runtime.pairing.pairUrl}
                    copyLabel={t('copyLink')} copiedLabel={t('copied')} />
                )}
                {runtime.pairing.expiresAt !== undefined && (
                  <p className={styles.hint}>{t('pairingExpiresAt', { time: formatInstant(runtime.pairing.expiresAt) })}</p>
                )}
                <div className={styles.actions}>
                  <Button variant="primary" size="sm" disabled={busy}
                    onClick={() => { void actions.regeneratePairing() }}>{t('regenerate')}</Button>
                </div>
                {runtime.pairing.usbPairUrl !== undefined && (
                  <details className={styles.details}>
                    <summary className={styles.detailsSummary}>{t('usbTitle')}</summary>
                    <div className={styles.detailsBody}>
                      <p className={styles.hint}>
                        {t('usbHint', { port: config.host.port })}
                      </p>
                      <CopyField label={t('usbLink')} text={runtime.pairing.usbPairUrl}
                        copyLabel={t('copyLink')} copiedLabel={t('copied')} />
                    </div>
                  </details>
                )}
              </div>
            </div>
          )
          : <p className={styles.empty}>{t('pairingClosed')}</p>}
      </section>
      <section className={styles.card} aria-labelledby="device-interconnect-config">
        <h3 id="device-interconnect-config" className={styles.cardTitle}>{t('configTitle')}</h3>
        <div className={styles.grid}>
          <TextField label={t('port')} value={draft.port} numeric disabled={busy}
            onEdit={value => { setDraft('port', value) }} />
          <TextField label={t('listenHost')} value={draft.listenHost} disabled={busy}
            onEdit={value => { setDraft('listenHost', value) }} />
          <TextField label={t('publicHost')} value={draft.publicHost} hint={t('publicHostHint')} disabled={busy}
            onEdit={value => { setDraft('publicHost', value) }} />
          <TextField label={t('publicOrigin')} value={draft.publicOrigin} hint={t('publicOriginHint')} disabled={busy}
            onEdit={value => { setDraft('publicOrigin', value) }} />
          <TextField label={t('discoveryPort')} value={draft.discoveryPort} numeric disabled={busy}
            onEdit={value => { setDraft('discoveryPort', value) }} />
          <TextField label={t('pagesPort')} value={draft.pagesPort} numeric disabled={busy}
            onEdit={value => { setDraft('pagesPort', value) }} />
        </div>
        <ToggleField label={t('discoveryEnabled')} checked={draft.discoveryEnabled} disabled={busy}
          onChange={next => { actions.toggle('discoveryEnabled', next) }} />
        <ToggleField label={t('pagesEnabled')} checked={draft.pagesEnabled} disabled={busy}
          onChange={next => { actions.toggle('pagesEnabled', next) }} />
        <ToggleField label={t('longTerm')} checked={draft.longTerm} disabled={busy}
          onChange={next => { actions.toggle('longTerm', next) }} />
        <p className={styles.hint}>{t('longTermHint')}</p>
        <p className={styles.hint}>{t('saveHint')}</p>
        <div className={styles.actions}>
          <Button variant="primary" size="sm" disabled={busy} onClick={() => { void actions.save() }}>
            {busy ? t('saving') : t('save')}
          </Button>
        </div>
      </section>
      <section className={styles.card} aria-labelledby="device-interconnect-devices">
        <h3 id="device-interconnect-devices" className={styles.cardTitle}>
          {t('devicesTitle')} ({String(runtime.devices.length)})
        </h3>
        {runtime.devices.length === 0
          ? <p className={styles.empty}>{t('devicesEmpty')}</p>
          : (
            <table className={styles.table}>
              <thead>
                <tr>
                  <th>{t('deviceLabel')}</th>
                  <th>{t('devicePairedAt')}</th>
                  <th>{t('deviceLastSeen')}</th>
                  <th>{t('status')}</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {runtime.devices.map((device) => {
                  const state = deviceState(device, now)
                  const label = state === 'active'
                    ? t('deviceActive')
                    : state === 'revoked' ? t('deviceRevoked') : t('deviceExpired')
                  return (
                    <tr key={device.id}>
                      <td>
                        <span className={styles.deviceName}>
                          <span>{device.label}</span>
                          <span className={`${styles.hint} ${styles.mono}`}>{device.id.slice(0, 8)}</span>
                        </span>
                      </td>
                      <td className={styles.statusDetail}>{formatInstant(device.createdAt)}</td>
                      <td className={styles.statusDetail}>{formatInstant(device.lastSeenAt)}</td>
                      <td>
                        <Tag tone={state === 'active' ? 'success' : 'neutral'}>{label}</Tag>
                      </td>
                      <td>
                        {state === 'active' && (
                          <Button variant="ghost" size="sm" disabled={busy}
                            onClick={() => { setPendingRevoke(device) }}>{t('revoke')}</Button>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
      </section>
      <TunnelCard runtime={runtime} draft={draft} actions={actions} busy={busy} t={t} />
      <section className={styles.card} aria-labelledby="device-interconnect-runner">
        <details>
          <summary id="device-interconnect-runner" className={styles.detailsSummary}>{t('runnerTitle')}</summary>
          <div className={styles.detailsBody}>
            <p className={styles.hint}>{t('runnerHint')}</p>
            <div className={styles.grid}>
              <TextField label={t('runnerNode')} value={draft.nodePath} disabled={busy}
                onEdit={value => { setDraft('nodePath', value) }} />
              <TextField label={t('runnerPnpm')} value={draft.pnpmPath} disabled={busy}
                onEdit={value => { setDraft('pnpmPath', value) }} />
              <TextField label={t('runnerRepo')} value={draft.repoDir} disabled={busy}
                onEdit={value => { setDraft('repoDir', value) }} />
              <TextField label={t('runnerProfile')} value={draft.profile} disabled={busy}
                onEdit={value => { setDraft('profile', value) }} />
              <TextField label={t('runnerPatch')} value={draft.patchPath} disabled={busy}
                onEdit={value => { setDraft('patchPath', value) }} />
              <TextField label={t('runnerDshHome')} value={draft.dshHome} disabled={busy}
                onEdit={value => { setDraft('dshHome', value) }} />
            </div>
            {runtime.runner.problems.length > 0 && (
              <ul className={styles.problemList}>
                {runtime.runner.problems.map(problem => <li key={problem.code}>{problem.message}</li>)}
              </ul>
            )}
          </div>
        </details>
      </section>
      <section className={styles.card} aria-labelledby="device-interconnect-logs">
        <details>
          <summary id="device-interconnect-logs" className={styles.detailsSummary}>{t('logsTitle')}</summary>
          <div className={styles.detailsBody}>
            {runtime.child.logsTail === ''
              ? <p className={styles.empty}>{t('logsEmpty')}</p>
              : <pre className={styles.logs}>{runtime.child.logsTail}</pre>}
          </div>
        </details>
      </section>
      <Modal
        open={pendingRevoke !== undefined}
        onClose={() => { setPendingRevoke(undefined) }}
        title={t('revokeTitle')}
        tone="warning"
        closeLabel={t('close')}
        {...(pendingRevoke === undefined ? {} : { description: t('revokeBody', { name: pendingRevoke.label }) })}
        footer={(
          <div className={styles.actions}>
            <Button variant="outline" size="sm" onClick={() => { setPendingRevoke(undefined) }}>{t('cancel')}</Button>
            <Button variant="primary" size="sm" disabled={busy}
              onClick={() => {
                const device = pendingRevoke
                setPendingRevoke(undefined)
                if (device !== undefined) void actions.revokeDevice(device.id)
              }}>{t('confirmRevoke')}</Button>
          </div>
        )}
      />
    </>
  )
}

/**
 * Render the Device Interconnect Settings page.
 * @param props - the shell's runtime share, the locale seat, and the injected
 * controller face.
 * @returns the page, or its loading and failure states.
 */
export function DeviceInterconnectSection(props: DeviceInterconnectSectionProps) {
  const { t, actions } = props
  const snapshot = props.useDeviceInterconnect(value => value)
  useEffect(() => {
    actions.open()
    return () => { actions.close() }
  }, [actions])
  if (snapshot.state === undefined) {
    return (
      <div className={styles.centered} role="status">
        {snapshot.error === undefined ? t('statusStarting') : diagnosticText(t, snapshot.error)}
      </div>
    )
  }
  if (snapshot.draft === undefined) {
    return <div className={styles.centered} role="status">{t('statusStarting')}</div>
  }
  return (
    <LoadedPage snapshot={snapshot} runtime={snapshot.state} draft={snapshot.draft} actions={actions} t={t} />
  )
}
