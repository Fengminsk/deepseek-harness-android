import { runKotlinHostTest } from './kotlin-host-test.mjs'

runKotlinHostTest({ prefix: 'workflow-callback-retirement-',
  javaClasses: ['PtcScriptEngine', 'IsolatedScriptRetirement', 'IsolatedScriptReceipt'],
  productionClasses: ['WorkflowCallbackRetirement'], testClasses: ['WorkflowCallbackRetirementTest'],
  mainClass: 'WorkflowCallbackRetirementTest',
})
