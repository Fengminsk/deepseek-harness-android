/**
 * Real Loader, tool pipeline, ApprovalService and Session audit regression.
 * Only the OS child process is substituted: these tests do not prove Android UID
 * enforcement or notification delivery. Run after staging the DSH runtime:
 * node --test apps/android/tool/tool-android-shell.test.mjs
 */
import assert from 'node:assert/strict'
import test from 'node:test'
import childProcess from 'node:child_process'
import { EventEmitter } from 'node:events'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { createRequire, registerHooks, syncBuiltinESMExports } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import { pathToFileURL } from 'node:url'

const staged = new URL('../../../.cache/android/runtime-bundle/package.json', import.meta.url)
const requireStaged = createRequire(staged)
const toolSource = new URL('../runtime/tool-android-shell.mjs', import.meta.url)
const resolver = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (context.parentURL === toolSource.href && specifier === '@deepseek-ai/dsh-tools') {
      return { url: pathToFileURL(requireStaged.resolve(specifier)).href, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
})
const load = specifier => import(pathToFileURL(requireStaged.resolve(specifier)).href)
const [
  { boot },
  { default: SystemPrompt },
  { default: ToolRuntime, defineTool },
  { default: ApprovalService, setApprovalPolicy },
  { Session, SessionId },
  { registerAndroidShell },
] = await Promise.all([
  load('@deepseek-ai/dsh-app-boot'),
  load('@deepseek-ai/dsh-system-prompt'),
  load('@deepseek-ai/dsh-tools'),
  load('@deepseek-ai/dsh-user-approval'),
  load('@deepseek-ai/dsh-session'),
  import(toolSource.href),
])
resolver.deregister()

async function fixture(t, { approval = true, policy = 'ask', timeoutMs = 60000 } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'android-shell-approval-'))
  const configPath = join(directory, 'cordis.yml')
  const rows = [
    { id: 'prompt', name: 'cordis:prompt' },
    { id: 'tools', name: 'cordis:tools' },
    ...(approval ? [{ id: 'approval', name: 'cordis:approval', config: { policy } }] : []),
    { id: 'android-shell', name: 'cordis:android-shell' },
  ]
  await writeFile(configPath, JSON.stringify(rows))
  const spawned = []
  const started = Promise.withResolvers()
  const spawn = t.mock.method(childProcess, 'spawn', (file, args, options) => {
    const child = new EventEmitter()
    child.pid = 982321
    child.stdout = new PassThrough()
    child.stderr = new PassThrough()
    child.finish = (code = 0, signal = null) => {
      child.stdout.end()
      child.stderr.end()
      child.emit('close', code, signal)
    }
    child.kill = signal => { queueMicrotask(() => child.finish(null, signal)); return true }
    spawned.push({ file, args, options, child })
    started.resolve(child)
    return child
  })
  const kill = t.mock.method(process, 'kill', (pid, signal) => {
    const child = spawned.find(row => row.child.pid === -pid)?.child
    assert.ok(child, 'only the fixture child process group may be terminated')
    queueMicrotask(() => child.finish(null, signal))
    return true
  })
  syncBuiltinESMExports()
  let ctx
  t.after(async () => {
    for (const { child } of spawned) child.finish()
    await ctx?.fiber.dispose()
    spawn.mock.restore()
    kill.mock.restore()
    syncBuiltinESMExports()
    await rm(directory, { recursive: true, force: true })
  })
  ctx = await boot('android-shell-test', configPath, [], (context) => {
    context.loader.builtins.prompt = SystemPrompt
    context.loader.builtins.tools = ToolRuntime
    context.loader.builtins.approval = ApprovalService
    context.loader.builtins['android-shell'] = {
      name: 'android-shell-test',
      inject: ['tools'],
      apply(scope) {
        registerAndroidShell(scope, {
          shellTimeoutMs: { get: () => timeoutMs },
          shellOutputLimit: { get: () => 4096 },
        })
      },
    }
  })
  const session = Session.create(SessionId('android-shell-fixture'))
  session.append('turn/start', { turn: 1 })
  // The approval service reads this Agent's real Session; no model is involved.
  const agent = { session }
  let serial = 0
  const execute = (signal = new AbortController().signal, extra = {}) => ctx.tools.execute({
    name: 'android_shell', callId: `shell-${++serial}`, arguments: { command: 'printf approved' },
    agent, signal, ...extra,
  })
  const outcomes = () => session.snapshotEvents().filter(event => event.type === 'approval/decided')
    .map(event => event.data.outcome)
  return { ctx, session, agent, execute, spawned, outcomes, kill, started: started.promise }
}

