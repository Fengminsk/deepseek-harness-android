/** A workflow child uses only its Host-issued subset of the parent's tools. */
import { applyWorkflowChildTools } from './workflow-child-tools.mjs'
export const name = 'android-workflow-child-sandbox'
export const inject = ['tools', 'androidWorkflowChildTools']

export function apply(ctx) {
  applyWorkflowChildTools(ctx)
}
