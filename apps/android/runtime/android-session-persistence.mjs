import { applyWithPublication } from '@deepseek-ai/dsh-session-persistence-jsonl'
import { publishImmutableFile } from './immutable-file-publisher.mjs'
export { name, Config } from '@deepseek-ai/dsh-session-persistence-jsonl'

/** The original JSONL owner retains leases, append, migration and flush behavior. */
export function apply(ctx, config) {
  return applyWithPublication(ctx, config, publishImmutableFile)
}
