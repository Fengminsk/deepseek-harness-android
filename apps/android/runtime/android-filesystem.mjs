import { SandboxedFileSystem } from '@deepseek-ai/dsh-fs-sandbox'
import { publishImmutableFile } from './immutable-file-publisher.mjs'

/** Keep the original policy, observation, lock and atomic-write owner intact. */
export default class AndroidFileSystem extends SandboxedFileSystem {
  constructor(ctx, config) {
    super(ctx, config)
    // App storage may reject hard links. The original publication boundary
    // expects an exclusive complete target and a retained source; our existing
    // Android publisher supplies both with copy + renameat2(RENAME_NOREPLACE).
    // fs-local still owns cancellation before publication and temp-dir cleanup.
    this.internals.linkFile = publishImmutableFile
  }
}
