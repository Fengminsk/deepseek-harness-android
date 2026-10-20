import assert from 'node:assert/strict'
import test from 'node:test'

const { AppStreams } = await import(new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/streams.mjs', import.meta.url))

function fixture(source, maxSubscriptions = 2) {
  const frames = [], waiters = []
  const streams = new AppStreams({ typertGateway: { stream: source } }, { notify(method, frame) {
    assert.equal(method, 'api.stream')
    frames.push(frame)
    for (const waiter of [...waiters]) if (waiter.predicate(frame)) {
      waiters.splice(waiters.indexOf(waiter), 1); waiter.resolve(frame)
    }
  } }, () => ({ principal: { kind: 'owner' } }), { maxSubscriptions: () => maxSubscriptions, maxFrameBytes: () => 1024 })
  const wait = predicate => frames.find(predicate) ?? new Promise(resolve => waiters.push({ predicate, resolve }))
  return { streams, frames, wait }
}
const params = { owner: 'activity-one', subscriptionId: 'watch', namespace: 'fixture', method: 'watch', args: {} }

test('App stream sends only one item until its exact owner acknowledges it', async () => {
  let yielded = 0
  const { streams, frames, wait } = fixture(async function* () {
    yielded++; yield { snapshot: 1 }
    yielded++; yield { snapshot: 2 }
  })
  try {
    await streams.subscribe(params)
    const first = await wait(frame => frame.type === 'item')
    assert.equal(yielded, 1)
    assert.equal(streams.ack({ ...first, owner: 'other' }).accepted, false)
    assert.equal(yielded, 1)
    streams.ack(first)
    const second = await wait(frame => frame.sequence === 2)
    assert.equal(second.value.snapshot, 2)
    streams.ack(first)
    assert.equal(frames.some(frame => frame.type === 'end'), false)
    streams.ack(second)
    await wait(frame => frame.type === 'end')
  } finally { await streams.close() }
})

test('closing an Activity releases its blocked streams but preserves another observer', async () => {
  const closed = []
  const { streams, wait } = fixture(async function* ({ args, signal }) {
    try { yield { owner: args.owner }; await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true })) }
    finally { closed.push(args.owner) }
  })
  await streams.subscribe({ ...params, args: { owner: 'first' } })
  await streams.subscribe({ ...params, owner: 'activity-two', args: { owner: 'second' } })
  await wait(frame => frame.owner === 'activity-two')
  await streams.closeOwner(params.owner)
  assert.deepEqual(closed, ['first'])
  assert.equal(streams.records.size, 1)
  await streams.close()
  assert.deepEqual(closed, ['first', 'second'])
})

test('stream admission limits and non-JSON results report failure without implicit conversion', async () => {
  const { streams, wait } = fixture(async function* () { yield { bytes: new Uint8Array([1]) } }, 1)
  await streams.subscribe(params)
  const error = await wait(frame => frame.type === 'error')
  assert.match(error.error.message, /JSON/)
  await streams.close()
  const blocked = fixture(async function* () { yield 1 }, 1)
  await blocked.streams.subscribe(params)
  await assert.rejects(blocked.streams.subscribe({ ...params, subscriptionId: 'second' }), /limit/)
  await blocked.streams.close()
})
