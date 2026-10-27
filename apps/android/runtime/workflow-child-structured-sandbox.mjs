/** Structured children share the same reviewed tools and their result tool. */
import { applyWorkflowChildTools } from './workflow-child-tools.mjs'
export const name = 'android-workflow-child-structured-sandbox'
export const inject = ['tools', 'androidWorkflowChildTools']

export function apply(ctx) {
  applyWorkflowChildTools(ctx, { structured: true })
}
