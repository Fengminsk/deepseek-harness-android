/** POSIX uses inherited descriptors; Windows exercises the same socket owner over real TCP. */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { createInterface } from 'node:readline'
import { createServer } from 'node:net'
import test from 'node:test'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/transport.mjs', import.meta.url)

async function launch(t, { descriptor = '3', platform, stdio = false, socket = true, failBeforeConnect = false } = {}) {
  const tcp = process.platform === 'win32' && socket && !stdio
  let server, connected
  if (tcp) {
    server = createServer()
    connected = once(server, 'connection')
    server.listen(0, '127.0.0.1')
    await once(server, 'listening')
  }
  const child = spawn(process.execPath, ['--input-type=module', '-e', `
    ${failBeforeConnect ? "throw new Error('fixture startup failure');" : ''}
    ${platform ? `Object.defineProperty(process, 'platform', { value: ${JSON.stringify(platform)} });` : ''}
    const { createRuntimeTransport, createSocketTransport } = await import(${JSON.stringify(carrier.href)});
    ${tcp ? `
      const { createConnection } = await import('node:net');
      const { once } = await import('node:events');
      const socket = createConnection({ host: '127.0.0.1', port: ${server.address().port} });
      await once(socket, 'connect');
      const ipc = createSocketTransport(socket);
    ` : 'const ipc = createRuntimeTransport();'}
    if (${!stdio}) console.info('["llm-deepseek-account"] fixture model catalogue diagnostic');
    ipc.transport.onRequest(async (method, params) => {
      if (method === 'echo') return params;
      if (method === 'fail') throw new Error('fixture handler failure');
      if (method === 'close') { setImmediate(() => { ipc.close(); ipc.close(); }); return { closed: true }; }
      throw new Error('unexpected fixture method');
    });
    ipc.transport.start();
    ipc.transport.notify('fixture.ready');
  `], {
    env: { ...process.env, DSH_ANDROID_IPC_FD: descriptor === null ? undefined : descriptor },
    stdio: stdio ? ['pipe', 'pipe', 'pipe'] : tcp ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe', 'pipe'],
  })
  let stdout = '', stderr = ''
  child.stdout.on('data', chunk => { stdout += chunk })
  child.stderr.on('data', chunk => { stderr += chunk })
  const exited = once(child, 'exit')
  const frames = [], waits = []
  child.on('exit', (code, signal) => {
    for (const waiter of waits.splice(0)) waiter.reject(new Error(`Fixture exited before its frame: ${code ?? signal}; ${stderr}`))
  })
  let channel, reader
  t.after(async () => {
    child.kill()
    try { await exited } finally {
      reader?.close()
      channel?.destroy()
      if (server) await new Promise(resolve => server.close(resolve))
    }
  })
  channel = stdio ? child.stdin : tcp ? (await Promise.race([
    connected,
    exited.then(([code, signal]) => { throw new Error(`Fixture exited before connection: ${code ?? signal}; ${stderr}`) }),
  ]))[0] : child.stdio[3]
  reader = createInterface({ input: stdio ? child.stdout : channel })
  reader.on('line', line => {
    const frame = JSON.parse(line)
    frames.push(frame)
    for (const waiter of [...waits]) if (waiter.predicate(frame)) {
      waits.splice(waits.indexOf(waiter), 1)
      waiter.resolve(frame)
    }
  })
  return {
    wait: predicate => frames.find(predicate) ?? new Promise((resolve, reject) => waits.push({ predicate, resolve, reject })),
    send: value => channel.write(typeof value === 'string' ? value : JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n'),
    end: () => channel.end(),
    exited, stdout: () => stdout, stderr: () => stderr, frames,
  }
}

test('model catalogue logs stay on stdout while RPC uses only the owned socket', { timeout: 10000 }, async t => {
  const child = await launch(t)
  await child.wait(frame => frame.method === 'fixture.ready')
  child.send({ id: 'echo', method: 'echo', params: { text: '专用双向通道' } })
  assert.deepEqual((await child.wait(frame => frame.id === 'echo')).result, { text: '专用双向通道' })
  child.send({ id: 'fail', method: 'fail' })
  assert.deepEqual((await child.wait(frame => frame.id === 'fail')).error, { code: -32603, message: 'fixture handler failure' })
  child.send({ id: 'close', method: 'close' })
  const [code] = await child.exited
  assert.equal(code, 0, child.stderr())
  assert.match(child.stdout(), /\["llm-deepseek-account"\]/)
  assert.doesNotMatch(child.stdout(), /fixture.ready|专用双向通道|"jsonrpc"/)
  assert.equal(child.stderr(), '')
})

for (const [label, frame, diagnostic] of [
  ['invalid JSON', 'not-json-sensitive-fixture\n', 'malformed JSON'],
  ['array', '["private-array-payload"]\n', 'non-object'],
]) {
  test(`${label} on the dedicated protocol closes it and emits a payload-free diagnostic`, { timeout: 10000 }, async t => {
    const child = await launch(t)
    await child.wait(item => item.method === 'fixture.ready')
    child.send(frame)
    await child.exited
    assert.match(child.stderr(), new RegExp(diagnostic))
    assert.doesNotMatch(child.stderr(), /sensitive-fixture|private-array-payload/)
    assert.equal(child.frames.length, 1)
  })
}

for (const descriptor of ['', '0', '1', '2', '-1', '3.5', ' 3', '2147483648', '9007199254740993']) {
  test(`rejects IPC descriptor ${JSON.stringify(descriptor)} before opening a stream`, { timeout: 10000 }, async t => {
    const child = await launch(t, { descriptor, socket: false })
    const [code] = await child.exited
    assert.notEqual(code, 0)
    assert.match(child.stderr(), /descriptor must be an integer/)
    assert.equal(child.frames.length, 0)
  })
}

test('Android refuses a missing dedicated descriptor', { timeout: 10000 }, async t => {
  const child = await launch(t, { descriptor: null, platform: 'android', socket: false })
  const [code] = await child.exited
  assert.notEqual(code, 0)
  assert.match(child.stderr(), /Android IPC descriptor is missing/)
})

test('ordinary host smoke keeps its explicit stdio carrier', { timeout: 10000 }, async t => {
  const child = await launch(t, { descriptor: null, stdio: true })
  await child.wait(frame => frame.method === 'fixture.ready')
  child.send({ id: 'echo', method: 'echo', params: { host: true } })
  assert.deepEqual((await child.wait(frame => frame.id === 'echo')).result, { host: true })
  child.send({ id: 'close', method: 'close' })
  child.end()
  await child.exited
})

test('truncated dedicated protocol frame reports its error without exposing content', { timeout: 10000 }, async t => {
  const child = await launch(t)
  await child.wait(frame => frame.method === 'fixture.ready')
  child.send('{"private-fixture":')
  child.end()
  await child.exited
  assert.match(child.stderr(), /incomplete frame/)
  assert.doesNotMatch(child.stderr(), /private-fixture/)
})

test('a bad frame cannot dispatch a valid command appended in the same chunk', { timeout: 10000 }, async t => {
  const child = await launch(t)
  await child.wait(frame => frame.method === 'fixture.ready')
  child.send('["invalid"]\n{"jsonrpc":"2.0","id":"must-not-run","method":"echo","params":{}}\n')
  await child.exited
  assert.match(child.stderr(), /non-object/)
  assert.equal(child.frames.some(frame => frame.id === 'must-not-run'), false)
})

test('Windows fixture startup failure still owns and closes its listening socket', {
  timeout: 10000, skip: process.platform !== 'win32',
}, async t => {
  await assert.rejects(launch(t, { failBeforeConnect: true }), /fixture startup failure/)
})
