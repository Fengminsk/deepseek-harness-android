import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseBadging, parseCertificate, parseInstalledPath, sdkTools } from './acceptance-upgrade-device.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.FileBrokerProviderInstrumentation`
const REQUIRED = ['secure-provider-and-revision', 'edit-create-and-stale', 'cancel-and-link-isolation']

function argument(args, flag) {
  const index = args.indexOf(flag)
  if (index < 0 || index + 1 >= args.length || args[index + 1].startsWith('--')) {
    throw new Error(`Missing ${flag}`)
  }
  return args[index + 1]
}

async function run(binary, args, timeout = 120_000) {
  const { stdout, stderr } = await exec(binary, args, {
    timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true,
  })
  return `${stdout}${stderr}`
}

async function fingerprint(input) {
  const path = resolve(input)
  const info = await stat(path)
  if (!path.endsWith('.apk') || !info.isFile() || info.size < 1) throw new Error(`Invalid APK: ${path}`)
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

/** Require the device probe to run inside the same isolated Agent process as the broker. */
export function requireFileBrokerInstrumentation(output) {
  const declarations = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1)
  const matches = declarations.filter(block => {
    const name = /android:name[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const target = /android:targetPackage[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const process = /android:targetProcesses[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    return name === `${PACKAGE}.FileBrokerProviderInstrumentation` &&
      target === PACKAGE && process === `${PACKAGE}:agent`
  })
  if (matches.length !== 1) throw new Error('AndroidTest APK lacks the exact Agent-process file-broker instrumentation')
}

/** Reject partial, duplicate, or nonterminal instrumentation receipts. */
export function parseFileBrokerResult(output) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const field = name => {
    const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${name}=(.*)$`, 'gm'))]
    if (matches.length !== 1) throw new Error(`Missing or duplicate ${name} file-broker result`)
    return matches[0][1].trim()
  }
  const passed = field('passed').split(',')
  const passedCount = Number(field('passedCount'))
  const failedCount = Number(field('failedCount'))
  const provider = field('provider')
  const links = Number(field('links'))
  if (codes.length !== 1 || codes[0][1] !== '-1' || field('failed') !== '' ||
      failedCount !== 0 || passedCount !== REQUIRED.length ||
      passedCount !== passed.length || !Number.isSafeInteger(passedCount) ||
      new Set(passed).size !== REQUIRED.length || REQUIRED.some(name => !passed.includes(name)) ||
      !provider.includes('SecureDirectoryStream') || links !== 1) {
    throw new Error(`File-broker provider device acceptance failed: ${output.slice(-4000)}`)
  }
  return { passed, provider, links }
}

async function main(args) {
  const [app, testApk] = await Promise.all([
    fingerprint(argument(args, '--apk')), fingerprint(argument(args, '--test-apk')),
  ])
  if (app.path === testApk.path) throw new Error('App and AndroidTest APK must differ')
  const tools = await sdkTools()
  const inspect = async artifact => ({
    ...parseBadging(await run(tools.aapt2, ['dump', 'badging', artifact.path], 30_000)),
    certificate: parseCertificate(await run('java', ['-jar', tools.apksigner,
      'verify', '--print-certs', artifact.path], 30_000)),
  })
  const [appIdentity, testIdentity] = await Promise.all([inspect(app), inspect(testApk)])
  if (appIdentity.packageName !== PACKAGE || testIdentity.packageName !== `${PACKAGE}.test` ||
      appIdentity.certificate !== testIdentity.certificate) {
    throw new Error('App and AndroidTest APK package or signing identity differs')
  }
  requireFileBrokerInstrumentation(await run(tools.aapt2,
    ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30_000))
  if (args.includes('--preflight-only')) {
    process.stdout.write(JSON.stringify({ result: 'preflight-pass',
      app: { ...app, ...appIdentity }, testApk: { ...testApk, ...testIdentity } }, null, 2) + '\n')
    return
  }
  const adb = args.includes('--adb') ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15_000),
    args.includes('--serial') ? argument(args, '--serial') : undefined)
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  const existed = parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15_000))
  if (existed && !args.includes('--allow-existing')) {
    throw new Error('App already installed; pass --allow-existing only after authorizing this test on that installation')
  }
  for (const artifact of [app, testApk]) {
    const installed = await device(['install', '-r', artifact.path], 120_000)
    if (!/^Success\s*$/m.test(installed)) throw new Error(`ADB install failed: ${installed}`)
  }
  const result = parseFileBrokerResult(await device(['shell', 'am', 'instrument', '-w', '-r', RUNNER], 90_000))
  process.stdout.write(JSON.stringify({ result: 'pass', serial, app: { ...app, ...appIdentity },
    testApk: { ...testApk, ...testIdentity }, ...result }, null, 2) + '\n')
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  })
}
