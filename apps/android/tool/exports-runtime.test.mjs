// Artifact test: requires the ordinary DSH archive package build used by the Android bundle.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { createRequire, registerHooks } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { test } from 'node:test'

const require = createRequire(new URL('../../../packages/session-query/session-log-export/package.json', import.meta.url))
const archiveModule = pathToFileURL(require.resolve('@deepseek-ai/dsh-session-log-export')).href
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === '@deepseek-ai/dsh-session-log-export') return next(archiveModule, context)
    return next(specifier, context)
  },
})
const { AppExports } = await import('../runtime/exports.mjs')
const { SESSION_LOG_FILENAME, serializeSessionLog } = await import(archiveModule)
const { unzipSync, strFromU8 } = require('fflate')

function fixture() {
  const headers = Object.fromEntries(['root', 'child'].map(id => [id, {
    version: Number(SESSION_LOG_FILENAME.match(/v(\d+)/)?.[1] ?? 0),
    id, createdAt: 1, isSeeded: false, delegationDepth: id === 'root' ? 0 : 1,
  }]))
  const digest = 'a'.repeat(64)
  const events = {
    root: [{ type: 'user/message', seq: 0, time: 1, data: { content: [
      { type: 'text', text: '本地导出🙂' },
      { type: 'file', attachment: { attachmentId: `sha256:${digest}`, name: 'notes.txt', bytes: 5 } },
    ] } }],
    child: [{ type: 'turn/start', seq: 0, time: 1, data: { turn: 1 } }],
  }
  const flushed = []
  const closed = []
  const services = {
    sessions: { get: id => ({ id }), flush: async session => { flushed.push(session.id) } },
    sessionPersistence: { open: async id => ({
      header: headers[id],
      read: async () => ({ events: events[id] }),
      close: async () => { closed.push(id) },
    }) },
    sessionQuery: { traceSession: async () => ({
      descendants: [{ session: { header: headers.child }, descendants: [] }],
    }) },
    attachments: { async *readFileStream() { yield new TextEncoder().encode('hello') } },
  }
  return { ctx: { get: name => services[name] }, services, headers, events, digest, flushed, closed }
}

async function withExports(run) {
  const directory = await mkdtemp(join(tmpdir(), 'pocket-export-test-'))
  const world = fixture()
  const exporter = new AppExports(world.ctx, { directory: async () => directory })
  try { await run(exporter, directory, world) }
  finally {
    await exporter.close()
    // This directory was freshly allocated by mkdtemp above and contains only test-owned artifacts.
    await rm(directory, { recursive: true })
  }
}

test('App export keeps original root, descendant and attachment ZIP entries without Web', async () => {
  await withExports(async (exporter, directory, world) => {
    const id = randomUUID()
    const result = await exporter.prepare({ id, sessionId: 'root', includeDescendants: true })
    const data = await readFile(join(directory, `${id}.zip`))
    const archive = unzipSync(data)
    assert.equal(result.filename, 'dsh-session-root.zip')
    assert.equal(result.size, data.length)
    assert.deepEqual(Object.keys(archive), [
      SESSION_LOG_FILENAME,
      `subagents/child/${SESSION_LOG_FILENAME}`,
      `files/aa/${world.digest}/notes.txt`,
    ])
    assert.equal(strFromU8(archive[SESSION_LOG_FILENAME]), serializeSessionLog(world.headers.root, world.events.root))
    assert.equal(strFromU8(archive[`subagents/child/${SESSION_LOG_FILENAME}`]), serializeSessionLog(world.headers.child, world.events.child))
    assert.equal(strFromU8(archive[`files/aa/${world.digest}/notes.txt`]), 'hello')
    assert.deepEqual(world.flushed, ['root', 'child'])
    assert.deepEqual(world.closed, ['root', 'child'])
    await exporter.release({ id })
    assert.deepEqual(await readdir(directory), [])
  })
})

test('duplicate prepare shares one artifact; reused id cannot change the session', async () => {
  await withExports(async (exporter, directory, world) => {
    const id = randomUUID()
    const one = exporter.prepare({ id, sessionId: 'root' })
    const two = exporter.prepare({ id, sessionId: 'root' })
    assert.equal(one, two)
    assert.throws(() => exporter.prepare({ id, sessionId: 'child' }), /different request/)
    await one
    assert.deepEqual(world.flushed, ['root', 'child'])
    assert.deepEqual(await readdir(directory), [`${id}.zip`])
  })
})

test('cancellation stops preparation and removes partial artifacts without cancelling sessions', async () => {
  await withExports(async (exporter, directory, world) => {
    const entered = Promise.withResolvers()
    world.services.attachments.readFileStream = async function* (_ref, signal) {
      entered.resolve()
      await new Promise((resolve, reject) => {
        if (signal.aborted) reject(signal.reason)
        else signal.addEventListener('abort', () => reject(signal.reason), { once: true })
      })
      yield new Uint8Array()
    }
    const id = randomUUID()
    const preparing = exporter.prepare({ id, sessionId: 'root' })
    const rejected = assert.rejects(preparing)
    await entered.promise
    await exporter.cancel({ id })
    await rejected
    assert.deepEqual(await readdir(directory), [])
    assert.equal(exporter.records.size, 0)
  })
})

test('foreign cache files survive UUID collisions and invalid ids never select paths', async () => {
  await withExports(async (exporter, directory) => {
    for (const extension of ['partial', 'zip']) {
      const id = randomUUID()
      const path = join(directory, `${id}.${extension}`)
      await writeFile(path, 'owned by previous producer')
      await assert.rejects(exporter.prepare({ id, sessionId: 'root' }))
      assert.equal(await readFile(path, 'utf8'), 'owned by previous producer')
      await exporter.release({ id })
      assert.equal(await readFile(path, 'utf8'), 'owned by previous producer')
    }
    assert.throws(() => exporter.prepare({ id: '../../private', sessionId: 'root' }), /identity/)
  })
})

test('archive read failure closes handles and leaves no incomplete ZIP', async () => {
  await withExports(async (exporter, directory, world) => {
    world.services.sessionPersistence.open = async () => ({
      header: world.headers.root,
      read: async () => { throw new Error('storage unavailable') },
      close: async () => { world.closed.push('failed') },
    })
    await assert.rejects(exporter.prepare({ id: randomUUID(), sessionId: 'root' }), /storage unavailable/)
    assert.deepEqual(world.closed, ['failed'])
    assert.deepEqual(await readdir(directory), [])
  })
})
