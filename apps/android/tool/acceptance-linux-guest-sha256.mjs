import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const [wasmPath, launcherPath, loaderPath] = process.argv.slice(2)
assert.ok(wasmPath && launcherPath && loaderPath,
  'usage: node acceptance-linux-guest-sha256.mjs CORE.wasm PROOT_ELF LOADER_ELF')
const { instance } = await WebAssembly.instantiate(await readFile(resolve(wasmPath)))
const { memory, dsh_guest_sha256: hash } = instance.exports
assert.ok(memory instanceof WebAssembly.Memory && typeof hash === 'function')
const outputAt = 0x10000
const inputAt = 0x20000
function digest(bytes) {
  const view = new Uint8Array(memory.buffer)
  assert.ok(bytes.length + inputAt < view.length, 'test fixture exceeds WASM memory')
  view.set(bytes, inputAt)
  hash(inputAt, bytes.length, outputAt)
  return Buffer.from(view.subarray(outputAt, outputAt + 32)).toString('hex')
}

const vectors = [
  Buffer.alloc(0), Buffer.from('abc'), Buffer.alloc(55, 0x61),
  Buffer.alloc(56, 0x61), Buffer.alloc(64, 0x61), Buffer.alloc(1000000, 0x61),
  Buffer.from(Array.from({ length: 1025 }, (_, index) => index & 0xff)),
]
assert.equal(digest(Buffer.alloc(0)),
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  'NIST SHA-256 empty-input vector')
assert.equal(digest(Buffer.from('abc')),
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  'NIST SHA-256 abc vector')
for (const bytes of vectors) {
  assert.equal(digest(bytes), createHash('sha256').update(bytes).digest('hex'),
    `SHA-256 core differs for ${bytes.length} bytes`)
}
const candidates = [
  [launcherPath, 'c22cdb13c5de4b6e0022f7ede7a5ca0bf88675d4b674aa339a885b96d8b26f7f'],
  [loaderPath, 'c5e85afb7599bd82f2419fb054d597514d5c9578954288bef0c5320cd8b63fbf'],
]
for (const [path, pinned] of candidates) {
  const bytes = await readFile(resolve(path))
  assert.equal(createHash('sha256').update(bytes).digest('hex'), pinned,
    `${path} changed from the pinned candidate`)
  assert.equal(digest(bytes), pinned, `${path} differs under the C SHA-256 core`)
  const altered = Buffer.from(bytes)
  altered[altered.length - 1] ^= 1
  assert.notEqual(digest(altered), pinned,
    `${path} modified bytes must not match the fixed native pin`)
}
console.log('Linux guest SHA-256 C core standard vectors and pinned ELF bytes PASS')
