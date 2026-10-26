/** Model-only child scope. Global and scope-local tools cannot execute. */
export const name = 'android-workflow-child-sandbox'
export const inject = ['tools']

export function apply(ctx) {
  // The reserved run_code transport is outside restriction filters. Force the
  // native presentation even if the host's default changes to PTC mode.
  ctx.tools.presentAs('native')
  ctx.tools.restrict({ allow: [] })
  // A later agent-scoped registration bypasses restrict({ allow: [] }) in the
  // tool registry. This monotonic guard still denies its execution.
  ctx.tools.guard(() => 'Workflow children have no tool capabilities')
}
