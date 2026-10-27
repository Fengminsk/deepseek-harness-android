import assert from 'node:assert/strict'
import { test } from 'node:test'
import { HarnessError } from '@deepseek-ai/dsh-llm'
import { NativeLinuxVm, LinuxVmOutcomeUncertainError, prepareLinuxVmCommand, prepareLinuxVmImport,
  LINUX_VM_IMPORT_BYTES } from '../runtime/native-linux-vm.mjs'

const sessionId = 'android-1793060921975320-627842147'
const writable = { persistChanges: true }
const completed = request => ({ id: request.id, sessionId: request.sessionId,
  status: 'completed', output: 'Linux riscv64\n', exitCode: 0, guestUid: 99001,
  timedOut: false, cancelled: false, truncated: false, diskCommitted: true,
  retirementConfirmed: true, detail: null })

test('passes arbitrary guest shell scripts with the host-bound conversation identity', async () => {
  let request
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    assert.equal(method, 'native.linuxVm.execute'); request = params
    return completed(params)
  } })
  const script = "printf '%s\\n' 中文; find . -type f | sort"
  const result = await owner.execute(sessionId, { command: script }, new AbortController().signal, writable)
  assert.equal(request.command, script)
  assert.equal(request.sessionId, sessionId)
  assert.equal(request.persistChanges, true)
  assert.equal(result.exitCode, 0)
  assert.equal(result.diskCommitted, true)
  await owner.dispose()
})

test('model arguments cannot choose an Android path, image, environment or session', () => {
  for (const args of [
    { command: 'id', cwd: '/data/data' }, { command: 'id', sessionId },
    { command: 'id', image: 'custom.img' }, { command: 'id', env: { TOKEN: 'x' } },
    { command: 'id', persistChanges: true },
    { command: '\0' }, { command: '汉'.repeat(12000) }, { command: 'id', timeoutMs: 120001 },
  ]) assert.throws(() => prepareLinuxVmCommand(args))
  assert.throws(() => prepareLinuxVmCommand({ get command() { throw new Error('getter was invoked') } }),
    /Invalid Linux VM request/)
})

test('a nonzero shell exit stays completed with an explicit nonzero status', async () => {
  const owner = new NativeLinuxVm({ request: async (_method, params) => ({ ...completed(params), exitCode: 7 }) })
  const result = await owner.execute(sessionId, { command: 'exit 7' }, new AbortController().signal, writable)
  assert.equal(result.exitCode, 7)
  await owner.dispose()
})

test('cancellation joins the original execution receipt without aborting its transport', async () => {
  const abort = new AbortController()
  let began
  const dispatched = new Promise(resolve => { began = resolve })
  const methods = []
  let finish, request, executionSignal
  const owner = new NativeLinuxVm({ request: (method, params, signal) => {
    methods.push(method)
    if (method.endsWith('.cancel')) {
      finish({ ...completed(request), status: 'cancelled', exitCode: null, cancelled: true, diskCommitted: false })
      return Promise.resolve({ cancelRequested: true, settled: true })
    }
    request = params; executionSignal = signal
    began()
    return new Promise(resolve => { finish = resolve })
  } })
  const pending = owner.execute(sessionId, { command: 'while :; do :; done' }, abort.signal, writable)
  await dispatched
  abort.abort(new Error('user cancelled'))
  const result = await pending
  assert.equal(executionSignal.aborted, false)
  assert.equal(result.status, 'cancelled')
  assert.equal(result.diskCommitted, false)
  assert.equal(result.cancelRequested, true)
  assert.deepEqual(methods, ['native.linuxVm.execute', 'native.linuxVm.cancel'])
  await owner.dispose()
})

test('unconfirmed VM retirement prevents a second run instead of silently retrying', async () => {
  const owner = new NativeLinuxVm({ request: async (method, params) => method.endsWith('.cancel')
    ? { cancelRequested: true, settled: false }
    : { ...completed(params), retirementConfirmed: false } })
  await assert.rejects(owner.execute(sessionId, { command: 'id' }, new AbortController().signal, writable),
    error => error instanceof HarnessError && error instanceof LinuxVmOutcomeUncertainError
      && error.code === 'linux-vm/outcome-uncertain' && error.diskCommitted === true
      && error.receipt.nativeStatus === 'completed' && error.receipt.retirementConfirmed === false
      && error.receipt.sessionId === sessionId)
  await assert.rejects(owner.execute(sessionId, { command: 'id' }, new AbortController().signal, writable), /owner is closed/)
})

