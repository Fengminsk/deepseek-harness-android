/**
 * Host entry of the Device Interconnect bundle: the Settings-page bridge plus
 * the supervised remote-host child process.
 * @module @deepseek-ai/dsh-device-interconnect
 */

export { apply, name } from './host/plugin.ts'
export type { Config } from './host/plugin.ts'
export type {
  ChildState, ControlPlaneState, DeviceInterconnectConfig, Diagnostic, ErrorBody, PairingSettings,
  PairingView, RemoteDevice, RemoteHostFacts, RemoteHostSettings, RunnerConfig, RunnerReadiness, RuntimeState,
} from './types.ts'
