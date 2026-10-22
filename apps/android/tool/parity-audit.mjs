/** Check the Android migration inventory against shipped DSH declarations. */
import { readFile, realpath, stat } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { isAbsolute, relative, resolve, sep } from 'node:path'
import { pathToFileURL } from 'node:url'
import { DEFAULT_SCHEMA, Type, load } from 'js-yaml'

const paths = {
  webUi: 'packages/bundle/web-app/cordis.patch.yml',
  standardPreset: 'packages/bundle/web-app/presets/standard.patch.yml',
  androidDisabled: 'apps/android/runtime/cordis.patch.yml',
}
const kinds = ['webUi', 'standardPreset', 'standardDelegation', 'androidDisabled']
const levels = ['core', 'ui', 'behavior', 'device']
const states = new Set(['unverified', 'partial', 'verified', 'not-applicable'])
const statuses = new Set(['not-migrated', 'partial', 'adapted', 'upstream-disabled'])
const manifestPath = 'apps/android/tool/parity-manifest.json'

// Configuration expressions are retained as data. Auditing must never evaluate them.
class InertExpression {
  constructor(source) { this.source = source }
}
const schema = DEFAULT_SCHEMA.extend(new Type('tag:yaml.org,2002:js', {
  kind: 'scalar',
  construct: source => new InertExpression(source),
}))

/**
 * Parse a Cordis patch without executing its JavaScript expressions.
 * @param source - YAML source to inspect.
 * @returns the patch rows, with expressions represented as inert objects.
 */
export function parseParityPatch(source) {
  const patch = load(source, { schema })
  if (!Array.isArray(patch)) throw new Error('A parity source patch must be a sequence')
  return patch
}

const inserted = patch => patch.flatMap(row => row.insert ?? [])

function canonical(value) {
  if (value instanceof InertExpression) return ['expression', value.source]
  if (value === null) return null
  if (Array.isArray(value)) return ['array', value.map(canonical)]
  if (value instanceof Date) return ['timestamp', value.toISOString()]
  if (value instanceof Uint8Array) return ['bytes', Array.from(value)]
  if (typeof value === 'object') {
    return ['object', Object.keys(value).sort().map(key => [key, canonical(value[key])])]
  }
  if (typeof value === 'number') return ['number', Object.is(value, -0) ? '-0' : String(value)]
  if (typeof value === 'string' || typeof value === 'boolean') return value
  throw new Error(`Unsupported YAML value in parity source: ${typeof value}`)
}

const digest = row => createHash('sha256').update(JSON.stringify(canonical(row))).digest('hex')

/**
 * Enumerate each declaration that the Android migration ledger must address.
 * @param patches - parsed web, standard preset, and Android patches.
 * @returns stable inventory keys and their source declarations.
 */
export function collectParityInventory(patches) {
  const presets = inserted(patches.standardPreset).filter(row => row.id === 'preset-standard')
  if (presets.length !== 1 || !Array.isArray(presets[0].config?.plugins)) {
    throw new Error('Expected exactly one standard preset with plugins')
  }
  const standard = presets[0].config.plugins
  const delegations = standard.filter(row => row.id === 'delegation')
  if (delegations.length !== 1 || !Array.isArray(delegations[0].config)) {
    throw new Error('Expected exactly one standard delegation group')
  }
  const rows = {
    webUi: inserted(patches.webUi).filter(row => row.id?.startsWith('ui-')),
    standardPreset: standard,
    standardDelegation: delegations[0].config,
    androidDisabled: patches.androidDisabled.filter(row => row.disabled === true
      || row.disabled instanceof InertExpression),
  }
  const inventory = []
  const seen = new Set()
  for (const kind of kinds) {
    for (const row of rows[kind]) {
      if (typeof row.id !== 'string' || !/^[a-z][a-z0-9-]*$/u.test(row.id)) {
        throw new Error(`Invalid source declaration id in ${kind}`)
      }
      const key = `${kind}/${row.id}`
      if (seen.has(key)) throw new Error(`Duplicate source declaration: ${key}`)
      seen.add(key)
      inventory.push({
        key, kind, id: row.id,
        plugin: row.name ?? null,
        source: paths[kind === 'standardDelegation' ? 'standardPreset' : kind],
        sourceDigest: digest(row),
      })
    }
  }
  return inventory
}

function relativeFile(path) {
  return typeof path === 'string' && path.length > 0 && !isAbsolute(path)
    && !/^[a-z]:/iu.test(path) && !path.includes('\\')
    && path.split('/').every(part => part !== '' && part !== '.' && part !== '..')
}

/**
 * Validate explicit migration claims and all referenced repository files.
 * A passing audit confirms ledger coverage, never feature completion or test success.
 * @param root - repository root used to resolve references.
 * @param manifest - parsed migration ledger.
 * @param inventory - current source declarations.
 * @returns errors and counts; evidence states are never inferred from file existence.
 */
