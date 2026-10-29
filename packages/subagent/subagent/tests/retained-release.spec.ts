import { describe, expect, it, onTestFinished, vi } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import type { CreateAgentOptions } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId } from '@deepseek-ai/dsh-session'
import SubagentRuntime from '../src/index.ts'
import { mountWorkingDirectoryFixture } from './working-directory-fixture.ts'
import { managerState, subagentManager } from './manager-internals.ts'

async function setup(disposeFailures = 1) {
  const ctx = new Context()
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(AgentLoop, { agents: [] })
  await mountWorkingDirectoryFixture(ctx)
  await ctx.plugin(SubagentRuntime)
  onTestFinished(() => ctx.fiber.dispose())
  ctx.subagents.registerProvider({
    name: 'local',
    capabilities: { agentOptions: true, agentPreset: true, outputSchema: true, depthLimit: true },
    inheritsParentContext: false,
    prepareContinuable: async () => ({}),
  })
  const parent = (await ctx.agents.create({ sessionId: SessionId('retained-parent') })).agent
  const childId = SessionId('retained-child')
  const spec = {
    provider: 'local', label: 'work', childId, delivery: 'caller' as const,
    signal: new AbortController().signal,
    request: { parent, prompt: [{ type: 'text' as const, text: 'work' }] },
  }
  const create = ctx.agents.create.bind(ctx.agents)
  let disposeAttempts = 0
  vi.spyOn(managerState(ctx).ownerCtx.agents, 'create').mockImplementation(async (options) => {
    // oxlint-disable-next-line typescript/no-unnecessary-type-assertion -- spy args are unknown; the cast restores the caller type.
    const handle = await create(options as CreateAgentOptions)
    if (handle.agent.id !== childId) return handle
    const realDispose = handle.dispose.bind(handle)
    vi.spyOn(handle, 'dispose').mockImplementation(async () => {
      disposeAttempts += 1
      if (disposeAttempts <= disposeFailures) throw new Error('temporary release failure')
      await realDispose()
    })
    return handle
  })
  return { ctx, parent, childId, spec, attempts: () => disposeAttempts }
}

describe('failed child release after materialization', () => {
  it('keeps an unpublished local child closed and owned until manager drain retries release', async () => {
    const { ctx, childId, spec, attempts } = await setup(2)
    const manager = subagentManager(ctx)
    vi.spyOn(manager['host'], 'observeActivation').mockReturnValue({
      start: () => { throw new Error('admission rejected') },
      settle: () => undefined,
    })
    await expect(ctx.subagents.startActivation(spec)).rejects.toThrow('admission rejected')
    expect(attempts()).toBe(1)
    expect(managerState(ctx).resident.has(childId)).toBe(true)
    expect(ctx.agents.get(childId)).toBeDefined()
    const pool = managerState(ctx).resident.get(childId)!.pool
    expect(() => pool.reserve(1)).toThrow('subagent limit reached')
    await expect(ctx.subagents.startActivation(spec)).rejects.toMatchObject({ code: 'DUPLICATE_CHILD' })
    await expect(manager.drain()).rejects.toThrow('temporary release failure')
    expect(attempts()).toBe(2)
    expect(managerState(ctx).resident.has(childId)).toBe(true)
    expect(() => pool.reserve(1)).toThrow('subagent limit reached')
    await manager.drain()
    expect(attempts()).toBe(3)
    expect(managerState(ctx).resident.has(childId)).toBe(false)
    expect(ctx.agents.get(childId)).toBeUndefined()
    pool.reserve(1)()
  })

  it('retains a child when catalog publication fails and its first disposal fails', async () => {
    const { ctx, parent, childId, spec, attempts } = await setup()
    const append = parent.session.append.bind(parent.session)
    vi.spyOn(parent.session, 'append').mockImplementation((...args) => {
      if (args[0] === 'subagent/catalog') throw new Error('catalog rejected')
      return Reflect.apply(append, parent.session, args) as ReturnType<typeof append>
    })
    await expect(ctx.subagents.startActivation(spec)).rejects.toThrow('catalog rejected')
    expect(attempts()).toBe(1)
    expect(managerState(ctx).resident.has(childId)).toBe(true)
    await expect(subagentManager(ctx).drain()).rejects.toThrow('temporary release failure')
    expect(attempts()).toBe(2)
    expect(managerState(ctx).resident.has(childId)).toBe(false)
    expect(ctx.agents.get(childId)).toBeUndefined()
  })
})