test('disposal requests cancellation but waits for the final original receipt', async () => {
  let began
  const dispatched = new Promise(resolve => { began = resolve })
  let finish, request, executionSignal
  const owner = new NativeLinuxVm({ request: (method, params, signal) => {
    if (method.endsWith('.cancel')) return Promise.resolve({ cancelRequested: true, settled: true })
    request = params; executionSignal = signal
    began()
    return new Promise(resolve => { finish = resolve })
  } })
  const pending = owner.execute(sessionId, { command: 'sleep 100' }, new AbortController().signal, writable)
  await dispatched
  let disposed = false
  const disposing = owner.dispose().then(() => { disposed = true })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(disposed, false)
  assert.equal(executionSignal.aborted, false)
  finish({ ...completed(request), status: 'cancelled', cancelled: true, exitCode: null, diskCommitted: false })
  assert.equal((await pending).cancelRequested, true)
  await disposing
  assert.equal(disposed, true)
})

test('invalid receipts cannot claim a timed-out disk was committed', async () => {
  const owner = new NativeLinuxVm({ request: async (method, params) => method.endsWith('.cancel')
    ? { cancelRequested: false, settled: true }
    : { ...completed(params), status: 'timed_out', timedOut: true } })
  await assert.rejects(owner.execute(sessionId, { command: 'sleep 3' }, new AbortController().signal, writable),
    error => error instanceof LinuxVmOutcomeUncertainError && /invalid execution receipt/.test(error.cause?.message))
  await owner.dispose()
})

test('uncertain disk publication stops the owner even when the virtual CPU has retired', async () => {
  const owner = new NativeLinuxVm({ request: async (method, params) => method.endsWith('.cancel')
    ? { cancelRequested: false, settled: true }
    : { ...completed(params), status: 'outcome_uncertain', diskCommitted: null } })
  await assert.rejects(owner.execute(sessionId, { command: 'echo data > result' }, new AbortController().signal, writable),
    LinuxVmOutcomeUncertainError)
  await assert.rejects(owner.execute(sessionId, { command: 'cat result' }, new AbortController().signal, writable), /owner is closed/)
})

test('read-only execution accepts only a receipt proving disk changes were discarded', async () => {
  for (const diskCommitted of [false, true]) {
    const owner = new NativeLinuxVm({ request: async (method, params) => {
      if (method.endsWith('.cancel')) return { cancelRequested: false, settled: true }
      assert.equal(params.persistChanges, false)
      return { ...completed(params), diskCommitted }
    } })
    const pending = owner.execute(sessionId, { command: 'echo transient > file' },
      new AbortController().signal, { persistChanges: false })
    if (diskCommitted) await assert.rejects(pending,
      error => error instanceof LinuxVmOutcomeUncertainError && /invalid execution receipt/.test(error.cause?.message))
    else assert.equal((await pending).diskCommitted, false)
    await owner.dispose()
  }
})

test('missing host persistence policy cannot silently enable writable guest storage', async () => {
  const owner = new NativeLinuxVm({ request() { throw new Error('must not dispatch') } })
  await assert.rejects(owner.execute(sessionId, { command: 'id' }, new AbortController().signal), /Invalid Linux VM request/)
  await assert.rejects(owner.importFile(sessionId, { source: 'app.apk', destination: 'app.apk' },
    new AbortController().signal, { persistChanges: false }), /writable session policy/)
  await owner.dispose()
})

test('import paths cannot choose roots, sessions, native policies or escape their fixed directory', () => {
  for (const path of ['', '/data/app.apk', '../app.apk', 'a/../b', 'a//b', '.', 'a/./b',
    'C:\\app.apk', 'content://documents/file', 'a\\b', 'a\0b', 'a\nb']) {
    assert.throws(() => prepareLinuxVmImport({ source: path, destination: 'app.apk' }))
    assert.throws(() => prepareLinuxVmImport({ source: 'app.apk', destination: path }))
  }
  for (const extra of [{ sessionId }, { root: '/data' }, { persistChanges: true }]) {
    assert.throws(() => prepareLinuxVmImport({ source: 'app.apk', destination: 'files/app.apk', ...extra }))
  }
  assert.deepEqual(prepareLinuxVmImport({ source: '附件/app.apk', destination: 'analysis/app.apk' }), {
    source: '附件/app.apk', destination: 'analysis/app.apk', timeoutMs: 120000,
  })
})

