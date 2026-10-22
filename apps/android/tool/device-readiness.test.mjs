import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { inspectDevice, parseDevices, parseOverlayPermission, parsePackageVersion } from './device-readiness.mjs'

const packageName = 'com.minnnng.dsh_android'

function withFixture(action) {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-device-readiness-'))
  const apkPath = join(directory, 'prepared.apk')
  const bytes = Buffer.from('prepared-apk-fixture')
  writeFileSync(apkPath, bytes)
  try {
    return action({ apkPath, expectedSha256: createHash('sha256').update(bytes).digest('hex') })
  } finally {
    unlinkSync(apkPath)
    rmdirSync(directory)
  }
}

test('parsers keep device authorization and app-op states distinct', () => {
  assert.deepEqual(parseDevices('List of devices attached\r\nA device product:x\r\nB unauthorized usb:2\r\n'), [
    { serial: 'A', state: 'device' }, { serial: 'B', state: 'unauthorized' },
  ])
  assert.equal(parsePackageVersion('versionCode=37 minSdk=28'), 37)
  assert.equal(parsePackageVersion('Unable to find package'), null)
  assert.equal(parseOverlayPermission('SYSTEM_ALERT_WINDOW: allow'), 'allow')
  assert.equal(parseOverlayPermission('No operations.'), 'not-reported')
})

test('a mismatched package hash prevents every ADB query', () => withFixture(({ apkPath }) => {
  let calls = 0
  const report = inspectDevice({ apkPath, expectedSha256: '0'.repeat(64), run: () => { calls += 1 } })
  assert.equal(report.apk.matched, false)
  assert.equal(report.device.state, 'unavailable')
  assert.equal(calls, 0)
}))

test('missing, unauthorized, and ambiguous devices require no further probes', () => withFixture((fixture) => {
  for (const [output, state] of [
    ['List of devices attached\n', 'not-connected'],
    ['List of devices attached\nA unauthorized\n', 'unauthorized'],
    ['List of devices attached\nA device\nB device\n', 'ambiguous'],
  ]) {
    const calls = []
    const report = inspectDevice({ ...fixture, run: (_adb, args) => {
      calls.push(args)
      return output
    } })
    assert.equal(report.device.state, state)
    assert.deepEqual(calls, [['devices', '-l']])
  }
}))

test('ADB failures do not become a false device or permission result', () => withFixture((fixture) => {
  const unavailable = inspectDevice({ ...fixture, run: () => { throw new Error('ADB unavailable') } })
  assert.equal(unavailable.device.state, 'adb-unavailable')
  const connected = inspectDevice({ ...fixture, run: (_adb, args) => {
    if (args[0] === 'devices') return 'List of devices attached\nSERIAL device\n'
    throw new Error('Probe unavailable')
  } })
  assert.equal(connected.device.state, 'connected')
  assert.deepEqual(connected.device.overlayPermission, { ok: false, error: 'unavailable' })
  assert.deepEqual(connected.device.overlayWindow, { ok: false, error: 'unavailable' })
}))

test('connected device probes are read-only and report unavailable facts as unknown', () => withFixture((fixture) => {
  const calls = []
  const outputs = new Map([
    ['devices -l', 'List of devices attached\nSERIAL device product:pixel\n'],
    ['shell getprop ro.build.version.sdk', '36'],
    ['shell getprop ro.product.cpu.abilist', 'arm64-v8a,armeabi-v7a'],
    [`shell pm path ${packageName}`, 'package:/data/app/base.apk'],
    [`shell dumpsys package ${packageName}`, 'versionCode=37 minSdk=28'],
    [`shell cmd appops get ${packageName} SYSTEM_ALERT_WINDOW`, 'SYSTEM_ALERT_WINDOW: allow'],
    ['shell dumpsys window windows', 'Window{a Pocket Harness task overlay}'],
  ])
  const report = inspectDevice({ ...fixture, run: (_adb, args) => {
    calls.push(args)
    assert.equal(args[0] === 'devices' ? true : args[0] === '-s' && args[1] === 'SERIAL', true)
    const key = args[0] === '-s' ? args.slice(2).join(' ') : args.join(' ')
    if (key === `shell pidof ${packageName}:agent`) throw new Error('No running process')
    return outputs.get(key) ?? ''
  } })
  assert.equal(report.apk.matched, true)
  assert.equal(report.device.state, 'connected')
  assert.equal(report.device.apiLevel.value, 36)
  assert.deepEqual(report.device.abi.value, ['arm64-v8a', 'armeabi-v7a'])
  assert.equal(report.device.installedVersionCode.value, 37)
  assert.equal(report.device.overlayPermission.value, 'allow')
  assert.equal(report.device.overlayWindow.value, true)
  assert.equal(report.device.agentPid.ok, false)
  assert.equal(calls.length, 8)
  assert.equal(calls.some((args) => args.includes('install') || args.includes('am') || args.includes('start')), false)
}))
