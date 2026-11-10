/**
 * The merged ToolRuntime dispatches complete call batches. Android host tests
 * still address one model-shaped call, so this adapter stringifies its
 * arguments and returns that call's settled outcome.
 */

/**
 * Dispatch one call and return its result.
 * @param {{ execute: Function }} tools - the ToolRuntime service.
 * @param {{ callId: string, name: string, arguments?: unknown, agent?: unknown, signal: AbortSignal, toolSet?: unknown }} call - the single call.
 * @returns {Promise<object>} the settled `ToolExecutionResult` for that call.
 */
export async function executeToolCall(tools, { callId, name, arguments: args, agent, signal, toolSet }) {
  const batch = await tools.execute({
    calls: [{ type: 'tool-call', id: callId, name, arguments: JSON.stringify(args ?? {}) }],
    signal,
    ...(agent === undefined ? {} : { agent }),
    ...(toolSet === undefined ? {} : { toolSet }),
  })
  return batch.results[0].result
}
