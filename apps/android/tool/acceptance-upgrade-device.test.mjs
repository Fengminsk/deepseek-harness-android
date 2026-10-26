import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  connectedDevice, parseBadging, parseCertificate, parseInstalledPath,
  parseInstalledVersion, parseInstrumentation, parseAgentPids, parseHoldStatus,
  requireUpgradeInstrumentation,
  validateArtifacts, validateSafReadableOption, encodeSafReadablePath,
} from './acceptance-upgrade-device.mjs'

const app = 'com.minnnng.dsh_android'
const certificate = 'a'.repeat(64)
const token = '1'.repeat(32)
const canarySha256 = 'b'.repeat(64)
const credentialSha256 = 'c'.repeat(64)
const safGrantSha256 = 'd'.repeat(64)
const safRootSha256 = 'e'.repeat(64)
const safDocumentIdSha256 = '9'.repeat(64)
const safDocumentSha256 = 'f'.repeat(64)
const identity = (packageName, versionCode, signer = certificate) =>
  ({ packageName, versionCode, certificate: signer })

test('APK preflight requires increasing versions, one package identity and matching signing certificates', () => {
  const old = parseBadging(`package: name='${app}' versionCode='77' versionName='0.1.0'\n`)
  const next = parseBadging(`package: name='${app}' versionCode='78' versionName='0.1.0'\n`)
  const androidTest = parseBadging(`package: name='${app}.test' versionCode='' versionName=''\n`)
  assert.equal(old.versionCode, 77)
  assert.equal(androidTest.versionCode, null)
  const signer = parseCertificate(`Signer #1 certificate SHA-256 digest: ${certificate}\n`)
  assert.equal(signer, certificate)
  assert.deepEqual(validateArtifacts({ ...old, certificate: signer }, { ...next, certificate: signer },
    { ...androidTest, certificate: signer }), {
    oldVersionCode: 77, newVersionCode: 78, certificate: signer,
  })
  assert.throws(() => validateArtifacts(identity(app, 77), identity(app, 77), identity(`${app}.test`, null)),
    /increase versionCode/)
  assert.throws(() => validateArtifacts(identity(app, 77), identity('other.app', 78),
    identity(`${app}.test`, null)), /identity differs/)
  assert.throws(() => validateArtifacts(identity(app, 77), identity(app, 78, 'd'.repeat(64)),
    identity(`${app}.test`, null)), /certificates differ/)
  assert.throws(() => parseCertificate('Signer #1 certificate SHA-256 digest: ' + certificate +
    '\nSigner #2 certificate SHA-256 digest: ' + 'd'.repeat(64) + '\n'), /Exactly one/)
  assert.throws(() => parseBadging('application-label:\'Wrong\'\n'), /could not be read/)
})

test('ADB preflight selects an authorized device and recognizes only App package paths', () => {
  const listing = 'List of devices attached\nphone-a\tdevice\nphone-b\tunauthorized\n\n'
  assert.equal(connectedDevice(listing), 'phone-a')
  assert.equal(connectedDevice(listing, 'phone-a'), 'phone-a')
  assert.throws(() => connectedDevice(listing, 'phone-b'), /not connected and authorized/)
  assert.throws(() => connectedDevice('List of devices attached\na\tdevice\nb\tdevice\n'), /Expected one/)
  assert.equal(parseInstalledPath(''), false)
  assert.equal(parseInstalledPath('package:/data/app/base.apk\npackage:/data/app/split.apk\n'), true)
  assert.throws(() => parseInstalledPath('Error: package manager unavailable\n'), /Unexpected/)
  assert.equal(parseInstalledVersion(`Packages:\n  Package [${app}] (abc):\n    userId=10231\n    versionCode=77 minSdk=28\n`), 77)
  assert.throws(() => parseInstalledVersion(`Package [other.app] (abc):\n versionCode=77\n`), /entry is unavailable/)
  assert.deepEqual(parseAgentPids('1234 5678\n'), [1234, 5678])
  assert.deepEqual(parseAgentPids(''), [])
  assert.throws(() => parseAgentPids('pidof: failed'), /Unexpected Agent PID/)
})

