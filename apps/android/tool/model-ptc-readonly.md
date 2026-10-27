# Android reviewed PTC owner

English | [中文](model-ptc-readonly.zh.md)

## Summary

The App-owned [PTC owner](../runtime/model-ptc-reviewed-owner.mjs) executes erasable TypeScript function bodies through an isolated V8 guest. It is a private composition component; it does not register a model tool or enable the disabled Android PTC profile. It supports file and webpage processing through the live parent's ToolRuntime, without Node, shell, direct network access or native file grants.

## Contents

- Reviewed calls
- Results and records
- Execution limits
- Validation

## Reviewed calls

The [model tool factory](../runtime/tool-model-ptc.mjs) is composed in the Android runtime behind the source-owned device acceptance switch. It exposes only `code` and `description`, reports the reviewed callback subset separately from native grants, and checks availability both before starting and before publishing a result. The switch remains closed until production device acceptance passes.

Each execution captures the live Agent, active parent token, exact scoped definition and registration identity. Original package factories identify their own frozen definitions; copying a definition or unloading its plugin fails identification. Every callback rechecks identity, visibility, parent lifetime and arguments before the original ToolRuntime authorization and execution pipeline runs.

| Tool | Permitted operations |
| --- | --- |
| `list_agents` | Existing reviewed child-agent listing |
| `read`, `glob`, `grep` | Original workspace reads and search under the Android file guard |
| `write`, `edit` | Original file mutations under the live writable policy and observation rules |
| `web_search`, `web_fetch` | Configured web providers with their existing policies and cancellation |
| `android_files` | `roots`, `list`, `read`, `search` on user-authorized document roots |
| `android_attachments` | `list`, `read`, `materialize`, `inspect_archive`, `inspect_apk` for current-session references |

Images, shell commands, Linux execution and nested PTC/workflow calls are excluded. File writes, edits and attachment materialization require the live writable sandbox policy and a participating Session persistence owner; model-requested escalation is refused. A tool absent from the live parent's scope is not exposed. Package identification grants no access by itself; host tool policy remains authoritative. The guest cannot supply the execution kind or its budget.

## Results and records

Successful callback values are bounded to 48 KiB of encoded JSON before guest delivery. Workspace reads keep complete lines and expose the next line offset when shortened; SAF and attachment reads keep valid UTF-8 or whole hex bytes and advance the byte offset precisely. Search and page excerpts explicitly report truncation without inventing a provider continuation. An indivisible entry that cannot fit returns a confirmed unsupported result.

APK analysis retains its exact coverage and independent Manifest cursors. A result exceeding 48 KiB is refused with recovery guidance: reduce the Manifest page `limit`, or use code `limit: 1` with `sampleLimit: 0`. An oversized single result remains available through the direct attachment tool; PTC does not silently drop nested declarations or change the analysis into an empty successful page.

The [tool-call port](isolated-tool-call-port.md) records the exact projected JSON delivered to the guest in the paired Session callback event. Its durable journal retains non-replayable call markers and result hashes. Callback audit, dispatch, cancellation or retirement uncertainty withholds success. Mutating calls require a successful Session flush after their start record and again after the terminal record, before journal confirmation and guest delivery. Read calls retain the existing append behavior. Session persistence and the separate journal do not form an atomic disk transaction.

Original tool metadata and deferred contexts remain in the host audit. Successful filesystem mutations retain their complete actual path before later cancellation can hide the normal result. Attachment receipts record the verified publication immediately; subsequent cancellation or cleanup can still remove that file, so the receipt does not guarantee its final presence. A host post-execute policy can withhold body contexts; an uncertain mutation then records the requested path when known and requires inspection before retrying. Cancellation or an error never implies rollback, and the owner never automatically replays a mutation.

## Execution limits

Native `ptc` admission accepts only an empty file/network grant scope and requires a bound ToolRuntime callback port before execution. It has a maximum 120-second wall deadline and a separate five-second CPU allowance on the V8 execution thread. The native watchdog samples that thread's CPU clock every 20 ms; waiting for host replies consumes wall time without consuming the compute allowance. A final CPU check precedes successful completion. Clock inspection failure refuses execution or terminates it without output. Ordinary scripts retain their five-second wall limit.

The App controller selects the explicit `function-body` Binder format for `ptc`; ordinary scripts and workflows keep `function-expression`. The service dispatches bodies to V8's native AsyncFunction constructor. The guest SDK sends exactly `{action:"TOOL_CALL",callId,name,arguments}`; the native relay validates that frame and attaches its private run identity before calling Node.

The native PTC callback parser independently restricts names and Android actions to the table above. It retains the existing 32-call cap, Binder sender UID and nonce checks, bounded frames, joined cancellation and durable retirement. The CPU limit is for the V8 execution thread, not an aggregate process CPU or RSS limit.

## Validation

`node --import tsx --test apps/android/tool/model-ptc-readonly.test.mjs` exercises original first-party definitions and the real parent ToolRuntime with a fixture native transport. It checks definition copying and retirement, prohibited actions, bounded pagination, and a [keyless Session transcript](expected/model-ptc-readonly.expected.json). Each callback's recorded JSON is compared byte-for-byte with the guest reply.

`node --import tsx --test apps/android/tool/model-ptc-mutations.test.mjs` exercises the model entry with original Android file tools, real Session JSONL persistence, current-policy changes and attachment materialization. Its native transport is a host fixture, not device evidence.

`node apps/android/tool/acceptance-ptc-script-engine.mjs` checks Java limits and native snapshot semantics on the host. The `ptc-readonly-budget` phase of `IsolatedScriptAcceptanceInstrumentation` checks native admission/action rejection, a callback wait longer than five seconds, and CPU termination under a 120-second wall allowance. These Binder fixtures are separate from production acceptance: real Node-to-native file, SAF, attachment and webpage calls, cancellation, process death and recovery still require device evidence before enabling the model entry.
