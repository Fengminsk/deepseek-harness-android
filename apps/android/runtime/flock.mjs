import { getSystemErrorName } from 'node:util'
import { join } from 'node:path'

const native = { exports: {} }
process.dlopen(native, join(process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR, 'libdsh_system.so'))

/** Retain the upstream asynchronous flock semantics with the Android-packaged addon. */
export async function tryLockExclusive(fd) {
  const errno = await new Promise(resolve => native.exports.tryLock(fd, resolve))
  if (errno === 0) return
  const code = getSystemErrorName(-errno)
  throw Object.assign(new Error(`${code}: flock failed`), { code, errno, syscall: 'flock' })
}
