/** The acceptance fiber is pending until the suites finish. Capture the exact
 * callback owners instead of looking them up as ACTIVE Cordis services. */
export function createAcceptanceCallbackRouting() {
  const owners = new Map()
  return {
    bind(kind, owner) {
      if (!['workflow', 'tool'].includes(kind) || owners.has(kind)
        || typeof owner?.call !== 'function' || typeof owner?.close !== 'function') {
        throw new Error('Invalid or duplicate acceptance callback owner')
      }
      owners.set(kind, owner)
      return () => { if (owners.get(kind) === owner) owners.delete(kind) }
    },
    async dispatch(method, params) {
      const match = /^native\.(workflow|tool)Callback(\.cancel)?$/.exec(method)
      if (!match) throw new Error(`Unexpected acceptance callback: ${method}`)
      const owner = owners.get(match[1])
      if (!owner) throw new Error('Acceptance callback owner is unavailable')
      return match[2] ? owner.close(params) : owner.call(params)
    },
  }
}
