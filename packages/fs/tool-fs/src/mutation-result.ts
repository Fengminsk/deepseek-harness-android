/** Shared observation and result fields for successful file mutations. */

import type { Context } from '@deepseek-ai/cordis'
import type { FsTarget, FsVersion } from '@deepseek-ai/dsh-fs'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import type { ToolRunContext } from '@deepseek-ai/dsh-tools'

declare module '@deepseek-ai/dsh-llm' {
  interface MessageSourceMap {
    /**
     * A successful provider mutation, retained through cancellation or observation failure.
     * @persistenceAttribution
     */
    'file-mutation-receipt': { kind: 'file-mutation-receipt' }
  }
}

/**
 * Retain a completed-mutation receipt before recording the new file version.
 * The receipt survives later cancellation or observation failure. It contains one
 * complete canonical path and operation, never file content or a truncated path.
 * @param ctx - filesystem and observation event owner.
 * @param target - resolved file that was mutated.
 * @param outcome - successful provider result; its version stays in the observation event.
 * @param exec - real calling tool execution, which owns the deferred receipt.
 * @returns the provider's result fields without the version, plus the canonical absolute path.
 */
export function mutationResult<T extends { version: FsVersion }>(
  ctx: Context, target: FsTarget, outcome: T, exec: ToolRunContext,
): Omit<T, 'version'> & { path: string } {
  const { version, ...result } = outcome
  const path = ctx.fs.processPath(target)
  exec.deferContext(createUserMessage({
    source: { kind: 'file-mutation-receipt' },
    content: [{ type: 'text', text: `File mutation completed: ${JSON.stringify({ operation: exec.name, path })}. Re-read before retrying.` }],
  }))
  ctx.emit('fs/observed', target, { kind: 'present', version }, exec)
  return { path, ...result }
}
