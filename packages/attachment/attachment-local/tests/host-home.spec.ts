import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join, relative, sep } from 'node:path'
import { afterEach, expect, it, vi } from 'vitest'
import { establishAttachmentHome } from '../src/store.ts'
import { saveFileStreamVerbatim, storedFilePath } from '../src/file-store.ts'

const directoryAccess = vi.hoisted(() => ({
  root: '',
  handleFile: '',
  reject: '',
  opened: [] as string[],
}))

vi.mock('node:fs/promises', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs/promises')>()
  return {
    ...actual,
    async open(...args: Parameters<typeof actual.open>): ReturnType<typeof actual.open> {
      if (args[1] !== constants.O_RDONLY) return actual.open(...args)
      const path = String(args[0])
      directoryAccess.opened.push(path)
      const distance = relative(directoryAccess.root, path)
      if (isAbsolute(distance) || distance === '..' || distance.startsWith(`..${sep}`)
        || path === directoryAccess.reject) {
        throw Object.assign(new Error(`EACCES: permission denied, open '${path}'`), { code: 'EACCES' })
      }
      // Windows has no read-only directory handle. This adapter models Android's
      // directory access while keeping the actual stream, fsync, links and bytes.
      return actual.open(directoryAccess.handleFile, 'r+')
    },
  }
})

const platform = process.platform
const temporary: string[] = []

async function sandbox() {
  const root = await mkdtemp(join(tmpdir(), 'dsh-host-attachment-'))
  temporary.push(root)
  const home = join(root, 'no_backup', 'dsh')
  await mkdir(home, { recursive: true })
  const handleFile = join(root, 'directory-handle')
  await writeFile(handleFile, '')
  Object.assign(directoryAccess, { root, handleFile, reject: '', opened: [] })
  Object.defineProperty(process, 'platform', { value: 'android' })
  return { root, home, storage: join(home, 'attachments', 'v1') }
}

afterEach(async () => {
  Object.defineProperty(process, 'platform', { value: platform })
  await Promise.all(temporary.splice(0).map(path => rm(path, { recursive: true, force: true })))
})

it('publishes real streamed bytes without opening parents outside the host data directory', async () => {
  const { root, home, storage } = await sandbox()
  const bytes = Buffer.from('Pocket Harness 附件验收\n')
  const input = () => ({ name: 'acceptance.txt', data: (async function* () { yield bytes })() })
  await expect(saveFileStreamVerbatim(storage, input())).rejects.toMatchObject({ code: 'EACCES' })
  directoryAccess.opened.length = 0

  await establishAttachmentHome(home, root)
  const first = await saveFileStreamVerbatim(storage, input())
  const second = await saveFileStreamVerbatim(storage, input())

  expect(first).toEqual(second)
  expect(first.attachmentId).toBe(`sha256:${createHash('sha256').update(bytes).digest('hex')}`)
  expect(await readFile(storedFilePath(storage, first))).toEqual(bytes)
  expect(directoryAccess.opened).toContain(root)
  expect(directoryAccess.opened.every(path => path === root || path.startsWith(`${root}${sep}`))).toBe(true)
})

it('rejects an existing home outside the trusted ancestor before opening directories', async () => {
  const { root, home } = await sandbox()
  await expect(establishAttachmentHome(root, home)).rejects.toThrow('inside the host durable directory')
  expect(directoryAccess.opened).toEqual([])
})

it('keeps errors inside the app directory visible and retries the durability work', async () => {
  const { root, home } = await sandbox()
  directoryAccess.reject = join(root, 'no_backup')
  await expect(establishAttachmentHome(home, root)).rejects.toMatchObject({ code: 'EACCES' })
  directoryAccess.reject = ''
  directoryAccess.opened.length = 0
  await establishAttachmentHome(home, root)
  expect(directoryAccess.opened).toEqual([join(root, 'no_backup'), root])
})