test('successful imports validate their actual file identity and bounded content receipt', async () => {
  const args = { source: 'files/app.apk', destination: 'analysis/app.apk', timeoutMs: 30000 }
  for (const invalid of [null, { source: 'other.apk' }, { destination: '/workspace/analysis/app.apk' },
    { bytes: LINUX_VM_IMPORT_BYTES + 1 }, { bytes: -1 }, { sha256: 'not-a-hash' }]) {
    const owner = new NativeLinuxVm({ request: async (method, params) => {
      if (method.endsWith('.cancel')) return { cancelRequested: false, settled: true }
      assert.equal(method, 'native.linuxVm.importFile')
      assert.deepEqual(Object.keys(params).sort(), ['destination', 'id', 'sessionId', 'source', 'timeoutMs'])
      return { ...completed(params), source: params.source, destination: params.destination,
        bytes: 3, sha256: 'a'.repeat(64), ...invalid }
    } })
    const pending = owner.importFile(sessionId, args, new AbortController().signal, writable)
    if (invalid) await assert.rejects(pending,
      error => error instanceof LinuxVmOutcomeUncertainError && /invalid import receipt/.test(error.cause?.message))
    else assert.equal((await pending).bytes, 3)
    await owner.dispose()
  }
})

test('an import command failure returns its diagnostic receipt without persisting disk changes', async () => {
  const owner = new NativeLinuxVm({ request: async (_method, params) => ({ ...completed(params),
    exitCode: 2, diskCommitted: false, output: 'destination is a directory' }) })
  const result = await owner.importFile(sessionId, { source: 'app.apk', destination: 'folder' },
    new AbortController().signal, writable)
  assert.equal(result.exitCode, 2)
  assert.equal(result.diskCommitted, false)
  await owner.dispose()
})

test('publication winning a user cancellation still returns its committed final receipt', async () => {
  const abort = new AbortController(), methods = []
  let finish, request, committed = false
  const owner = new NativeLinuxVm({ request(method, params, signal) {
    methods.push(method)
    if (method.endsWith('.cancel')) {
      assert.equal(committed, true)
      queueMicrotask(() => finish(completed(request)))
      return Promise.resolve({ cancelRequested: true, settled: true })
    }
    request = params
    committed = true
    queueMicrotask(() => { abort.abort(new DOMException('Cancelled', 'AbortError')); assert.equal(signal.aborted, false) })
    return new Promise(resolve => { finish = resolve })
  } })
  const result = await owner.execute(sessionId, { command: 'echo data > result' }, abort.signal, writable)
  assert.equal(result.status, 'completed')
  assert.equal(result.diskCommitted, true)
  assert.equal(result.cancelRequested, true)
  assert.deepEqual(methods, ['native.linuxVm.execute', 'native.linuxVm.cancel'])
  await owner.dispose()
})

test('lost execution receipt is uncertain even when cancellation confirms retirement', async () => {
  const abort = new AbortController()
  let calls = 0
  const owner = new NativeLinuxVm({ request: async method => {
    if (method.endsWith('.cancel')) return { cancelRequested: true, settled: true }
    calls++
    abort.abort(new DOMException('Cancelled after publication', 'AbortError'))
    throw new Error('execution RPC disconnected after disk publication')
  } })
  await assert.rejects(owner.execute(sessionId, { command: 'echo data > result' }, abort.signal, writable),
    LinuxVmOutcomeUncertainError)
  await assert.rejects(owner.execute(sessionId, { command: 'cat result' }, new AbortController().signal, writable), /owner is closed/)
  assert.equal(calls, 1)
  await owner.dispose()
})

test('disposal surfaces uncertainty when the execution receipt is lost', async () => {
  let fail, began
  const started = new Promise(resolve => { began = resolve })
  const owner = new NativeLinuxVm({ request(method) {
    if (method.endsWith('.cancel')) {
      fail(new Error('execution deadline elapsed without receipt'))
      return Promise.resolve({ cancelRequested: true, settled: true })
    }
    began()
    return new Promise((_resolve, reject) => { fail = reject })
  } })
  const pending = owner.execute(sessionId, { command: 'sleep 100' }, new AbortController().signal, writable)
  const rejected = assert.rejects(pending, LinuxVmOutcomeUncertainError)
  await started
  await assert.rejects(owner.dispose(), LinuxVmOutcomeUncertainError)
  await rejected
})

