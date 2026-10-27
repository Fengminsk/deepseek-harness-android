import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { APK_MANIFEST_MAX_BYTES, parseApkManifest } from '../runtime/apk-manifest.mjs'

const ANDROID = 'http://schemas.android.com/apk/res/android'
const NONE = 0xffffffff
const attr = (name, value, type = typeof value === 'boolean' ? 0x12 : typeof value === 'number' ? 0x10 : 3,
  ns = ANDROID) => ({ name, value, type, ns })
const element = (name, attrs = [], children = [], ns = null) => ({ name, attrs, children, ns })
const manifest = children => element('manifest', [attr('package', 'org.example.fixture', 3, null),
  attr('versionCode', 42), attr('versionName', '1.2')], children)
const align = bytes => Buffer.concat([bytes, Buffer.alloc((4 - bytes.length % 4) % 4)])
function chunk(type, headerBytes, body = Buffer.alloc(0)) {
  const bytes = align(Buffer.concat([Buffer.alloc(8), headerBytes, body]))
  bytes.writeUInt16LE(type); bytes.writeUInt16LE(8 + headerBytes.length, 2); bytes.writeUInt32LE(bytes.length, 4)
  return bytes
}
function uints(...values) {
  const buffer = Buffer.alloc(values.length * 4)
  values.forEach((value, index) => buffer.writeUInt32LE(value >>> 0, index * 4))
  return buffer
}
function encodedLength(value, wide) {
  if (wide) {
    const result = Buffer.alloc(value < 32768 ? 2 : 4)
    result.writeUInt16LE(value < 32768 ? value : 0x8000 | (value >>> 16))
    if (result.length === 4) result.writeUInt16LE(value & 65535, 2)
    return result
  }
  return value < 128 ? Buffer.from([value]) : Buffer.from([0x80 | (value >>> 8), value & 255])
}
function binary(root, { utf8 = true, resourceMap = {}, additionalNamespaces = [] } = {}) {
  const strings = [], indices = new Map()
  const intern = value => {
    if (value === null || value === undefined) return NONE
    if (!indices.has(value)) { indices.set(value, strings.length); strings.push(value) }
    return indices.get(value)
  }
  const namespaces = [['android', ANDROID], ...additionalNamespaces]
  for (const [prefix, uri] of namespaces) { intern(prefix); intern(uri) }
  const register = node => {
    intern(node.ns); intern(node.name)
    for (const item of node.attrs) {
      intern(item.ns); intern(item.name)
      if (item.type === 3) intern(item.value)
      if (item.raw !== undefined) intern(item.raw)
    }
    node.children.forEach(register)
  }
  register(root)
  const data = [], offsets = []
  let length = 0
  for (const value of strings) {
    const text = Buffer.from(value, utf8 ? 'utf8' : 'utf16le')
    const encoded = Buffer.concat([encodedLength(value.length, !utf8),
      ...(utf8 ? [encodedLength(text.length, false)] : []), text, Buffer.alloc(utf8 ? 1 : 2)])
    offsets.push(length); data.push(encoded); length += encoded.length
  }
  const pool = chunk(1, uints(strings.length, 0, utf8 ? 256 : 0, 28 + strings.length * 4, 0),
    Buffer.concat([uints(...offsets), ...data]))
  const xmlHeader = uints(1, NONE)
  const parts = [pool]
  if (Object.keys(resourceMap).length) {
    parts.push(chunk(0x180, Buffer.alloc(0), uints(...strings.map(value => resourceMap[value] ?? 0))))
  }
  for (const [prefix, uri] of namespaces) parts.push(chunk(0x100, xmlHeader, uints(intern(prefix), intern(uri))))
  const write = node => {
    const extension = Buffer.alloc(20)
    extension.writeUInt32LE(intern(node.ns)); extension.writeUInt32LE(intern(node.name), 4)
    extension.writeUInt16LE(20, 8); extension.writeUInt16LE(20, 10); extension.writeUInt16LE(node.attrs.length, 12)
    const attrs = node.attrs.map(item => {
      const bytes = Buffer.alloc(20)
      bytes.writeUInt32LE(intern(item.ns)); bytes.writeUInt32LE(intern(item.name), 4)
      bytes.writeUInt32LE(item.raw === undefined ? NONE : intern(item.raw), 8)
      bytes.writeUInt16LE(8, 12); bytes[15] = item.type
      bytes.writeUInt32LE(item.type === 3 ? intern(item.value) : typeof item.value === 'boolean'
        ? item.value ? NONE : 0 : item.value >>> 0, 16)
      return bytes
    })
    parts.push(chunk(0x102, xmlHeader, Buffer.concat([extension, ...attrs])))
    node.children.forEach(write)
    parts.push(chunk(0x103, xmlHeader, uints(intern(node.ns), intern(node.name))))
  }
  write(root)
  for (const [prefix, uri] of [...namespaces].reverse()) parts.push(chunk(0x101, xmlHeader, uints(intern(prefix), intern(uri))))
  return chunk(3, Buffer.alloc(0), Buffer.concat(parts))
}
function parts(bytes) {
  const result = []
  for (let at = 8; at < bytes.length; at += bytes.readUInt32LE(at + 4)) {
    result.push({ at, type: bytes.readUInt16LE(at), size: bytes.readUInt32LE(at + 4) })
  }
  return result
}
function change(original, modify) { const result = Buffer.from(original); modify(result); return result }
const malformed = bytes => assert.throws(() => parseApkManifest(bytes), { code: 'apk-manifest/malformed' })

