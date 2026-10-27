/** Only explicit service selection changes the established black-Activity default. */
export function acceptanceCarrier(args) {
  const positions = args.flatMap((value, index) => value === '--foreground-carrier' ? [index] : [])
  if (positions.length > 1) throw new Error('Duplicate --foreground-carrier')
  return requireAcceptanceCarrier(positions.length ? args[positions[0] + 1] : 'activity')
}

export function requireAcceptanceCarrier(value) {
  if (value !== 'activity' && value !== 'service') throw new Error('Choose foreground carrier activity or service')
  return value
}

/** Validate framework state without treating it as pixel or physical-panel evidence. */
export function carrierEvidence(output, selected, { prefix = 'RESULT', closed = true } = {}) {
  requireAcceptanceCarrier(selected)
  if (!['RESULT', 'STATUS'].includes(prefix)) throw new Error('Unknown carrier evidence prefix')
  const field = name => {
    const entries = [...output.matchAll(new RegExp(`^INSTRUMENTATION_${prefix}: ${name}=(.*)$`, 'gm'))]
    if (entries.length !== 1) throw new Error(`Missing or duplicate carrier ${name}`)
    return entries[0][1].trim()
  }
  if (field('foregroundCarrier') !== selected) throw new Error('Foreground carrier differs from the request')
  const state = name => {
    const value = JSON.parse(field(name))
    if (!value || ['interactive', 'keyguardLocked', 'deviceLocked'].some(key => typeof value[key] !== 'boolean') ||
      !Array.isArray(value.displays) || !value.displays.length || value.displays.some(display =>
        !Number.isSafeInteger(display.id) || display.id < 0 || !Number.isSafeInteger(display.state) ||
        display.state < 0 || display.state > 6)) throw new Error(`Invalid carrier ${name}`)
    return value
  }
  const result = { foregroundCarrier: selected, deviceStateBefore: state('deviceStateBefore'),
    deviceStateReady: state('deviceStateReady') }
  if (closed) {
    if (field('foregroundClosed') !== 'true' || field('nativeOwnersClosed') !== 'true')
      throw new Error('Carrier or native owner closure is unconfirmed')
    Object.assign(result, { foregroundClosed: true, nativeOwnersClosed: true, deviceStateAfter: state('deviceStateAfter') })
  } else if (field('foregroundConfirmed') !== 'true') throw new Error('Carrier readiness is unconfirmed')
  return result
}

/** The packaged Node carrier sends readiness separately from its deliberate process-death marker. */
export function requireNodeCarrierReady(output, selected) {
  requireAcceptanceCarrier(selected)
  const frames = output.split(/^INSTRUMENTATION_STATUS_CODE:.*$/m)
  const ready = frames.filter(frame => /^INSTRUMENTATION_STATUS: stage=foreground-ready\s*$/m.test(frame))
  if (ready.length !== 1 || !new RegExp(`^INSTRUMENTATION_STATUS: foregroundCarrier=${selected}\\s*$`, 'm').test(ready[0]))
    throw new Error('Preparation did not confirm the requested foreground carrier')
}
