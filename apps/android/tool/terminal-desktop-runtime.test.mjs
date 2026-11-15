import assert from 'node:assert/strict'
import test from 'node:test'
import { DesktopAppTerminals } from '../runtime/terminal-desktop.mjs'

const SESSION = 'session-1'
const AGENT = 'agent-1'
const TERMINAL = 'terminal-1'
const SHELL_PATH = 'C:/Program Files/PowerShell/7/pwsh.exe'
const noop = () => {}

/** Controller-side `WebTerminalInfo`, the payload the Gateway returns from `terminal.list/create`. */
function controllerInfo(overrides = {}) {
  return {
    id: TERMINAL,
    title: 'pwsh',
    shell: { path: SHELL_PATH, args: [], name: 'pwsh' },
    cwd: 'C:/work',
    cols: 80,
    rows: 24,
    state: 'running',
    exitCode: null,
    ...overrides,
  }
}

/** The App-facing terminal info every facade method returns (local Android `info()` shape). */
function appInfo(overrides = {}) {
  return {
    id: TERMINAL,
    sessionId: SESSION,
    cwd: 'C:/work',
    name: 'pwsh',
    shellId: SHELL_PATH,
    cols: 80,
    rows: 24,
    state: 'running',
    exitCode: null,
    ...overrides,
  }
}

/** A structured Remote failure: exactly what the Gateway throws across the facade. */
function failure(code, message, details) {
  const error = new Error(message)
  error.code = code
  if (details !== undefined) error.details = details
  return error
}

/** A channel the fixture hands the adapter as an AsyncIterable and the test drives frame by frame. */
function createChannel() {
  const items = []
  const waiters = []
  let closed = false
  let channelFailure

  const next = () => {
    if (items.length > 0) return Promise.resolve({ done: false, value: items.shift() })
    if (closed) return channelFailure === undefined
      ? Promise.resolve({ done: true, value: undefined }) : Promise.reject(channelFailure)
    return new Promise((resolve, reject) => waiters.push({ resolve, reject }))
  }
  return {
    push(frame) {
      if (closed) return false
      const waiter = waiters.shift()
      if (waiter === undefined) items.push(frame)
      else waiter.resolve({ done: false, value: frame })
      return true
    },
    end() {
      if (closed) return
      closed = true
      for (const waiter of waiters.splice(0)) waiter.resolve({ done: true, value: undefined })
    },
    fail(error) {
      if (closed) return
      closed = true
      channelFailure = error
      for (const waiter of waiters.splice(0)) waiter.reject(error)
    },
    iterable() {
      const channel = this
      return {
        [Symbol.asyncIterator]: () => ({
          next,
          return() { channel.end(); return Promise.resolve({ done: true, value: undefined }) },
          throw(error) { channel.fail(error); return Promise.reject(error) },
        }),
      }
    },
    get closed() { return closed },
  }
}

/** Fakes `ctx.typertGateway.invoke`/`stream` and `sessionController.resolveAgent`. */
function createHost(options = {}) {
  const state = {
    available: options.available ?? true,
    autorespondRetain: options.autorespondRetain ?? true,
    agentCalls: [],
    invokes: [],
    streams: [],
    claimWaiters: [],
    handlers: new Map(),
    onStream: options.onStream,
  }
  state.resolveAgent = options.resolveAgent ?? (async (sessionId) => {
    state.agentCalls.push(sessionId)
    return { agent: { id: AGENT } }
  })

  const invoke = async (namespace, method, args, signal) => {
    const call = { namespace, method, args, signal }
    state.invokes.push(call)
    const handler = state.handlers.get(`${namespace}/${method}`)
    if (handler === undefined) return undefined
    return handler(call, state)
  }

  const stream = async (request) => {
    const refused = typeof options.streamFailure === 'function' ? options.streamFailure(request) : undefined
    if (refused !== undefined) throw refused
    const channel = createChannel()
    const entry = { request, channel, commands: [], consumer: undefined, claimed: false }
    state.streams.push(entry)
    if (request.signal !== undefined) {
      request.signal.addEventListener('abort', () => {
        channel.fail(request.signal.reason ?? new Error('gateway stream aborted'))
      }, { once: true })
    }
    if (request.uplink !== undefined) {
      entry.consumer = (async () => {
        try {
          for await (const command of request.uplink) entry.commands.push(command)
        } catch {
          // Attachment teardown ends the uplink; the consumer has nothing left to record.
        }
      })()
    }
    if (request.method === 'retain' && state.autorespondRetain) channel.push({ type: 'retained' })
    state.onStream?.(entry, state)
    for (const waiter of [...state.claimWaiters]) {
      if (waiter.method !== request.method) continue
      state.claimWaiters.splice(state.claimWaiters.indexOf(waiter), 1)
      entry.claimed = true
      waiter.resolve(entry)
    }
    return channel.iterable()
  }

  const terminals = new DesktopAppTerminals({
    available: () => state.available,
    resolveAgent: sessionId => state.resolveAgent(sessionId),
    invoke,
    stream,
  })
  return { terminals, state }
}

