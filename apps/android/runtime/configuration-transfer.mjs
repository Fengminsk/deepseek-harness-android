import Schema from '@deepseek-ai/schemastery'
import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'

const FORMAT = 'pocket-harness-settings'
const MAX_BYTES = 1048576
const MAX_FIELDS = 4096
const MAX_PLANS = 8
const unsafeKeys = new Set(['__proto__', 'prototype', 'constructor'])
const deviceFields = new Set(['cwd', 'apiKeyEnv'])
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const own = (value, key) => object(value) && Object.hasOwn(value, key)
const clone = value => structuredClone(value)

function exact(value, keys, where) {
  if (!object(value) || Object.keys(value).some(key => !keys.includes(key))) {
    throw new TypeError(`${where}包含未知字段或不是对象`)
  }
}

function safeJson(value, depth = 0) {
  if (depth > 40) throw new TypeError('配置嵌套超过 40 层')
  if (object(value) || Array.isArray(value)) {
    for (const [key, child] of Object.entries(value)) {
      if (unsafeKeys.has(key)) throw new TypeError('配置含不允许的字段名')
      safeJson(child, depth + 1)
    }
  } else if (!['string', 'number', 'boolean'].includes(typeof value) && value !== null) {
    throw new TypeError('配置只接受 JSON 数据')
  }
}

function branches(node) {
  if (node?.type === 'transform') return branches(node.inner)
  if (node?.type === 'intersect' || node?.type === 'union') return node.list.flatMap(branches)
  return node ? [node] : []
}

function containsSecret(node, visited = new Set()) {
  if (!node || visited.has(node)) return false
  if (node.meta?.role === 'secret') return true
  const seen = new Set(visited).add(node)
  return [...Object.values(node.dict ?? {}), node.inner, ...(node.list ?? [])]
    .some(child => containsSecret(child, seen))
}

function atNodes(nodes, path) {
  for (const key of path) {
    nodes = nodes.flatMap(node => branches(node).flatMap(branch =>
      branch.type === 'object' ? (Object.hasOwn(branch.dict ?? {}, key) ? [branch.dict[key]] : [])
        : branch.type === 'dict' ? [branch.inner] : []))
  }
  return nodes
}

function valueAt(value, path) {
  for (const key of path) {
    if (!own(value, key)) return undefined
    value = value[key]
  }
  return value
}

/** Reject unknown nested keys instead of relying on Schemastery's permissive object handling. */
function knownValue(nodes, value) {
  const flat = nodes.flatMap(branches)
  if (flat.length === 0 || flat.some(node => node.type === 'any')) return false
  if (Array.isArray(value)) {
    const arrays = flat.filter(node => node.type === 'array')
    return arrays.length > 0 && value.every(item => knownValue(arrays.map(node => node.inner), item))
  }
  if (object(value)) {
    return Object.entries(value).every(([key, child]) => {
      const children = flat.flatMap(node => node.type === 'dict' ? [node.inner]
        : node.type === 'object' && Object.hasOwn(node.dict ?? {}, key) ? [node.dict[key]] : [])
      return knownValue(children, child)
    })
  }
  return true
}

function restriction(schema, path, nodes) {
  if (path.some(key => deviceFields.has(key))) return '设备路径或凭据引用须在目标设备单独设置'
  for (let size = 0; size <= path.length; size++) {
    if (atNodes([schema], path.slice(0, size)).some(node => node.meta?.role === 'secret')) {
      return '凭据须在专门入口设置，不参与导入导出'
    }
  }
  if (nodes.some(node => containsSecret(node))) return '包含凭据的容器保持原样，不参与导入导出'
  return null
}

