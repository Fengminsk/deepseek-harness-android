import assert from 'node:assert/strict'
import { test } from 'node:test'
import { LinuxCommandOutcomeUncertainError, NativeLinuxCommands } from '../runtime/native-linux-commands.mjs'

const receipt = params => ({ id: params.id, command: params.command, kind: 'COMPLETED',
  output: 'ok\n', exitCode: 0, guestUid: 12345, detail: null, retirementConfirmed: true })

test('sends only a fixed command and bounded encoded input to the App owner', async () => {
  const calls = []
  const port = new NativeLinuxCommands({ request: async (method, params) => {
    calls.push({ method, params })
    return receipt(params)
  } })
  const result = await port.execute({ command: 'sha256', stdin: Buffer.from('hello') })
  assert.equal(result.kind, 'COMPLETED')
  assert.equal(calls.length, 1)
  assert.equal(calls[0].method, 'native.linuxCommand.execute')
  assert.equal(calls[0].params.stdinBase64, 'aGVsbG8=')
  assert.equal(calls[0].params.argument, '')
  await port.dispose()
})

test('rejects shell fragments, debug commands, paths, oversized input and parameters before dispatch', async () => {
  let calls = 0
  const port = new NativeLinuxCommands({ request: async () => { calls++; return null } })
  const invalid = [
    { command: 'sh', stdin: Buffer.from('id') },
    { command: '_test_delay' },
    { command: 'kernel', stdin: Buffer.from('x') },
    { command: 'sort_lines', stdin: Buffer.alloc(65537) },
    { command: 'filter_literal', argument: 'a\nb', stdin: Buffer.from('x') },
    { command: 'sort_lines', cwd: '/data/data/private' },
  ]
  for (const input of invalid) await assert.rejects(port.execute(input))
  assert.equal(calls, 0)
  await port.dispose()
})

test('cancels a dispatched request on caller abort and never reports late success', async () => {
  const calls = []
  let dispatched
  const started = new Promise(resolve => { dispatched = resolve })
  const port = new NativeLinuxCommands({ request: (method, params, signal) => {
    calls.push(method)
    if (method.endsWith('.cancel')) return Promise.resolve({ cancelRequested: true, settled: true })
    dispatched()
    return new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true })
    })
  } })
  const controller = new AbortController()
  const pending = port.execute({ command: 'identity' }, controller.signal)
  await started
  controller.abort(new Error('cancelled by owner'))
  await assert.rejects(pending, /cancelled by owner/)
  assert.deepEqual(calls, ['native.linuxCommand.execute', 'native.linuxCommand.cancel'])
  await port.dispose()
})

test('an already aborted caller never creates a native run or cancellation tombstone', async () => {
  const methods = []
  const port = new NativeLinuxCommands({ request: async method => {
    methods.push(method)
    throw new Error('unexpected native RPC')
  } })
  const controller = new AbortController()
  controller.abort(new Error('cancelled before dispatch'))
  await assert.rejects(port.execute({ command: 'kernel' }, controller.signal),
    /cancelled before dispatch/)
  assert.deepEqual(methods, [])
  await port.dispose()
})

test('rejects mismatched native receipts and retires the run', async () => {
  const calls = []
  const port = new NativeLinuxCommands({ request: async (method, params) => {
    calls.push(method)
    return method.endsWith('.cancel') ? { cancelRequested: false, settled: true }
      : { ...receipt(params), id: 'wrong' }
  } })
  await assert.rejects(port.execute({ command: 'kernel' }), /invalid receipt/)
  assert.deepEqual(calls, ['native.linuxCommand.execute', 'native.linuxCommand.cancel'])
  await port.dispose()
})

test('preserves the no-match exit status of a literal filter', async () => {
  const port = new NativeLinuxCommands({ request: async (method, params) => ({
    ...receipt(params), output: '', exitCode: 1,
  }) })
  const result = await port.execute({ command: 'filter_literal', argument: 'missing',
    stdin: Buffer.from('present\n') })
  assert.equal(result.kind, 'COMPLETED')
  assert.equal(result.exitCode, 1)
  await port.dispose()
})

test('bounds concurrent internal commands and cancels them during disposal', async () => {
  const calls = []
  const pending = new Map()
  const port = new NativeLinuxCommands({ request: (method, params, signal) => {
    calls.push({ method, id: params.id })
    if (method.endsWith('.cancel')) {
      pending.get(params.id)?.reject(new Error('closed'))
      return Promise.resolve({ cancelRequested: true, settled: true })
    }
    return new Promise((resolve, reject) => pending.set(params.id, { resolve, reject }))
  } })
  const first = port.execute({ command: 'kernel' })
  const second = port.execute({ command: 'identity' })
  await assert.rejects(port.execute({ command: 'sha256' }), /capacity/)
  await port.dispose()
  await assert.rejects(first)
  await assert.rejects(second)
  assert.equal(calls.filter(call => call.method.endsWith('.cancel')).length, 2)
})

