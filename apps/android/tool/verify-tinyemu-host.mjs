import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, writeFile, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../../../', import.meta.url))
const suite = process.argv[2] ?? 'smoke'
if (!['smoke', 'alpine', 'lifecycle'].includes(suite)) throw new Error('Use smoke, alpine or lifecycle')
const buildArgument = process.argv[3]
if (process.argv.length > 4 || buildArgument !== undefined && !buildArgument.startsWith('--build-record=')) {
  throw new Error('Optional argument: --build-record=PATH')
}
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
const record = JSON.parse(await readFile(buildArgument === undefined
  ? join(root, '.cache/android/tinyemu-host/latest.json') : buildArgument.slice('--build-record='.length), 'utf8'))
assert.equal(record.librarySha256, sha(await readFile(record.library)))
const buildRecordFile = join(dirname(record.library), 'build.json')
const buildRecord = await readFile(buildRecordFile)
assert.deepEqual(JSON.parse(buildRecord), record)
for (const input of record.inputs) assert.equal(input.sha256, sha(await readFile(input.source)))
for (const input of record.javaSources) assert.equal(input.sha256, sha(await readFile(join(root, input.source))))
assert.equal(record.patchSha256, sha(await readFile(new URL('./patch-tinyemu.mjs', import.meta.url))))
assert.equal(record.hostHeaderSha256, sha(await readFile(new URL('./linux-vm-host/include/sys/select.h', import.meta.url))))
const assets = join(root, '.cache/android/linux-vm-assets')
const imageManifest = JSON.parse(await readFile(join(assets, 'linux-vm/manifest.json'), 'utf8'))
for (const name of ['bios', 'kernel', 'disk']) {
  const input = imageManifest[name], bytes = await readFile(join(assets, input.asset))
  assert.equal(bytes.length, input.bytes); assert.equal(sha(bytes), input.sha256)
}
const output = join(root, '.cache/android/tinyemu-host/runs')
await mkdir(output, { recursive: true })
const run = await mkdtemp(join(output, `${suite}-`))
const reports = []
const invoke = async (name, command, disk, workspace = '-', extra = '-', {
  timeoutMs = 120000, cancelOnReady = false, expectedNativeStatus = 0,
} = {}) => {
  const commandFile = join(run, `${name}.sh`)
  await writeFile(commandFile, command, { flag: 'wx' })
  const destination = join(run, name)
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/KEY|SECRET|TOKEN|PASSWORD/iu.test(key)))
  env.PATH = `${join(record.compilerRoot, 'bin')};${env.PATH ?? env.Path ?? ''}`
  delete env.Path
  let failure
  try {
    execFileSync(join(record.jdk, 'bin/java.exe'), ['-Xmx768m', '-XX:MaxDirectMemorySize=768m',
      '-cp', record.classes, 'com.minnnng.dsh_android.LinuxVmHost', record.library,
      join(assets, imageManifest.bios.asset), join(assets, imageManifest.kernel.asset),
      disk, workspace, extra, '-', commandFile, destination, String(workspace === '-'), String(timeoutMs), String(cancelOnReady)],
    { env, windowsHide: true, timeout: 140000, maxBuffer: 2 * 1024 * 1024, encoding: 'utf8' })
  } catch (error) { failure = error }
  const result = JSON.parse(await readFile(join(destination, 'result.json'), 'utf8'))
  const text = Buffer.from(result.outputBase64, 'base64').toString('utf8')
  delete result.outputBase64
  reports.push({ name, ...result, output: text, commandSha256: sha(command), directory: destination })
  console.log(JSON.stringify(reports.at(-1)))
  assert.equal(result.nativeStatus, expectedNativeStatus)
  if (expectedNativeStatus === 0) {
    if (failure) throw failure
    assert.equal(result.exitCode, 0); assert.equal(result.imagesWritten, true)
  } else {
    assert.equal(failure?.status, 1); assert.equal(result.imagesWritten, false)
    assert.equal(result.exitCode, null)
  }
  return { directory: destination, text, result }
}
let failure, alpineImage, imageBuildInput
try {
  if (suite === 'smoke') {
    const first = await invoke('first', "set -e\nuname -srm\nprintf persistent > /workspace/probe.txt\ncat /workspace/probe.txt\n", join(assets, imageManifest.disk.asset))
    assert.match(first.text, /Linux.*riscv64/u)
    const next = await invoke('second', 'test "$(cat /workspace/probe.txt)" = persistent\nprintf DSH_HOST_PERSISTENCE_OK\n',
      join(first.directory, 'root.bin'), join(first.directory, 'workspace.bin'))
    assert.match(next.text, /DSH_HOST_PERSISTENCE_OK/u)
  } else if (suite === 'alpine') {
    const input = join(root, '.cache/android/linux-image-build-assets/linux-image-build')
    const manifest = JSON.parse(await readFile(join(input, 'manifest.json'), 'utf8'))
    const tar = join(input, 'input.tar')
    assert.equal((await stat(tar)).size, manifest.bytes); assert.equal(sha(await readFile(tar)), manifest.sha256)
    const packageLock = await readFile(new URL('./alpine-packages.lock.json', import.meta.url))
    assert.equal(manifest.packageLockSha256, sha(packageLock))
    assert.equal(manifest.builderSha256, sha(await readFile(new URL('./build-alpine-vm-input.py', import.meta.url))))
    imageBuildInput = { ...manifest, artifact: tar }
    const built = await invoke('build', await readFile(new URL('./linux-vm-host/build-alpine.sh', import.meta.url), 'utf8'),
      join(assets, imageManifest.disk.asset), '-', tar)
    assert.match(built.text, /DSH_ALPINE_IMAGE_BUILT/u)
    const probe = await invoke('probe', await readFile(new URL('./linux-vm-host/probe-alpine.sh', import.meta.url), 'utf8'),
      join(built.directory, 'extra.bin'), join(built.directory, 'workspace.bin'))
    assert.match(probe.text, /DSH_ALPINE_RUNTIME_OK/u)
    const checked = await invoke('filesystem', 'set -e\ne2fsck -fn /dev/vdc\nprintf DSH_ALPINE_FILESYSTEM_OK\n',
      join(built.directory, 'extra.bin'), join(probe.directory, 'workspace.bin'), join(built.directory, 'extra.bin'))
    assert.match(checked.text, /DSH_ALPINE_FILESYSTEM_OK/u)
    const image = join(built.directory, 'extra.bin')
    alpineImage = { artifact: image, bytes: (await stat(image)).size, sha256: sha(await readFile(image)) }
  } else {
    const disk = join(assets, imageManifest.disk.asset)
    const before = sha(await readFile(disk))
    const timed = await invoke('timeout', "printf changed > /workspace/uncommitted.txt\nprintf 'DSH_HOST_TIMEOUT_READY\\n'\nwhile :; do :; done\n", disk, '-', '-',
      { timeoutMs: 3000, expectedNativeStatus: 1 })
    assert.match(timed.text, /DSH_HOST_TIMEOUT_READY/u)
    assert.ok(timed.result.elapsedMs >= 3000 && timed.result.elapsedMs < 10000)
    const cancelled = await invoke('cancel', "printf changed > /workspace/uncommitted.txt\nprintf 'DSH_HOST_CANCEL_READY\\n'\nwhile :; do :; done\n", disk, '-', '-',
      { cancelOnReady: true, expectedNativeStatus: 2 })
    assert.equal(cancelled.result.cancelAfterGuestEntry, true)
    assert.ok(cancelled.result.elapsedMs < 10000)
    assert.equal(sha(await readFile(disk)), before)
  }
} catch (error) { failure = String(error.message).slice(0, 2000) }
const result = { format: 'linux-vm-host-report-v2', suite, passed: failure === undefined,
  host: process.platform, androidDeviceVerified: false, runnerSha256: sha(await readFile(import.meta.filename)),
  hostBuild: { file: buildRecordFile, sha256: sha(buildRecord) },
  librarySha256: record.librarySha256, imageManifest, reports,
  ...(imageBuildInput ? { imageBuildInput } : {}), ...(alpineImage ? { alpineImage } : {}),
  ...(failure ? { failure } : {}) }
await writeFile(join(run, 'report.json'), JSON.stringify(result, null, 2) + '\n')
console.log(JSON.stringify({ report: join(run, 'report.json'), passed: result.passed, androidDeviceVerified: false }))
if (failure) process.exitCode = 1
