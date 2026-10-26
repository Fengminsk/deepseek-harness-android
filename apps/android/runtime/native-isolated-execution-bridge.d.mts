import type { JsonRpcTransportPeer } from '@deepseek-ai/dsh-sdk-protocol'
import type { DurableIsolatedExecutionBridge } from './isolated-execution-run.mjs'

/** One native admission carries an opaque token in addition to its exact run ID. */
export interface NativeIsolatedRunAdmission {
  readonly runId: string
  readonly token: string
}

/** Construct the internal no-capability App service adapter. */
export function createNativeIsolatedExecutionBridge(
  transport: Pick<JsonRpcTransportPeer, 'request'>,
): DurableIsolatedExecutionBridge<NativeIsolatedRunAdmission>