function inflight(promise) {
  promise.catch(noop)
  return promise
}

function claimStream(state, method) {
  const existing = state.streams.find(entry => !entry.claimed && entry.request.method === method)
  if (existing !== undefined) {
    existing.claimed = true
    return Promise.resolve(existing)
  }
  return new Promise(resolve => state.claimWaiters.push({ method, resolve }))
}

/** Claim the next stream of `method`, failing the test instead of hanging when it never opens. */
async function claimWithin(state, method) {
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`gateway stream "${method}" was never requested`)), 2000)
  })
  try {
    return await Promise.race([claimStream(state, method), timeout])
  } finally {
    clearTimeout(timer)
  }
}

async function flush() {
  await new Promise(resolve => setImmediate(resolve))
}

async function eventually(predicate, message) {
  for (let attempt = 0; attempt < 500; attempt++) {
    if (predicate()) return
    await flush()
  }
  assert.fail(message)
}

async function readEventually(terminals, params, predicate) {
  let last
  for (let attempt = 0; attempt < 500; attempt++) {
    last = await terminals.read(params)
    if (predicate(last)) return last
    await flush()
  }
  assert.fail(`terminal.read never reached the expected state: ${JSON.stringify(last)?.slice(0, 400)}`)
}

function snapshot(screen = 'ready', info = controllerInfo(), writable = true) {
  return { type: 'snapshot', sequence: 1, screen, info, writable }
}

/**
 * Create `TERMINAL`, attach it and install an initial snapshot screen.
 * @returns the host fixture plus the retain/attach stream entries the test keeps driving.
 */
async function attachTerminal(options = {}) {
  const { terminals, state } = createHost(options)
  state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  const retainClaim = claimWithin(state, 'retain')
  const created = await terminals.create({ sessionId: SESSION, id: TERMINAL })
  const retain = await retainClaim
  const attachClaim = claimWithin(state, 'attach')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const attach = await attachClaim
  attach.channel.push(options.snapshot ?? snapshot())
  const initial = await reading
  return { terminals, state, created, retain, attach, initial }
}

async function settle(terminals) {
  try { await terminals.dispose() } catch { /* disposal failures are asserted by the tests that care. */ }
}

test('a host without terminal-controller rejects every terminal method before touching the gateway', async () => {
  const { terminals, state } = createHost({ available: false })
  const calls = [
    () => terminals.list({ sessionId: SESSION }),
    () => terminals.shells({ sessionId: SESSION }),
    () => terminals.create({ sessionId: SESSION, id: TERMINAL }),
    () => terminals.read({ sessionId: SESSION, id: TERMINAL }),
    () => terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'x' }),
    () => terminals.resize({ sessionId: SESSION, id: TERMINAL, cols: 100, rows: 30 }),
    () => terminals.rename({ sessionId: SESSION, id: TERMINAL, name: 'shell' }),
    () => terminals.close({ sessionId: SESSION, id: TERMINAL }),
  ]
  for (const call of calls) {
    await assert.rejects(call, (error) => {
      assert.equal(error.code, 'terminal/unavailable')
      assert.equal(error.details, undefined)
      return true
    })
  }
  assert.deepEqual(state.invokes, [])
  assert.deepEqual(state.streams, [])
  await settle(terminals)
})

