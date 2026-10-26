import { createConnection } from 'node:net'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const modulePath = join(process.env.POCKET_UPGRADE_BUNDLE_ROOT,
  'node_modules/@minnnng/dsh-android-runtime/transport.mjs')
const { createSocketTransport } = await import(pathToFileURL(modulePath).href)

/** Use the packaged carrier framing; loopback replaces only Android's JNI socketpair. */
export function createRuntimeTransport() {
  const port = Number(process.env.POCKET_ACCOUNT_FIXTURE_IPC_PORT)
  if (!Number.isSafeInteger(port) || port < 1 || port > 65535) throw new Error('Missing allocated fixture IPC port')
  return createSocketTransport(createConnection({ host: '127.0.0.1', port }))
}