function parse(text) {
  if (typeof text !== 'string' || Buffer.byteLength(text, 'utf8') > MAX_BYTES) {
    throw new TypeError('配置文件必须是最多 1 MiB 的 UTF-8 JSON')
  }
  let input
  try { input = JSON.parse(text) } catch (_failure) { throw new TypeError('文件不是有效 JSON，原输入已保留') }
  safeJson(input)
  exact(input, ['format', 'version', 'sections', 'excluded'], '文件')
  if (input.format !== FORMAT || input.version !== 1 || !Array.isArray(input.sections)) {
    throw new TypeError('只接受 Pocket Harness 运行设置格式第 1 版；此入口不接受 Cordis YAML')
  }
  if (input.excluded !== undefined && (!Array.isArray(input.excluded) || input.excluded.some(item => {
    exact(item, ['ns', 'path', 'reason'], '排除说明')
    return typeof item.reason !== 'string' || (item.ns !== undefined && typeof item.ns !== 'string')
      || (item.path !== undefined && (!Array.isArray(item.path) || item.path.some(key => typeof key !== 'string')))
  }))) throw new TypeError('排除说明格式无效')
  const namespaces = new Set()
  let fields = 0
  for (const section of input.sections) {
    exact(section, ['ns', 'fields'], '命名空间')
    if (typeof section.ns !== 'string' || !section.ns || namespaces.has(section.ns) || !Array.isArray(section.fields)) {
      throw new TypeError('命名空间必须唯一且包含 fields 数组')
    }
    namespaces.add(section.ns)
    const paths = []
    for (const field of section.fields) {
      exact(field, ['path', 'value'], '字段')
      if (!Array.isArray(field.path) || !field.path.length || field.path.some(key => typeof key !== 'string' || !key || unsafeKeys.has(key))
        || !own(field, 'value')) throw new TypeError('每个字段必须包含非空路径和 value')
      if (paths.some(path => {
        const size = Math.min(path.length, field.path.length)
        return path.slice(0, size).every((key, index) => key === field.path[index])
      })) throw new TypeError('字段路径重复或相互覆盖')
      paths.push(field.path)
      if (++fields > MAX_FIELDS) throw new TypeError('配置字段数量超过 4096')
    }
  }
  return input
}

/** Versioned ordinary-settings transfer. The original settings service owns every write. */
export class AppConfigurationTransfers {
  constructor(ctx, { protectedNamespaces = new Set() } = {}) {
    this.settings = ctx.settings
    this.protectedNamespaces = new Set(protectedNamespaces)
    this.plans = new Map()
    this.closed = false
  }

  available() {
    if (this.closed) throw new Error('运行设置迁移已关闭')
    return this.settings.describe({ redactSecrets: true })
  }

  /** Export only known ordinary values, with an explicit list of omitted fields. */
  export() {
    const sections = [], excluded = [
      { reason: '不包含账号与凭据、主题、插件安装/启停/拓扑、原始 Cordis 配置、会话、Web 开关和设备文件授权' },
    ]
    for (const descriptor of this.available()) {
      const ns = descriptor.ns
      if (this.protectedNamespaces.has(ns)) {
        excluded.push({ ns, reason: 'Android 运行组件及设备配置由专门入口管理' })
        continue
      }
      const schema = new Schema(descriptor.schema)
      const fields = []
      const walk = (value, path) => {
        const nodes = atNodes([schema], path)
        // Walk objects so a secret sibling does not prevent ordinary leaves transferring.
        if (object(value) && path.length < 40 && Object.keys(value).length) {
          if (nodes.some(node => node.meta?.role === 'secret')) {
            excluded.push({ ns, path, reason: '凭据须在专门入口管理' })
          } else for (const [key, child] of Object.entries(value)) walk(child, [...path, key])
          return
        }
        const reason = restriction(schema, path, nodes)
          ?? (!knownValue(nodes, value) ? '无法静态验证的字段，保留在原高级配置入口' : null)
        if (reason || !path.length) excluded.push({ ns, path, reason: reason ?? '空配置无需迁移' })
        else fields.push({ path, value: clone(value) })
      }
      walk(descriptor.value, [])
      for (const secret of descriptor.secrets ?? []) {
        if (!excluded.some(item => item.ns === ns && isDeepStrictEqual(item.path, secret.path))) {
          excluded.push({ ns, path: secret.path, reason: '凭据须在专门入口管理' })
        }
      }
      if (fields.length) sections.push({ ns, fields })
    }
    const text = JSON.stringify({ format: FORMAT, version: 1, sections, excluded }, null, 2)
    parse(text)
    return { text, sections, excluded }
  }