test('the facade mirrors the local Android request/response contract for all eight methods', async () => {
  const { terminals, state } = createHost()
  state.handlers.set('terminal/list', () => [controllerInfo()])
  state.handlers.set('terminal/shells', () => [{ path: SHELL_PATH, args: [], name: 'pwsh' }])
  state.handlers.set('terminal/create', ({ args }) => controllerInfo({
    id: args.request.id, cols: args.request.cols, rows: args.request.rows,
  }))
  state.handlers.set('terminal/rename', () => undefined)
  state.handlers.set('terminal/close', () => undefined)

  const list = await terminals.list({ sessionId: SESSION })
  assert.deepEqual(list, [appInfo()])
  assert.deepEqual(state.invokes.at(-1).args, { sessionId: SESSION })
  assert.deepEqual(state.agentCalls, [], 'list answers a cold Session without resolving its Agent')

  const shells = await terminals.shells({ sessionId: SESSION })
  assert.deepEqual(shells, [{ id: SHELL_PATH, label: 'pwsh' }])
  assert.deepEqual(state.invokes.at(-1).args, { agentId: AGENT })
  assert.deepEqual(state.agentCalls, [SESSION])

  const retainClaim = claimWithin(state, 'retain')
  const created = await terminals.create({ sessionId: SESSION, id: TERMINAL })
  assert.deepEqual(created, appInfo())
  assert.deepEqual(state.invokes.at(-1).args, { agentId: AGENT, request: { id: TERMINAL, cols: 80, rows: 24 } })
  const retain = await retainClaim
  assert.equal(retain.request.namespace, 'terminal')
  assert.equal(retain.request.method, 'retain')
  assert.deepEqual(retain.request.args, { sessionId: SESSION, id: TERMINAL })
  assert.ok(retain.request.signal instanceof AbortSignal)

  const attachClaim = claimWithin(state, 'attach')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const attach = await attachClaim
  assert.equal(attach.request.namespace, 'terminal')
  assert.equal(attach.request.method, 'attach')
  assert.deepEqual(attach.request.args, { agentId: AGENT, id: TERMINAL })
  assert.ok(attach.request.signal instanceof AbortSignal)
  assert.ok(attach.request.uplink !== undefined, 'attach carries the input uplink')
  attach.channel.push({ type: 'snapshot', sequence: 1, screen: 'ready', info: controllerInfo(), writable: true })
  const read = await reading
  assert.deepEqual(Object.keys(read).sort(), [
    'cols', 'cwd', 'display', 'exitCode', 'id', 'name', 'revision', 'rows',
    'screen', 'sessionId', 'shellId', 'state', 'view',
  ])
  assert.equal(read.id, TERMINAL)
  assert.equal(read.sessionId, SESSION)
  assert.equal(read.cwd, 'C:/work')
  assert.equal(read.name, 'pwsh')
  assert.equal(read.shellId, SHELL_PATH)
  assert.equal(read.cols, 80)
  assert.equal(read.rows, 24)
  assert.equal(read.state, 'running')
  assert.equal(read.exitCode, null)
  assert.ok(Number.isSafeInteger(read.revision) && read.revision >= 1)
  assert.match(read.screen, /ready/u)
  assert.equal(read.display.trimEnd(), 'ready')
  assert.equal(read.view.cols, 80)
  assert.equal(read.view.rows, 24)
  assert.ok(Array.isArray(read.view.lines))
  assert.equal(JSON.stringify(read.view).includes('\x1b'), false, 'view never exposes raw VT controls')

  const write = inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'echo hi\r' }))
  await eventually(() => attach.commands.length === 1, 'write command was never delivered')
  assert.deepEqual(attach.commands[0], { type: 'write', sequence: 1, data: 'echo hi\r' })
  attach.channel.push({ type: 'ack', sequence: 1 })
  assert.deepEqual(await write, { accepted: true })

  const resize = inflight(terminals.resize({ sessionId: SESSION, id: TERMINAL, cols: 120, rows: 40 }))
  await eventually(() => attach.commands.length === 2, 'resize command was never delivered')
  assert.deepEqual(attach.commands[1], { type: 'resize', sequence: 2, cols: 120, rows: 40 })
  attach.channel.push({ type: 'state', info: controllerInfo({ cols: 120, rows: 40 }), writable: true })
  attach.channel.push({ type: 'ack', sequence: 2 })
  assert.deepEqual(await resize, appInfo({ cols: 120, rows: 40 }))
  const resized = await readEventually(terminals, { sessionId: SESSION, id: TERMINAL },
    result => result.view.cols === 120 && result.view.rows === 40)
  assert.equal(resized.cols, 120)

  const renamed = await terminals.rename({ sessionId: SESSION, id: TERMINAL, name: 'Build shell' })
  assert.deepEqual(renamed, appInfo({ name: 'Build shell', cols: 120, rows: 40 }))
  assert.deepEqual(state.invokes.at(-1).args, { agentId: AGENT, id: TERMINAL, title: 'Build shell' })

  const closed = await terminals.close({ sessionId: SESSION, id: TERMINAL })
  assert.deepEqual(closed, { closed: true })
  assert.deepEqual(state.invokes.at(-1).args, { agentId: AGENT, id: TERMINAL })
  assert.equal(attach.request.signal.aborted, true)
  assert.equal(retain.request.signal.aborted, true)
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 0 })

  const explicitClaim = claimWithin(state, 'retain')
  const second = await terminals.create({ sessionId: SESSION, id: 'terminal-2', cols: 100, rows: 30, shellId: SHELL_PATH })
  assert.deepEqual(second, appInfo({ id: 'terminal-2', cols: 100, rows: 30 }))
  assert.deepEqual(state.invokes.at(-1).args, {
    agentId: AGENT, request: { id: 'terminal-2', cols: 100, rows: 30, shellPath: SHELL_PATH },
  })
  await explicitClaim
  await settle(terminals)
})