test('unconfirmed cancellation is explicit and closes the carrier before another command', async () => {
  let started
  const dispatched = new Promise(resolve => { started = resolve })
  const methods = []
  const port = new NativeLinuxCommands({ request: (method, params, signal) => {
    methods.push(method)
    if (method.endsWith('.cancel')) return Promise.resolve({ cancelRequested: true, settled: false })
    started()
    return new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true })
    })
  } })
  const controller = new AbortController()
  const pending = port.execute({ command: 'identity' }, controller.signal)
  await dispatched
  controller.abort(new Error('owner requested stop'))
  await assert.rejects(pending, error => {
    assert.equal(error instanceof LinuxCommandOutcomeUncertainError, true)
    assert.equal(error.code, 'outcome-uncertain')
    assert.equal(error.command, 'identity')
    assert.match(error.message, /do not retry automatically/)
    assert.equal(error.cause.message, 'owner requested stop')
    return true
  })
  await assert.rejects(port.execute({ command: 'kernel' }), /carrier is closed/)
  assert.deepEqual(methods, ['native.linuxCommand.execute', 'native.linuxCommand.cancel'])
})

test('a missing or malformed cancel receipt leaves transport failures unconfirmed', async () => {
  for (const response of [undefined, { cancelled: true }, { cancelRequested: true, settled: 'yes' }]) {
    const port = new NativeLinuxCommands({ request: async (method) => {
      if (method.endsWith('.cancel')) return response
      throw new Error('native transport disconnected')
    } })
    await assert.rejects(port.execute({ command: 'kernel' }), error => {
      assert.equal(error.code, 'outcome-uncertain')
      assert.equal(error.cause.message, 'native transport disconnected')
      return true
    })
    await assert.rejects(port.execute({ command: 'identity' }), /carrier is closed/)
  }
})

test('a worker death receipt remains uncertain even if a later cancel says settled', async () => {
  const methods = []
  const port = new NativeLinuxCommands({ request: async (method, params) => {
    methods.push(method)
    if (method.endsWith('.cancel')) return { cancelRequested: false, settled: true }
    return { ...receipt(params), kind: 'WORKER_DIED', output: '', exitCode: -1 }
  } })
  await assert.rejects(port.execute({ command: 'kernel' }), error => {
    assert.equal(error.code, 'outcome-uncertain')
    return true
  })
  await assert.rejects(port.execute({ command: 'identity' }), /carrier is closed/)
  assert.deepEqual(methods, ['native.linuxCommand.execute', 'native.linuxCommand.cancel'])
})

test('a terminal error without direct child retirement proof remains uncertain', async () => {
  const methods = []
  const port = new NativeLinuxCommands({ request: async (method, params) => {
    methods.push(method)
    if (method.endsWith('.cancel')) return { cancelRequested: false, settled: false }
    return { ...receipt(params), kind: 'ERROR', output: '', exitCode: -1,
      retirementConfirmed: false, detail: 'child retirement unconfirmed' }
  } })
  await assert.rejects(port.execute({ command: 'kernel' }), error => {
    assert.equal(error.code, 'outcome-uncertain')
    assert.equal(error.command, 'kernel')
    return true
  })
  await assert.rejects(port.execute({ command: 'identity' }), /carrier is closed/)
  assert.deepEqual(methods, ['native.linuxCommand.execute', 'native.linuxCommand.cancel'])
})

test('a native receipt missing retirement evidence is rejected and not rendered', async () => {
  const port = new NativeLinuxCommands({ request: async (method, params) => {
    if (method.endsWith('.cancel')) return { cancelRequested: false, settled: true }
    const response = receipt(params)
    delete response.retirementConfirmed
    return response
  } })
  await assert.rejects(port.execute({ command: 'kernel' }), error => {
    assert.equal(error.code, 'outcome-uncertain')
    return true
  })
  await assert.rejects(port.execute({ command: 'identity' }), /carrier is closed/)
})

test('a late success after confirmed cancellation cannot reach the tool', async () => {
  let complete
  let started
  const dispatched = new Promise(resolve => { started = resolve })
  const port = new NativeLinuxCommands({ request: (method, params) => {
    if (method.endsWith('.cancel')) return Promise.resolve({ cancelRequested: true, settled: true })
    started()
    return new Promise(resolve => { complete = () => resolve(receipt(params)) })
  } })
  const controller = new AbortController()
  const pending = port.execute({ command: 'identity' }, controller.signal)
  await dispatched
  controller.abort(new Error('owner stopped'))
  complete()
  await assert.rejects(pending, /owner stopped/)
  await port.dispose()
})

test('host deadline with no retirement receipt is outcome-uncertain', { timeout: 9000 }, async () => {
  const port = new NativeLinuxCommands({ request: (method, _params, signal) => {
    if (method.endsWith('.cancel')) return Promise.resolve({ cancelRequested: true, settled: false })
    return new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true })
    })
  } })
  await assert.rejects(port.execute({ command: 'identity' }), error => {
    assert.equal(error.code, 'outcome-uncertain')
    assert.equal(error.cause.name, 'TimeoutError')
    return true
  })
})

test('dispose reports unconfirmed child retirement and blocks subsequent calls', async () => {
  let failExecute
  let started
  const dispatched = new Promise(resolve => { started = resolve })
  const port = new NativeLinuxCommands({ request: (method) => {
    if (method.endsWith('.cancel')) return Promise.resolve({ cancelRequested: true, settled: false })
    started()
    return new Promise((resolve, reject) => { failExecute = reject })
  } })
  const pending = port.execute({ command: 'kernel' })
  await dispatched
  await assert.rejects(port.dispose(), error => error.code === 'outcome-uncertain')
  failExecute(new Error('service closed'))
  await assert.rejects(pending, error => error.code === 'outcome-uncertain')
  await assert.rejects(port.execute({ command: 'identity' }), /carrier is closed/)
})
