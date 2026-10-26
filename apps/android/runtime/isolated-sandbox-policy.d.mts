import type { IsolatedExecutionScope } from './isolated-execution-contract.mjs'

export type IsolatedFileMode = 'read-only' | 'workspace-write'
export type IsolatedNetworkMode = 'deny' | 'allow-listed-https'

/** Host-selected policy projection; native approval and brokers remain authoritative. */
export interface IsolatedSandboxPolicy {
  readonly mode: IsolatedFileMode
  readonly networkMode: IsolatedNetworkMode
  readonly scope: Readonly<IsolatedExecutionScope>
}

export interface IsolatedSandboxDecision {
  /** Scope must come from the trusted App approval owner, never model arguments. */
  approvedScope: IsolatedExecutionScope
  /** Defaults to read-only. The Android guest does not support unrestricted access. */
  mode?: IsolatedFileMode
  /** Defaults to deny; allowed network is exact HTTPS hosts only. */
  networkMode?: IsolatedNetworkMode
}

export function projectIsolatedSandboxPolicy(decision: IsolatedSandboxDecision,
  parent?: IsolatedSandboxPolicy): IsolatedSandboxPolicy
export function requireIsolatedSandboxPolicy(value: unknown): IsolatedSandboxPolicy
