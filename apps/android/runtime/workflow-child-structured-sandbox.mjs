/** Structured workflow child: only its own scoped result tool may execute. */
export const name = 'android-workflow-child-structured-sandbox'
export const inject = ['tools']

export function apply(ctx) {
  ctx.tools.presentAs('native')
  // Hide every global tool, even a host-wide tool with the same name. The
  // original subagent outputSchema attachment shadows globals with its own
  // schema-validated, child-local structured_output tool before the loop runs.
  ctx.tools.restrict({ allow: [] })
  // Scoped tools bypass the global visibility filter; the monotonic guard
  // therefore denies late child-local tools regardless of registration order.
  ctx.tools.guard(exec => exec.name === 'structured_output'
    ? undefined : 'Workflow children have no tool capabilities beyond structured output')
}
