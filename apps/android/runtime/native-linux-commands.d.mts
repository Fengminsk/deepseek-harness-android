export type LinuxCommandName =
  | 'kernel' | 'identity' | 'sha256' | 'count_bytes' | 'count_lines'
  | 'sort_lines' | 'filter_literal'

export type LinuxCommandRequest = {
  command: LinuxCommandName
  argument?: string
  stdin?: Uint8Array
}

export type LinuxCommandResult = Readonly<{
  id: string
  command: LinuxCommandName
  kind: 'COMPLETED' | 'CANCELLED' | 'TIMED_OUT' | 'WORKER_DIED' | 'ERROR'
  output: string
  exitCode: number
  guestUid: number | null
  detail: string | null
}>

export class LinuxCommandOutcomeUncertainError extends Error {
  readonly code: 'outcome-uncertain'
  readonly runId: string
  readonly command: LinuxCommandName
}

export class NativeLinuxCommands {
  constructor(transport: { request(method: string, params: unknown, signal?: AbortSignal): Promise<unknown> })
  execute(value: LinuxCommandRequest, signal?: AbortSignal): Promise<LinuxCommandResult>
  dispose(): Promise<void>
}
