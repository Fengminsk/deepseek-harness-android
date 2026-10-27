---
kind: reference
title: Production AgentService account-task acceptance
---

# Production AgentService account-task acceptance

English | [中文](agent-service-task-device.zh.md)

## Summary

This acceptance checks whether the installed App can use its current DeepSeek account and default model to complete and persist one background request while the phone stays locked. The default echo exercise checks a reply without tools; the opt-in `radio-linux` exercise checks one pending Linux call across a measured offline interval. Both use the production AgentService and its existing home with one dedicated Session. Build 116 r33 completed the echo check in 5,051 ms; the retained r32 timeout and process-freeze observations remain unresolved.

## Contents

- [Admission and account use](#admission-and-account-use)
- [Opt-in radio and Linux exercise](#radio-linux)
- [Completion and persistence](#completion-and-persistence)
- [Cleanup and screen protection](#cleanup-and-screen-protection)
- [Build 116 device observations](#build-116-observations)
- [Evidence limits](#evidence-limits)

<a id="admission-and-account-use"></a>
## Admission and account use

The [echo device adapter](acceptance-agent-service-task-device.mjs) requires explicit `acceptRealAccountRequest: true`; the [instrumentation](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskAcceptanceInstrumentation.kt) independently requires the matching argument. The [recovery entry](agent-service-recovery-driver.md#radio-linux) additionally requires explicit radio-change consent for `radio-linux`. The request uses the existing account and can consume its quota. The device must already be locked and noninteractive, and the production runtime must report no running, queued or waiting tasks, background jobs or package operations before admission.

The current default provider must be `deepseek-account`, and its model must appear exactly once in the account's available model catalog. Missing credentials or an unavailable default do not select a replacement. The fixture ensures a newly created Session, gives it a dedicated title, rechecks the default, and submits with `selectModel: false`. It does not change the global model selection or account settings.

Each run uses independent random identifiers for the case, Session, request and export and submits one user message. Echo asks for a unique marker and forbids tools or file reads; any observed `tool/*` event or assistant tool-call block rejects it. Radio permits only the call defined below. These restrictions are prompts and acceptance conditions, not a sandbox: production tool callbacks remain available, and detecting an unexpected tool attempt cannot undo its effects. One user submission does not imply one provider HTTP request; neither exercise establishes the number of provider HTTP requests.

<a id="radio-linux"></a>
## Opt-in radio and Linux exercise

`radio-linux` asks the real account model to invoke `linux_exec` exactly once, with only `command` and `timeoutMs: 120000`. The command must match [the fixed Python script](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt): it measures monotonic time, sleeps for 40 seconds, and prints JSON containing the case marker, its SHA-256 and elapsed milliseconds. It requests no guest network access and reads or changes no files. The model must then return only the marker.

The native `ready` checkpoint requires the durable `tool/call` event, the same running parent task and a still-pending call. That event precedes scheduler preparation and dispatch: readiness does not establish that the Linux guest or Python has started. Each checkpoint binds the case, Session, Agent PID, runtime generation, call ID, call sequence and command digest. The [host validator](agent-service-task-radio.mjs) rejects changed identities, missing pending work, unknown network capabilities or a lost locked/noninteractive state.

The [shared recovery driver](agent-service-recovery-driver.md) disables Wi-Fi and mobile data only after this checkpoint. It confirms both flags are off and no non-VPN INTERNET network remains, then collects at least two observations over a host-monotonic interval of at least 15 seconds. Each must retain the same Agent PID, its running task and the pending Linux call. It restores the exact original flags and observes usable underlying connectivity before allowing the native task to finish. The native offline-to-restored interval must also reach 15 seconds. This establishes sampled continuity of pending work, not continuous guest CPU execution throughout the outage.

Completion must match the original call to one successful `tool/result`, a completed Linux receipt with exit code zero and confirmed guest retirement, and the final marker in both live and flushed Session records. The guest UID must differ from the App UID; the output marker and SHA-256 must match, and the measured wait must be between 39,000 and 120,000 ms. Cancellation, timeout, truncated output, extra calls or cleanup cancellation reject acceptance. This exercise does not test guest networking or an interrupted model HTTP stream and does not establish model transport retry behavior. The [r34 device record](#radio-linux-r34) establishes this exercise's narrower result.

<a id="completion-and-persistence"></a>
## Completion and persistence

Before, during and after the task, the fixture requires the same production AgentService PID and runtime generation, a ready runtime, and a foreground service reported by ActivityManager. During execution it must observe its own Session as running and a fresh native background summary with a positive running count. Foreground service status does not mean a visible Activity: the fixture launches no Activity and adds no wake lock. The App's existing background power policy still applies.

The [evidence validator](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt) requires one user message with the submitted request ID and prompt, the selected account model in every recorded request header, an uninterrupted final assistant message whose text matches the marker, and one completed first turn. Reasoning blocks are allowed. Echo rejects tool-call blocks; radio separately validates its single preceding tool call and result. The received `task.completed` notification must identify the same turn and end sequence. A successful send acknowledgement alone is insufficient.

The fixture compares `session.read` with a flushed `session.export.prepare` result for its own Session, without descendants. It reads only its own canonical UUID-named ZIP in the App export cache, checks the Session ID, and requires a single `session.v4.jsonl` entry within a one-MiB bound. The selected user, request, turn and assistant events must agree between live and durable records. The result retains counts and a digest, not account secrets or the assistant's raw text.

<a id="cleanup-and-screen-protection"></a>
## Cleanup and screen protection

Work has a 300-second total budget, with readiness bounded by 120 seconds from entry and the turn wait bounded by 120 seconds. Native cleanup has at most 60 further seconds, capped at 360 seconds from entry; the radio adapter's independent 330-second host deadline can expire earlier. If a submitted task has not settled, native cleanup first awaits `session.ensure` as an admission barrier, then cancels only that Session and confirms that it has no running, queued or waiting work. It archives the dedicated Session, releases only its own export, and unregisters and unbinds its Messenger connection. Native cleanup does not clear data, stop the service or modify other Sessions; radio's host owner separately restores the network and retires the App and test processes.

Success requires settlement, archive, export release and disconnection, without a cleanup cancellation. Cleanup failure invalidates success. Failures retain bounded codes and exception types rather than account details, model text or arbitrary error messages. The [host checks](acceptance-agent-service-task-host.mjs) compile the instrumentation and exercise the evidence helper, including the original Session export format; they do not establish a real account request or device success.

Native locked/noninteractive observations and parser success do not establish physical panel state or process retirement. The outer device owner must use [screen protection](device-screen-protection.md), preserve its panel observations, close its owned host process, and confirm device retirement before reporting the run as accepted. The echo adapter explicitly returns `physicalPanelEvidence` and `processRetirement` as requiring that outer owner. Neither exercise wakes or unlocks the phone. Echo does not change radios; radio changes and restoration belong only to the [shared host cleanup owner](agent-service-recovery-driver.md).

<a id="build-116-observations"></a>
## Build 116 device observations

The r33 result is `.cache/android/account-task-116-r33-protected-20261028.json.result.json`; the outer report omits `.result.json`. The archived pair is recorded in `.cache/android/device-v116-20261028/r33/archive-manifest.json`: App SHA-256 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`, AndroidTest SHA-256 `b5086aff18d3fcebc02b64de02016627bbeda2e7152d5af04661bb6c55af4a21`. The production App is unchanged from the [116 upgrade record](upgrade-116-acceptance.md).

The real current default `deepseek-account` / `deepseek-flash` completed one submitted user message in dedicated Session `android-account-acceptance-97a23b00-607e-4dbc-b490-1bbdad59361d`; the whole acceptance took 5,051 ms. Its single assistant marker and completed turn matched the live and durable records, with zero tool calls and 15 durable events; history SHA-256 is `3f43f1b8b036079893f7fd8f43c3bcf28c652d3e2b4088ec3af8d80fcf9eb265`. Settlement, export release, Session archive and disconnection succeeded without cleanup cancellation.

AgentService retained PID 6299 and the same runtime generation and foreground status. The task observation had one running task and the production wake lock held; before and after it, the service was idle with zero running tasks and no wake lock held. Native observations were locked and noninteractive. The outer report records five samples with both physical panels Off, actual host close and confirmed device-process retirement. These are sampled states for this short request, not continuous panel or long-suspend evidence.

The earlier `.cache/android/account-task-116-r32-protected-20261028.json.result.json` failed with `DEADLINE_EXCEEDED` after 190,012 ms and zero submissions. At capture, `.cache/android/account-task-r32-scheduler-01.json` read `cgroup.freeze=1` and `cgroup.events` with `frozen 1` for the main PID 28936 and Agent PID 28956. The actor that applied the freeze is unknown. The r33 success and added early progress pulses do not demonstrate a fix for that freeze or explain the r32 timeout.

The read-only `.cache/android/account-task-r33-power-policy.json` records `RUN_ANY_IN_BACKGROUND: allow`, no explicit `RUN_IN_BACKGROUND` record with default mode `allow`, and DSH already in the user device-idle whitelist; `settingsChanged` is false. This is the observed policy configuration, not proof that every system scheduler or freezer permits continued execution.

<a id="radio-linux-r34"></a>
### r34 active Linux call across network loss

The passing record is `.cache/android/radio-linux-116-r34-recovery-20261028.json`; the companion screen report replaces `recovery` with `screen`. The r34 archive manifest in `.cache/android/device-v116-20261028/r34/archive-manifest.json` retains the same App digest recorded above and AndroidTest SHA-256 `ab9149a554af7ba6d0cdb4f0be5a60ebca34c4a795ca356bda550e58a3e844d5`. The current account model completed one user submission, one Linux call and one final marker in 62,902 ms, with 24 durable events. History SHA-256 is `9c5a5d17c9552f7e49941b43bc76dfd2cb9bddf1a91c2deb50f620bd470df96f`.

Host readiness arrived at 13,724.261 ms. Nine offline observations ran from 18,320.3411 to 33,554.017 ms, with the enforced dwell from the first completed offline sample measuring 15,233.6717 ms. Each retained Agent PID 13213, the same runtime generation and call identity, its running parent task and the pending Linux call. The separate native offline-to-restored interval was 18,534 ms. These two clocks have different origins; neither readiness nor these sampled pending states establish when Python began executing.

The final receipt records guest UID 99480, a 40,006 ms Python wait, exit code zero, `diskCommitted: true` and `retirementConfirmed: true`; its output SHA-256 is `67ff8e8ac3df4dffcd6d440fb0cd34f07d33f2f25e7c0ff8452d25d43efd0b2e`. The same call's result and final reply matched live and durable records. Native settlement, Session archive, export release and disconnection completed without cleanup cancellation. Wi-Fi and mobile-data flags returned to their original `1` / `1`, and the outer owner confirmed host close and device-process retirement. All 29 screen samples showed both panels Off, and screen control was restored while noninteractive. Zero retry events were recorded: this run proves completion of the observed pending Linux task after connectivity restoration, not interrupted model HTTP retry, prolonged Doze survival or a fix for the r32 freeze.

<a id="evidence-limits"></a>
## Evidence limits

The r33 result establishes one real account-backed echo request through the production service and its durable reply; r34 additionally establishes one pending Linux call retained across the measured outage and completed after connectivity restoration. Both use new dedicated Sessions. Neither establishes account-login UI or avatar rendering, reopening an older conversation, token refresh, interrupted model HTTP retry, recovery after service death, prolonged Doze operation or the cause or resolution of the r32 freeze. The [idle-service recovery acceptance](agent-service-recovery-driver.md) and [Build 116 upgrade record](upgrade-116-acceptance.md) own their separate observations; neither substitutes for these account-task results.
