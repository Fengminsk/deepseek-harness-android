import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'

const runId = '00000000-0000-4000-8000-000000000095'
const token = 'host-admission'
const snapshot = JSON.parse(readFileSync(new URL('./isolated-tool-call-journal.snapshot.json', import.meta.url), 'utf8'))
const prepared = { kind: 'script', runId, sessionId: runId, scope: {
  ownerId: 'host', sessionId: runId, version: 1, workspaceId: null,
  readablePaths: [], writablePaths: [], exactHosts: [], fileCallLimit: 0,
  networkCallLimit: 0, leaseMillis: 5000,
} }

function privateRoot(t) {
  const root = mkdtempSync(join(tmpdir(), 'dsh-tool-journal-test-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  return root
}

async function owner(journal, execute, append = () => {}) {
  const transport = { async request(method) {
    assert.equal(method, 'native.isolated.bindTools')
    return true
  } }
  const callbacks = new NativeIsolatedToolCallbacks(transport, journal)
  const definition = { name: 'safe_echo' }
  await callbacks.bind({ prepared, admission: { runId, token },
    runtime: { get: name => name === 'safe_echo' ? definition : undefined, execute },
    parent: { token: Symbol('parent'), callId: 'outer', signal: new AbortController().signal,
      agent: { session: { id: runId, append } } },
    allowedToolNames: ['safe_echo'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }) })
  return callbacks
}

function request() {
  return { runId, token, callId: 1, name: 'safe_echo', arguments: { value: 'hello' } }
}

test('prepare, dispatch and confirmation are durable exclusive markers without payloads', async t => {
  const root = privateRoot(t)
  const journal = new IsolatedToolCallJournal(root)
  const input = { runId, callId: 1, parentCallId: 'outer', name: 'safe_echo', arguments: { secret: 'do not persist' } }
  const states = [(await journal.inspect(input)).state]
  await journal.prepare(input)
  states.push((await new IsolatedToolCallJournal(root).inspect(input)).state)
  await assert.rejects(journal.prepare(input), { code: snapshot.restartReplay })
  await journal.dispatch(input)
  states.push((await new IsolatedToolCallJournal(root).inspect(input)).state)
  await journal.observe({ ...input, result: { secret: 'do not persist' } })
  states.push((await new IsolatedToolCallJournal(root).inspect(input)).state)
  await journal.confirm({ ...input, outcome: 'success', result: { secret: 'do not persist' } })
  states.push((await new IsolatedToolCallJournal(root).inspect(input)).state)
  assert.deepEqual(states, snapshot.states)
  assert.equal(snapshot.payloadsPersisted, false)
  assert.deepEqual(await new IsolatedToolCallJournal(root).inspect(input),
    { runId, callId: 1, state: 'confirmed', outcome: 'success' })
  assert.equal(readFileSync(join(root, runId, '1.prepare.json'), 'utf8').includes('do not persist'), false)
  assert.equal(readFileSync(join(root, runId, '1.confirm.json'), 'utf8').includes('do not persist'), false)
})

test('native run claim is durable before a callback and refuses a second binding', async t => {
  const root = privateRoot(t)
  const journal = new IsolatedToolCallJournal(root)
  await journal.claimRun(runId)
  await assert.rejects(new IsolatedToolCallJournal(root).claimRun(runId),
    { code: snapshot.restartReplay })
  assert.equal((await journal.inspect({ runId, callId: 1 })).state, 'absent')
})

test('process death after run claim but before first callback blocks native rebinding', async t => {
  const root = privateRoot(t)
  const journalUrl = new URL('../runtime/isolated-tool-call-journal.mjs', import.meta.url).href
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { IsolatedToolCallJournal } from ${JSON.stringify(journalUrl)};
    await new IsolatedToolCallJournal(${JSON.stringify(root)}).claimRun(${JSON.stringify(runId)});
    process.exit(0);
  `], { encoding: 'utf8', timeout: 10000 })
  assert.equal(child.status, 0, child.stderr)
  const journal = new IsolatedToolCallJournal(root)
  assert.equal((await journal.inspect({ runId, callId: 1 })).state, 'absent')
  let bindingRequests = 0
  const callbacks = new NativeIsolatedToolCallbacks({ request: async () => { bindingRequests++; return true } }, journal)
  const definition = { name: 'safe_echo' }
  await assert.rejects(callbacks.bind({ prepared, admission: { runId, token },
    runtime: { get: () => definition, execute: async () => { throw Error('must not dispatch') } },
    parent: { token: Symbol('parent'), callId: 'outer', signal: new AbortController().signal,
      agent: { session: { id: runId, append() {} } } },
    allowedToolNames: ['safe_echo'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }),
  }), { code: snapshot.restartReplay })
  assert.equal(bindingRequests, 0)
  await callbacks.dispose()
})

test('confirmation rejects a different result and reconciliation detects altered hashes', async t => {
  const root = privateRoot(t)
  const journal = new IsolatedToolCallJournal(root)
  const input = { runId, callId: 1, parentCallId: 'outer', name: 'safe_echo', arguments: {} }
  await journal.prepare(input)
  await journal.dispatch(input)
  await journal.observe({ ...input, result: { observed: true } })
  await assert.rejects(journal.confirm({ ...input, outcome: 'success', result: { observed: false } }),
    { code: 'ANDROID_TOOL_JOURNAL_UNAVAILABLE' })
  assert.equal((await journal.inspect(input)).state, 'result-unconfirmed')
  await journal.confirm({ ...input, outcome: 'success', result: { observed: true } })
  const path = join(root, runId, '1.confirm.json')
  const confirmed = JSON.parse(readFileSync(path, 'utf8'))
  writeFileSync(path, JSON.stringify({ ...confirmed, resultSha256: '0'.repeat(64) }))
  await assert.rejects(journal.inspect(input), { code: 'ANDROID_TOOL_JOURNAL_UNAVAILABLE' })
})

test('real native callback cannot replay a confirmed call after owner restart', async t => {
  const root = privateRoot(t)
  const journal = new IsolatedToolCallJournal(root)
  let effects = 0
  const first = await owner(journal, async () => {
    effects++
    return { isError: false, content: [], value: { okay: true } }
  })
  assert.deepEqual(JSON.parse(JSON.stringify(await first.call(request()))),
    { runId, callId: 1, value: { okay: true } })
  assert.equal((await journal.inspect(request())).state, 'confirmed')
  await first.close({ runId, token })
  await assert.rejects(owner(new IsolatedToolCallJournal(root), async () => {
    effects++
    return { isError: false, content: [], value: { repeated: true } }
  }), { code: 'ANDROID_TOOL_REPLAY' })
  assert.equal(effects, 1)
})

test('process death during ToolRuntime execution leaves uncertain marker and blocks replay', async t => {
  const root = privateRoot(t)
  const effectFile = join(root, 'effect.txt')
  const journalUrl = new URL('../runtime/isolated-tool-call-journal.mjs', import.meta.url).href
  const callbacksUrl = new URL('../runtime/native-isolated-tool-callbacks.mjs', import.meta.url).href
  const script = `
    import { appendFileSync } from 'node:fs';
    import { IsolatedToolCallJournal } from ${JSON.stringify(journalUrl)};
    import { NativeIsolatedToolCallbacks } from ${JSON.stringify(callbacksUrl)};
    const runId = ${JSON.stringify(runId)}, token = ${JSON.stringify(token)};
    const callbacks = new NativeIsolatedToolCallbacks({ request: async () => true },
      new IsolatedToolCallJournal(${JSON.stringify(root)}));
    const definition = { name: 'safe_echo' };
    await callbacks.bind({ prepared: ${JSON.stringify(prepared)}, admission: { runId, token },
      runtime: { get: name => name === 'safe_echo' ? definition : undefined,
        execute: async () => { appendFileSync(${JSON.stringify(effectFile)}, 'effect\\n'); process.exit(0) } },
      parent: { token: Symbol('parent'), callId: 'outer', signal: new AbortController().signal,
        agent: { session: { id: runId, append() {} } } },
      allowedToolNames: ['safe_echo'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }) });
    await callbacks.call({ runId, token, callId: 1, name: 'safe_echo', arguments: { value: 'hello' } });
  `
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
    encoding: 'utf8', timeout: 10000,
  })
  assert.equal(child.status, 0, child.stderr)
  assert.equal(readFileSync(effectFile, 'utf8'), 'effect\n')
  const journal = new IsolatedToolCallJournal(root)
  assert.equal((await journal.inspect(request())).state, 'dispatch-unconfirmed')
  await assert.rejects(owner(journal, async () => {
    throw Error('replay reached a side effect')
  }), { code: 'ANDROID_TOOL_REPLAY' })
  assert.equal(readFileSync(effectFile, 'utf8'), 'effect\n')
})

test('session terminal audit failure cannot claim confirmation or guest success', async t => {
  const journal = new IsolatedToolCallJournal(privateRoot(t))
  const callbacks = await owner(journal,
    async () => ({ isError: false, content: [], value: 'effect happened' }),
    type => { if (type === 'tool/ptc-dispatch') throw Error('audit unavailable') })
  await assert.rejects(callbacks.call(request()), /audit unavailable/)
  assert.equal((await journal.inspect(request())).state, 'result-unconfirmed')
  await assert.rejects(callbacks.close({ runId, token }), { code: 'ANDROID_TOOL_DISPATCH_UNCONFIRMED' })
})
