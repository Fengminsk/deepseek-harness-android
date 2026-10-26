/** The native toolbar talks to the currently mounted original preview owner. */
export function createDocumentControls() {
  let commands;
  let closed = false;
  return {
    bind(value) {
      if (closed) return () => {};
      commands = value;
      return () => { if (commands === value) commands = undefined; };
    },
    refresh() {
      if (closed || typeof commands?.refresh !== 'function') return false;
      commands.refresh();
      return true;
    },
    close() { closed = true; commands = undefined; },
  };
}