export async function validateParityManifest(root, manifest, inventory) {
  const errors = []
  if (manifest?.version !== 1) errors.push('Unsupported parity manifest version')
  if (!Array.isArray(manifest?.entries)) {
    return { ok: false, errors: [...errors, 'Manifest entries must be an array'], counts: {} }
  }
  const expected = new Map(inventory.map(row => [row.key, row]))
  const seen = new Set()
  const refs = new Map()
  const counts = Object.fromEntries(kinds.map(kind => [kind, 0]))
  const evidence = Object.fromEntries(levels.map(level => [level,
    Object.fromEntries([...states].map(state => [state, 0]))]))
  const register = (path, owner) => {
    if (!relativeFile(path)) {
      errors.push(`${owner}: reference must be a repository-relative file: ${String(path)}`)
    } else {
      const owners = refs.get(path) ?? []
      owners.push(owner)
      refs.set(path, owners)
    }
  }
  for (const entry of manifest.entries) {
    if (!entry || typeof entry.key !== 'string') {
      errors.push('Manifest entry is missing a stable key')
      continue
    }
    const key = entry.key
    if (seen.has(key)) errors.push(`Duplicate manifest entry: ${key}`)
    seen.add(key)
    const source = expected.get(key)
    if (!source) errors.push(`Stale or unknown manifest entry: ${key}`)
    else {
      counts[source.kind]++
      if (entry.plugin !== source.plugin) errors.push(`${key}: source plugin changed; review its mapping`)
      if (entry.sourceDigest !== source.sourceDigest) {
        errors.push(`${key}: source declaration changed; review sourceDigest and migration evidence`)
      }
      if (!Array.isArray(entry.sources) || !entry.sources.includes(source.source)) {
        errors.push(`${key}: source declaration reference is required`)
      }
    }
    if (!statuses.has(entry.status)) errors.push(`${key}: invalid migration status ${entry.status}`)
    if (typeof entry.note !== 'string' || entry.note.trim().length === 0) errors.push(`${key}: explanatory note is required`)
    for (const field of ['sources', 'android']) {
      if (!Array.isArray(entry[field]) || (field === 'sources' && entry[field].length === 0)) {
        errors.push(`${key}: ${field} must be a${field === 'sources' ? ' nonempty' : 'n'} array`)
      } else {
        for (const path of entry[field]) register(path, `${key}.${field}`)
      }
    }
    if (['partial', 'adapted'].includes(entry.status) && entry.android?.length === 0) {
      errors.push(`${key}: ${entry.status} mapping requires Android source references`)
    }
    for (const level of levels) {
      const state = entry.evidence?.[level]
      if (!states.has(state)) errors.push(`${key}: invalid ${level} evidence state ${state}`)
      else evidence[level][state]++
      const citations = entry.evidenceRefs?.[level] ?? []
      if (!Array.isArray(citations)) errors.push(`${key}: ${level} evidence references must be an array`)
      else {
        if (state === 'verified' && citations.length === 0) errors.push(`${key}: verified ${level} needs evidence references`)
        for (const path of citations) register(path, `${key}.${level}`)
      }
      const reason = entry.notApplicable?.[level]
      if (state === 'not-applicable' && (typeof reason !== 'string' || reason.trim().length === 0)) {
        errors.push(`${key}: ${level} not-applicable needs a reason`)
      }
    }
    for (const field of ['evidence', 'evidenceRefs', 'notApplicable']) {
      if (entry[field] != null && (typeof entry[field] !== 'object' || Array.isArray(entry[field]))) {
        errors.push(`${key}: ${field} must be an object`)
      } else {
        for (const level of Object.keys(entry[field] ?? {})) {
          if (!levels.includes(level)) errors.push(`${key}: unknown evidence level ${level}`)
        }
      }
    }
  }
  for (const key of expected.keys()) {
    if (!seen.has(key)) errors.push(`Unmapped source declaration: ${key}`)
  }
  const actualRoot = await realpath(root)
  for (const [path, owners] of refs) {
    try {
      const actual = await realpath(resolve(root, path))
      const distance = relative(actualRoot, actual)
      if (distance === '..' || distance.startsWith(`..${sep}`) || isAbsolute(distance)
        || !(await stat(actual)).isFile()) {
        errors.push(`${owners[0]}: reference is not a file inside the repository: ${path}`)
      }
    } catch (error) {
      errors.push(`${owners[0]}: reference unavailable: ${path} (${error.code ?? error.message})`)
    }
  }
  return { ok: errors.length === 0, errors, counts, evidence }
}

/**
 * Read the current repository declarations and check the migration ledger.
 * @param root - repository root; defaults to this tool's repository.
 * @returns audit diagnostics without modifying sources or the ledger.
 */
export async function auditParity(root = resolve(import.meta.dirname, '../../..')) {
  const patches = Object.fromEntries(await Promise.all(Object.entries(paths).map(async ([kind, path]) =>
    [kind, parseParityPatch(await readFile(resolve(root, path), 'utf8'))])))
  const manifest = JSON.parse(await readFile(resolve(root, manifestPath), 'utf8'))
  return validateParityManifest(root, manifest, collectParityInventory(patches))
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const result = await auditParity()
    if (!result.ok) {
      for (const error of result.errors) console.error(error)
      process.exitCode = 1
    } else {
      console.log(`Parity ledger covers ${Object.values(result.counts).reduce((sum, count) => sum + count, 0)} declarations.`)
      console.log(JSON.stringify({ counts: result.counts, evidence: result.evidence }))
      console.log('Coverage is not completion. Unverified and partial migration claims remain open.')
    }
  } catch (error) {
    console.error(`Parity audit failed: ${error.message}`)
    process.exitCode = 1
  }
}