test('snapshot installs the screen, output appends, state frames update info and writability', async () => {
  const { terminals, state, attach, initial } = await attachTerminal({ snapshot: snapshot('A\x1b[1;31mB\x1b[0mC') })
  assert.equal(initial.display.trimEnd(), 'ABC')
  const styled = initial.view.lines[0].runs.find(run => run.text === 'B')
  assert.equal(styled.bold, true)
  assert.equal(styled.fg, 1)
  const firstRevision = initial.revision

  attach.channel.push({ type: 'output', sequence: 2, data: 'D' })
  const appended = await readEventually(terminals, { sessionId: SESSION, id: TERMINAL },
    result => result.revision > firstRevision)
  assert.equal(appended.display.trimEnd(), 'ABCD')
  assert.equal(appended.view.lines[0].runs.map(run => run.text).join(''), 'ABCD ')

  attach.channel.push({
    type: 'state',
    info: controllerInfo({ title: 'renamed-by-desktop', state: 'exited', exitCode: 0, error: 'pty died' }),
    writable: false,
  })
  const exited = await readEventually(terminals, { sessionId: SESSION, id: TERMINAL }, result => result.state === 'exited')
  assert.equal(exited.name, 'renamed-by-desktop')
  assert.equal(exited.exitCode, 0)
  assert.equal(exited.error, 'pty died')
  assert.ok(exited.revision > appended.revision)

  await assert.rejects(
    terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'x' }),
    (error) => {
      assert.equal(error.code, 'terminal/control-unavailable')
      assert.deepEqual(error.details, { reason: 'not-running' })
      return true
    })
  assert.equal(attach.commands.length, 0, 'refused input never reaches the uplink')
  await settle(terminals)
})

test('a live attachment is reused by later reads instead of opening another attach stream', async () => {
  const { terminals, state } = await attachTerminal()
  const attachStreams = () => state.streams.filter(entry => entry.request.method === 'attach')
  assert.equal(attachStreams().length, 1)
  await terminals.read({ sessionId: SESSION, id: TERMINAL })
  await terminals.read({ sessionId: SESSION, id: TERMINAL })
  assert.equal(attachStreams().length, 1)
  assert.equal(state.streams.filter(entry => entry.request.method === 'retain').length, 1)
  await settle(terminals)
})

test('ack frames settle writes by sequence; refusals map to terminal/control-unavailable', async () => {
  const { terminals, attach } = await attachTerminal()

  const accepted = inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'a' }))
  await eventually(() => attach.commands.length === 1, 'first write command was never delivered')
  attach.channel.push({ type: 'ack', sequence: 1 })
  assert.deepEqual(await accepted, { accepted: true })

  const readOnly = inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'b' }))
  await eventually(() => attach.commands.length === 2, 'second write command was never delivered')
  attach.channel.push({ type: 'ack', sequence: 2, refusal: 'read-only' })
  await assert.rejects(readOnly, (error) => {
    assert.equal(error.code, 'terminal/control-unavailable')
    assert.deepEqual(error.details, { reason: 'read-only' })
    return true
  })

  const notRunning = inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'c' }))
  await eventually(() => attach.commands.length === 3, 'third write command was never delivered')
  attach.channel.push({ type: 'ack', sequence: 3, refusal: 'not-running' })
  await assert.rejects(notRunning, (error) => {
    assert.equal(error.code, 'terminal/control-unavailable')
    assert.deepEqual(error.details, { reason: 'not-running' })
    return true
  })

  assert.deepEqual(attach.commands.map(command => command.sequence), [1, 2, 3])
  await settle(terminals)
})

test('an unacknowledged write times out with gateway/timeout', async (t) => {
  const { terminals, attach } = await attachTerminal()
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const writing = inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'late' }))
  await eventually(() => attach.commands.length === 1, 'write command was never delivered')
  t.mock.timers.tick(5000)
  await assert.rejects(writing, (error) => {
    assert.equal(error.code, 'gateway/timeout')
    return true
  })
  assert.deepEqual(attach.commands[0], { type: 'write', sequence: 1, data: 'late' })
  await settle(terminals)
})

test('read-only attachments refuse input before it enters the uplink', async () => {
  const { terminals, attach } = await attachTerminal({ snapshot: snapshot('ready', controllerInfo(), false) })
  await assert.rejects(
    terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'x' }),
    (error) => {
      assert.equal(error.code, 'terminal/control-unavailable')
      assert.deepEqual(error.details, { reason: 'read-only' })
      return true
    })
  assert.equal(attach.commands.length, 0)
  await settle(terminals)
})

