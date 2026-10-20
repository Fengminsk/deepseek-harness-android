import { Context } from '@deepseek-ai/cordis'
import { SessionId } from '@deepseek-ai/dsh-session'
import { constants } from 'node:fs'
import { copyFile, link, mkdir, mkdtemp, open, readFile, readdir, rm, unlink, writeFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, expect, it } from 'vitest'
import { applyWithPublication, type JsonlFilePublisher } from '../src/index.ts'
import { generationLogPath, logPath } from '../src/format.ts'
import { meta, oneTurnLog } from '../../session-persistence/tests/contract.ts'

const roots: string[] = []
const contexts: Context[] = []

async function copyExclusive(source: string, target: string): Promise<void> {
  const temporary = join(dirname(target), randomUUID())
  await copyFile(source, temporary, constants.COPYFILE_EXCL)
  try {
    const handle = await open(temporary, 'r+')
    try { await handle.sync() } finally { await handle.close() }
    await link(temporary, target)
  } finally { await unlink(temporary) }
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'dsh-session-publisher-'))
  roots.push(root)
  const publications: string[] = []
  async function mount(publish: JsonlFilePublisher = copyExclusive) {
    const ctx = new Context()
    contexts.push(ctx)
    await ctx.plugin({
      name: 'host-session-persistence',
      apply: scope => applyWithPublication(scope, { root, compression: 'none' }, async (source, target) => {
        publications.push(target)
        await publish(source, target)
      }),
    })
    return ctx
  }
  return { root, mount, publications }
}

afterEach(async () => {
  for (const ctx of contexts.splice(0).reverse()) await ctx.fiber.dispose()
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true, maxRetries: 3 })
})

it('uses the host carrier for first materialization, then restores the real contiguous log', async () => {
  const { root, mount, publications } = await fixture()
  const ctx = await mount()
  const header = meta('host-persisted')
  const events = oneTurnLog()
  const writer = await ctx.sessionPersistence.create(header)
  await writer.append(events.slice(0, 3))
  await writer.append(events.slice(3))
  await writer.flush()
  await writer.close()
  await ctx.fiber.dispose()
  const target = logPath(root, header.cwd, header.id, 'none')
  expect(publications).toEqual([target])
  const reopened = await mount()
  const reader = await reopened.sessionPersistence.open(header.id, 'read')
  try { expect((await reader.read()).events).toEqual(events) } finally { await reader.close() }
  expect((await readdir(dirname(target))).filter(name => name.endsWith('.tmp'))).toEqual([])
})

it('fails before publishing on host errors and can explicitly retry the same flush', async () => {
  const { root, mount, publications } = await fixture()
  const failure = Object.assign(new Error('synthetic host failure'), { code: 'EACCES' })
  let failing = true
  const ctx = await mount(async (source, target) => {
    if (failing) throw failure
    await copyExclusive(source, target)
  })
  const header = meta('retry')
  const writer = await ctx.sessionPersistence.create(header)
  await expect(writer.flush()).rejects.toBe(failure)
  const target = logPath(root, header.cwd, header.id, 'none')
  await expect(readFile(target)).rejects.toMatchObject({ code: 'ENOENT' })
  expect((await readdir(dirname(target))).filter(name => name.endsWith('.tmp'))).toEqual([])
  failing = false
  await writer.flush()
  await writer.close()
  expect(publications).toEqual([target, target])
})

it('does not overwrite a target that appears at the host publication boundary', async () => {
  const { root, mount } = await fixture()
  const ctx = await mount(async (source, target) => {
    await writeFile(target, 'another producer', { flag: 'wx' })
    await copyExclusive(source, target)
  })
  const header = meta('collision')
  const writer = await ctx.sessionPersistence.create(header)
  await expect(writer.flush()).rejects.toMatchObject({ code: 'EEXIST' })
  await writer.close()
  expect(await readFile(logPath(root, header.cwd, header.id, 'none'), 'utf8')).toBe('another producer')
})

it('publishes a verified historical generation through the same carrier and keeps the source', async () => {
  const { root, mount, publications } = await fixture()
  const id = SessionId('historical')
  const source = generationLogPath(root, undefined, id, 3, 'none')
  const current = generationLogPath(root, undefined, id, 4, 'none')
  const historical = JSON.stringify({ type: 'session', version: 3, id, createdAt: 1, isSeeded: false, delegationDepth: 0 }) + '\n'
  await mkdir(dirname(source), { recursive: true })
  await writeFile(source, historical)
  const ctx = await mount()
  const reader = await ctx.sessionPersistence.open(id, 'read')
  await reader.close()
  expect(publications).toEqual([])
  const writer = await ctx.sessionPersistence.open(id, 'write')
  await writer.close()
  expect(publications).toEqual([current])
  expect(await readFile(source, 'utf8')).toBe(historical)
  expect(JSON.parse((await readFile(current, 'utf8')).trim())).toMatchObject({ version: 4 })
  expect((await readdir(dirname(current))).filter(name => name.endsWith('.tmp'))).toEqual([])
})

it('refuses a conflicting migration winner without replacing it or changing the historical source', async () => {
  const { root, mount } = await fixture()
  const id = SessionId('migration-collision')
  const source = generationLogPath(root, undefined, id, 3, 'none')
  const current = generationLogPath(root, undefined, id, 4, 'none')
  const historical = JSON.stringify({ type: 'session', version: 3, id, createdAt: 1, isSeeded: false, delegationDepth: 0 }) + '\n'
  await mkdir(dirname(source), { recursive: true })
  await writeFile(source, historical)
  const ctx = await mount(async (staged, target) => {
    await writeFile(target, 'foreign current bytes', { flag: 'wx' })
    await copyExclusive(staged, target)
  })
  await expect(ctx.sessionPersistence.open(id, 'write')).rejects.toThrow()
  expect(await readFile(source, 'utf8')).toBe(historical)
  expect(await readFile(current, 'utf8')).toBe('foreign current bytes')
  expect((await readdir(dirname(current))).filter(name => name.endsWith('.tmp'))).toEqual([])
})
