/**
 * Read-only subscription helper for desktop Host events this bundle does not own.
 *
 * The bundle listens to `session/event`, `agent/status`, and `agent/disposed` on
 * the desktop Host so it can relay desktop-owned work to the remote-host child.
 * Those event names are declared by packages this bundle does not import, so the
 * merged `Context['on']` map cannot type them here; the helper keeps the single
 * required assertion in one place and every consumer narrows its own payloads.
 * @module @deepseek-ai/dsh-device-interconnect/host/desktop-events
 */

import type { Context } from '@deepseek-ai/cordis'

/** Event-bus face with a free event name; the Host `Context.on` map types only known events. */
interface DesktopEventBus {
  on(name: string, listener: (...args: never[]) => void): () => boolean
}

/**
 * Subscribe to one desktop Host event by name.
 * @param ctx - desktop Host plugin context.
 * @param event - event name, for example `session/event`.
 * @param listener - receives the dispatch arguments; payloads are narrowed by the caller.
 * @returns disposer removing the listener.
 */
export function onDesktopEvent(
  ctx: Context,
  event: string,
  listener: (...args: readonly unknown[]) => void,
): () => void {
  const bus = ctx as unknown as DesktopEventBus
  const dispose = bus.on(event, listener)
  return () => { dispose() }
}