test('independent RPC and cancellation deadlines bound disposal even for an unresponsive transport', async t => {
  const realTimeout = AbortSignal.timeout.bind(AbortSignal), deadlines = []
  t.mock.method(AbortSignal, 'timeout', milliseconds => {
    deadlines.push(milliseconds)
    return realTimeout(5)
  })
  // AbortSignal timeouts are unref'ed; retain only this test's bounded wait.
  const keepAlive = setTimeout(() => {}, 1000)
  try {
    const owner = new NativeLinuxVm({ request: () => new Promise(() => {}) })
    const pending = owner.execute(sessionId, { command: 'sleep 100', timeoutMs: 1000 },
      new AbortController().signal, writable)
    const rejected = assert.rejects(pending, LinuxVmOutcomeUncertainError)
    await assert.rejects(owner.dispose(), LinuxVmOutcomeUncertainError)
    await rejected
    assert.deepEqual(deadlines, [31000, 10000])
  } finally { clearTimeout(keepAlive) }
})

test('export validates file publication without treating it as a guest disk commit', async () => {
  const args = { source: 'report.txt', destination: 'agent/report.txt' }
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    assert.equal(method, 'native.linuxVm.exportFile')
    assert.equal(Object.hasOwn(params, 'persistChanges'), false)
    return { ...completed(params), source: params.source, destination: params.destination,
      diskCommitted: false, filePublished: true, bytes: 3, sha256: 'a'.repeat(64) }
  } })
  const result = await owner.exportFile(sessionId, args, new AbortController().signal, writable)
  assert.equal(result.filePublished, true)
  assert.equal(result.diskCommitted, false)
  await owner.dispose()
})

test('export rejects publication claims without bounded and matching content metadata', async () => {
  for (const invalid of [{ source: 'other' }, { destination: 'other' }, { bytes: LINUX_VM_IMPORT_BYTES + 1 },
    { sha256: 'invalid' }, { filePublished: false }, { diskCommitted: true }]) {
    const owner = new NativeLinuxVm({ request: async (method, params) => method.endsWith('.cancel')
      ? { cancelRequested: false, settled: true }
      : { ...completed(params), source: params.source, destination: params.destination, diskCommitted: false,
        filePublished: true, bytes: 3, sha256: 'a'.repeat(64), ...invalid } })
    await assert.rejects(owner.exportFile(sessionId, { source: 'report', destination: 'out' },
      new AbortController().signal, writable), LinuxVmOutcomeUncertainError)
    await owner.dispose()
  }
})

test('uncertain host publication closes the export owner and preserves the publication fact', async () => {
  for (const filePublished of [true, null]) {
    const owner = new NativeLinuxVm({ request: async (method, params) => method.endsWith('.cancel')
      ? { cancelRequested: false, settled: true }
      : { ...completed(params), status: 'outcome_uncertain', diskCommitted: false,
        filePublished, detail: 'host publication uncertain' } })
    await assert.rejects(owner.exportFile(sessionId, { source: 'report', destination: 'out' },
      new AbortController().signal, writable), error => error instanceof LinuxVmOutcomeUncertainError
        && error.filePublished === filePublished && error.receipt.filePublished === filePublished
        && error.receipt.diskCommitted === false && error.receipt.operation === 'native.linuxVm.exportFile')
    await assert.rejects(owner.execute(sessionId, { command: 'id' }, new AbortController().signal, writable), /owner is closed/)
    await owner.dispose()
  }
})

test('failed exports and denied write policy never claim a published file', async () => {
  const owner = new NativeLinuxVm({ request: async (_method, params) => ({ ...completed(params),
    exitCode: 73, output: 'target already exists', diskCommitted: false, filePublished: false }) })
  const args = { source: 'report', destination: 'out' }
  await assert.rejects(owner.exportFile(sessionId, args, new AbortController().signal,
    { persistChanges: false }), /writable session policy/)
  const result = await owner.exportFile(sessionId, args, new AbortController().signal, writable)
  assert.equal(result.exitCode, 73)
  assert.equal(result.filePublished, false)
  await owner.dispose()
})
