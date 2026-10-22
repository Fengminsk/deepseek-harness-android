import { createHash } from 'node:crypto'
import { lstatSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const binaryName = 'libpocket_ripgrep.so'

/** Reject a missing, replaced, or wrong-architecture Android search executable. */
export function checkedAndroidRipgrepPath(libraryDirectory, descriptor) {
  if (typeof libraryDirectory !== 'string' || libraryDirectory.length === 0
    || typeof descriptor?.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(descriptor.sha256)
    || descriptor.abi !== 'arm64-v8a' || descriptor.version !== '15.0.0') {
    throw new Error('Android ripgrep package identity is missing')
  }
  const path = join(libraryDirectory, binaryName)
  const info = lstatSync(path)
  if (!info.isFile() || info.isSymbolicLink() || info.size === 0) {
    throw new Error('Android ripgrep is not a packaged executable')
  }
  const bytes = readFileSync(path)
  if (bytes.length < 64 || bytes.toString('ascii', 0, 4) !== '\x7fELF'
    || bytes[4] !== 2 || bytes[5] !== 1 || bytes.readUInt16LE(16) !== 3
    || bytes.readUInt16LE(18) !== 183) {
    throw new Error('Android ripgrep is not an ARM64 PIE executable')
  }
  if (createHash('sha256').update(bytes).digest('hex') !== descriptor.sha256) {
    throw new Error('Android ripgrep checksum mismatch')
  }
  return path
}

// The original tool-fs-search plugin imports this module only on Android.
// Keep its parser, limits, cancellation and subprocess ownership unchanged.
export const rgPath = process.platform === 'android'
  ? checkedAndroidRipgrepPath(process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR,
    JSON.parse(readFileSync(new URL('./android-ripgrep.json', import.meta.url), 'utf8')))
  : undefined
