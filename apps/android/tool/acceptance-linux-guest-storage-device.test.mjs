import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseStorageProbeResult, requireStorageProbeDeclarations, requireStorageProbeLibrary } from './acceptance-linux-guest-storage-device.mjs'

const app = 'com.minnnng.dsh_android'
const service = `    E: service (line=60)\n` +
  `      A: android:name(0x01010003)="${app}.DebugGuestStorageProbeService"\n` +
  '      A: android:exported(0x01010010)=false\n' +
  '      A: android:process(0x01010011)=":guest_storage_probe"\n' +
  '      A: android:isolatedProcess(0x010103a9)=true\n'
const instrumentation = `  E: instrumentation (line=20)\n` +
  `    A: android:name(0x01010003)="${app}.GuestStorageProbeInstrumentation"\n` +
  `    A: android:targetPackage(0x01010021)="${app}"\n` +
  `    A: android:targetProcesses(0x01010541)="${app}:agent"\n`

const fields = {
  result: 'guest-storage-probe-pass', state: 'observed', uid: '99001', isolated: 'true',
  privateRead: 'denied', privateWrite: 'denied', fdRead: 'allowed', fdWrite: 'denied',
  directoryChildRead: 'denied', directoryChildWrite: 'denied',
  memoryRead: 'allowed', memoryWrite: 'denied',
  tempWrite: 'denied', tempRead: 'untested', tempExec: 'untested', tempExecMap: 'denied',
}
const output = (values = fields, code = -1) => Object.entries(values)
  .map(([key, value]) => `INSTRUMENTATION_RESULT: ${key}=${value}\n`).join('') +
  `INSTRUMENTATION_CODE: ${code}\n`

test('requires one private isolated debug service and one Agent-process test entry', () => {
  assert.doesNotThrow(() => requireStorageProbeDeclarations(service, instrumentation))
  assert.throws(() => requireStorageProbeDeclarations(service + service, instrumentation), /exact/)
  assert.throws(() => requireStorageProbeDeclarations(service, instrumentation + instrumentation), /exact/)
  assert.throws(() => requireStorageProbeDeclarations(service.replace('true', 'false'), instrumentation), /exact/)
  assert.throws(() => requireStorageProbeDeclarations(service.replace('exported(0x01010010)=false',
    'exported(0x01010010)=true'), instrumentation), /exact/)
  assert.throws(() => requireStorageProbeDeclarations(service,
    instrumentation.replace(':agent', ':main')), /exact/)
  // Attributes from a later provider must never complete a partial Service block.
  assert.throws(() => requireStorageProbeDeclarations(
    service.replace('      A: android:exported(0x01010010)=false\n', '') +
      '    E: provider\n      A: android:exported(0x01010010)=false\n', instrumentation), /exact/)
})

test('requires the debug-only native openat observer in the signed ARM64 APK', () => {
  const entry = 'lib/arm64-v8a/libpocket_guest_storage_probe.so'
  assert.doesNotThrow(() => requireStorageProbeLibrary(`AndroidManifest.xml\n${entry}\n`))
  assert.throws(() => requireStorageProbeLibrary('AndroidManifest.xml\n'), /probe library/)
  assert.throws(() => requireStorageProbeLibrary(`${entry}\n${entry}\n`), /probe library/)
  assert.throws(() => requireStorageProbeLibrary('lib/x86_64/libpocket_guest_storage_probe.so\n'), /probe library/)
})

test('requires exact read-only FD observations and keeps temp capability as data', () => {
  assert.deepEqual(parseStorageProbeResult(output()).temp, {
    tempWrite: 'denied', tempRead: 'untested', tempExec: 'untested', tempExecMap: 'denied',
  })
  assert.throws(() => parseStorageProbeResult(output(fields, 0)), /did not complete/)
  assert.throws(() => parseStorageProbeResult(output({ ...fields, fdWrite: 'allowed' })), /fdWrite/)
  assert.throws(() => parseStorageProbeResult(output({ ...fields, directoryChildRead: 'allowed' })), /directoryChildRead/)
  assert.throws(() => parseStorageProbeResult(output({ ...fields, directoryChildWrite: 'untested' })), /directoryChildWrite/)
  assert.throws(() => parseStorageProbeResult(output({ ...fields, privateRead: 'untested' })), /privateRead/)
  assert.throws(() => parseStorageProbeResult(output({ ...fields, tempExec: 'unknown' })), /tempExec/)
  assert.throws(() => parseStorageProbeResult(output({ ...fields, uid: '0' })), /did not complete/)
  assert.throws(() => parseStorageProbeResult(output({ ...fields, isolated: 'false' })), /did not complete/)
  assert.throws(() => parseStorageProbeResult(output() + 'INSTRUMENTATION_CODE: -1\n'), /did not complete/)
  assert.throws(() => parseStorageProbeResult(output() +
    'INSTRUMENTATION_RESULT: fdRead=allowed\n'), /duplicate fdRead/)
})
