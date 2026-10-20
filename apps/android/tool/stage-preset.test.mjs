import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { load, dump, Type, DEFAULT_SCHEMA } from 'js-yaml'
import { stagePreset } from './stage-preset.mjs'

const root = resolve(import.meta.dirname, '../../..')
const standardPath = 'packages/bundle/web-app/presets/standard.patch.yml'
const androidPath = 'apps/android/runtime/cordis.patch.yml'
class JsExpression {
  constructor(source) { this.source = source }
}
const schema = DEFAULT_SCHEMA.extend(new Type('tag:yaml.org,2002:js', {
  kind: 'scalar',
  construct: source => new JsExpression(source),
  instanceOf: JsExpression,
  represent: value => value.source,
}))
const readPatch = async path => load(await readFile(path, 'utf8'), { schema })
const plugins = (patch, id) => patch.flatMap(row => row.insert ?? [])
  .find(entry => entry.id === id).config.plugins
const delegationIds = [
  'tool-subagent-control', 'tool-subagent-list-agents', 'tool-subagent', 'tool-subagent-fork',
]

async function fixture(t) {
  const base = resolve(tmpdir())
  const directory = await mkdtemp(join(base, 'pocket-preset-'))
  t.after(async () => {
    assert.equal(dirname(resolve(directory)), base)
    assert.ok(basename(directory).startsWith('pocket-preset-'))
    await rm(directory, { recursive: true, force: true })
  })
  const source = await readPatch(join(root, standardPath))
  const target = await readPatch(join(root, androidPath))
  const destination = join(directory, 'staged')
  await mkdir(destination)
  return {
    directory, source, target, destination,
    async save() {
      for (const [path, patch] of [[standardPath, source], [androidPath, target]]) {
        const fullPath = join(directory, path)
        await mkdir(dirname(fullPath), { recursive: true })
        await writeFile(fullPath, dump(patch, { schema, noRefs: true, lineWidth: -1 }))
      }
    },
  }
}

test('Android stages original local delegation without enabling PTC or changing its command groups', async t => {
  const world = await fixture(t)
  await stagePreset(root, world.destination)
  const staged = await readPatch(join(world.destination, 'cordis.patch.yml'))
  const original = plugins(world.source, 'preset-standard')
  const android = plugins(staged, 'preset-android')
  const upstream = original.find(entry => entry.id === 'delegation')
  const delegated = android.find(entry => entry.id === 'delegation')
  assert.ok(delegated, 'Android agents must receive the original delegation tools')
  assert.deepEqual(delegated, {
    ...upstream,
    config: upstream.config.filter(entry => delegationIds.includes(entry.id)),
  })
  assert.deepEqual(delegated.config.map(entry => entry.id), delegationIds)
  assert.deepEqual(delegated.config.find(entry => entry.id === 'tool-subagent').config,
    { provider: 'spawn', toolName: 'subagent', modelSelectionSettings: true })
  assert.deepEqual(delegated.config.find(entry => entry.id === 'tool-subagent-fork').config,
    { provider: 'fork', toolName: 'subagent_fork' })
  assert.equal(staged.find(entry => entry.id === 'ptc-runtime').disabled, true)
  assert.equal(delegated.config.some(entry => entry.id.startsWith('workflow')
    || entry.id === 'tool-workflow'), false)
  for (const id of ['command-goal', 'tool-goal', 'planning', 'compaction', 'tool-schedule']) {
    assert.deepEqual(android.find(entry => entry.id === id), original.find(entry => entry.id === id))
  }
  assert.deepEqual(staged.find(entry => entry.id === 'sandbox-policy'),
    world.target.find(entry => entry.id === 'sandbox-policy'), '!!js expressions must survive staging')
  assert.equal(staged.find(entry => entry.id === 'approval').config.policy, 'ask')
})

for (const kind of ['missing', 'duplicate']) {
  test(`a ${kind} original delegation tool rejects staging without replacing the current patch`, async t => {
    const world = await fixture(t)
    const delegation = plugins(world.source, 'preset-standard').find(entry => entry.id === 'delegation')
    if (kind === 'missing') {
      delegation.config = delegation.config.filter(entry => entry.id !== 'tool-subagent-fork')
    } else {
      delegation.config.push(delegation.config.find(entry => entry.id === 'tool-subagent-fork'))
    }
    await world.save()
    const output = join(world.destination, 'cordis.patch.yml')
    await writeFile(output, '# previously staged profile\n')
    await assert.rejects(stagePreset(world.directory, world.destination), /tool-subagent-fork/)
    assert.equal(await readFile(output, 'utf8'), '# previously staged profile\n')
  })
}

for (const kind of ['missing', 'duplicate']) {
  test(`a ${kind} original delegation group rejects staging`, async t => {
    const world = await fixture(t)
    const standard = plugins(world.source, 'preset-standard')
    const index = standard.findIndex(entry => entry.id === 'delegation')
    if (kind === 'missing') standard.splice(index, 1)
    else standard.push(standard[index])
    await world.save()
    await assert.rejects(stagePreset(world.directory, world.destination), /exactly one delegation group/)
  })
}

test('an Android delegation override rejects staging instead of registering tools twice', async t => {
  const world = await fixture(t)
  plugins(world.target, 'preset-android').push({ id: 'delegation', name: 'cordis:group', group: true, config: [] })
  await world.save()
  await assert.rejects(stagePreset(world.directory, world.destination), /Android preset overrides original delegation/)
})