test('UTF-8 manifest reports versions, SDK, permissions, component declarations and application flags', () => {
  const bytes = binary(manifest([
    element('uses-sdk', [attr('minSdkVersion', 28), attr('targetSdkVersion', 36)]),
    element('uses-permission', [attr('name', 'android.permission.INTERNET')]),
    element('uses-permission-sdk-23', [attr('name', 'android.permission.CAMERA'), attr('maxSdkVersion', 32)]),
    element('permission', [attr('name', 'org.example.fixture.PRIVATE'), attr('protectionLevel', 2, 0x11)]),
    element('application', [attr('name', '.Application'), attr('debuggable', false), attr('allowBackup', true),
      attr('usesCleartextTraffic', false), attr('extractNativeLibs', false)], [
      element('activity', [attr('name', '.Main'), attr('exported', true)], [element('intent-filter')]),
      element('service', [attr('name', 'Worker'), attr('exported', false), attr('isolatedProcess', true)]),
      element('receiver', [attr('name', 'com.other.Receiver')]),
      element('activity-alias', [attr('name', '.Shortcut'), attr('targetActivity', '.Main')]),
      element('provider', [attr('name', '.Provider'), attr('authorities', 'org.example.fixture.files'),
        attr('readPermission', 'read.permission'), attr('grantUriPermissions', true)]),
    ]),
  ]), { resourceMap: { name: 16842755, exported: 16842768, debuggable: 16842767 } })
  const result = parseApkManifest(bytes)
  assert.equal(result.status, 'parsed'); assert.equal(result.package, 'org.example.fixture')
  assert.deepEqual(result.version, { code: 42, codeMajor: null, name: '1.2' })
  assert.deepEqual(result.sdk, { min: 28, target: 36, max: null })
  assert.equal(result.permissionCount, 3); assert.equal(result.permissions[1].maxSdkVersion, 32)
  assert.equal(result.permissions[2].protectionLevel, 2)
  assert.equal(result.application.flags.debuggable, false); assert.equal(result.application.flags.allowBackup, true)
  assert.equal(result.application.flags.testOnly, null)
  assert.equal(result.componentCount, 5); assert.equal(result.components[0].intentFilterCount, 1)
  assert.equal(result.components[0].qualifiedName, 'org.example.fixture.Main')
  assert.equal(result.components[1].qualifiedName, 'org.example.fixture.Worker')
  assert.deepEqual(result.components[1].exported, { value: false, source: 'explicit', declaration: false })
  assert.deepEqual(result.components[2].exported, { value: null, source: 'not-declared', declaration: null })
  assert.equal(result.components[3].targetActivity, '.Main'); assert.equal(result.components[4].grantUriPermissions, true)
  assert.match(result.evidence, /packing have not been verified/)
})

test('UTF-16, UTF-8 extended lengths, non-BMP strings and sliced byte views retain exact text', () => {
  for (const utf8 of [true, false]) {
    const label = '应用📦'.repeat(50)
    const bytes = binary(manifest([element('application', [attr('label', label)])]), { utf8 })
    const padded = Buffer.concat([Buffer.from([7, 8, 9]), bytes, Buffer.from([10])])
    const before = Buffer.from(padded)
    const result = parseApkManifest(new Uint8Array(padded.buffer, padded.byteOffset + 3, bytes.length))
    assert.equal(result.application.label, label); assert.deepEqual(padded, before)
  }
  const result = parseApkManifest(binary(manifest([element('application', [attr('label', 'x'.repeat(33000))])]), { utf8: false }))
  assert.equal(result.status, 'partial'); assert.equal(result.application.label.kind, 'truncated-string')
  assert.equal(result.application.label.characters, 33000); assert.equal(result.application.label.preview.length, 2048)
})

