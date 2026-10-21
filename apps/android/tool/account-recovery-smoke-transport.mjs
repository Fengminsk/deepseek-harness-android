import { createConnection } from 'node:net'
import { createSocketTransport } from '../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/transport.mjs'

/** Exercise the Android framed socket carrier; loopback replaces only its JNI socketpair. */
export function createRuntimeTransport() {
  const port = Number(process.env.POCKET_ACCOUNT_FIXTURE_IPC_PORT)
  if (!Number.isSafeInteger(port) || port < 1 || port > 65535) throw new Error('Missing allocated fixture IPC port')
  return createSocketTransport(createConnection({ host: '127.0.0.1', port }))
}
