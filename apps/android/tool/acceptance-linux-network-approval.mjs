import { runKotlinHostTest } from './kotlin-host-test.mjs'

runKotlinHostTest({ prefix: 'linux-network-approval-',
  javaClasses: ['IsolatedExecutionApprovalInbox', 'IsolatedExecutionApprovalStore', 'LinuxVmConsole'],
  productionClasses: ['LinuxVmNetworkApprovalCoordinator'], testClasses: ['LinuxVmNetworkApprovalCoordinatorTest'],
  mainClass: 'LinuxVmNetworkApprovalCoordinatorTest',
})
