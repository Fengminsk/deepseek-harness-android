---
kind: reference
title: Reviewed Linux tools in Android PTC
---

# Reviewed Linux tools in Android PTC

English | [中文](model-ptc-linux.zh.md)

## Summary

The [Linux review](../runtime/model-ptc-linux-review.mjs) lets an admitted Android PTC program compose the parent's original `linux_import`, `linux_exec`, `linux_export` and `linux_inspect` tools. This supports file-analysis sequences without giving the PTC guest Node APIs, App-UID shell, native file grants or network grants. Both PTC and Linux product availability still require their existing device acceptance controls; a tool absent from the parent scope stays absent inside PTC.

## Contents

- [Authority and execution](#authority-and-execution)
- [Results and cancellation](#results-and-cancellation)
- [Verification](#verification)
- [Dev Note](#dev-note)

<a id="authority-and-execution"></a>
## Authority and execution

The review captures only the exact live first-party definition and registration identity. Each call retains the active parent's ToolRuntime token and Agent Session. A replacement registration cannot inherit the review, even under the same name. The original Linux tools continue to resolve the current Session policy and any workflow-child grant; PTC adds no filesystem root, Session identity, persistence override or approval token to model arguments.

`linux_import` and `linux_export` require the live writable policy. Import reads the authorized current Agent workspace; export rejects existing destinations, protected metadata and paths outside that workspace. `linux_exec` under read-only policy discards guest disk changes. The native owner performs its normal first-Session inspection, one-slot admission and retirement checks. `linux_inspect` reports the current Session without replaying or unlocking prior work. The [Linux tool reference](linux-vm-runtime.md) owns those execution and transfer semantics.

Network arguments remain requests, not grants. A networked `linux_exec` crosses the original ApprovalService and [native one-time review](linux-network-native-approval.md), with the same command, caller, audit ID, hosts, budget, persistence and applied route. Approval denial or PTC cancellation cannot produce an execution grant. PTC cannot approve its own request or use its empty native network scope as Linux network authority.

The PTC wall deadline remains 120 seconds for the entire program, including every Linux boot, approval wait and command. It does not reset per call. Each Linux timeout remains capped by its original tool. PTC calls are serial, so Linux steps use the existing single App-wide slot; another owner's busy slot is a failure, not permission to replay automatically. Long work must use suitably bounded direct Linux calls rather than assume PTC extends a command's lifetime.

<a id="results-and-cancellation"></a>
## Results and cancellation

`linux_exec`, `linux_import` and `linux_export` use the reviewed `isolated-execution` effect, even when an execution discards guest changes. They require successful Session flushes after the callback start record and after its terminal record, before journal confirmation and guest delivery. They cannot be relabelled pure or read-only to skip durability. `linux_inspect` keeps the existing read-only append behavior. The [callback port](isolated-tool-call-port.md) owns dispatch and journal ordering.

Linux results retain all bounded native fields; the 48 KiB guest limit never silently drops publication or retirement facts. An oversized result returns an explicit unsupported error and directs the caller to inspect the recorded receipt and `linux_inspect`, without automatically rerunning the command. Bound output in future commands; use the direct tool when its larger reply limit is needed. Native truncation remains the native tool's own fact.

Original Linux deferred contexts are forwarded to the parent and recorded even if ToolRuntime replaces a late success with cancellation. A published export can therefore retain `filePublished:true`, `diskCommitted:false` and `cancelRequested:true` together. Callback close waits for the real nested call; an unconfirmed journal or Session flush withholds PTC success without rewriting a known commit. Recovery inspection, uncertain publication or unconfirmed network-approval cleanup retain their original stop-and-review behavior. An error never implies rollback.

<a id="verification"></a>
## Verification

`node --import tsx --test apps/android/tool/model-ptc-linux.test.mjs` runs the original AgentLoop, ToolRuntime, Linux tool factories, NativeLinuxVm parsing/cancellation, ApprovalService, PTC callback bridge and JSONL persistence. The [recorded projection](expected/model-ptc-linux.expected.json) retains the import/execute/export/inspect sequence. The native PTC and Linux transports are explicitly simulated; actual temporary file reads and writes test the composition, not a guest filesystem or Android publication. On Windows, original atomic Session publication requires host permission when the runner sandbox rejects `MoveFileExW`.

The checks exercise live policy and definition changes, file scope and no-overwrite checks, both durability barriers, publication before cancellation, oversized output, native recovery refusal, original one-time network admission, and cancellation during pending approval. They do not certify native UI gestures, guest Python execution, Android UID/Binder separation, network traffic, shared wall-deadline termination or process-death recovery.

`node apps/android/tool/acceptance-ptc-linux-tools.mjs` compiles and executes the real Kotlin request parser with SDK JSON. It verifies that the four Linux names are admitted only for reviewed PTC, rejects ambient or unreviewed names and malformed frames, and preserves independent receipt facts. The shared [host compiler](kotlin-host-test.mjs) requires JDK 17 or newer, cached Kotlin compiler dependencies and Android 36 SDK sources; it does not assemble or install an APK. Installed-artifact acceptance must still run the production PTC-to-Linux chain and its cancellation path before availability changes.

The `ptc` device suite declares `reviewed-ptc-linux-import-analysis-export` in [its fixture](device-runtime-acceptance/ptc-linux.mjs). Inside the existing real AgentLoop turn it calls the production PTC tool, whose isolated JavaScript guest invokes original Linux import, Python JSON analysis, export and inspection. A new acceptance Session must first inspect as absent; there is no warm-up command or alternate native implementation. The three guest boots share the unchanged 120-second PTC wall limit. The carrier adds only waiting room for this extra check, not execution authority. Missing guest assets, slow execution or unconfirmed retirement are failures.

The check reads the actual exported bytes and independently compares their SHA-256, size and computed result, native import/export paths, original Linux run IDs, App/PTC/Linux UID separation, both disk-commit facts and export publication. It flushes the parent Session and reopens its persistence reader to verify all four callback start/end pairs, three original Linux receipts and the final inspection context. Registrations live in a disposable fiber so `all` can subsequently mount the separate Linux suite owner. Only UUID-named acceptance files are removed; Session logs and native execution records remain evidence.

`node --import tsx --test apps/android/tool/device-runtime-acceptance-ptc-linux.test.mjs apps/android/tool/device-runtime-acceptance-report.test.mjs` checks the fixture's fail-closed validator, generated program's stop-on-uncertainty behavior, original Cordis registration cleanup and required report naming. It runs the exact embedded Python body against actual temporary host files. Synthetic observations used to test the validator and host Python execution are not device evidence. The new device chain remains unverified until run against the installed paired artifacts; it does not certify PTC-to-Linux cancellation, shared-deadline expiry, network approval or process-death recovery. Those boundaries remain separate from a successful offline chain.

<a id="dev-note"></a>
## Dev Note

This adapter remains a reviewed tool subset, not the original unrestricted Node PTC environment. Neither successful host composition nor a declaration-count change supplies the missing production device evidence.
