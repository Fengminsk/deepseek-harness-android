import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  prepareIsolatedLinuxToolRequest,
  projectIsolatedLinuxToolResult,
  registerIsolatedLinuxTool,
} from '../runtime/tool-isolated-linux.mjs'

test('the Agent tool admits only fixed commands with bounded supplied text', () => {
  assert.deepEqual(prepareIsolatedLinuxToolRequest({ command: 'kernel' }), { command: 'kernel' })
  const sorted = prepareIsolatedLinuxToolRequest({ command: 'sort_lines', input: 'z\na\n' })
  assert.equal(sorted.command, 'sort_lines')
  assert.deepEqual([...sorted.stdin], [...new TextEncoder().encode('z\na\n')])
  assert.deepEqual(prepareIsolatedLinuxToolRequest({ command: 'filter_literal', literal: '-e', input: 'a\n' }).argument, '-e')
  for (const args of [
    { command: 'sh', input: 'id' },
    { command: '/system/bin/sh', input: 'id' },
    { command: 'kernel', input: '' },
    { command: 'sha256' },
    { command: 'sha256', input: 'x', path: '/data/data/app' },
    { command: 'filter_literal', input: 'x', literal: '\n' },
    { command: 'sort_lines', input: 'x\0y' },
    { command: 'sort_lines', input: 'x'.repeat(64 * 1024 + 1) },
    { command: 'sort_lines', input: 'a', literal: 'extra' },
  ]) {
    assert.throws(() => prepareIsolatedLinuxToolRequest(args), { name: 'TypeError' })
  }
  assert.throws(() => prepareIsolatedLinuxToolRequest(Object.defineProperty({ command: 'kernel' }, 'input', {
    get() { throw new Error('getter evaluated') }, enumerable: true,
  })), { name: 'TypeError' })
})

test('only completed receipts expose output to the Agent', () => {
  assert.deepEqual(projectIsolatedLinuxToolResult({ kind: 'COMPLETED', command: 'identity', output: '99001\n', exitCode: 0 }),
    { status: 'completed', command: 'identity', output: '99001\n', exitCode: 0 })
  assert.deepEqual(projectIsolatedLinuxToolResult({ kind: 'WORKER_DIED', command: 'identity', output: 'private data', detail: 'x' }),
    { status: 'worker_died', command: 'identity' })
})

test('the registered tool forwards only a prepared request and the Agent cancellation signal', async () => {
  let registered
  let actualSignal
  const calls = []
  const ctx = {
    effect(register) { register() },
    tools: { register(tool) { registered = tool; return () => {} } },
  }
  registerIsolatedLinuxTool(ctx, {
    async execute(request, signal) {
      calls.push(request)
      actualSignal = signal
      return { kind: 'COMPLETED', command: request.command, output: '3\n', exitCode: 0 }
    },
  })
  assert.equal(registered.name, 'android_linux')
  const signal = new AbortController().signal
  const result = await registered.execute({ command: 'count_bytes', input: 'abc' }, { agent: { session: { id: 's' } }, signal })
  assert.equal(actualSignal, signal)
  assert.equal(calls.length, 1)
  assert.equal(calls[0].argument, undefined)
  assert.deepEqual([...calls[0].stdin], [...new TextEncoder().encode('abc')])
  assert.deepEqual(result, { status: 'completed', command: 'count_bytes', output: '3\n', exitCode: 0 })
  await assert.rejects(registered.execute({ command: 'kernel' }, { signal }), /Agent session/)
  assert.equal(calls.length, 1)
  await assert.rejects(registered.execute({ command: 'sh', input: 'id' }, { agent: {}, signal }), /Unsupported Android Linux command/)
  assert.equal(calls.length, 1)
})
