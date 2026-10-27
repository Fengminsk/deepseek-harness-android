// Android binary XML layout: AOSP androidfw/ResourceTypes.h (ResXMLTree and ResStringPool).
// This module accepts one already-authorized, bounded entry; it never opens a path or executes code.
export const APK_MANIFEST_MAX_BYTES = 4 * 1024 * 1024
const NO_INDEX = 0xffffffff
const ANDROID = 'http://schemas.android.com/apk/res/android'
const LIMITS = { strings: 65536, decodedUnits: 4 * 1024 * 1024, stringUnits: 65536,
  chunks: 50000, nodes: 20000, depth: 128, attributes: 1024, totalAttributes: 65536 }
const frameworkAttributes = new Map(Object.entries({
  allowBackup: 16843392, authorities: 16842776, debuggable: 16842767, directBootAware: 16844037,
  enabled: 16842766, exported: 16842768, extractNativeLibs: 16844010, grantUriPermissions: 16842779,
  hasCode: 16842764, isolatedProcess: 16843689, label: 16842753, maxSdkVersion: 16843377,
  minSdkVersion: 16843276, name: 16842755, networkSecurityConfig: 16844071, permission: 16842758,
  persistent: 16842765, process: 16842769, protectionLevel: 16842761, readPermission: 16842759,
  requestLegacyExternalStorage: 16844291, supportsRtl: 16843695, targetActivity: 16843266,
  targetSdkVersion: 16843376, testOnly: 16843378, usesCleartextTraffic: 16844012,
  usesPermissionFlags: 16844356, versionCode: 16843291, versionCodeMajor: 16844150,
  versionName: 16843292, writePermission: 16842760,
}))
const frameworkNames = new Map([...frameworkAttributes].map(([name, id]) => [id, name]))
const componentKinds = new Set(['activity', 'activity-alias', 'service', 'receiver', 'provider'])
const permissionKinds = new Set(['uses-permission', 'uses-permission-sdk-23', 'uses-permission-sdk-m', 'permission'])
const appBooleanFields = ['debuggable', 'allowBackup', 'usesCleartextTraffic', 'extractNativeLibs',
  'testOnly', 'persistent', 'directBootAware', 'enabled', 'hasCode', 'supportsRtl', 'requestLegacyExternalStorage']

function fail(code, message) {
  const error = new Error(`APK Manifest ${message}`)
  error.code = `apk-manifest/${code}`
  throw error
}
function malformed(message) { fail('malformed', message) }
function bounded(condition, message) { if (!condition) fail('limit-exceeded', message) }
function hex(value) { return `0x${value.toString(16).padStart(8, '0')}` }
function page(value, fallback, min, max) {
  const result = value ?? fallback
  if (!Number.isSafeInteger(result) || result < min || result > max) fail('invalid-arguments', 'page is invalid')
  return result
}

/** Decode declarations without resource resolution or Android installation/default-policy evaluation.
 * @param {Buffer|Uint8Array} input The complete, already-verified AndroidManifest.xml entry, up to 4 MiB.
 * @param {object} options Independent component and permission pagination, each limited to 100 rows.
 * @returns {object} Parsed declarations or an explicit unsupported-format result. Malformed input throws a coded error.
 */
