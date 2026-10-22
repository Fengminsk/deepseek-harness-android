import { createHash } from 'node:crypto'
import { lstat, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

/** Verify the pinned Android binary before copying its identity into the runtime. */
export async function stageRipgrep({ repositoryRoot, staging }) {
  const lock = JSON.parse(await readFile(join(repositoryRoot, 'apps/android/tool/runtime-lock.json'), 'utf8')).ripgrep
  if (lock?.version !== '15.0.0' || lock?.abi !== 'arm64-v8a'
    || lock?.target !== 'aarch64-linux-android'
    || lock?.revision !== '3a612f88b805e14aef45bfa43e25a54abc6297fc'
    || !/^[a-f0-9]{64}$/.test(lock.sha256 ?? '')) {
    throw new Error('Android ripgrep lock is invalid')
  }
  const binary = join(repositoryRoot, 'apps/android/android/app/src/main/jniLibs/arm64-v8a/libpocket_ripgrep.so')
  const info = await lstat(binary)
  if (!info.isFile() || info.isSymbolicLink() || info.size === 0) {
    throw new Error('Android ARM64 ripgrep executable is missing')
  }
  const bytes = await readFile(binary)
  if (bytes.length < 64 || bytes.toString('ascii', 0, 4) !== '\x7fELF'
    || bytes[4] !== 2 || bytes[5] !== 1 || bytes.readUInt16LE(16) !== 3
    || bytes.readUInt16LE(18) !== 183) {
    throw new Error('Android ripgrep must be an ARM64 PIE ELF')
  }
  const sha256 = createHash('sha256').update(bytes).digest('hex')
  if (sha256 !== lock.sha256) throw new Error('Android ripgrep does not match its pinned hash')
  await writeFile(join(staging, 'node_modules/@minnnng/dsh-android-runtime/android-ripgrep.json'),
    `${JSON.stringify({ version: lock.version, abi: lock.abi, sha256 }, null, 2)}\n`)
  return { version: lock.version, abi: lock.abi, sha256, bytes: bytes.length }
}