test('resource references and complex values remain unresolved; absent exported never becomes a default', () => {
  const result = parseApkManifest(binary(manifest([element('application', [attr('label', 0x7f010001, 1),
    attr('debuggable', 0x7f020001, 1), attr('networkSecurityConfig', 0x7f030001, 7)], [
    element('activity', [attr('name', '.Ref'), attr('exported', 0x7f020002, 1)]),
    element('provider', [attr('name', '.Absent')]),
    element('service', [attr('name', '.Bad'), attr('exported', 'perhaps')]),
  ])])))
  assert.equal(result.status, 'partial')
  assert.deepEqual(result.application.flags.debuggable, { kind: 'resource-reference', id: '0x7f020001', referenceType: 'resource' })
  assert.equal(result.application.networkSecurityConfig.referenceType, 'dynamic-resource')
  assert.equal(result.components[0].exported.source, 'unresolved')
  assert.equal(result.components[1].exported.source, 'not-declared')
  assert.equal(result.components[2].exported.declaration.kind, 'invalid-boolean')
})

test('foreign namespaces and nested lookalike declarations cannot become Android attributes or components', () => {
  const result = parseApkManifest(binary(manifest([
    element('queries', [], [element('application', [], [element('activity', [attr('name', '.Fake')])])]),
    element('application', [attr('debuggable', true, 0x12, 'urn:foreign')], [
      element('activity', [attr('name', '.Real'), attr('exported', true, 0x12, 'urn:foreign')]),
      element('activity', [attr('name', '.Foreign')], [], 'urn:foreign'),
    ]),
  ]), { additionalNamespaces: [['other', 'urn:foreign']] }))
  assert.equal(result.componentCount, 1); assert.equal(result.application.flags.debuggable, null)
  assert.equal(result.components[0].exported.source, 'not-declared')
})

test('component and permission pagination is independent and reports remaining rows', () => {
  const result = parseApkManifest(binary(manifest([
    ...Array.from({ length: 5 }, (_, i) => element('uses-permission', [attr('name', `permission.${i}`)])),
    element('application', [], Array.from({ length: 4 }, (_, i) => element('activity', [attr('name', `.A${i}`)]))),
  ])), { componentOffset: 1, componentLimit: 2, permissionOffset: 3, permissionLimit: 2 })
  assert.deepEqual(result.components.map(item => item.name), ['.A1', '.A2'])
  assert.equal(result.nextComponentOffset, 3); assert.equal(result.nextPermissionOffset, null)
  assert.deepEqual(result.permissions.map(item => item.name), ['permission.3', 'permission.4'])
  assert.throws(() => parseApkManifest(Buffer.alloc(0), { componentLimit: 101 }), { code: 'apk-manifest/invalid-arguments' })
})

test('duplicate declarations, duplicate attributes and mapped framework identity mismatches are refused', () => {
  malformed(binary(manifest([element('application'), element('application')])))
  malformed(binary(manifest([element('uses-sdk'), element('uses-sdk')])))
  malformed(binary(manifest([element('application', [attr('debuggable', true), attr('debuggable', false)])])))
  malformed(binary(manifest([element('application', [attr('debuggable', true)])]), { resourceMap: { debuggable: 16842768 } }))
  malformed(binary(manifest([element('application', [attr('fake', true)])]), { resourceMap: { fake: 16842767 } }))
})

test('document, chunk and attribute-array bounds are checked before reads', () => {
  const bytes = binary(manifest([])), start = parts(bytes).find(item => item.type === 0x102).at
  malformed(change(bytes, value => value.writeUInt32LE(value.length + 4, 4)))
  malformed(change(bytes, value => value.writeUInt32LE(0, 12)))
  malformed(change(bytes, value => value.writeUInt16LE(4, 10)))
  malformed(change(bytes, value => value.writeUInt16LE(0, start + 16 + 10)))
  malformed(change(bytes, value => value.writeUInt16LE(65535, start + 16 + 8)))
  malformed(change(bytes, value => value.writeUInt16LE(4, start + 16 + 20 + 12)))
  for (let length = 8; length < bytes.length; length++) malformed(bytes.subarray(0, length))
})

test('string offsets, terminators, UTF-8 encoding and indices cannot escape pool bounds', () => {
  const bytes = binary(manifest([])), pool = 8
  const data = pool + bytes.readUInt32LE(pool + 20)
  malformed(change(bytes, value => value.writeUInt32LE(NONE, pool + 28)))
  malformed(change(bytes, value => { value[data + 1] = 127 }))
  malformed(change(bytes, value => { value[data + 2] = 0xff }))
  malformed(change(bytes, value => { value[data + 2 + 'android'.length] = 1 }))
  const start = parts(bytes).find(item => item.type === 0x102).at
  malformed(change(bytes, value => value.writeUInt32LE(NONE - 1, start + 20)))
  malformed(change(bytes, value => value.writeUInt32LE(NONE - 1, start + 16 + 20 + 16)))
  const wide = binary(manifest([]), { utf8: false }), wideData = pool + wide.readUInt32LE(pool + 20)
  malformed(change(wide, value => value.writeUInt16LE(0xd800, wideData + 2)))
})