export function parseApkManifest(input, options = {}) {
  if (!(input instanceof Uint8Array)) fail('invalid-arguments', 'input must be bytes')
  bounded(input.byteLength <= APK_MANIFEST_MAX_BYTES, 'exceeds 4 MiB')
  const componentOffset = page(options.componentOffset, 0, 0, Number.MAX_SAFE_INTEGER)
  const componentLimit = page(options.componentLimit, 100, 1, 100)
  const permissionOffset = page(options.permissionOffset, 0, 0, Number.MAX_SAFE_INTEGER)
  const permissionLimit = page(options.permissionLimit, 100, 1, 100)
  const bytes = Buffer.from(input.buffer, input.byteOffset, input.byteLength)
  const warnings = new Set()
  const evidence = 'Manifest declarations only. Resource references, platform defaults, runtime reachability, APK signatures and packing have not been verified.'
  const unsupported = reason => ({ format: 'unknown', status: 'unsupported', reason, warnings: [], evidence })
  if (bytes.length < 8 || bytes.readUInt16LE(0) !== 3) return unsupported('Not Android binary XML; plain XML and protobuf manifests are not parsed')
  function chunk(at, end) {
    if (at + 8 > end) malformed('truncated chunk header')
    const type = bytes.readUInt16LE(at), header = bytes.readUInt16LE(at + 2), size = bytes.readUInt32LE(at + 4)
    if (header < 8 || size < header || size % 4 || at + size > end) malformed('invalid chunk bounds')
    return { at, type, header, size, end: at + size, extension: at + header }
  }
  const document = chunk(0, bytes.length)
  if (document.header !== 8 || document.size !== bytes.length) malformed('invalid document bounds')
  let strings, resources, poolSeen = false, resourceMapSeen = false, rootSeen = false, rootClosed = false
  let chunks = 0, nodes = 0, attributes = 0, decodedUnits = 0
  const stack = [], namespaces = [], components = [], permissions = []
  const summary = { package: null, version: { code: null, codeMajor: null, name: null },
    sdk: { min: null, target: null, max: null }, application: null }
  let usesSdkSeen = false

  function string(index, optional = false) {
    if (optional && index === NO_INDEX) return null
    if (!strings || index >= strings.length) malformed('string index is outside its pool')
    return strings[index]
  }
  function pool(part) {
    if (poolSeen || rootSeen || part.header < 28) malformed('unexpected string pool')
    poolSeen = true
    const count = bytes.readUInt32LE(part.at + 8), styles = bytes.readUInt32LE(part.at + 12)
    const flags = bytes.readUInt32LE(part.at + 16), start = bytes.readUInt32LE(part.at + 20)
    const styleStart = bytes.readUInt32LE(part.at + 24)
    bounded(count <= LIMITS.strings, 'string pool has too many strings')
    if (styles > count || part.header + (count + styles) * 4 > start || start > part.size
      || (styleStart && (styleStart < start || styleStart > part.size)) || Boolean(styles) !== Boolean(styleStart)) {
      malformed('invalid string pool bounds')
    }
    if (styles) return false
    if (flags & ~257) warnings.add('unknown-string-pool-flags')
    const end = part.at + (styleStart || part.size), cache = new Map(), result = []
    const utf8 = Boolean(flags & 256)
    function length(at, wide) {
      if (at + (wide ? 2 : 1) > end) malformed('truncated string length')
      const first = wide ? bytes.readUInt16LE(at) : bytes[at], unit = wide ? 2 : 1
      if (!(first & (wide ? 0x8000 : 0x80))) return [first, at + unit]
      if (at + unit * 2 > end) malformed('truncated extended string length')
      return [wide ? (first & 0x7fff) * 65536 + bytes.readUInt16LE(at + 2)
        : (first & 0x7f) * 256 + bytes[at + 1], at + unit * 2]
    }
    for (let index = 0; index < count; index++) {
      const offset = bytes.readUInt32LE(part.at + part.header + index * 4)
      if (offset >= end - part.at - start) malformed('string offset is outside pool data')
      if (cache.has(offset)) { result.push(cache.get(offset)); continue }
      let [units, at] = length(part.at + start + offset, !utf8), encoded = units * 2
      bounded(units <= LIMITS.stringUnits && decodedUnits + units <= LIMITS.decodedUnits, 'decoded string limit exceeded')
      if (utf8) [encoded, at] = length(at, false)
      const terminator = utf8 ? 1 : 2
      if (at + encoded + terminator > end || (utf8 ? bytes[at + encoded] : bytes.readUInt16LE(at + encoded))) {
        malformed('string length or terminator is invalid')
      }
      let text
      try { text = new TextDecoder(utf8 ? 'utf-8' : 'utf-16le', { fatal: true, ignoreBOM: true }).decode(bytes.subarray(at, at + encoded)) }
      catch { malformed('invalid string encoding') }
      if (text.length !== units || text.includes('\0')) malformed('string length or embedded null is invalid')
      decodedUnits += units
      cache.set(offset, text); result.push(text)
    }
    strings = result
    return true
  }
  function typed(at) {
    if (bytes.readUInt16LE(at) !== 8 || bytes[at + 2] !== 0) malformed('invalid typed-value header')
    const type = bytes[at + 3], data = bytes.readUInt32LE(at + 4)
    if (type === 3) return string(data)
    if (type === 0x10) return bytes.readInt32LE(at + 4)
    if (type === 0x11) return data
    if (type === 0x12) return data !== 0
    if ([1, 2, 7, 8].includes(type)) return { kind: 'resource-reference', id: hex(data),
      referenceType: ({ 1: 'resource', 2: 'attribute', 7: 'dynamic-resource', 8: 'dynamic-attribute' })[type] }
    return { kind: 'typed-value', type: hex(type), data: hex(data) }
  }
  function visible(value) {
    if (typeof value === 'string' && value.length > 2048) {
      warnings.add('projected-string-truncated')
      return { kind: 'truncated-string', characters: value.length, preview: value.slice(0, 2048) }
    }
    if (value && typeof value === 'object') warnings.add('unresolved-attribute-values')
    return value
  }
  function field(attrs, name, boolean = false, namespace = ANDROID) {
    const attribute = attrs.get(`${namespace ?? ''}\0${name}`)
    if (!attribute) return null
    const value = visible(attribute.value)
    if (!boolean || typeof value === 'boolean' || (value && typeof value === 'object')) return value
    if (typeof value === 'number') return value !== 0
    if (value === 'true' || value === 'false') return value === 'true'
    warnings.add('unresolved-attribute-values')
    return { kind: 'invalid-boolean', value }
  }
  function declaredExport(attrs) {
    const value = field(attrs, 'exported', true)
    return { value: typeof value === 'boolean' ? value : null,
      source: value === null ? 'not-declared' : typeof value === 'boolean' ? 'explicit' : 'unresolved', declaration: value }
  }
  function qualified(name) {
    if (typeof name !== 'string' || typeof summary.package !== 'string') return null
    return name.startsWith('.') ? summary.package + name : name.includes('.') ? name : `${summary.package}.${name}`
  }
  function project(element) {
    const parent = stack.at(-1), attrs = element.attrs
    if (!parent) {
      if (rootSeen || element.ns !== null || element.name !== 'manifest') malformed('expected one manifest root')
      rootSeen = true
      summary.package = field(attrs, 'package', false, null)
      summary.version = { code: field(attrs, 'versionCode'), codeMajor: field(attrs, 'versionCodeMajor'), name: field(attrs, 'versionName') }
      if (typeof summary.package !== 'string' || !summary.package) warnings.add('missing-or-unresolved-package')
      return
    }
    if (element.ns !== null) return
    if (parent.name === 'manifest' && parent.ns === null && stack.length === 1) {
      if (element.name === 'uses-sdk') {
        if (usesSdkSeen) malformed('duplicate uses-sdk declaration')
        usesSdkSeen = true
        summary.sdk = { min: field(attrs, 'minSdkVersion'), target: field(attrs, 'targetSdkVersion'), max: field(attrs, 'maxSdkVersion') }
      } else if (element.name === 'application') {
        if (summary.application) malformed('duplicate application declaration')
        summary.application = { name: field(attrs, 'name'), label: field(attrs, 'label'),
          permission: field(attrs, 'permission'), process: field(attrs, 'process'),
          networkSecurityConfig: field(attrs, 'networkSecurityConfig'),
          flags: Object.fromEntries(appBooleanFields.map(name => [name, field(attrs, name, true)])) }
        element.application = true
      } else if (permissionKinds.has(element.name)) {
        permissions.push({ kind: element.name, name: field(attrs, 'name'), maxSdkVersion: field(attrs, 'maxSdkVersion'),
          usesPermissionFlags: field(attrs, 'usesPermissionFlags'), protectionLevel: field(attrs, 'protectionLevel') })
      }
    }
    if (parent.application && componentKinds.has(element.name)) {
      const name = field(attrs, 'name')
      element.component = { type: element.name, name, qualifiedName: qualified(name),
        exported: declaredExport(attrs), enabled: field(attrs, 'enabled', true), permission: field(attrs, 'permission'),
        process: field(attrs, 'process'), directBootAware: field(attrs, 'directBootAware', true), intentFilterCount: 0 }
      if (element.name === 'activity-alias') element.component.targetActivity = field(attrs, 'targetActivity')
      if (element.name === 'service') element.component.isolatedProcess = field(attrs, 'isolatedProcess', true)
      if (element.name === 'provider') Object.assign(element.component, { authorities: field(attrs, 'authorities'),
        readPermission: field(attrs, 'readPermission'), writePermission: field(attrs, 'writePermission'),
        grantUriPermissions: field(attrs, 'grantUriPermissions', true) })
      components.push(element.component)
    } else if (parent.component && element.name === 'intent-filter') parent.component.intentFilterCount++
  }
  for (let at = document.header; at < document.end;) {
    bounded(++chunks <= LIMITS.chunks, 'chunk count exceeded')
    const part = chunk(at, document.end)
    at = part.end
    if (part.type === 1) {
      if (!pool(part)) return unsupported('Styled binary XML string pools are not supported')
      continue
    }
    if (!strings) malformed('XML nodes precede string pool')
    if (part.type === 0x180) {
      if (rootSeen || resourceMapSeen || part.header !== 8 || (part.size - 8) / 4 > strings.length) malformed('invalid resource map')
      resourceMapSeen = true
      resources = Array.from({ length: (part.size - 8) / 4 }, (_, i) => bytes.readUInt32LE(part.at + 8 + i * 4))
      continue
    }
    if (![0x100, 0x101, 0x102, 0x103, 0x104].includes(part.type)) return unsupported(`Unknown binary XML chunk ${hex(part.type)}`)
    if (part.header < 16) malformed('truncated XML node header')
    string(bytes.readUInt32LE(part.at + 12), true)
    const ext = part.extension
    if (part.type === 0x100 || part.type === 0x101) {
      if (ext + 8 > part.end) malformed('truncated namespace')
      const prefix = string(bytes.readUInt32LE(ext), true), uri = string(bytes.readUInt32LE(ext + 4))
      if (part.type === 0x100) {
        if (rootClosed) malformed('namespace starts after the root')
        bounded(namespaces.length < LIMITS.depth, 'namespace depth exceeded')
        namespaces.push({ prefix, uri, depth: stack.length })
      } else {
        const current = namespaces.pop()
        if (!current || current.prefix !== prefix || current.uri !== uri || current.depth !== stack.length) malformed('namespace closure mismatch')
      }
      continue
    }
    if (part.type === 0x104) {
      if (!stack.length || ext + 12 > part.end) malformed('invalid character-data node')
      const text = string(bytes.readUInt32LE(ext)); typed(ext + 4)
      if (text.trim()) warnings.add('non-whitespace-character-data')
      continue
    }
    if (ext + 8 > part.end) malformed('truncated element')
    const ns = string(bytes.readUInt32LE(ext), true), name = string(bytes.readUInt32LE(ext + 4))
    if (!name || name.length > 1024) malformed('invalid element name')
    if (ns !== null && !namespaces.some(item => item.uri === ns)) malformed('undeclared element namespace')
    if (part.type === 0x103) {
      const open = stack.pop()
      if (!open || open.name !== name || open.ns !== ns) malformed('element closure mismatch')
      if (!stack.length) rootClosed = true
      continue
    }
    if (rootClosed || ext + 20 > part.end) malformed('invalid element start')
    bounded(++nodes <= LIMITS.nodes && stack.length < LIMITS.depth, 'element count or depth exceeded')
    const start = bytes.readUInt16LE(ext + 8), stride = bytes.readUInt16LE(ext + 10), count = bytes.readUInt16LE(ext + 12)
    bounded(count <= LIMITS.attributes && attributes + count <= LIMITS.totalAttributes, 'attribute limit exceeded')
    attributes += count
    if (start < 20 || stride < 20 || ext + start + stride * count > part.end
      || [14, 16, 18].some(offset => bytes.readUInt16LE(ext + offset) > count)) malformed('invalid attribute array')
    if (stride !== 20 || start !== 20 || part.header !== 16) warnings.add('extended-xml-node-layout')
    const attrs = new Map()
    for (let index = 0; index < count; index++) {
      const attr = ext + start + index * stride, nameIndex = bytes.readUInt32LE(attr + 4)
      const namespace = string(bytes.readUInt32LE(attr), true), attributeName = string(nameIndex)
      if (!attributeName || attributeName.length > 1024) malformed('invalid attribute name')
      if (namespace !== null && !namespaces.some(item => item.uri === namespace)) malformed('undeclared attribute namespace')
      const raw = string(bytes.readUInt32LE(attr + 8), true), value = typed(attr + 12)
      const resource = resources?.[nameIndex] ?? 0
      if (resource && ((namespace === ANDROID && frameworkAttributes.has(attributeName)
        && frameworkAttributes.get(attributeName) !== resource) || (frameworkNames.has(resource)
        && (namespace !== ANDROID || frameworkNames.get(resource) !== attributeName)))) malformed('attribute resource identity mismatch')
      const key = `${namespace ?? ''}\0${attributeName}`
      if (attrs.has(key)) malformed('duplicate attribute')
      if (raw !== null && typeof value === 'string' && raw !== value) warnings.add('raw-and-typed-string-differ')
      attrs.set(key, { value })
    }
    const element = { ns, name, attrs }
    project(element)
    // Only projected declarations and the open stack are retained; no generic XML tree is built.
    element.attrs = undefined
    stack.push(element)
  }
  if (!rootSeen || !rootClosed || stack.length || namespaces.length) malformed('incomplete XML document')
  return { format: 'android-binary-xml', status: warnings.size ? 'partial' : 'parsed', ...summary,
    componentCount: components.length, components: components.slice(componentOffset, componentOffset + componentLimit),
    nextComponentOffset: componentOffset + componentLimit < components.length ? componentOffset + componentLimit : null,
    permissionCount: permissions.length, permissions: permissions.slice(permissionOffset, permissionOffset + permissionLimit),
    nextPermissionOffset: permissionOffset + permissionLimit < permissions.length ? permissionOffset + permissionLimit : null,
    warnings: [...warnings].sort(), evidence }
}
