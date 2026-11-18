/**
 * Typing for the one App-runtime module the remote host imports.
 *
 * The remote host shares the authenticated connection with the App runtime that
 * runs in the same child process, so it presents session events with the exact
 * function the runtime uses on its own page line
 * (`apps/android/runtime/live-state.mjs`). That package is plain JavaScript and
 * exposes no declarations; this file declares only the function the host imports
 * so a change to the runtime signature still has to be reflected here.
 * @module @deepseek-ai/dsh-remote-host/android-runtime-live-state
 */

declare module '@minnnng/dsh-android-runtime/live-state.mjs' {
  /**
   * Present one recorded Session event the way the App expects on the page line.
   *
   * `assistant/attempt` events gain the assembled `assistantContent` prefix (or
   * `assistantContentError` when the stream cannot be assembled); every other
   * event is returned unchanged.
   * @param event - raw Session event.
   * @returns the presented event.
   */
  export function presentSessionEvent(event: Record<string, unknown>): Record<string, unknown>
}
