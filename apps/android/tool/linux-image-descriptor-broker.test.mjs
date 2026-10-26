import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import { ALPINE_ROOTFS_SOURCE } from './linux-userland-source-lock.mjs'

const java = new URL('../android/app/src/main/java/com/minnnng/dsh_android/LinuxImageLeaseOwner.java', import.meta.url)

function constant(source, name) {
  const value = new RegExp(`static final (?:String|long) ${name} = ([^;]+);`).exec(source)?.[1]
  if (!value) throw new Error(`Missing App image lock ${name}`)
  return value.trim()
}

test('Android image FD broker pin tracks the independently reviewed Alpine source', async () => {
  const source = await readFile(java, 'utf8')
  assert.equal(JSON.parse(constant(source, 'VERSION')), ALPINE_ROOTFS_SOURCE.version)
  assert.equal(JSON.parse(constant(source, 'SHA256')), ALPINE_ROOTFS_SOURCE.sha256)
  assert.equal(Number(constant(source, 'ARCHIVE_BYTES').replaceAll('_', '').replace(/L$/, '')),
    ALPINE_ROOTFS_SOURCE.bytes)
  assert.match(source, /versions\.resolve\(imageSha256\)/)
  assert.doesNotMatch(source, /(?:https?:\/\/|execve|ProcessBuilder)/)
})