test('detachAll releases attach and retain streams, fails pending writes and keeps the terminal', async () => {
  const { terminals, state, retain, attach } = await attachTerminal()
  const writing = inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'unconfirmed' }))
  await eventually(() => attach.commands.length === 1, 'write command was never delivered')
  const resizing = inflight(terminals.resize({ sessionId: SESSION, id: TERMINAL, cols: 100, rows: 30 }))
  await eventually(() => attach.commands.length === 2, 'resize command was never delivered')

  terminals.detachAll()

  await assert.rejects(writing, (error) => {
    assert.equal(error.code, 'gateway/cancelled')
    return true
  })
  await assert.rejects(resizing, (error) => {
    assert.equal(error.code, 'gateway/cancelled')
    return true
  })
  assert.equal(attach.request.signal.aborted, true)
  assert.equal(retain.request.signal.aborted, true)
  assert.equal(state.invokes.some(call => call.method === 'close'), false, 'detachAll never ends the process')
  assert.deepEqual(terminals.activitySnapshot(), { live: 1, pending: 0 })

  await flush()
  const reconnectRetain = claimWithin(state, 'retain')
  const reconnectAttach = claimWithin(state, 'attach')
  const recovering = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const secondAttach = await reconnectAttach
  await reconnectRetain
  secondAttach.channel.push(snapshot('recovered'))
  const recovered = await recovering
  assert.equal(recovered.display.trimEnd(), 'recovered')
  assert.match(recovered.screen, /recovered/u)
  await settle(terminals)
})

test('the retain hold is opened once per page and re-opened after a disconnect', async () => {
  const { terminals, state, retain } = await attachTerminal()
  assert.deepEqual(retain.request.args, { sessionId: SESSION, id: TERMINAL })
  await terminals.read({ sessionId: SESSION, id: TERMINAL })
  assert.equal(state.streams.filter(entry => entry.request.method === 'retain').length, 1,
    'an open page keeps exactly one retain hold')

  terminals.detachAll()
  await eventually(() => retain.request.signal.aborted, 'detachAll did not abort the retain hold')

  const reconnectRetain = claimWithin(state, 'retain')
  const reconnectAttach = claimWithin(state, 'attach')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const secondAttach = await reconnectAttach
  const secondRetain = await reconnectRetain
  assert.notEqual(secondRetain, retain)
  secondAttach.channel.push(snapshot('again'))
  assert.equal((await reading).display.trimEnd(), 'again')
  assert.equal(state.streams.filter(entry => entry.request.method === 'retain').length, 2)
  await settle(terminals)
})

test('a retain stream that ends without acknowledgement fails the read and forgets the record', async () => {
  const { terminals, state } = createHost({ autorespondRetain: false })
  state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  await terminals.create({ sessionId: SESSION, id: TERMINAL })
  const retain = await claimWithin(state, 'retain')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  retain.channel.end()
  await assert.rejects(reading, (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    return true
  })
  assert.equal(state.streams.filter(entry => entry.request.method === 'attach').length, 0)
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 0 })
  await settle(terminals)
})

test('a retain refusal with a structured Remote code is preserved', async () => {
  const { terminals, state } = createHost({ autorespondRetain: false })
  state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  await terminals.create({ sessionId: SESSION, id: TERMINAL })
  const retain = await claimWithin(state, 'retain')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  retain.channel.fail(failure('terminal/unavailable', 'Terminal is closing or unavailable', {}))
  await assert.rejects(reading, (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    assert.equal(error.message, 'Terminal is closing or unavailable')
    return true
  })
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 0 })
  await settle(terminals)
})

test('an attach failure before the snapshot forgets the record and the next read recovers', async () => {
  const { terminals, state } = createHost()
  state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  await terminals.create({ sessionId: SESSION, id: TERMINAL })
  await claimWithin(state, 'retain')
  const firstAttachClaim = claimWithin(state, 'attach')
  const failing = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const firstAttach = await firstAttachClaim
  firstAttach.channel.fail(failure('terminal/unavailable', 'Terminal no longer exists in this Session', {}))
  await assert.rejects(failing, (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    assert.equal(error.message, 'Terminal no longer exists in this Session')
    return true
  })
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 0 })

  const retainClaim = claimWithin(state, 'retain')
  const attachClaim = claimWithin(state, 'attach')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const attach = await attachClaim
  await retainClaim
  attach.channel.push(snapshot('second life'))
  const recovered = await reading
  assert.equal(recovered.display.trimEnd(), 'second life')
  assert.equal(state.streams.filter(entry => entry.request.method === 'attach').length, 2)
  await settle(terminals)
})

test('a snapshot that never arrives times out the read with gateway/timeout', async (t) => {
  const { terminals, state } = createHost()
  state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  await terminals.create({ sessionId: SESSION, id: TERMINAL })
  await claimWithin(state, 'retain')
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  await claimWithin(state, 'attach')
  t.mock.timers.tick(15000)
  await assert.rejects(reading, (error) => {
    assert.equal(error.code, 'gateway/timeout')
    return true
  })
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 0 })
  await settle(terminals)
})

test('the per-Session terminal limit surfaces as terminal/limit-reached with details.limit', async () => {
  const { terminals, state } = createHost()
  let created = 0
  state.handlers.set('terminal/create', ({ args }) => {
    if (created >= 8) throw failure('terminal/limit-reached', 'Session terminal limit reached', { limit: 8 })
    created++
    return controllerInfo({ id: args.request.id })
  })
  for (let index = 1; index <= 8; index++) {
    await terminals.create({ sessionId: SESSION, id: `terminal-${index}` })
  }
  assert.equal(terminals.activitySnapshot().live, 8)
  await assert.rejects(
    terminals.create({ sessionId: SESSION, id: 'terminal-9' }),
    (error) => {
      assert.equal(error.code, 'terminal/limit-reached')
      assert.deepEqual(error.details, { limit: 8 })
      return true
    })
  assert.equal(terminals.activitySnapshot().live, 8, 'a refused create allocates nothing')
  await settle(terminals)
})

