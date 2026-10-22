/** Compose portable tools and command groups from the shipped preset without forking their policy. */
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

/** Stage original context, job controls, skills, command groups and local delegation. */
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
  // The shared host supplies jobs, skills, fs, workingDirectory and sessionProjections.
  // These entries retain the standard provider settings and scoped ownership;
  // Android's separate tool-fs write/edit policy is not changed here.
  for (const id of ['agent-instructions', 'time-context', 'tool-jobs',
    'skill-filesystem', 'tool-skill', 'tool-todo', 'present',
    'command-goal', 'tool-goal', 'planning', 'compaction', 'tool-schedule']) {
    const entries = original.filter(item => item.id === id)
    if (entries.length !== 1) throw new Error(`Original preset must contain exactly one ${id}`)
    if (android.some(item => item.id === id)) {
      throw new Error(`Android preset overrides original ${id}`)
    }
    android.push(entries[0])
  }
  if (android.some(item => item.id === 'delegation')) {
    throw new Error('Android preset overrides original delegation')
  }
  const groups = original.filter(item => item.id === 'delegation')
  if (groups.length !== 1 || !Array.isArray(groups[0].config)) {
    throw new Error('Original preset must declare exactly one delegation group')
  }
  const delegation = groups[0]
  // The in-process spawn/fork providers already belong to the shared host.
  // Select their original tools, retaining configuration and group isolation;
  // workflow-ptc/tool-workflow require the disabled Android PTC runtime.
  const tools = ['tool-subagent-control', 'tool-subagent-list-agents', 'tool-subagent', 'tool-subagent-fork']
    .map(id => {
      const entries = delegation.config.filter(item => item.id === id)
      if (entries.length !== 1) throw new Error(`Original delegation must contain exactly one ${id}`)
      return entries[0]
    })
  android.push({ ...delegation, config: tools })
  await writeFile(join(destination, 'cordis.patch.yml'),
    '# Generated with original standard preset portable tools, command groups and local delegation by stage-preset.mjs.\n'
    + dump(target, { schema, noRefs: true, lineWidth: -1 }))
}
