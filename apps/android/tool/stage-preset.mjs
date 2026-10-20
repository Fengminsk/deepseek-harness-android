/** Compose portable command groups from the shipped preset without forking their policy text. */
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { load, dump, Type, DEFAULT_SCHEMA } from 'js-yaml'

class JsExpression {
  constructor(source) { this.source = source }
}
const schema = DEFAULT_SCHEMA.extend(new Type('tag:yaml.org,2002:js', {
  kind: 'scalar',
  construct: source => new JsExpression(source),
  instanceOf: JsExpression,
  represent: expression => expression.source,
}))

/** Stage the Android preset with the original goal, planning, and compaction plugins. */
export async function stagePreset(root, destination) {
  const source = load(await readFile(join(root,
    'packages/bundle/web-app/presets/standard.patch.yml'), 'utf8'), { schema })
  const target = load(await readFile(join(root,
    'apps/android/runtime/cordis.patch.yml'), 'utf8'), { schema })
  const pluginsFor = (document, id) => {
    if (!Array.isArray(document)) throw new Error('Preset patch must be a sequence')
    const entry = document.flatMap(row => row.insert ?? []).find(item => item.id === id)
    if (Array.isArray(entry?.config?.plugins)) return entry.config.plugins
    throw new Error(`Missing preset ${id}`)
  }
  const original = pluginsFor(source, 'preset-standard')
  const android = pluginsFor(target, 'preset-android')
  for (const id of ['command-goal', 'tool-goal', 'planning', 'compaction']) {
    const entry = original.find(item => item.id === id)
    if (!entry) throw new Error(`Original preset is missing ${id}`)
    if (android.some(item => item.id === id)) {
      throw new Error(`Android preset overrides original ${id}`)
    }
    android.push(entry)
  }
  await writeFile(join(destination, 'cordis.patch.yml'),
    '# Generated with original standard preset command groups by stage-preset.mjs.\n'
    + dump(target, { schema, noRefs: true, lineWidth: -1 }))
}
