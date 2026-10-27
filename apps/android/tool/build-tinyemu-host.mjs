import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tinyEmuHeadlessSources, tinyEmuSourceLock } from './tinyemu-source-lock.mjs'
import { tinyEmuHeaderHashes } from './build-tinyemu.mjs'

const root = fileURLToPath(new URL('../../../', import.meta.url))
const sha = data => createHash('sha256').update(data).digest('hex')
const toolchain = {
  name: 'llvm-mingw-20260908-ucrt-x86_64',
  url: 'https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/llvm-mingw-20260908-ucrt-x86_64.zip',
  sha256: '1bcf74d06b724aeecaa6412ca85f5b26fb1da770e7cdcefa9263c9c5c3ad34b6',
}
const cleanEnvironment = () => Object.fromEntries(Object.entries(process.env)
  .filter(([key]) => !/KEY|SECRET|TOKEN|PASSWORD/iu.test(key)))

/** Compile the exact prepared interpreter and production JNI/console for a host-only JVM probe. */
export async function buildTinyEmuHost({ jdk, compilerRoot, output } = {}) {
  if (process.platform !== 'win32') throw new Error('This host probe targets Windows x86_64')
  if (!jdk) throw new Error('Pass --jdk=PATH to a local JDK')
  jdk = resolve(jdk)
  const cache = join(root, '.cache/android/windows-host-tools')
  compilerRoot = resolve(compilerRoot ?? join(cache, toolchain.name))
  if (sha(await readFile(join(cache, `${toolchain.name}.zip`))) !== toolchain.sha256) {
    throw new Error('Official host compiler archive hash differs')
  }
  const compiler = join(compilerRoot, 'bin/x86_64-w64-mingw32-clang.exe')
  await stat(compiler); await stat(join(jdk, 'include/jni.h'))
  const prepared = JSON.parse(await readFile(join(root, '.cache/android/tinyemu-probe/build/latest.json'), 'utf8'))
  if (prepared.sourceArchive.sha256 !== tinyEmuSourceLock.sha256
    || sha(await readFile(prepared.sourceArchive.path)) !== tinyEmuSourceLock.sha256
    || prepared.patchSha256 !== sha(await readFile(new URL('./patch-tinyemu.mjs', import.meta.url)))
    || JSON.stringify(prepared.headers) !== JSON.stringify(await tinyEmuHeaderHashes(prepared.source))) {
    throw new Error('Prepared TinyEMU source record differs')
  }
  const inputs = [], objects = []
  output = resolve(output ?? join(root, '.cache/android/tinyemu-host'))
  await mkdir(output, { recursive: true })
  const build = await mkdtemp(join(output, 'build-'))
  const flags = ['-std=gnu11', '-O2', '-fno-strict-aliasing', '-D_GNU_SOURCE',
    '-D_FILE_OFFSET_BITS=64', '-D_LARGEFILE_SOURCE', '-DCONFIG_RISCV_MAX_XLEN=64',
    '-DCONFIG_VERSION="2019-12-21"', '-I', prepared.source,
    '-I', join(root, 'apps/android/tool/linux-vm-host/include'),
    '-I', join(jdk, 'include'), '-I', join(jdk, 'include/win32')]
  const exec = (file, argv) => execFileSync(file, argv, { windowsHide: true, env: cleanEnvironment(), stdio: 'inherit' })
  const compile = async (name, source, extra = [], preparedInput = true) => {
    const hash = sha(await readFile(source))
    if (preparedInput && prepared.inputs.find(input => input.name === name)?.sha256 !== hash) {
      throw new Error(`Prepared source changed: ${name}`)
    }
    inputs.push({ name, source, sha256: hash })
    const target = join(build, `${name}.o`)
    exec(compiler, [...flags, ...extra, '-c', source, '-o', target])
    objects.push(target)
  }
  for (const source of tinyEmuHeadlessSources) await compile(source.slice(0, -2), join(prepared.source, source))
  for (const bits of [32, 64]) await compile(`riscv_cpu${bits}`, join(prepared.source, 'riscv_cpu.c'), [`-DMAX_XLEN=${bits}`])
  await compile('linux_vm_engine', join(root, 'apps/android/android/app/src/main/cpp/linux_vm_engine.c'), [], false)
  const library = join(build, 'pocket_linux_vm.dll')
  exec(compiler, ['-shared', ...objects, '-lm', '-lwinpthread', '-o', library])
  const classes = join(build, 'classes')
  await mkdir(classes)
  const javaSources = ['apps/android/android/app/src/main/java/com/minnnng/dsh_android/LinuxVmConsole.java',
    'apps/android/tool/linux-vm-host/LinuxVmHost.java']
  exec(join(jdk, 'bin/javac.exe'), ['-encoding', 'UTF-8', '-d', classes, ...javaSources.map(source => join(root, source))])
  const result = { format: 'tinyemu-windows-host-v1', library, classes, jdk, compilerRoot,
    compiler: execFileSync(compiler, ['--version'], { encoding: 'utf8', windowsHide: true, env: cleanEnvironment() }).trim(),
    librarySha256: sha(await readFile(library)), sourceArchiveSha256: tinyEmuSourceLock.sha256,
    patchSha256: prepared.patchSha256, inputs, toolchain,
    javaSources: await Promise.all(javaSources.map(async source => ({ source, sha256: sha(await readFile(join(root, source))) }))),
    hostHeaderSha256: sha(await readFile(join(root, 'apps/android/tool/linux-vm-host/include/sys/select.h'))),
    androidDeviceVerified: false }
  await writeFile(join(build, 'build.json'), JSON.stringify(result, null, 2) + '\n')
  await writeFile(join(output, 'latest.json'), JSON.stringify(result, null, 2) + '\n')
  return result
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = Object.fromEntries(process.argv.slice(2).map(arg => {
    const at = arg.indexOf('=')
    if (!arg.startsWith('--') || at < 0) throw new Error('Use --jdk=PATH --compilerRoot=PATH --output=PATH')
    return [arg.slice(2, at), arg.slice(at + 1)]
  }))
  console.log(JSON.stringify(await buildTinyEmuHost(args), null, 2))
}
