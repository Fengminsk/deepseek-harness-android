import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  prepareModelIsolatedScript, runModelIsolatedScript,
  startAppOwnedModelIsolatedScript,
} from '../runtime/model-isolated-script.mjs'
import { projectIsolatedSandboxPolicy } from '../runtime/isolated-sandbox-policy.mjs'
import { createNativeIsolatedExecutionBridge } from '../runtime/native-isolated-execution-bridge.mjs'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'

const AsyncFunction = (async () => {}).constructor
const sessionId = 'android-1793060921975320-627842147'
const token = 'native-private-token'
const tempRoots = []
process.once('exit', () => { for (const root of tempRoots) rmSync(root, { recursive: true, force: true }) })
const scope = () => ({ ownerId: 'app-model-script', sessionId, version: 1,
  workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
  fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 30_000 })
const model = () => ({ language: 'typescript-function-body',
  description: 'Use a selected read-only tool',
  code: 'const reply: { value: { text: string } } = await host.callAsync({ callId: 1, name: "safe_echo", arguments: { text: "hello" } }); return { text: reply.value.text }',
})
const draft = (policy = projectIsolatedSandboxPolicy({ approvedScope: scope() })) =>
  prepareModelIsolatedScript(model(), { sessionId, sandboxPolicy: policy, deadlineMillis: 5000 })

function setup(options = {}) {
  const calls = []
  const audits = []
  let callbacks
  let outputJson
  let program
  let inputJson
  let cancelled = false
  const transport = { async request(method, params, signal) {
    calls.push(method)
    assert.ok(signal instanceof AbortSignal)
    if (method === 'native.isolated.admit') {
      assert.deepEqual(Object.keys(params).sort(),
        ['deadlineMillis', 'inputJson', 'kind', 'program', 'runId', 'scope', 'sessionId'])
      assert.equal(params.scope.sessionId, sessionId)
      program = params.program
      inputJson = params.inputJson
      return { runId: params.runId, token }
    }
    if (method === 'native.isolated.bindTools') return true
    if (method === 'native.isolated.execute') {
      if (options.beforeExecute) return options.beforeExecute()
      const body = new AsyncFunction('input', 'host', program)
      const result = await body(JSON.parse(inputJson), { callAsync: async value => {
        const response = await callbacks.call({ runId: params.runId, token,
          callId: value.callId, name: value.name, arguments: value.arguments })
        return { value: response.value }
      } })
      outputJson = JSON.stringify(result)
      return true
    }
    if (method === 'native.isolated.cancel') { cancelled = true; options.onCancel?.(); return true }
    if (method === 'native.isolated.settle') return { runId: params.runId,
      state: cancelled ? 'CANCELLED' : 'COMPLETED',
      outputJson: cancelled ? null : outputJson,
      detail: cancelled ? 'cancelled' : null,
      guestUid: cancelled ? null : 99001 }
    if (method === 'native.isolated.release') return true
    throw new Error(`Unexpected native method ${method}`)
  } }
  const root = mkdtempSync(join(tmpdir(), 'dsh-app-model-call-'))
  tempRoots.push(root)
  callbacks = new NativeIsolatedToolCallbacks(transport, new IsolatedToolCallJournal(root))
  const bridge = createNativeIsolatedExecutionBridge(transport)
  const safeEcho = { name: 'safe_echo' }
  const runtime = { get(name) { return name === 'safe_echo' ? safeEcho : undefined },
    async execute(batch) {
      const block = batch.calls[0]
      return { results: [{ callId: block.id, result: { isError: false,
        content: [{ type: 'text', text: 'ok' }], value: JSON.parse(block.arguments) } }],
      additionalContexts: [], concluded: false }
    } }
  const parent = { token: Symbol('parent'), callId: 'model-call',
    signal: new AbortController().signal,
    agent: { session: { id: sessionId,
      append(type, payload) { audits.push({ type, payload }) } } } }
  const host = signal => ({ bridge, callbacks, runtime, parent: { ...parent, signal },
    allowedToolNames: ['safe_echo'], authorizeTool: async input => ({ effect: 'pure', definition: input.definition }), signal })
  return { calls, audits, callbacks, host }
}

test('App-owned model draft runs through native admission, tool binding and durable settlement', async () => {
  const prepared = draft()
  const owner = setup()
  const run = startAppOwnedModelIsolatedScript(prepared, owner.host(new AbortController().signal))
  const result = await run.result
  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    runId: prepared.execution.runId, state: 'completed', value: { text: 'hello' }, logs: [], guestUid: 99001,
  })
  assert.deepEqual(owner.calls, ['native.isolated.admit', 'native.isolated.bindTools',
    'native.isolated.execute', 'native.isolated.settle', 'native.isolated.release'])
  assert.deepEqual(owner.audits.map(item => item.type),
    ['tool/ptc-dispatch-start', 'tool/ptc-dispatch'])
  assert.throws(() => startAppOwnedModelIsolatedScript(prepared,
    owner.host(new AbortController().signal)), { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  await owner.callbacks.dispose()
})

test('forged draft or bridge cannot reach native admission; published model tool stays closed', async () => {
  const prepared = draft()
  const owner = setup()
  const signal = new AbortController().signal
  assert.throws(() => startAppOwnedModelIsolatedScript({ ...prepared }, owner.host(signal)),
    { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  assert.throws(() => startAppOwnedModelIsolatedScript(prepared,
    { ...owner.host(signal), bridge: { admit() {} } }), /App-owned native isolated bridge required/)
  assert.throws(() => startAppOwnedModelIsolatedScript(prepared,
    { ...owner.host(signal), parent: { ...owner.host(signal).parent,
      agent: { session: { id: 'other-session' } } } }),
  { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  assert.throws(() => runModelIsolatedScript(prepared, owner.host(signal).bridge, signal),
    { code: 'ANDROID_PTC_UNAVAILABLE' })
  assert.deepEqual(owner.calls, [])
  await owner.callbacks.dispose()
})

test('nonempty App scope fails native admission before executing or binding tools', async () => {
  const policy = projectIsolatedSandboxPolicy({ approvedScope: {
    ...scope(), workspaceId: 'b6350414-f332-43f3-ae59-70695b38b791', readablePaths: ['notes.txt'], fileCallLimit: 1,
  } })
  const prepared = draft(policy)
  const owner = setup()
  const run = startAppOwnedModelIsolatedScript(prepared, owner.host(new AbortController().signal))
  await assert.rejects(run.result, { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.deepEqual(owner.calls, [])
  await owner.callbacks.dispose()
})

test('external cancellation joins native stop and withholds a late result', async () => {
  let releaseExecution
  const waiting = new Promise(resolve => { releaseExecution = resolve })
  let enteredExecution
  const entered = new Promise(resolve => { enteredExecution = resolve })
  const owner = setup({
    beforeExecute: async () => { enteredExecution(); await waiting; return true },
    onCancel: () => releaseExecution(),
  })
  const controller = new AbortController()
  const run = startAppOwnedModelIsolatedScript(draft(), owner.host(controller.signal))
  await entered
  controller.abort('user cancelled')
  const result = await run.result
  assert.equal(result.state, 'failed')
  assert.equal(Object.hasOwn(result, 'value'), false)
  assert.ok(owner.calls.includes('native.isolated.cancel'))
  assert.equal(owner.calls.at(-1), 'native.isolated.release')
  await owner.callbacks.dispose()
})