test('activitySnapshot reports in-flight creates for safe host replacement', async () => {
  const { terminals, state } = createHost()
  const gate = Promise.withResolvers()
  state.handlers.set('terminal/create', async ({ args }) => {
    await gate.promise
    return controllerInfo({ id: args.request.id })
  })
  const creating = inflight(terminals.create({ sessionId: SESSION, id: TERMINAL }))
  await eventually(() => state.invokes.some(call => call.method === 'create'), 'create was never invoked')
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 1 })
  gate.resolve()
  await creating
  assert.deepEqual(terminals.activitySnapshot(), { live: 1, pending: 0 })
  await settle(terminals)
})

test('structured Gateway failures keep their code and details', async () => {
  const { terminals, state } = createHost()
  state.handlers.set('terminal/list', () => {
    throw failure('gateway/not-found', 'Session does not exist', { sessionId: 'missing' })
  })
  await assert.rejects(terminals.list({ sessionId: SESSION }), (error) => {
    assert.equal(error.code, 'gateway/not-found')
    assert.deepEqual(error.details, { sessionId: 'missing' })
    return true
  })

  const unresolved = createHost({ resolveAgent: async () => ({ error: failure('session/not-found', 'Session does not exist', { sessionId: 'missing' }) }) })
  await assert.rejects(unresolved.terminals.shells({ sessionId: SESSION }), (error) => {
    assert.equal(error.code, 'gateway/not-found')
    assert.deepEqual(error.details, { sessionId: 'missing' })
    return true
  })
  await settle(unresolved.terminals)

  const typing = createHost({ resolveAgent: async () => { throw new TypeError('Invalid session') } })
  await assert.rejects(typing.terminals.create({ sessionId: SESSION, id: TERMINAL }), (error) => {
    assert.equal(error.code, 'gateway/bad-request')
    return true
  })
  await settle(typing.terminals)

  const crashing = createHost({ resolveAgent: async () => { throw new Error('resume exploded') } })
  await assert.rejects(crashing.terminals.create({ sessionId: SESSION, id: TERMINAL }), (error) => {
    assert.equal(error.code, 'gateway/internal')
    assert.match(error.message, /resume exploded/u)
    return true
  })
  await settle(crashing.terminals)
  await settle(terminals)
})

test('parameter validation fails with gateway/bad-request before any gateway traffic', async () => {
  const { terminals, state } = createHost()
  const cases = {
    'list without sessionId': () => terminals.list({}),
    'invalid sessionId': () => terminals.list({ sessionId: 'bad/session' }),
    'create with invalid id': () => terminals.create({ sessionId: SESSION, id: 'bad id' }),
    'create with tiny dimensions': () => terminals.create({ sessionId: SESSION, id: TERMINAL, cols: 1, rows: 24 }),
    'create with huge dimensions': () => terminals.create({ sessionId: SESSION, id: TERMINAL, cols: 80, rows: 201 }),
    'create with fractional dimensions': () => terminals.create({ sessionId: SESSION, id: TERMINAL, cols: 80.5, rows: 24 }),
    'create with empty shellId': () => terminals.create({ sessionId: SESSION, id: TERMINAL, shellId: '' }),
    'create with oversized shellId': () => terminals.create({ sessionId: SESSION, id: TERMINAL, shellId: 'x'.repeat(4097) }),
    'read with invalid id': () => terminals.read({ sessionId: SESSION, id: '' }),
    'write without data': () => terminals.write({ sessionId: SESSION, id: TERMINAL }),
    'write with non-string data': () => terminals.write({ sessionId: SESSION, id: TERMINAL, data: 7 }),
    'write over 64 KiB': () => terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'x'.repeat(65537) }),
    'write with invalid id': () => terminals.write({ sessionId: SESSION, id: 'bad id', data: 'x' }),
    'resize out of range': () => terminals.resize({ sessionId: SESSION, id: TERMINAL, cols: 500, rows: 0 }),
    'rename with empty name': () => terminals.rename({ sessionId: SESSION, id: TERMINAL, name: '' }),
    'rename with leading space': () => terminals.rename({ sessionId: SESSION, id: TERMINAL, name: ' shell' }),
    'rename with trailing space': () => terminals.rename({ sessionId: SESSION, id: TERMINAL, name: 'shell ' }),
    'rename with control characters': () => terminals.rename({ sessionId: SESSION, id: TERMINAL, name: 'sh\x07ell' }),
    'rename with 65 graphemes': () => terminals.rename({ sessionId: SESSION, id: TERMINAL, name: 'x'.repeat(65) }),
    'close with invalid sessionId': () => terminals.close({ sessionId: '', id: TERMINAL }),
    'shells with invalid sessionId': () => terminals.shells({ sessionId: 'bad session' }),
  }
  for (const [label, call] of Object.entries(cases)) {
    await assert.rejects(call(), (error) => {
      assert.equal(error.code, 'gateway/bad-request', label)
      return true
    })
  }
  assert.deepEqual(state.invokes, [])
  assert.deepEqual(state.streams, [])
  await settle(terminals)
})

