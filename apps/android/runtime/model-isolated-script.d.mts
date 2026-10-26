import type { PreparedIsolatedExecution, NativeIsolatedReceipt, JsonValue } from './isolated-execution-contract.mjs'
import type { IsolatedSandboxPolicy } from './isolated-sandbox-policy.mjs'

export interface ModelScriptArguments {
  code: string
  description: string
  language: 'typescript-function-body'
}

export interface TrustedModelScriptHost {
  sessionId: string
  sandboxPolicy: IsolatedSandboxPolicy
  deadlineMillis: number
}

export interface ModelScriptDraft {
  readonly description: string
  readonly language: 'typescript-function-body'
  readonly source: string
  readonly compiled: Readonly<{
    language: 'typescript-function-body'
    javaScript: string
    sourceSha256: string
    javaScriptSha256: string
    sourceLines: number
    nativePreludeLines: number
  }>
  readonly execution: PreparedIsolatedExecution
}

export function prepareModelIsolatedScript(
  modelArguments: ModelScriptArguments, host: TrustedModelScriptHost): ModelScriptDraft
export function runModelIsolatedScript(draft: ModelScriptDraft, bridge: unknown, signal?: AbortSignal): never
export function projectModelIsolatedScriptReceipt(receipt: NativeIsolatedReceipt,
  expectedRunId: string): Readonly<{
    runId: string
    state: 'completed'
    value: JsonValue
    logs: readonly string[]
  } | {
    runId: string
    state: 'failed'
    failure: Exclude<NativeIsolatedReceipt['state'], 'COMPLETED'>
    requiresReview: boolean
    detail: string | null
  }>
