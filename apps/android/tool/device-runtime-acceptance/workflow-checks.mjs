export const WORKFLOW_DEVICE_CHECKS = Object.freeze([
  'real-tool-runtime-native-compute',
  'real-confined-child-and-durable-session',
  'real-dsl-parallel-pipeline-phase-log',
  'real-structured-child-and-json-contract',
  'real-json-rejection-and-native-retirement',
  'real-child-and-item-limits',
  'real-ordinary-child-failure-and-sibling-result',
  'real-infrastructure-failure-and-child-retirement',
  'real-foreground-cancellation-and-child-retirement',
  'real-background-completion-and-job-output',
  'real-background-job-kill-and-child-retirement',
])

export const WORKFLOW_DEADLINE_CHECK = 'native-workflow-deadline-and-nested-wait-retirement'
export const WORKFLOW_DEATH_CHECK = 'workflow-binder-death-and-app-restart'

export const WORKFLOW_UNVERIFIED_CHECKS = Object.freeze([
  WORKFLOW_DEADLINE_CHECK,
  WORKFLOW_DEATH_CHECK,
  'workflow-upgrade-record-retention',
])