test('test APK must declare the exact upgrade runner, target package and Agent process before installation', () => {
  const declaration = `E: instrumentation (line=30)\n` +
    `  A: android:name(0x01010003)="${app}.UpgradePersistenceInstrumentation"\n` +
    `  A: android:targetPackage(0x01010021)="${app}"\n` +
    `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
  assert.doesNotThrow(() => requireUpgradeInstrumentation(declaration))
  assert.throws(() => requireUpgradeInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireUpgradeInstrumentation(declaration.replace(`${app}.UpgradePersistenceInstrumentation`,
    `${app}.OtherInstrumentation`)), /lacks/)
  assert.throws(() => requireUpgradeInstrumentation(declaration + declaration), /one expected/)
})

test('process-death hold requires a complete ready status from this run', () => {
  const status = `INSTRUMENTATION_STATUS: holdReady=true\n` +
    `INSTRUMENTATION_STATUS: token=${token}\n` +
    `INSTRUMENTATION_STATUS: processPid=4321\nINSTRUMENTATION_STATUS_CODE: 1\n`
  assert.equal(parseHoldStatus(status, token), 4321)
  assert.equal(parseHoldStatus(status.replace('INSTRUMENTATION_STATUS_CODE: 1\n', ''), token), null)
  assert.throws(() => parseHoldStatus(status, '2'.repeat(32)), /does not match/)
  assert.throws(() => parseHoldStatus(status.replace('processPid=4321', 'processPid=0'), token),
    /does not match/)
})

function result(phase, options = {}) {
  return `INSTRUMENTATION_RESULT: phase=${phase}\n` +
    `INSTRUMENTATION_RESULT: token=${token}\n` +
    `INSTRUMENTATION_RESULT: versionCode=${phase === 'seed' ? 77 : 78}\n` +
    `INSTRUMENTATION_RESULT: canarySha256=${canarySha256}\n` +
    `INSTRUMENTATION_RESULT: credentialSha256=${credentialSha256}\n` +
    `INSTRUMENTATION_RESULT: safGrantCount=${options.safGrantCount ?? '1'}\n` +
    `INSTRUMENTATION_RESULT: safGrantSha256=${safGrantSha256}\n` +
    (options.safReadable ?
      `INSTRUMENTATION_RESULT: safRootSha256=${safRootSha256}\n` +
      `INSTRUMENTATION_RESULT: safDocumentIdSha256=${safDocumentIdSha256}\n` +
      `INSTRUMENTATION_RESULT: safDocumentSha256=${safDocumentSha256}\n` +
      `INSTRUMENTATION_RESULT: safDocumentBytes=${options.safDocumentBytes ?? '42'}\n` : '') +
    `INSTRUMENTATION_RESULT: processPid=4321\n` +
    `INSTRUMENTATION_RESULT: internetNetworkCount=${options.internetNetworkCount ?? '0'}\n` +
    `INSTRUMENTATION_RESULT: passed=${options.passed ?? 'true'}\n` +
    (phase === 'cleanup' ? 'INSTRUMENTATION_RESULT: cleaned=true\n' : '') +
    `INSTRUMENTATION_CODE: ${options.code ?? '-1'}\n`
}

test('upgrade phases require the same nonce and hashes, terminal result, and explicit cleanup proof', () => {
  const seed = parseInstrumentation(result('seed'), 'seed', token)
  assert.equal(seed.versionCode, 77)
  assert.equal(seed.safGrantCount, 1)
  assert.equal(seed.processPid, 4321)
  const verified = parseInstrumentation(result('verify'), 'verify', token, seed)
  assert.equal(verified.versionCode, 78)
  assert.equal(parseInstrumentation(result('cleanup'), 'cleanup', token, seed).cleaned, true)
  assert.throws(() => parseInstrumentation(result('verify'), 'verify', '2'.repeat(32), seed), /failed/)
  assert.throws(() => parseInstrumentation(result('verify').replace(canarySha256, 'd'.repeat(64)),
    'verify', token, seed), /failed/)
  assert.throws(() => parseInstrumentation(result('verify').replace(safGrantSha256, 'e'.repeat(64)),
    'verify', token, seed), /failed/)
  assert.throws(() => parseInstrumentation(result('verify', { safGrantCount: '2' }),
    'verify', token, seed), /failed/)
  assert.throws(() => parseInstrumentation(result('verify').replace(
    `INSTRUMENTATION_RESULT: safGrantSha256=${safGrantSha256}\n`, ''),
  'verify', token, seed), /failed/)
  assert.throws(() => parseInstrumentation(result('seed', { safGrantCount: '0' }),
    'seed', token, null, { requireSafGrant: true }), /failed/)
  assert.equal(parseInstrumentation(result('seed', { safGrantCount: '0' }),
    'seed', token).safGrantCount, 0)
  assert.throws(() => parseInstrumentation(result('seed').replace('processPid=4321', 'processPid=0'),
    'seed', token), /failed/)
  assert.throws(() => parseInstrumentation(result('seed', { internetNetworkCount: '1' }),
    'seed', token, null, { requireOffline: true }), /failed/)
  assert.throws(() => parseInstrumentation(result('seed').replace(
    'INSTRUMENTATION_RESULT: internetNetworkCount=0\n', ''), 'seed', token), /failed/)
  assert.equal(parseInstrumentation(result('seed', { internetNetworkCount: '1' }),
    'seed', token).internetNetworkCount, 1)
  assert.throws(() => parseInstrumentation(result('verify', { code: '0' }), 'verify', token, seed), /failed/)
  assert.throws(() => parseInstrumentation(result('verify', { passed: 'false' }), 'verify', token, seed), /failed/)
  assert.throws(() => parseInstrumentation(result('cleanup').replace('cleaned=true', 'cleaned=false'),
    'cleanup', token, seed), /failed/)
  assert.throws(() => parseInstrumentation(result('seed') +
    `INSTRUMENTATION_RESULT: canarySha256=${canarySha256}\n`, 'seed', token), /Duplicate/)
})

test('SAF file mode requires an existing app, a bounded relative path and matching read proof after upgrade', () => {
  assert.equal(validateSafReadableOption(undefined, false, false), false)
  assert.equal(validateSafReadableOption('acceptance/probe.txt', true, true), true)
  for (const path of ['', '/probe.txt', 'probe.txt/', 'dir/../probe.txt', 'dir//probe.txt',
    'dir\\probe.txt', 'a\u0000b.txt', 'x'.repeat(1025)]) {
    assert.throws(() => validateSafReadableOption(path, true, true), /Invalid --saf-readable-path/)
  }
  assert.throws(() => validateSafReadableOption('probe.txt', false, true), /existing old App/)
  assert.throws(() => validateSafReadableOption('probe.txt', true, false), /--allow-existing/)
  assert.equal(validateSafReadableOption('项目资料/升级 验收.txt', true, true), true)
  const encoded = encodeSafReadablePath('项目资料/升级 验收.txt')
  assert.match(encoded, /^[A-Za-z0-9_-]+$/)
  assert.equal(Buffer.from(encoded, 'base64url').toString('utf8'), '项目资料/升级 验收.txt')
  const mode = { requireSafGrant: true, requireSafReadable: true }
  const seed = parseInstrumentation(result('seed', { safReadable: true }), 'seed', token, null, mode)
  assert.equal(seed.safDocumentBytes, 42)
  assert.equal(seed.safRootSha256, safRootSha256)
  assert.equal(parseInstrumentation(result('verify', { safReadable: true }), 'verify', token, seed,
    mode).safDocumentSha256, safDocumentSha256)
  assert.equal(parseInstrumentation(result('cleanup', { safReadable: true }), 'cleanup', token, seed,
    mode).cleaned, true)
  assert.throws(() => parseInstrumentation(result('verify'), 'verify', token, seed, mode), /failed/)
  assert.throws(() => parseInstrumentation(result('verify', { safReadable: true })
    .replace(safDocumentSha256, '0'.repeat(64)), 'verify', token, seed, mode), /failed/)
  assert.throws(() => parseInstrumentation(result('verify', { safReadable: true })
    .replace(safRootSha256, '0'.repeat(64)), 'verify', token, seed, mode), /failed/)
  assert.throws(() => parseInstrumentation(result('verify', { safReadable: true })
    .replace(safDocumentIdSha256, '0'.repeat(64)), 'verify', token, seed, mode), /failed/)
  assert.throws(() => parseInstrumentation(result('verify', { safReadable: true, safDocumentBytes: '43' }),
    'verify', token, seed, mode), /failed/)
  assert.throws(() => parseInstrumentation(result('seed', { safReadable: true, safDocumentBytes: '16777217' }),
    'seed', token, null, mode), /failed/)
  assert.throws(() => parseInstrumentation(result('seed', { safReadable: true })
    .replace(`INSTRUMENTATION_RESULT: safDocumentSha256=${safDocumentSha256}\n`, ''),
    'seed', token, null, mode), /failed/)
})