test('namespace and element stacks reject incomplete or mismatched closures', () => {
  const bytes = binary(manifest([element('application')])), all = parts(bytes)
  const end = all.find(item => item.type === 0x103).at
  malformed(change(bytes, value => value.writeUInt32LE(0, end + 20)))
  const namespace = all.find(item => item.type === 0x101).at
  malformed(change(bytes, value => value.writeUInt32LE(0, namespace + 20)))
  const withoutClosure = bytes.subarray(0, namespace)
  malformed(change(withoutClosure, value => value.writeUInt32LE(value.length, 4)))
  const noNamespace = binary(manifest([element('application', [attr('label', 'x', 3, 'urn:undeclared')])]))
  malformed(noNamespace)
})

test('unsupported XML encodings and chunks are explicit and do not contain guessed declarations', () => {
  for (const input of [Buffer.from('<manifest package="example"/>'), Buffer.from([0x0a, 0x01, 0x01]), Buffer.alloc(0)]) {
    const result = parseApkManifest(input)
    assert.equal(result.status, 'unsupported'); assert.equal(result.package, undefined)
  }
  const bytes = binary(manifest([])), start = parts(bytes).find(item => item.type === 0x102).at
  const unknown = parseApkManifest(change(bytes, value => value.writeUInt16LE(0x177, start)))
  assert.equal(unknown.status, 'unsupported'); assert.match(unknown.reason, /chunk/)
})

test('input, string count and nesting limits stop oversized manifests', () => {
  assert.throws(() => parseApkManifest(Buffer.alloc(APK_MANIFEST_MAX_BYTES + 1)), { code: 'apk-manifest/limit-exceeded' })
  const bytes = binary(manifest([]))
  assert.throws(() => parseApkManifest(change(bytes, value => value.writeUInt32LE(65537, 16))), { code: 'apk-manifest/limit-exceeded' })
  let deep = element('leaf')
  for (let i = 0; i < 130; i++) deep = element('nested', [], [deep])
  assert.throws(() => parseApkManifest(binary(manifest([deep]))), { code: 'apk-manifest/limit-exceeded' })
})

test('official aapt2 output agrees with its xmltree dump without sharing the synthetic encoder', () => {
  const fixture = JSON.parse(readFileSync(new URL('./fixtures/apk-manifest-aapt2.json', import.meta.url), 'utf8'))
  const bytes = Buffer.from(fixture.base64, 'base64')
  assert.equal(createHash('sha256').update(bytes).digest('hex'), fixture.sha256)
  assert.match(fixture.generator, /Android Asset Packaging Tool/)
  const result = parseApkManifest(bytes)
  assert.equal(result.status, 'parsed'); assert.equal(result.package, 'org.example.apkparser')
  assert.deepEqual(result.version, { code: 17, codeMajor: null, name: '2.3' })
  assert.deepEqual(result.sdk, { min: 28, target: 36, max: null })
  assert.equal(result.application.label, '样例📦')
  assert.equal(result.application.flags.debuggable, false); assert.equal(result.application.flags.allowBackup, true)
  assert.equal(result.application.flags.extractNativeLibs, false); assert.equal(result.application.flags.usesCleartextTraffic, false)
  assert.equal(result.componentCount, 4); assert.equal(result.permissionCount, 2)
  assert.deepEqual(result.components.map(row => row.exported.value), [true, false, null, false])
  assert.equal(result.components[1].isolatedProcess, true); assert.equal(result.components[3].grantUriPermissions, true)
  assert.match(fixture.xmltree, /versionCode\(0x0101021b\)=17/)
  assert.match(fixture.xmltree, /label\(0x01010001\)="样例📦"/)
})

test('bounded deterministic mutations return declarations, unsupported results, or coded validation errors', () => {
  const fixture = JSON.parse(readFileSync(new URL('./fixtures/apk-manifest-aapt2.json', import.meta.url), 'utf8'))
  const original = Buffer.from(fixture.base64, 'base64')
  let state = 0x3415926
  const random = () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state }
  for (let i = 0; i < 1500; i++) {
    const bytes = Buffer.from(original)
    bytes[random() % bytes.length] ^= 1 << (random() % 8)
    try { assert.ok(['parsed', 'partial', 'unsupported'].includes(parseApkManifest(bytes).status)) }
    catch (error) { assert.ok(['apk-manifest/malformed', 'apk-manifest/limit-exceeded'].includes(error.code), String(error)) }
  }
})