test('real Loader tool waits for one-shot approval and records the exact call identity', async t => {
  const f = await fixture(t)
  const asked = Promise.withResolvers(), answer = Promise.withResolvers()
  f.ctx.on('approval/request', request => { asked.resolve(request); return answer.promise })
  const running = f.execute()
  const request = await asked.promise
  assert.equal(request.toolName, 'android_shell')
  assert.equal(request.callId, 'shell-1')
  assert.match(request.displayReason.zh, /不构成文件访问沙箱/)
  assert.equal(f.spawned.length, 0)
  answer.resolve('allowed-once')
  // A named process-start observation avoids sleep-based authorization checks.
  const child = await f.started
  child.stdout.write('approved')
  child.finish()
  const result = await running
  assert.equal(result.isError, false)
  assert.equal(f.spawned.length, 1)
  assert.deepEqual(f.spawned[0].args, ['-c', 'printf approved'])
  assert.deepEqual(f.outcomes(), ['allowed-once'])
  assert.equal(f.session.snapshotEvents().find(event => event.type === 'approval/asked').data.callId, 'shell-1')
})

for (const outcome of ['rejected', 'cancelled', 'unavailable']) {
  test(`original ${outcome} outcome never starts the command`, async t => {
    const f = await fixture(t)
    f.ctx.on('approval/request', () => Promise.resolve(outcome))
    assert.equal((await f.execute()).isError, true)
    assert.equal(f.spawned.length, 0)
    assert.deepEqual(f.outcomes(), [outcome])
  })
}

test('never policy rejects without contacting an answerer', async t => {
  const f = await fixture(t, { policy: 'never' })
  let prompts = 0
  f.ctx.on('approval/request', () => { prompts++; return Promise.resolve('allowed-once') })
  assert.equal((await f.execute()).isError, true)
  assert.equal(prompts, 0)
  assert.equal(f.spawned.length, 0)
  assert.deepEqual(f.outcomes(), ['rejected'])
})

test('per-session never policy remains authoritative over the deployment ask default', async t => {
  const f = await fixture(t)
  setApprovalPolicy(f.session, 'never')
  let prompts = 0
  f.ctx.on('approval/request', () => { prompts++; return Promise.resolve('allowed-once') })
  assert.equal((await f.execute()).isError, true)
  assert.equal(prompts, 0)
  assert.equal(f.spawned.length, 0)
})

for (const approval of [true, false]) {
  test(`missing ${approval ? 'answerer' : 'ApprovalService'} fails closed`, async t => {
    const f = await fixture(t, { approval })
    assert.equal((await f.execute()).isError, true)
    assert.equal(f.spawned.length, 0)
    assert.deepEqual(f.outcomes(), approval ? ['unavailable'] : [])
  })
}

test('caller cancellation while waiting discards a late allowed-once response', async t => {
  const f = await fixture(t)
  const asked = Promise.withResolvers(), answer = Promise.withResolvers()
  f.ctx.on('approval/request', () => { asked.resolve(); return answer.promise })
  const controller = new AbortController()
  const running = f.execute(controller.signal)
  await asked.promise
  controller.abort()
  answer.resolve('allowed-once')
  assert.equal((await running).isError, true)
  assert.equal(f.spawned.length, 0)
  assert.deepEqual(f.outcomes(), ['cancelled'])
})

test('already cancelled calls never ask or start a process', async t => {
  const f = await fixture(t)
  let prompts = 0
  f.ctx.on('approval/request', () => { prompts++; return Promise.resolve('allowed-once') })
  assert.equal((await f.execute(AbortSignal.abort())).isError, true)
  assert.equal(prompts, 0)
  assert.equal(f.spawned.length, 0)
})

test('downstream denial is preserved and cannot be changed into an approval', async t => {
  const f = await fixture(t)
  f.ctx.on('tools/pre-execute', () => Promise.resolve({ kind: 'deny', reason: 'original policy denial' }))
  let prompts = 0
  f.ctx.on('approval/request', () => { prompts++; return Promise.resolve('allowed-once') })
  const result = await f.execute()
  assert.match(result.error.message, /original policy denial/)
  assert.equal(prompts, 0)
  assert.equal(f.spawned.length, 0)
})

