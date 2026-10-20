import { constants } from 'node:fs'
import { link, open, unlink } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { dirname, join } from 'node:path'
import { createRequire } from 'node:module'

/** Keep the source and expose only a fully copied, synced file at the exclusive target. */
export function createCopiedFilePublisher(renameExclusive) {
  return async (source, target) => {
    const temporary = join(dirname(target), `.pocket-publish-${randomUUID()}`)
    let owned = false
    try {
      const input = await open(source, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
      try {
        const sourceInfo = await input.stat()
        if (!sourceInfo.isFile()) throw new Error('Publication source must be a regular file')
        const output = await open(temporary, 'wx', 0o600)
        owned = true
        try {
          for await (const chunk of input.createReadStream({ autoClose: false })) await output.writeFile(chunk)
          await output.chmod(sourceInfo.mode & 0o777)
          await output.sync()
        } finally { await output.close() }
      } finally { await input.close() }
      await renameExclusive(temporary, target)
      owned = false
    } finally {
      if (owned) await unlink(temporary)
    }
  }
}

const publish = process.platform === 'android'
  ? createCopiedFilePublisher(createRequire(import.meta.url)('./file-publish-native.cjs').renameExclusive)
  : link

/** Android app storage uses copied publication; other hosts retain hard links. */
export const publishImmutableFile = publish
