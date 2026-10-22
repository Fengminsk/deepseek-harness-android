import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { registerHooks } from 'node:module'

const staged = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/', import.meta.url)
const carrier = new URL('index.mjs', staged).href
const sessions = new URL('sessions.mjs', staged).href
const origin = process.env.POCKET_CONTEXT_MODEL_ORIGIN
const originalFetch = globalThis.fetch
const notify = (method, params) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n')
let fixture

globalThis.fetch = (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url)
  if (url.origin !== origin) {
    notify('fixture.unexpectedNetwork')
    return Promise.reject(new Error('Portable context fixture permits only its loopback model'))
  }
  return originalFetch(input, init)
}

// The shipped profile and original context/job plugins stay intact. This fixture
// adds only host inspection and a deferred producer to the existing jobs seam.
registerHooks({
  load(url, context, nextLoad) {
    if (url === sessions) return { format: 'module', shortCircuit: true,
      source: readFileSync(new URL('../runtime/sessions.mjs', import.meta.url)) }
    const result = nextLoad(url, context)
    if (url !== carrier) return result
    let source = result.source.toString()
    const entry = 'export function apply(ctx, config)', dispatch = 'transport.onRequest(async (method, params) => {'
    assert.ok(source.includes(entry) && source.includes(dispatch), 'Staged Android carrier fixture seam changed')
    source = source.replace(entry, 'function applyStagedRuntime(ctx, config)').replace(dispatch,
      dispatch + "\nif (method.startsWith('fixture.')) return portableContextFixtureCall(method, params);")
    return { ...result, source: source + `
import { preparePortableContextFixture, portableContextFixtureCall } from ${JSON.stringify(import.meta.url)}
export function apply(ctx, config) {
  applyStagedRuntime(ctx, config)
  ctx.inject(['jobs', 'agents', 'tools'], scope => preparePortableContextFixture(scope))
}
` }
  },
})

export function preparePortableContextFixture(ctx) {
  fixture = { ctx, producers: new Map(), closed: false }
  const owned = fixture
  ctx.effect(() => async () => {
    owned.closed = true
    for (const producer of owned.producers.values()) producer.cancel('fixture disposal')
    await Promise.all([...owned.producers.values()].map(producer => producer.done))
  })
  notify('fixture.portableContextReady')
}

export async function portableContextFixtureCall(method, params) {
  assert.ok(fixture && !fixture.closed, 'Portable fixture must be live')
  const { ctx, producers } = fixture
  if (method === 'fixture.startJob') {
    assert.ok(ctx.agents.get(params.owner), 'The original session must be active before starting work')
    const settled = Promise.withResolvers()
    const producer = { done: settled.promise, complete: settled.resolve, settled: false, cancelled: 0,
      cancel(reason) {
        if (producer.settled) return
        producer.cancelled++
        producer.settled = true
        settled.resolve({ status: 'killed', detail: reason ?? 'fixture cancelled' })
      },
    }
    const id = ctx.jobs.start({ kind: 'fixture', owner: params.owner, label: params.label,
      run(handle) {
        producer.handle = handle
        handle.append('FIRST_OUTPUT\n')
        return { cancel: reason => producer.cancel(reason), done: producer.done }
      },
    })
    producers.set(id, producer)
    return { id, owner: params.owner }
  }
  if (method === 'fixture.settleJob') {
    const producer = producers.get(params.id)
    assert.ok(producer && !producer.settled, 'Only a live fixture-owned producer may settle')
    producer.handle.append('FINAL_OUTPUT\n')
    // Complete through the registered producer, not by mutating registry state.
    producer.settled = true
    producer.complete({ status: 'completed', result: 'FIXTURE_JOB_COMPLETE' })
    return true
  }
  if (method === 'fixture.inspectJobs') {
    return { jobs: ctx.jobs.snapshot(), producers: [...producers].map(([id, producer]) => ({
      id, settled: producer.settled, cancelled: producer.cancelled,
    })) }
  }
  if (method === 'fixture.cleanupJobs') {
    const pending = ctx.jobs.snapshot().filter(job => job.owner === params.owner
      && (job.status === 'running' || job.status === 'stopping'))
    const waits = pending.map(job => ctx.jobs.wait(job.id, 5000, params.owner))
    for (const job of pending) ctx.jobs.kill(job.id, params.owner, 'fixture cleanup')
    await Promise.all(waits)
    return { jobs: ctx.jobs.snapshot().filter(job => job.owner === params.owner),
      producers: [...producers].map(([id, producer]) => ({ id, settled: producer.settled, cancelled: producer.cancelled })) }
  }
  throw new Error(`Unknown portable context fixture method ${method}`)
}