  /** Hold an immutable, validated plan. No write occurs while previewing. */
  preview({ text }) {
    const input = parse(text)
    const descriptors = this.available()
    if (this.plans.size >= MAX_PLANS) throw new Error('预览数量已达上限，请关闭旧预览后重试')
    const sections = [], issues = []
    for (const section of input.sections) {
      const descriptor = descriptors.find(item => item.ns === section.ns)
      if (!descriptor || this.protectedNamespaces.has(section.ns)) {
        issues.push({ ns: section.ns, reason: descriptor ? 'Android 运行组件由专门入口管理' : '本机不存在此可编辑命名空间；不会安装或启用插件' })
        continue
      }
      const schema = new Schema(descriptor.schema)
      const changes = [], fields = []
      for (const field of section.fields) {
        const nodes = atNodes([schema], field.path)
        let reason = restriction(schema, field.path, nodes)
        if (!reason && !knownValue(nodes, field.value)) reason = '未知字段或无法静态验证的值；请使用高级配置入口'
        if (!reason) {
          try {
            // Original Schemastery validators own accepted values, ranges and enums.
            if (!nodes.some(node => {
              try { node(clone(field.value)); return true } catch (_failure) { return false }
            })) reason = '值未通过本机原配置 schema 校验'
          } catch (_failure) { reason = '值未通过本机原配置 schema 校验' }
        }
        if (reason) { issues.push({ ns: section.ns, path: field.path, reason }); continue }
        fields.push(clone(field))
        const before = valueAt(descriptor.value, field.path)
        if (!isDeepStrictEqual(before, field.value)) {
          changes.push({ path: field.path, ...(before === undefined ? {} : { before: clone(before) }), after: clone(field.value) })
        }
      }
      sections.push({ ns: section.ns, revision: descriptor.revision, changes, fields, status: 'pending' })
    }
    const plan = { id: randomUUID(), sections, issues, excluded: input.excluded ?? [], busy: false }
    this.plans.set(plan.id, plan)
    return this.view(plan)
  }

  view(plan) {
    return clone({ id: plan.id, sections: plan.sections.map(({ fields: _fields, ...section }) => section),
      issues: plan.issues, excluded: plan.excluded, busy: plan.busy })
  }

  /** Acknowledged writes are never replayed. Stop on the first conflict or unknown outcome. */
  async apply({ id, namespaces }) {
    this.available()
    const plan = this.plans.get(id)
    if (!plan || plan.busy) throw new Error('预览不存在或正在应用，请重新预览')
    if (!Array.isArray(namespaces) || namespaces.length === 0 || new Set(namespaces).size !== namespaces.length
      || namespaces.some(ns => !plan.sections.some(section => section.ns === ns))) throw new TypeError('请选择预览中的命名空间')
    if (plan.issues.length) throw new Error('预览含未处理字段，请修正文件后重新预览；未写入任何设置')
    const selected = plan.sections.filter(section => namespaces.includes(section.ns))
    if (selected.some(section => section.status !== 'pending')) throw new Error('此预览已有执行结果，请核对结果后重新预览；不会自动重放')
    plan.busy = true
    try {
      for (const section of selected) {
        const descriptor = this.available().find(item => item.ns === section.ns)
        if (!descriptor || descriptor.revision !== section.revision) {
          section.status = 'conflict'
          section.message = '本机设置已变化，未覆盖。原文件和预览保留，请重新比较'
          break
        }
        if (!section.changes.length) { section.status = 'unchanged'; continue }
        const ops = section.changes.map(change => ({ op: 'set', path: change.path, value: change.after }))
        try {
          await this.settings.mutate(section.ns, ops, section.revision)
          section.status = 'applied'
        } catch (failure) {
          section.status = failure.code === 'SETTINGS_CONFLICT' ? 'conflict' : 'unknown'
          section.message = section.status === 'conflict'
            ? '原服务拒绝过期版本；原文件保留，请重新比较'
            : '写入结果未确认；已停止后续写入，请读取当前设置核对，不会自动重试'
          break
        }
      }
      plan.busy = false
      return this.view(plan)
    } finally { plan.busy = false }
  }

  /** Releasing a preview cannot cancel an original settings write already in flight. */
  release({ id }) {
    const plan = this.plans.get(id)
    if (plan?.busy) throw new Error('设置正在写入，请等待结果后关闭')
    this.plans.delete(id)
    return { released: true }
  }

  close() {
    this.closed = true
    this.plans.clear()
  }
}
