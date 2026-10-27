import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../../../', import.meta.url))
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const args = Object.fromEntries(process.argv.slice(2).map(value => {
  const at = value.indexOf('=')
  if (!value.startsWith('--') || at < 0) throw new Error('Use --proxyPort=7897 --candidate=PATH --mode=live')
  return [value.slice(2, at), value.slice(at + 1)]
}))
const outputRoot = join(root, '.cache/android/linux-vm-network')
await mkdir(outputRoot, { recursive: true })
const output = await mkdtemp(join(outputRoot, 'run-'))
const sources = [
  'apps/android/tool/linux-vm-host/LinuxVmNetworkHost.java',
  'apps/android/android/app/src/test/java/com/minnnng/dsh_android/LinuxVmNetworkHostTest.java',
]
const sourceRoot = join(root, 'apps/android/android/app/src/main/java')
const classes = join(output, 'classes')
await mkdir(classes)
execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', sourceRoot, '-d', classes,
  ...sources.map(file => join(root, file))], { stdio: 'inherit', windowsHide: true })
const run = (name, argv, host) => {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/KEY|SECRET|TOKEN|PASSWORD/iu.test(key)))
  if (host) {
    const path = env.PATH ?? env.Path ?? ''
    delete env.Path
    env.PATH = `${join(host.compilerRoot, 'bin')};${path}`
  }
  return execFileSync(host ? join(host.jdk, 'bin/java.exe') : 'java', ['-Xmx768m', '-XX:MaxDirectMemorySize=768m',
    `-Ddsh.test.cache=${output}`, '-cp', classes, `com.minnnng.dsh_android.${name}`, ...argv],
  { encoding: 'utf8', windowsHide: true, timeout: 150_000, env })
}
const tests = args.candidate ? null : run('LinuxVmNetworkHostTest', []).trim()
if (tests) console.log(tests)
const report = { format: 'linux-vm-https-host-v1', output, tests, androidDeviceVerified: false,
  directoryFsyncVerified: false, productionIntegrated: false }
const classDirectory = join(classes, 'com/minnnng/dsh_android')
const classNames = (await readdir(classDirectory)).filter(name => name.endsWith('.class')).sort()
const mainNames = [...new Set(classNames.map(name => name.split('$')[0].replace(/\.class$/u, '')))]
const sourceNames = [...sources, ...mainNames
  .filter(name => !['LinuxVmEngine', 'LinuxVmNetworkHost', 'LinuxVmNetworkHostTest'].includes(name))
  .map(name => `apps/android/android/app/src/main/java/com/minnnng/dsh_android/${name}.java`),
'apps/android/tool/acceptance-linux-vm-network.mjs', 'apps/android/android/app/src/main/assets/linux-vm-network/dsh-fetch.py']
report.sourceInputs = await Promise.all(sourceNames.sort().map(async path => ({ path,
  sha256: hash(await readFile(join(root, path))) })))
report.compiledClasses = await Promise.all(classNames.map(async name => ({ name,
  sha256: hash(await readFile(join(classDirectory, name))) })))
if (args.candidate) {
  if (!/^(?:[1-9][0-9]{0,4})$/u.test(args.proxyPort ?? '') || Number(args.proxyPort) > 65535) {
    throw new Error('Live guest probes require an explicit local HTTP proxy port')
  }
  const candidate = resolve(args.candidate)
  const host = JSON.parse(await readFile(join(root, '.cache/android/tinyemu-host/latest.json'), 'utf8'))
  if (hash(await readFile(host.library)) !== host.librarySha256) throw new Error('Host native library changed')
  const engine = 'apps/android/android/app/src/main/cpp/linux_vm_engine.c'
  if (hash(await readFile(join(root, engine))) !== host.inputs.find(input => input.name === 'linux_vm_engine')?.sha256) {
    throw new Error('Host JNI library does not match current engine source')
  }
  const assets = join(candidate, 'assets/linux-vm')
  const manifest = JSON.parse(await readFile(join(assets, 'manifest.json'), 'utf8'))
  const images = {}
  for (const part of ['bios', 'kernel', 'disk']) {
    const bytes = await readFile(join(assets, `${part}.bin`))
    if (hash(bytes) !== manifest[part].sha256 || bytes.length !== manifest[part].bytes) {
      throw new Error(`Candidate ${part} does not match its image manifest`)
    }
    images[part] = manifest[part]
  }
  const mode = args.mode ?? 'live'
  const guestOutput = run('LinuxVmNetworkHost', [host.library, ...['bios', 'kernel', 'disk'].map(part => join(assets, `${part}.bin`)),
    join(root, 'apps/android/android/app/src/main/assets/linux-vm-network/dsh-fetch.py'), join(output, 'guest'), args.proxyPort, mode], host)
  report.guest = JSON.parse(guestOutput.trim())
  report.images = images
  report.librarySha256 = host.librarySha256
  report.proxy = `http://127.0.0.1:${report.guest.proxyPort}`
  report.guestScriptSha256 = hash(await readFile(join(root, 'apps/android/android/app/src/main/assets/linux-vm-network/dsh-fetch.py')))
  console.log(guestOutput.trim())
}
await writeFile(join(output, 'report.json'), `${JSON.stringify(report, null, 2)}\n`)
console.log(join(output, 'report.json'))
