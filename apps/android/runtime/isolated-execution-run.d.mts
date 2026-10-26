import type {
  IsolatedExecutionRequest,
  IsolatedExecutionScope,
  NativeIsolatedReceipt,
  PreparedIsolatedExecution,
  ProjectedIsolatedReceipt,
} from './isolated-execution-contract.mjs'

/** An opaque native admission belongs to one exact run. */
export interface NativeRunAdmission {
  readonly runId: string
}

/**
 * Trusted App/Service adapter. admit must commit durable ownership before it
 * resolves; execute must settle the guest and its descendants; cancel must
 * request durable cancellation; settle must read the terminal native record;
 * release must wait for confinement retirement. Never provide this adapter
 * from a model tool argument or from guest JavaScript.
 */
export interface DurableIsolatedExecutionBridge<T extends NativeRunAdmission = NativeRunAdmission> {
  admit(prepared: PreparedIsolatedExecution, signal: AbortSignal): Promise<T>
  execute(admission: T, prepared: PreparedIsolatedExecution, signal: AbortSignal): Promise<void>
  cancel(admission: T, reason: unknown): Promise<void>
  settle(admission: T): Promise<NativeIsolatedReceipt>
  release(admission: T): Promise<void>
}

/** Trusted host registration; bind runs after durable admission and before guest execution. */
export interface IsolatedToolBinding<T extends NativeRunAdmission = NativeRunAdmission> {
  bind(prepared: PreparedIsolatedExecution, admission: T, signal: AbortSignal):
    Promise<{ close(): Promise<void> }>
}

export interface IsolatedExecutionRunOptions<T extends NativeRunAdmission = NativeRunAdmission> {
  request: IsolatedExecutionRequest
  /** Separately chosen by App policy. Never derived from request. */
  scope: IsolatedExecutionScope
  parentScope?: IsolatedExecutionScope
  bridge: DurableIsolatedExecutionBridge<T>
  toolBinding?: IsolatedToolBinding<T>
  signal?: AbortSignal
}

export class IsolatedExecutionRun {
  constructor(options: IsolatedExecutionRunOptions)
  readonly result: Promise<ProjectedIsolatedReceipt>
  get runId(): string
  get cancelled(): boolean
  cancel(reason?: unknown): void
  dispose(): Promise<void>
}

export function startIsolatedExecutionRun(options: IsolatedExecutionRunOptions): IsolatedExecutionRun