test('rename without a local record falls back to the controller list', async () => {
  const { terminals, state } = createHost()
  let title = 'old title'
  state.handlers.set('terminal/rename', () => { title = 'new title' })
  state.handlers.set('terminal/list', () => [controllerInfo({ title })])
  const renamed = await terminals.rename({ sessionId: SESSION, id: TERMINAL, name: 'new title' })
  assert.deepEqual(renamed, appInfo({ name: 'new title' }))

  state.handlers.set('terminal/list', () => [])
  await assert.rejects(terminals.rename({ sessionId: SESSION, id: 'missing', name: 'x' }), (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    return true
  })
  await settle(terminals)
})

test('dispose releases every attachment and hold and refuses later calls', async () => {
  const { terminals, state, retain, attach } = await attachTerminal()
  const writing = inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: 'pending' }))
  await eventually(() => attach.commands.length === 1, 'write command was never delivered')
  await terminals.dispose()
  await assert.rejects(writing, (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    return true
  })
  assert.equal(attach.request.signal.aborted, true)
  assert.equal(retain.request.signal.aborted, true)
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 0 })
  await assert.rejects(terminals.list({ sessionId: SESSION }), (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    return true
  })
  await terminals.dispose()
  assert.equal(state.invokes.some(call => call.method === 'close'), false, 'dispose never ends host terminals')
})

test('resize acknowledgements are settled by sequence and refusals map to terminal/control-unavailable', async () => {
  const { terminals, attach } = await attachTerminal()
  const refused = inflight(terminals.resize({ sessionId: SESSION, id: TERMINAL, cols: 100, rows: 30 }))
  await eventually(() => attach.commands.length === 1, 'resize command was never delivered')
  attach.channel.push({ type: 'ack', sequence: 1, refusal: 'read-only' })
  await assert.rejects(refused, (error) => {
    assert.equal(error.code, 'terminal/control-unavailable')
    assert.deepEqual(error.details, { reason: 'read-only' })
    return true
  })
  await settle(terminals)
})

test('resize projects the acknowledged dimensions even without a state broadcast', async () => {
  const { terminals, attach } = await attachTerminal()
  const resizing = inflight(terminals.resize({ sessionId: SESSION, id: TERMINAL, cols: 100, rows: 30 }))
  await eventually(() => attach.commands.length === 1, 'resize command was never delivered')
  attach.channel.push({ type: 'ack', sequence: 1 })
  assert.deepEqual(await resizing, appInfo({ cols: 100, rows: 30 }))
  const read = await terminals.read({ sessionId: SESSION, id: TERMINAL })
  assert.equal(read.cols, 100)
  assert.equal(read.rows, 30)
  assert.equal(read.view.cols, 100)
  assert.equal(read.view.rows, 30)
  await settle(terminals)
})

test('a repeated create for the same identity reuses the controller terminal and its hold', async () => {
  const { terminals, state } = createHost()
  state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  const first = await terminals.create({ sessionId: SESSION, id: TERMINAL })
  await claimWithin(state, 'retain')
  const second = await terminals.create({ sessionId: SESSION, id: TERMINAL })
  assert.deepEqual(first, second)
  assert.equal(state.streams.filter(entry => entry.request.method === 'retain').length, 1)
  assert.equal(terminals.activitySnapshot().live, 1)
  await settle(terminals)
})

test('read opens the retain hold before the attach stream for a terminal that was never created locally', async () => {
  const { terminals, state } = createHost()
  const retainClaim = claimWithin(state, 'retain')
  const attachClaim = claimWithin(state, 'attach')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const attach = await attachClaim
  const retain = await retainClaim
  assert.ok(state.streams.indexOf(retain) < state.streams.indexOf(attach),
    'the page is retained before the attachment starts')
  attach.channel.push(snapshot('read-only attach'))
  assert.equal((await reading).display.trimEnd(), 'read-only attach')
  await settle(terminals)
})

