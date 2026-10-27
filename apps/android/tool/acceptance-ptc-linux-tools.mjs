import { runKotlinHostTest } from './kotlin-host-test.mjs'

runKotlinHostTest({ prefix: 'ptc-linux-tools-', javaClasses: ['PtcScriptEngine', 'IsolatedScriptWire'],
  productionClasses: ['IsolatedToolRequest'], testClasses: ['IsolatedToolRequestTest'],
  mainClass: 'IsolatedToolRequestTest',
})
