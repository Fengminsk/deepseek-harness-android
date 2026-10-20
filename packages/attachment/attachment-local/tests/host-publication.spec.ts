import { randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { chmod, copyFile, link, mkdtemp, open, readFile, readdir, rm, stat, unlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import { afterEach, expect, it } from 'vitest'
import { LocalAttachmentStore } from '../src/index.ts'
import type { ImmutableFilePublisher } from '../src/store.ts'

const homes: string[] = []
const contexts: Context[] = []

async function fixture(publish?: ImmutableFilePublisher) {
  const home = await mkdtemp(join(tmpdir(), 'dsh-publication-'))
  homes.push(home)
  const ctx = new Context()
  contexts.push(ctx)
  const calls: string[] = []
  class CopiedStore extends LocalAttachmentStore {
    protected override publishImmutableFile: ImmutableFilePublisher = async (source, target) => {
      calls.push(target)
      if (publish !== undefined) return publish(source, target)
      // Simulate the host's rename-no-replace with a real exclusive link from
      // a private copy. Core tests pin the publisher contract, not OS support.
      const temporary = join(home, randomUUID())
      await copyFile(source, temporary, constants.COPYFILE_EXCL)
      await chmod(temporary, 0o600)
      try {
        const handle = await open(temporary, 'r+')
        try { await handle.sync() } finally { await handle.close() }
        await link(temporary, target)
      } finally { await unlink(temporary) }
    }
  }
  return { home, store: new CopiedStore(ctx, { dshHome: home }), calls }
}

afterEach(async () => {
  await Promise.all(contexts.splice(0).map(ctx => ctx.fiber.dispose()))
  await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true, maxRetries: 3 })))
})

it('publishes file bytes and aliases through the instance carrier and deduplicates concurrent saves', async () => {
  const { store, calls } = await fixture()
  const data = Buffer.from('host-owned copied publication')
  const input = () => ({ name: 'one.txt', data: (async function* () { yield data })() })
  const [first, repeated] = await Promise.all([store.saveFileStream(input()), store.saveFileStream(input())])
  const renamed = await store.saveFile({ data, name: 'two.txt' })
  expect(first).toEqual(repeated)
  expect(first.attachmentId).toBe(renamed.attachmentId)
  expect(await readFile(store.fileHostPath(first))).toEqual(data)
  expect(await readFile(store.fileHostPath(renamed))).toEqual(data)
  expect((await stat(store.fileHostPath(first))).ino).not.toBe((await stat(store.fileHostPath(renamed))).ino)
  expect(calls).toHaveLength(6)
  expect(await readdir(join(store.root, 'tmp'))).toEqual([])
})

it('keeps corruption detection on pre-existing copied aliases without replacing their bytes', async () => {
  const { store } = await fixture()
  const data = Buffer.from('original bytes')
  const ref = await store.saveFile({ data, name: 'one.txt' })
  const path = store.fileHostPath(ref)
  await chmod(path, 0o600)
  await writeFile(path, 'corrupt')
  await expect(store.saveFile({ data, name: 'one.txt' })).rejects.toMatchObject({ code: 'ATTACHMENT_CORRUPT' })
  expect(await readFile(path, 'utf8')).toBe('corrupt')
  const other = await store.saveFile({ data, name: 'two.txt' })
  expect(await readFile(store.fileHostPath(other))).toEqual(data)
})

it('keeps publication failure visible and clears only the uncommitted staging file', async () => {
  const cause = Object.assign(new Error('native publication failed'), { code: 'EACCES' })
  const { store } = await fixture(() => Promise.reject(cause))
  await expect(store.saveFile({ data: Buffer.from('synthetic'), name: 'one.txt' }))
    .rejects.toMatchObject({ code: 'ATTACHMENT_WRITE_FAILED', cause })
  expect(await readdir(join(store.root, 'tmp'))).toEqual([])
})

it('uses the same host publication for single and batched normalized images', async () => {
  const { store, calls } = await fixture()
  const data = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADElEQVQImWNgZGIGAAAOAAeCcsnOAAAAAElFTkSuQmCC', 'base64')
  const input = { data, mediaType: 'image/png' as const }
  const first = await store.saveImage(input)
  const batch = await store.saveImages([input, input])
  expect(batch).toEqual([first, first])
  expect(calls).toHaveLength(3)
  expect((await store.readImage(first)).data.byteLength).toBe(first.bytes)
})
