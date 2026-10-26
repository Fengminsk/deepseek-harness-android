import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { parseBadging, parseCertificate, sdkTools } from './acceptance-upgrade-device.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.SafGrantReadInstrumentation`
const FIXTURE_DIGEST = createHash('sha256').update('Pocket Harness SAF acceptance v1\n').digest('hex')

function arg(args, name) {
  const index = args.indexOf(name)
  if (index < 0 || index + 1 >= args.length || args[index + 1].startsWith('--')) throw new Error(`Missing ${name}`)
  return args[index + 1]
}

async function fingerprint(input) {
  const path = resolve(input)
  if (!path.endsWith('.apk')) throw new Error(`Not an APK: ${path}`)
  const info = await stat(path)
  if (!info.isFile() || info.size === 0) throw new Error(`Empty APK: ${path}`)
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

async function adb(binary, serial, args) {
  const { stdout, stderr } = await exec(binary, [...(serial ? ['-s', serial] : []), ...args], {
    timeout: 120_000, maxBuffer: 1024 * 1024, windowsHide: true,
  })
  return `${stdout}${stderr}`
}

async function inspectApk(tools, artifact) {
  const [badging, signed] = await Promise.all([
    adb(tools.aapt2, undefined, ['dump', 'badging', artifact.path]),
    adb('java', undefined, ['-jar', tools.apksigner, 'verify', '--print-certs', artifact.path]),
  ])
  return { ...parseBadging(badging), certificate: parseCertificate(signed) }
}

export function requireSafInstrumentation(output) {
  const declarations = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1)
  const matches = declarations.filter((block) =>
    /android:name[^\r\n]*="com\.minnnng\.dsh_android\.SafGrantReadInstrumentation"/.test(block) &&
    /android:targetPackage[^\r\n]*="com\.minnnng\.dsh_android"/.test(block) &&
    /android:targetProcesses[^\r\n]*="com\.minnnng\.dsh_android:agent"/.test(block))
  if (matches.length !== 1) throw new Error('AndroidTest APK lacks one Agent-process SAF read instrumentation')
}

export function selectDevice(output, requested) {
  const devices = output.split(/\r?\n/).map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => serial && state === 'device').map(([serial]) => serial)
  if (requested) {
    if (!devices.includes(requested)) throw new Error(`ADB device ${requested} is not authorized`)
    return requested
  }
  if (devices.length !== 1) throw new Error(`Expected one authorized device, found ${devices.length}`)
  return devices[0]
}

export function parseRead(output) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const field = (key) => {
    const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${key}=(.*)$`, 'gm'))]
    if (matches.length !== 1) throw new Error(`SAF read instrumentation missing or duplicated ${key}`)
    return matches[0][1].trim()
  }
  if (codes.length !== 1 || codes[0][1] !== '-1' || field('result') !== 'saf-persisted-read-pass') {
    throw new Error(`SAF read instrumentation failed: ${output.slice(-3000)}`)
  }
  const rootId = field('rootId')
  const processPid = Number(field('processPid'))
  if (!/^[0-9a-f]{64}$/.test(rootId ?? '') || field('contentSha256') !== FIXTURE_DIGEST ||
      !Number.isSafeInteger(processPid) || processPid <= 0) {
    throw new Error(`SAF read instrumentation returned incomplete evidence: ${output.slice(-3000)}`)
  }
  return { rootId, processPid, contentSha256: FIXTURE_DIGEST }
}

async function main(args) {
  const app = await fingerprint(arg(args, '--apk'))
  const testApk = await fingerprint(arg(args, '--test-apk'))
  if (app.path === testApk.path) throw new Error('App and AndroidTest APK must differ')
  const tools = await sdkTools()
  const [appIdentity, testIdentity] = await Promise.all([
    inspectApk(tools, app), inspectApk(tools, testApk),
  ])
  if (appIdentity.packageName !== PACKAGE || testIdentity.packageName !== `${PACKAGE}.test` ||
      appIdentity.certificate !== testIdentity.certificate) {
    throw new Error('App and AndroidTest APK package or signing identity differs')
  }
  requireSafInstrumentation(await adb(tools.aapt2, undefined,
    ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path]))
  const binary = args.includes('--adb') ? resolve(arg(args, '--adb')) : tools.adb
  const serial = selectDevice(await adb(binary, undefined, ['devices']),
    args.includes('--serial') ? arg(args, '--serial') : undefined)
  for (const artifact of [app, testApk]) {
    const installed = await adb(binary, serial, ['install', '-r', artifact.path])
    if (!/^Success\s*$/m.test(installed)) throw new Error(`ADB install failed: ${installed}`)
  }
  const first = parseRead(await adb(binary, serial, ['shell', 'am', 'instrument', '-w', '-r', RUNNER]))
  await adb(binary, serial, ['shell', 'am', 'force-stop', PACKAGE])
  const second = parseRead(await adb(binary, serial, ['shell', 'am', 'instrument', '-w', '-r',
    '-e', 'rootId', first.rootId, RUNNER]))
  if (first.processPid === second.processPid || first.rootId !== second.rootId ||
      first.contentSha256 !== second.contentSha256) {
    throw new Error('SAF persisted read did not prove a distinct post-stop Agent process with the same grant and bytes')
  }
  process.stdout.write(JSON.stringify({ result: 'pass', serial, app: { ...app, ...appIdentity },
    testApk: { ...testApk, ...testIdentity }, fixture: 'dsh-saf-acceptance.txt',
    first, second }, null, 2) + '\n')
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((failure) => {
    process.stderr.write(`${failure.message}\n`)
    process.exitCode = 1
  })
}
