import { createHash } from 'node:crypto'
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tinyEmuGuestFixtureLock } from './tinyemu-source-lock.mjs'

/** Stage pinned boot fixtures only for explicitly requested same-package device acceptance builds. */
export async function stageLinuxVmFixture() {
  const repository = fileURLToPath(new URL('../../../', import.meta.url))
  const source = join(repository, '.cache/android/tinyemu-probe', tinyEmuGuestFixtureLock.root)
  const directory = join(repository, '.cache/android/linux-vm-assets/linux-vm')
  const manifest = { version: 1, machine: 'riscv64', distribution: tinyEmuGuestFixtureLock.distribution }
  await mkdir(directory, { recursive: true })
  for (const [kind, expected] of Object.entries(tinyEmuGuestFixtureLock.files)) {
    const path = join(source, expected.name)
    const bytes = await readFile(path)
    if (bytes.length !== expected.bytes || createHash('sha256').update(bytes).digest('hex') !== expected.sha256) {
      throw new Error(`Linux VM fixture differs: ${kind}`)
    }
    await copyFile(path, join(directory, `${kind}.bin`))
    manifest[kind] = { asset: `linux-vm/${kind}.bin`, bytes: expected.bytes, sha256: expected.sha256 }
  }
  await writeFile(join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
  return { directory, manifest }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(await stageLinuxVmFixture(), null, 2))
}
