---
kind: reference
title: Workflow runtime device acceptance
---

# Workflow runtime device acceptance

English | [中文](workflow-device-acceptance.zh.md)

## Summary

The [workflow fixture](device-runtime-acceptance/workflow.mjs) exercises the registered `workflow` tool through the production ToolRuntime, native owner, isolated JavaScript guest, callback bridge, real child Agents and durable Sessions. Only the model stream is scripted. Its eleven named checks require actual Android receipts; passing the host checks or the separate native-only instrumentation does not establish this runtime acceptance.

## Contents

- [Execution and evidence](#execution-and-evidence)
- [Scenarios](#scenarios)
- [Unverified behavior](#unverified-behavior)
- [Host verification](#host-verification)
- [Dev Note](#dev-note)

<a id="execution-and-evidence"></a>
## Execution and evidence

The [runtime carrier](device-runtime-acceptance.md) selects this fixture with `suite=workflow`, or before PTC and Linux with `suite=all`. It uses a dedicated acceptance home and parent Session. The fixture first verifies that default registration is unavailable, then registers the original tool with an acceptance-only availability callback. It does not change the product's capability settings. The default Activity carrier requires an already unlocked phone and a drawn, focused, all-black window. Explicit `foregroundCarrier=service` uses the non-visual acceptance service and supports a locked, noninteractive phone; the [OLED wrapper](device-screen-protection.md) separately verifies that every internal panel stays powered off. Neither carrier may wake or unlock the phone.

The eleven checks issue fourteen workflow runs: JSON rejection uses three runs, and the two limit checks use two runs. Each production run retains its 120-second ceiling; the carrier must budget all runs plus bounded retirement, rather than assume one ceiling covers the suite. Child concurrency remains two and total children remain eight per run. A failed check stops subsequent checks, aborts and joins foreground tool calls, and leaves owner disposal to cancel and join background work before the carrier finishes.

Each passing run requires the actual native settlement receipt, an acknowledged native release, a matching read-only native inspection, and one durable parent `run-start` / `run-end` pair. Every reserved child must be `RETIRED` and absent from the live Agent registry. Activated children additionally require distinct nonempty durable Session logs; the report includes their IDs, event counts and SHA-256 values. An authorization rejection can reserve an ID without activating an Agent; the report distinguishes that case instead of inventing a child Session.

The fixture records `phase` and `log` only after the production callback acknowledges them, preserving order and child phase labels. These two progress kinds are not standalone durable Session events in the current workflow recorder. Child start/end and run start/end events are durable. The report does not describe callback observations as persisted phase/log history.

<a id="scenarios"></a>
## Scenarios

The [named check definitions](device-runtime-acceptance/workflow-checks.mjs) are the report authority. The following rows describe the executed behavior and required result; an expected workflow failure is a passing check only when retirement and durable failure are confirmed.

| Behavior | Required observation |
| --- | --- |
| Pure computation | Original ToolRuntime invocation returns `42` with no child reservation. |
| Plain child | One real Agent returns the scripted text and retains its separate Session after disposal. |
| `parallel`, `pipeline`, `phase`, `log` | Two model streams meet at a barrier, four children complete, pipeline stages preserve original item/index, ordinary thunk failure becomes `null`, and acknowledged progress has the expected order. |
| Structured JSON | A real `structured_output` tool call and matching successful result are in the child Session; nested JSON, Unicode, nulls and repeated shared values return without lossy coercion. |
| Invalid JSON | A cycle, negative zero and an undefined object member each produce native `FAILED`, no successful output and confirmed retirement. |
| Limits | Eight children complete; a ninth cannot start even if the script catches the error. A 33-item parallel request also fails without child activation. |
| Ordinary child failure | An intentional model exception produces a failed child and a `null` item while its sibling completes; the workflow itself completes. |
| Infrastructure failure | A child provider-route widening is rejected by the real authorization path; the workflow fails, including retirement of an already activated sibling and the denied reservation. |
| Foreground cancellation | Abort occurs after the held child enters its model stream; the child observes cancellation and the native run ends `CANCELLED`. |
| Background completion | The original jobs registry reaches `completed`; `job_output` returns the child result and the run is durably complete. |
| Background cancellation | The original `job_kill` cancels a held child; `killed` requires native cancellation, child retirement and the durable cancelled run. |

<a id="unverified-behavior"></a>
## Unverified behavior

The fixture always declares three separate evidence gaps: native deadline while waiting on nested work, workflow Binder death / App restart, and workflow-record retention across upgrade. Eleven passing checks therefore mean executed checks passed, while `complete` remains false. The [aggregator](device-runtime-acceptance/report.mjs) also retains these gaps if a producer omits them; numeric pass counters cannot replace named results.

These checks do not establish actual provider/network behavior, child file/web permission inheritance, Linux child execution, infinite-loop termination, or process-death recovery. The [runtime suite](device-runtime-acceptance.md), [child tool tests](workflow-child-tools.test.mjs) and [lifecycle reference](linux-vm-lifecycle-device.md) own their respective evidence. Process termination and APK installation can remove the black foreground Activity; they require a separate screen-preservation strategy and must not run under an unsupported all-black requirement.

<a id="host-verification"></a>
## Host verification

`node --import tsx --test apps/android/tool/device-runtime-acceptance-workflow-model.test.mjs` checks real AgentLoop / ToolRuntime / JSONL children: simultaneous model streams, ordinary failure, structured output, cancellation, route denial and the eight-child limit. Route-denial checks also exercise the production callback envelope and its single-use, exact-run-and-child attestation; a denied start does not itself retire a held sibling. It drives production Node ports without a native guest and creates no Android receipt. Windows requires permission for atomic Session JSONL publication; a host filesystem denial is a failed test, not a device result.

Failure reports preserve the native receipt, release acknowledgement, Node callback-close observations and per-child native state separately. At most eight failed runs receive a three-second diagnostic inspection, including current Agent liveness; an unavailable inspection remains explicit. These observations do not turn an unconfirmed receipt into a passing check. `node --import tsx --test apps/android/tool/workflow-failure-observation.test.mjs` checks that failure-report behavior and its deadline, without executing device acceptance.

`node --test apps/android/tool/device-runtime-acceptance-report.test.mjs` verifies named aggregation, including rejection of historical three-case coverage, failed checks hidden behind counters, and omitted lifecycle gaps. `node apps/android/tool/check-device-runtime-profile.mjs` imports the copied fixture through the normal `dsh` profile and stops at the first native admission request. It verifies startup only and neither runs nor simulates native workflow completion.

<a id="dev-note"></a>
## Dev Note

The model adapter controls only streamed model content and cooperative waiting. It does not forge tool results, Session events, native settlement, release or retirement. Preserve the raw device report and its named unverified checks; adding this fixture does not enable model-facing workflow execution.