test('agent-less execution cannot skip the original routing and audit requirement', async t => {
  const f = await fixture(t)
  let prompts = 0
  f.ctx.on('approval/request', () => { prompts++; return Promise.resolve('allowed-once') })
  assert.equal((await f.execute(undefined, { agent: undefined })).isError, true)
  assert.equal(prompts, 0)
  assert.equal(f.spawned.length, 0)
})

test('approved process timeout terminates its group and reports timeout separately', async t => {
  const f = await fixture(t, { timeoutMs: 1 })
  f.ctx.on('approval/request', () => Promise.resolve('allowed-once'))
  const result = await f.execute()
  const value = JSON.parse(result.content[0].text)
  assert.equal(f.spawned.length, 1)
  assert.equal(value.timedOut, true)
  assert.equal(value.cancelled, false)
  assert.equal(f.kill.mock.callCount(), 1)
})

test('each invocation requires a new decision and does not reuse an earlier grant', async t => {
  const f = await fixture(t)
  let prompts = 0
  f.ctx.on('approval/request', () => {
    prompts++
    return Promise.resolve(prompts === 1 ? 'allowed-once' : 'rejected')
  })
  const first = f.execute()
  ;(await f.started).finish()
  assert.equal((await first).isError, false)
  assert.equal((await f.execute()).isError, true)
  assert.equal(prompts, 2)
  assert.equal(f.spawned.length, 1)
  assert.deepEqual(f.outcomes(), ['allowed-once', 'rejected'])
})

test('an existing ask is not duplicated and its original audit reason is retained', async t => {
  const f = await fixture(t)
  f.ctx.on('tools/pre-execute', () => Promise.resolve({ kind: 'ask', reason: 'original hook needs approval' }))
  let prompts = 0
  f.ctx.on('approval/request', request => {
    prompts++
    assert.equal(request.reason, 'original hook needs approval')
    return Promise.resolve('rejected')
  })
  assert.equal((await f.execute()).isError, true)
  assert.equal(prompts, 1)
  assert.equal(f.spawned.length, 0)
})

test('other tools keep their original execution policy', async t => {
  const f = await fixture(t)
  f.ctx.tools.register(defineTool({
    name: 'fixture_read', description: 'fixture',
    parameters: {},
    output: { schema: { type: 'json' }, render: () => [{ type: 'text', text: 'read' }] },
    async execute() { return { read: true } },
  }))
  let prompts = 0
  f.ctx.on('approval/request', () => { prompts++; return Promise.resolve('rejected') })
  const result = await f.execute(undefined, { name: 'fixture_read', arguments: {} })
  assert.equal(result.isError, false)
  assert.equal(prompts, 0)
  assert.equal(f.spawned.length, 0)
})

test('cancellation at the audit commit of an allowed answer still prevents spawning', async t => {
  const f = await fixture(t)
  const controller = new AbortController()
  const originalAppend = f.session.append.bind(f.session)
  t.mock.method(f.session, 'append', (type, data) => {
    const event = originalAppend(type, data)
    if (type === 'approval/decided') controller.abort()
    return event
  })
  f.ctx.on('approval/request', () => Promise.resolve('allowed-once'))
  assert.equal((await f.execute(controller.signal)).isError, true)
  assert.equal(f.spawned.length, 0)
  assert.deepEqual(f.outcomes(), ['allowed-once'])
})

test('cancellation after approval terminates the running command', async t => {
  const f = await fixture(t)
  const controller = new AbortController()
  f.ctx.on('approval/request', () => Promise.resolve('allowed-once'))
  const running = f.execute(controller.signal)
  await f.started
  controller.abort()
  assert.equal((await running).isError, true)
  assert.equal(f.spawned.length, 1)
  assert.equal(f.kill.mock.callCount(), 1)
})

test('disposing the owning plugin removes both the tool and its request rule', async t => {
  const f = await fixture(t)
  const entry = [...f.ctx.loader.entries()].find(item => item.options.id === 'android-shell')
  assert.ok(entry)
  await entry.fiber.dispose()
  assert.equal(f.ctx.tools.get('android_shell'), undefined)
  let prompts = 0
  f.ctx.on('approval/request', () => { prompts++; return Promise.resolve('rejected') })
  f.ctx.tools.register(defineTool({
    name: 'android_shell', description: 'replacement probe',
    parameters: {},
    output: { schema: { type: 'json' }, render: () => [{ type: 'text', text: 'replacement' }] },
    async execute() { return { replacement: true } },
  }))
  assert.equal((await f.execute(undefined, { arguments: {} })).isError, false)
  assert.equal(prompts, 0)
})