test('pending input above the controller buffer ceiling is refused before it reaches the uplink', async () => {
  const { terminals, attach } = await attachTerminal()
  const chunk = 'x'.repeat(65536)
  const writes = []
  for (let index = 0; index < 32; index++) {
    writes.push(inflight(terminals.write({ sessionId: SESSION, id: TERMINAL, data: chunk })))
  }
  await eventually(() => attach.commands.length === 32, 'unacknowledged writes were not all delivered')
  await assert.rejects(terminals.write({ sessionId: SESSION, id: TERMINAL, data: chunk }), (error) => {
    assert.equal(error.code, 'gateway/bad-request')
    return true
  })
  assert.equal(attach.commands.length, 32)
  assert.equal(attach.commands.every((command, index) => command.sequence === index + 1), true)
  await settle(terminals)
})

test('a stream that fails before iteration keeps its structured code', async () => {
  const retainRefused = createHost({
    autorespondRetain: false,
    streamFailure: request => request.method === 'retain'
      ? failure('terminal/unavailable', 'Terminal is closing or unavailable', {}) : undefined,
  })
  retainRefused.state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  await retainRefused.terminals.create({ sessionId: SESSION, id: TERMINAL })
  await assert.rejects(retainRefused.terminals.read({ sessionId: SESSION, id: TERMINAL }), (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    assert.equal(error.message, 'Terminal is closing or unavailable')
    return true
  })
  await settle(retainRefused.terminals)

  const attachRefused = createHost({
    streamFailure: request => request.method === 'attach'
      ? failure('terminal/unavailable', 'Terminal attachment requires a Remote invocation', {}) : undefined,
  })
  attachRefused.state.handlers.set('terminal/create', ({ args }) => controllerInfo({ id: args.request.id }))
  await attachRefused.terminals.create({ sessionId: SESSION, id: TERMINAL })
  await assert.rejects(attachRefused.terminals.read({ sessionId: SESSION, id: TERMINAL }), (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    assert.equal(error.message, 'Terminal attachment requires a Remote invocation')
    return true
  })
  assert.deepEqual(attachRefused.terminals.activitySnapshot(), { live: 0, pending: 0 })
  await settle(attachRefused.terminals)
})

test('a read issued right after detachAll opens a fresh retain hold', async () => {
  const { terminals, state, retain } = await attachTerminal()
  terminals.detachAll()
  const retainClaim = claimWithin(state, 'retain')
  const attachClaim = claimWithin(state, 'attach')
  const reading = inflight(terminals.read({ sessionId: SESSION, id: TERMINAL }))
  const freshRetain = await retainClaim
  const attach = await attachClaim
  assert.notEqual(freshRetain, retain)
  attach.channel.push(snapshot('fresh hold'))
  assert.equal((await reading).display.trimEnd(), 'fresh hold')
  await settle(terminals)
})

test('dispose waits for an in-flight create and releases what it opened', async () => {
  const { terminals, state } = createHost()
  const gate = Promise.withResolvers()
  state.handlers.set('terminal/create', async ({ args }) => {
    await gate.promise
    return controllerInfo({ id: args.request.id })
  })
  const creating = inflight(terminals.create({ sessionId: SESSION, id: TERMINAL }))
  await eventually(() => state.invokes.some(call => call.method === 'create'), 'create was never invoked')
  const disposing = terminals.dispose()
  gate.resolve()
  await assert.rejects(creating, (error) => {
    assert.equal(error.code, 'terminal/unavailable')
    return true
  })
  await disposing
  assert.deepEqual(terminals.activitySnapshot(), { live: 0, pending: 0 })
  const holds = state.streams.filter(entry => entry.request.method === 'retain')
  assert.equal(holds.every(entry => entry.request.signal.aborted), true, 'no retain hold survives dispose')
})

test('a create that lands after detachAll does not keep the terminal retained', async () => {
  const { terminals, state } = createHost()
  const gate = Promise.withResolvers()
  state.handlers.set('terminal/create', async ({ args }) => {
    await gate.promise
    return controllerInfo({ id: args.request.id })
  })
  const creating = inflight(terminals.create({ sessionId: SESSION, id: TERMINAL }))
  await eventually(() => state.invokes.some(call => call.method === 'create'), 'create was never invoked')
  terminals.detachAll()
  gate.resolve()
  assert.deepEqual(await creating, appInfo())
  assert.equal(state.streams.filter(entry => entry.request.method === 'retain').length, 0,
    'a detached connection must not leave a retain hold preventing idle reclamation')
  assert.deepEqual(terminals.activitySnapshot(), { live: 1, pending: 0 })
  await settle(terminals)
})

test('read responses stay bounded when the scrollback is much larger than the view', async () => {
  const { terminals, attach } = await attachTerminal()
  const output = Array.from({ length: 600 }, (_, index) => `line-${String(index).padStart(3, '0')}`).join('\r\n')
  attach.channel.push({ type: 'output', sequence: 2, data: output })
  const read = await readEventually(terminals, { sessionId: SESSION, id: TERMINAL },
    result => result.display.includes('line-599'))
  assert.ok(read.view.lines.length <= 500, `view kept ${read.view.lines.length} lines`)
  assert.equal(read.view.truncated, true)
  await settle(terminals)
})
