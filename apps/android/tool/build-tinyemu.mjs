import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, readdir, stat, writeFile, copyFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { patchTinyEmu } from './patch-tinyemu.mjs'
import { tinyEmuSourceLock, tinyEmuHeadlessSources, tinyEmuGuestFixtureLock } from './tinyemu-source-lock.mjs'

const repository = fileURLToPath(new URL('../../../', import.meta.url))
const digest = data => createHash('sha256').update(data).digest('hex')

async function checkedFile(path, expected) {
  const bytes = await readFile(path)
  if (digest(bytes) !== expected.sha256 || (expected.bytes !== undefined && bytes.length !== expected.bytes)) {
    throw new Error(`Pinned input differs: ${path}`)
  }
  return { path, bytes: bytes.length, sha256: expected.sha256 }
}

export async function tinyEmuHeaderHashes(source, prefix = '') {
  const hashes = []
  for (const entry of await readdir(join(source, prefix), { withFileTypes: true })) {
    const name = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isDirectory()) hashes.push(...await tinyEmuHeaderHashes(source, name))
    else if (entry.isFile() && entry.name.endsWith('.h')) hashes.push({ name, sha256: digest(await readFile(join(source, name))) })
  }
  return hashes.sort((a, b) => a.name.localeCompare(b.name, 'en'))
}

/** Build only the buffer-backed RV64 interpreter and Android JNI into a cache artifact. */
export async function buildTinyEmu({ archive, ndk, output } = {}) {
  archive = resolve(archive ?? join(repository, '.cache/android/tinyemu-api/tinyemu.tar.gz'))
  if (!ndk && !process.env.ANDROID_NDK_HOME) {
    const properties = await readFile(join(repository, 'apps/android/android/local.properties'), 'utf8')
    const sdk = /^sdk\.dir=(.+)$/mu.exec(properties)?.[1]?.trim().replaceAll('\\\\', '\\').replaceAll('\\:', ':')
    if (!sdk) throw new Error('Pass --ndk=PATH or configure sdk.dir in Android local.properties')
    ndk = join(sdk, 'ndk/28.2.13676358')
  }
  ndk = resolve(ndk ?? process.env.ANDROID_NDK_HOME)
  output = resolve(output ?? join(repository, '.cache/android/tinyemu-probe/build'))
  const sourceArchive = await checkedFile(archive, tinyEmuSourceLock)
  const clang = join(ndk, 'toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe')
  await stat(clang)
  await mkdir(output, { recursive: true })
  const build = await mkdtemp(join(output, 'rv64-')), unpack = join(build, 'source')
  await mkdir(unpack)
  const members = execFileSync('tar', ['-tf', archive], { encoding: 'utf8', windowsHide: true }).trim().split(/\r?\n/u)
  if (members.some(name => !name.startsWith(`${tinyEmuSourceLock.root}/`) || name.includes('\\')
    || name.split('/').includes('..'))) throw new Error('TinyEMU archive layout differs')
  execFileSync('tar', ['-xf', archive, '-C', unpack], { windowsHide: true })
  const source = join(unpack, tinyEmuSourceLock.root)
  await patchTinyEmu(source)
  const include = ['-I', source]
  const flags = ['--target=aarch64-linux-android28', '-std=gnu11', '-O2', '-fPIC', '-fno-strict-aliasing',
    '-D_GNU_SOURCE', '-D_FILE_OFFSET_BITS=64', '-D_LARGEFILE_SOURCE', '-DCONFIG_RISCV_MAX_XLEN=64',
    '-DCONFIG_VERSION="2019-12-21"', ...include]
  const objects = [], inputs = []
  const compile = async (name, path, extra = []) => {
    const object = join(build, `${name}.o`)
    inputs.push({ name, sha256: digest(await readFile(path)) })
    execFileSync(clang, [...flags, ...extra, '-c', path, '-o', object], { windowsHide: true, stdio: 'inherit' })
    objects.push(object)
  }
  for (const name of tinyEmuHeadlessSources) await compile(name.slice(0, -2), join(source, name))
  await compile('riscv_cpu32', join(source, 'riscv_cpu.c'), ['-DMAX_XLEN=32'])
  await compile('riscv_cpu64', join(source, 'riscv_cpu.c'), ['-DMAX_XLEN=64'])
  await compile('linux_vm_engine', join(repository, 'apps/android/android/app/src/main/cpp/linux_vm_engine.c'))
  await compile('linux_vm_files', join(repository, 'apps/android/android/app/src/main/cpp/linux_vm_files.c'))
  const artifact = join(build, 'libpocket_linux_vm.so')
  execFileSync(clang, ['--target=aarch64-linux-android28', '-shared', '-Wl,--no-undefined',
    '-Wl,-z,max-page-size=16384', ...objects, '-lm', '-o', artifact], { windowsHide: true, stdio: 'inherit' })
  await copyFile(join(source, tinyEmuSourceLock.licenseFile), join(build, 'TinyEMU-MIT-LICENSE.txt'))
  const result = { format: 'pocket-tinyemu-build-v1', sourceArchive,
    patchSha256: digest(await readFile(new URL('./patch-tinyemu.mjs', import.meta.url))),
    source, artifact, bytes: (await stat(artifact)).size, sha256: digest(await readFile(artifact)),
    ndk, compiler: execFileSync(clang, ['--version'], { encoding: 'utf8', windowsHide: true }).trim(),
    flags, inputs, headers: await tinyEmuHeaderHashes(source), guestFixture: tinyEmuGuestFixtureLock, deviceBootVerified: false }
  await writeFile(join(build, 'build.json'), JSON.stringify(result, null, 2) + '\n')
  await writeFile(join(output, 'latest.json'), JSON.stringify(result, null, 2) + '\n')
  return result
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = Object.fromEntries(process.argv.slice(2).map(arg => {
    const index = arg.indexOf('=')
    if (!arg.startsWith('--') || index < 0) throw new Error('Use --archive=PATH --ndk=PATH --output=PATH')
    return [arg.slice(2, index), arg.slice(index + 1)]
  }))
  console.log(JSON.stringify(await buildTinyEmu(args), null, 2))
}
