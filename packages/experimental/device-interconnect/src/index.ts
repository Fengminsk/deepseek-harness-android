/**
 * Host entry of the Device Interconnect bundle: the Settings-page bridge plus
 * the supervised remote-host child process.
 * @module @deepseek-ai/dsh-device-interconnect
 */

export { apply, name } from './host/plugin.ts'
export type { Config } from './host/plugin.ts'
export type {
  ChildState, ControlPlaneState, DeviceInterconnectConfig, DeviceInterconnectConfigInput, DeviceInterconnectView,
  Diagnostic, ErrorBody, PairingSettings, PairingView, ProvisionRequest, ProvisionStep, ProvisionStepStatus,
  RemoteDevice, RemoteHostFacts, RemoteHostSettings, RunnerConfig, RunnerReadiness, RuntimeState, TunnelAccount,
  TunnelFrpcInfo, TunnelInfo, TunnelLogsResponse, TunnelNodeInfo, TunnelProvider, TunnelProvisionState,
  TunnelReadiness, TunnelRequest, TunnelSettings, TunnelSettingsInput, TunnelSettingsView, TunnelState,
} from './types.ts'
