/** Internal Android admission data. Native policy ownership remains authoritative. */
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }

export interface IsolatedExecutionScope {
  ownerId: string
  sessionId: string
  version: number
  /** App-selected opaque identity; never a guest-supplied pathname. */
  workspaceId: string | null
  /** Relative exact files or directory roots ending in `/`; guest handles remain exact files. */
  readablePaths: readonly string[]
  /** Every write root must be contained in a read root. */
  writablePaths: readonly string[]
  exactHosts: readonly string[]
  fileCallLimit: number
  networkCallLimit: number
  leaseMillis: number
}

export interface WorkflowPhase {
  title: string
  detail?: string
  provider?: string
  model?: string
}

export interface WorkflowMeta {
  name: string
  description: string
  whenToUse?: string
  phases?: readonly WorkflowPhase[]
}

export type IsolatedExecutionRequest = {
  kind: 'script'
  runId: string
  sessionId: string
  program: string
  args?: JsonValue
  deadlineMillis: number
} | {
  kind: 'workflow'
  runId: string
  sessionId: string
  program: string
  args?: JsonValue
  deadlineMillis: number
  meta: WorkflowMeta
  maxTotalAgents: number
  maxConcurrentAgents: number
}

export type PreparedIsolatedExecution = Readonly<IsolatedExecutionRequest & {
  args: JsonValue
  scope: Readonly<IsolatedExecutionScope>
}>

export interface NativeIsolatedReceipt {
  runId: string
  state: 'COMPLETED' | 'CANCELLED' | 'TIMED_OUT' | 'WORKER_DIED' | 'ERROR'
    | 'RETIRE_UNCONFIRMED' | 'INTERRUPTED_UNCONFIRMED'
  outputJson?: string | null
  logsJson?: string | null
  detail?: string | null
  guestUid?: number | null
}

export type ProjectedIsolatedReceipt = Readonly<{
  runId: string
  state: 'completed'
  value: JsonValue
  logs: readonly string[]
  guestUid: number
} | {
  runId: string
  state: 'failed'
  failure: Exclude<NativeIsolatedReceipt['state'], 'COMPLETED'>
  requiresReview: boolean
  guestUid: number | null
  detail: string | null
}>

export class IsolatedExecutionContractError extends Error {
  readonly code: string
  constructor(code: string, message: string)
}

export function normalizeExecutionScope(value: IsolatedExecutionScope,
  parent?: IsolatedExecutionScope): Readonly<IsolatedExecutionScope>
export function snapshotIsolatedJson(value: unknown, name?: string, maxBytes?: number): JsonValue
export function prepareIsolatedExecution(request: IsolatedExecutionRequest,
  scope: IsolatedExecutionScope, parentScope?: IsolatedExecutionScope): PreparedIsolatedExecution
export function requireModelFacingIsolatedExecution(): never
export function projectIsolatedReceipt(value: NativeIsolatedReceipt,
  expectedRunId: string): ProjectedIsolatedReceipt
