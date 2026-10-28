/** Default-off settings, per-session policy reads, and shared delegation registration. */

import { mountWorkingDirectoryFixture } from '../../subagent/tests/working-directory-fixture.ts'
import { describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import { assembleContextFor } from '@deepseek-ai/dsh-agent'
import SessionStore, { Session, SessionId } from '@deepseek-ai/dsh-session'
import { bindScopeParent, createScope, scopeOf } from '@deepseek-ai/dsh-scope'
import { liveConfig } from '../../../settings/settings/tests/live-config.ts'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import SubagentRuntime from '@deepseek-ai/dsh-subagent'
import * as SubagentSpawn from '@deepseek-ai/dsh-subagent-spawn-in-process'
import * as tool from '../src/index.ts'
import SubagentModelSelectionConfig from '../src/model-selection-settings.ts'
import {
  subagentModelSelectionPolicy,
  subagentModelSelectionProjectionDefinition,
} from '../src/model-selection-state.ts'
import { callSubagent } from './harness.ts'

const ALLOWED_MODELS = [{ provider: 'alpha', model: 'fast-model' }]

const selectionConfigs = new WeakMap<Context, Awaited<ReturnType<typeof liveConfig>>>()
const subagentConfigs = new WeakMap<Context, Awaited<ReturnType<typeof liveConfig>>>()
const modelSelectionPresets = new WeakMap<Context, ReturnType<typeof createScope>>()

/** Mount the real settings, Agent, provider, and optional preset tool services. */
async function boot(withPreset = true): Promise<Context> {
  const ctx = new Context()

  selectionConfigs.set(ctx, await liveConfig(ctx, SubagentModelSelectionConfig))
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(AgentLoop, { agents: [] })
  await mountWorkingDirectoryFixture(ctx)
  subagentConfigs.set(ctx, await liveConfig(ctx, SubagentRuntime))
  await ctx.plugin(SubagentSpawn, { providerName: 'spawn' })
  if (withPreset) {
    const preset = createScope(ctx, { preset: 'model-selection-test' })
    await preset.ctx.plugin(tool, {
      provider: 'spawn',
      modelSelection: true,
      modelDiscovery: true,
    })
    modelSelectionPresets.set(ctx, preset)
  }
  return ctx
}

/** Create one Agent joined to the test's preset scope. */
async function createAgent(ctx: Context, id: string) {
  const preset = modelSelectionPresets.get(ctx)
  if (preset === undefined) throw new Error('context has no model-selection preset')
  const handle = await ctx.agents.create({
    sessionId: SessionId(id),
    setup: (agentCtx) => {
      bindScopeParent(scopeOf(agentCtx)!, scopeOf(preset.ctx)!)
    },
  })
  return handle.agent
}

describe('SubagentModelSelectionConfig', () => {
  it('uses the composed default without a settings provider', async () => {
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(SessionProjectionRegistry)
    await ctx.plugin(SubagentModelSelectionConfig, { enabled: true, allowedModels: ALLOWED_MODELS })

    expect(ctx.subagentModelSelection.current()).toEqual({ enabled: true, allowedModels: ALLOWED_MODELS })
    await ctx.fiber.dispose()
  })

  it('defaults off and follows the validated user layer', async () => {
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(SessionProjectionRegistry)

    selectionConfigs.set(ctx, await liveConfig(ctx, SubagentModelSelectionConfig))

    expect(ctx.subagentModelSelection.current()).toEqual({ enabled: false, allowedModels: [] })
    await selectionConfigs.get(ctx)!.update({
      enabled: true,
      allowedModels: ALLOWED_MODELS,
    })
    expect(ctx.subagentModelSelection.current()).toEqual({ enabled: true, allowedModels: ALLOWED_MODELS })
    await ctx.fiber.dispose()
  })

  it('rejects duplicate routes, enabled empty settings, and an empty durable policy', async () => {
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(SessionProjectionRegistry)
    selectionConfigs.set(ctx, await liveConfig(ctx, SubagentModelSelectionConfig))
    const handle = await ctx.sessionProjections.register(subagentModelSelectionProjectionDefinition)

    // A stored policy the service cannot apply fails when it is read, not when the profile row is written.
    await selectionConfigs.get(ctx)!.update({ allowedModels: [...ALLOWED_MODELS, ...ALLOWED_MODELS] })
    expect(() => ctx.subagentModelSelection.current()).toThrow('repeats route "alpha/fast-model"')

    await selectionConfigs.get(ctx)!.update({ enabled: true, allowedModels: [] })
    expect(() => ctx.subagentModelSelection.current()).toThrow('enabled subagent model selection requires at least one allowed model')
    await selectionConfigs.get(ctx)!.update({
      enabled: false,
      allowedModels: ALLOWED_MODELS,
    })
    expect(ctx.subagentModelSelection.current()).toEqual({ enabled: false, allowedModels: ALLOWED_MODELS })
    await selectionConfigs.get(ctx)!.update({ allowedModels: [] })
    expect(ctx.subagentModelSelection.current()).toEqual({ enabled: false, allowedModels: [] })

    const invalid = Session.create(SessionId('empty-policy'))
    invalid.append('subagent/model-selection-policy', { allowedModels: [] })
    expect(() => subagentModelSelectionPolicy(handle, invalid)).toThrow('requires at least one route')

    const malformed = Session.create(SessionId('malformed-policy'))
    malformed.append('subagent/model-selection-policy', {
      allowedModels: [{ provider: 1, model: 'fast-model' }],
    } as never)
    expect(() => subagentModelSelectionPolicy(handle, malformed))
      .toThrow('requires non-empty provider and model ids')
    await ctx.fiber.dispose()
  })

  it('shares one delegation definition across Agents in the same preset scope', async () => {
    const ctx = await boot()
    try {
      const first = await createAgent(ctx, 'shared-preset-a')
      const second = await createAgent(ctx, 'shared-preset-b')
      const schema = ctx.tools.schemas(first).find(candidate => candidate.name === 'subagent')
      const properties = (schema?.parameters as { properties?: Record<string, unknown> } | undefined)?.properties
      expect(properties?.['provider']).toBeDefined()
      expect(properties?.['model']).toBeDefined()
      expect(properties?.['reasoning_effort']).toBeDefined()
      expect(ctx.tools.schemas(first)).toEqual(ctx.tools.schemas(second))
      expect(ctx.tools.schemas(first).some(candidate => candidate.name === 'list_subagent_models')).toBe(true)
    } finally {
      await ctx.fiber.dispose()
    }
  })

  it('reads the saved default depth at each delegation without remounting the tool', async () => {
    const ctx = await boot(false)
    const depths: Array<number | undefined> = []
    try {
      ctx.subagents.registerProvider({
        name: 'capture-depth',
        capabilities: { agentOptions: true, agentPreset: false, outputSchema: true, depthLimit: true },
        inheritsParentContext: false,
        start: async (request) => {
          depths.push(request.maxDepth)
          return { id: SessionId(`depth-${depths.length}`),
            result: Promise.resolve({ output: [], stopReason: 'completed' as const }), dispose: async () => {} }
        },
      })
      await ctx.plugin(tool, { provider: 'capture-depth' })
      const { agent } = await ctx.agents.create({ sessionId: SessionId('live-depth-context') })
      const initial = await ctx.systemPrompt.assemble(assembleContextFor(agent))
      expect(initial.contexts.find(part => part.name === 'tool:subagent:depth')?.text)
        .toBe('')
      await callSubagent(ctx, { description: 'first', prompt: 'work' })
      await subagentConfigs.get(ctx)!.update({ maxDepth: 5 })
      const updated = ctx.systemPrompt.refreshContext(initial, assembleContextFor(agent))
      expect(updated.contexts.find(part => part.name === 'tool:subagent:depth')?.text)
        .toBe('')
      await callSubagent(ctx, { description: 'second', prompt: 'work' })
      await subagentConfigs.get(ctx)!.update({ maxDepth: 0 })
      const disabled = ctx.systemPrompt.refreshContext(initial, assembleContextFor(agent))
      expect(disabled.contexts.find(part => part.name === 'tool:subagent:depth')?.text)
        .toBe('Delegation depth for `subagent`: current 0, maximum 0, remaining levels 0. Do not call `subagent` at this depth; carry out the work directly.')
      expect(disabled.sections).toEqual(initial.sections)
      expect(disabled.tools).toEqual(initial.tools)
      await subagentConfigs.get(ctx)!.update({ maxDepth: 2 })
      expect(ctx.systemPrompt.refreshContext(disabled, assembleContextFor(agent))
        .contexts.find(part => part.name === 'tool:subagent:depth')?.text).toBe('')
      await subagentConfigs.get(ctx)!.update({ maxDepth: 0 })
      await callSubagent(ctx, { description: 'disabled', prompt: 'work' })
      expect(depths).toEqual([1, 5, 0])
    } finally {
      await ctx.fiber.dispose()
    }
  })
})
