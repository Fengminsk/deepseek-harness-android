---
kind: reference
title: Production AgentService account-task acceptance
---

# Production AgentService account-task acceptance

English | [中文](agent-service-task-device.zh.md)

## Summary

This acceptance checks whether the installed App can use its current DeepSeek account and default model to complete and persist one background request while the phone stays locked. The default echo exercise checks a reply without tools; the opt-in `radio-linux` exercise checks one pending Linux call across a measured offline interval. Both use the production AgentService and its existing home with one dedicated Session. Build 116 r33 completed the echo check in 5,051 ms; the retained r32 timeout and process freeze are attributed to the device's OEM freezer, which froze the App while AMS reported no freeze.

## Contents

- [Admission and account use](#admission-and-account-use)
- [Opt-in radio and Linux exercise](#radio-linux)
- [Programmatic and child Linux exercises](#programmatic)
- [Completion and persistence](#completion-and-persistence)
- [Opt-in system completion notice](#completion-notice)
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

<a id="programmatic"></a>
## Programmatic and child Linux exercises

The task adapter also accepts explicit `exercise: 'ptc'`, `'workflow'` or `'workflow-linux'`. Each requires the current real account, one dedicated parent Session and the same outer screen and retirement owner. The [programmatic validator](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceProgrammaticEvidence.kt) requires the fixed parent tool arguments and result, ordered callback or member events, a completed parent reply and matching live and durable records. `ptc` permits only one reviewed `list_agents` callback. `workflow` requires one completed child with its own marker and no tools. Both parent and validated child are archived through their original owners; the child uses `workspace.archiveSession`, whose receipt contains the complete archive set. Cleanup failure remains an acceptance failure.

`workflow-linux` asks that child to call `linux_exec` once with the [fixed offline Python file task](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceChildLinuxEvidence.kt). It writes only its generated input inside a new temporary directory under the child's `/workspace`, packs and reads back a ZIP, checks the content, computes SHA-256 and removes the temporary directory. The child's reply and parent workflow result must contain the exact child marker, digest and byte count. Its independently exported Session must contain the matching Linux call, native result and source-event link. Acceptance requires completed execution, exit zero, confirmed guest retirement, a guest UID different from the production App UID, no timeout, cancellation or truncation, and confirmed temporary-file cleanup. `diskCommitted` records the actual policy outcome: a read-only child may finish this temporary task without committing its disk. This exercise imports no phone files and requests no guest networking; account model traffic still occurs. Focused host checks validate the carrier and evidence rules; they do not certify a real-device child Linux run.

Argument mismatches retain `PROGRAMMATIC_ARGUMENTS_CHANGED` and attach fixed-field diagnostics: presence, type, UTF-8 byte length, SHA-256 and equality for `code` / `description` or `script` / `meta` / `meta.name` / `meta.description`. Unknown field names and raw values are never emitted; extra fields are counted. These observations do not relax exact argument equality or undo a tool already dispatched before the event was checked.

The separate `runAgentServiceTaskDiagnostic` adapter selects `workflow-diagnose`, `diagnosticCaseId`, the original `workflow` or `workflow-linux` exercise, and `acceptRealAccountRequest: false`. It reads only the named dedicated parent and a uniquely recorded child, compares live history with owned exports, and validates the original parent request and prompt. Verified child lineage additionally requires its exported header to identify that parent and `origin: subagent`. Missing member records, conflicting lineage and unavailable child evidence remain explicit; none authorizes cleanup or certifies the original task. The diagnostic makes no Session ensure, send, cancel or archive request and releases only its own exports. Existing `workflow-cleanup` remains a separate, completed-workflow-only mode. `parseAgentServiceTaskDiagnosticResult` preserves the outer screen and process-retirement obligations.

The r42 `workflow-linux` attempt remains rejected by exact argument comparison. Its read-only r43 diagnosis, `.cache/android/workflow-linux-r42-diagnostic-under-120-r43-20261028.json.result.json`, found matching metadata and no extra fields, but a 1,311-byte expected script versus 1,308 observed bytes. The local fixed-fixture calculation `.cache/android/workflow-linux-r42-slash-variants.json` matched the observed SHA-256 `5c22393b82ee9ee59c7e1abb1abb92c534cec313add8c4fcb7b314d33f56368b` in exactly one of 128 slash-escape variants: one redundant backslash was removed at each of three nested-JSON slashes. Both decode to the same child prompt. This explains the mismatch; it does not certify task execution or change the accepted input. The diagnostic recorded one workflow start and no member record (`no_member_record`), which establishes neither that no child was created nor permission to archive a child.

<a id="completion-and-persistence"></a>
## Completion and persistence

Before, during and after the task, the fixture requires the same production AgentService PID and runtime generation, a ready runtime, and a foreground service reported by ActivityManager. During execution it must observe its own Session as running and a fresh native background summary with a positive running count. Foreground service status does not mean a visible Activity: the fixture launches no Activity and adds no wake lock. The App's existing background power policy still applies.

The [evidence validator](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt) requires one user message with the submitted request ID and prompt, the selected account model in every recorded request header, an uninterrupted final assistant message whose text matches the marker, and one completed first turn. Reasoning blocks are allowed. Echo rejects tool-call blocks; radio separately validates its single preceding tool call and result. The received `task.completed` notification must identify the same turn and end sequence. A successful send acknowledgement alone is insufficient.

The fixture compares `session.read` with a flushed `session.export.prepare` result for its own Session, without descendants. It reads only its own canonical UUID-named ZIP in the App export cache, checks the Session ID, and requires a single `session.v4.jsonl` entry within a one-MiB bound. The selected user, request, turn and assistant events must agree between live and durable records. The result retains counts and a digest, not account secrets or the assistant's raw text.

<a id="completion-notice"></a>
## Opt-in system completion notice

The echo adapter and result parser accept an explicit `requireCompletionNotice: true` option, passed to instrumentation as `-e requireCompletionNotice true`. The default is false; an ordinary echo pass cannot certify notification delivery. Before submission, this option checks the App's notification permission, notification enablement and existing `task-completed` channel without changing them.

After the real `task.completed` signal and matching durable final response, the fixture waits at most eight seconds for exactly one active Android notification with this Session's tag and notification ID 3. It checks the exact synthetic marker, channel, private visibility, auto-cancel flag, and a content PendingIntent created by this App's package and UID. The report retains hashes and fixed facts, not notification text. It neither reads cross-process SharedPreferences nor sends the PendingIntent; `notificationTapTested` remains false. Thus it does not verify tapping the notice or opening its Session.

Cleanup cancels only this run's exact notification tag and ID and waits at most three seconds to confirm its absence. It leaves user notifications and preferences untouched. Success requires `cleanup.completionNoticeCancelled: true`; failure invalidates acceptance. The [host adapter checks](acceptance-agent-service-task-device.test.mjs) cover explicit admission and invalid notice evidence. The [r35 device record](#completion-notice-r35) establishes delivery for this option; r33 and r34 did not inspect active system notifications. The independent [receipt crash acceptance](task-completion-device-acceptance.md) covers a different path and remains separate.

<a id="cleanup-and-screen-protection"></a>
## Cleanup and screen protection

Work has a 300-second total budget, with readiness bounded by 120 seconds from entry and the turn wait bounded by 120 seconds. Native cleanup has at most 60 further seconds, capped at 360 seconds from entry; the radio adapter's independent 330-second host deadline can expire earlier. If a submitted task has not settled, native cleanup first awaits `session.ensure` as an admission barrier, then cancels only that Session and confirms that it has no running, queued or waiting work. It archives the dedicated Session, releases only its own export, and unregisters and unbinds its Messenger connection. Native cleanup does not clear data, stop the service or modify other Sessions; radio's host owner separately restores the network and retires the App and test processes.

Success requires settlement, archive, export release and disconnection, without a cleanup cancellation. Cleanup failure invalidates success. Failures retain bounded codes, exception types and the fixed-field fingerprints above rather than account details, model text or arbitrary error messages. The [host checks](acceptance-agent-service-task-host.mjs) compile the instrumentation and exercise the evidence helper, including the original Session export format; they do not establish a real account request or device success.

Native locked/noninteractive observations and parser success do not establish physical panel state or process retirement. The outer device owner must use [screen protection](device-screen-protection.md), preserve its panel observations, close its owned host process, and confirm device retirement before reporting the run as accepted. The echo adapter explicitly returns `physicalPanelEvidence` and `processRetirement` as requiring that outer owner. Neither exercise wakes or unlocks the phone. Echo does not change radios; radio changes and restoration belong only to the [shared host cleanup owner](agent-service-recovery-driver.md).

<a id="build-116-observations"></a>
## Build 116 device observations

The r33 result is `.cache/android/account-task-116-r33-protected-20261028.json.result.json`; the outer report omits `.result.json`. The archived pair is recorded in `.cache/android/device-v116-20261028/r33/archive-manifest.json`: App SHA-256 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`, AndroidTest SHA-256 `b5086aff18d3fcebc02b64de02016627bbeda2e7152d5af04661bb6c55af4a21`. The production App is unchanged from the [116 upgrade record](upgrade-116-acceptance.md).

The real current default `deepseek-account` / `deepseek-flash` completed one submitted user message in dedicated Session `android-account-acceptance-97a23b00-607e-4dbc-b490-1bbdad59361d`; the whole acceptance took 5,051 ms. Its single assistant marker and completed turn matched the live and durable records, with zero tool calls and 15 durable events; history SHA-256 is `3f43f1b8b036079893f7fd8f43c3bcf28c652d3e2b4088ec3af8d80fcf9eb265`. Settlement, export release, Session archive and disconnection succeeded without cleanup cancellation.

AgentService retained PID 6299 and the same runtime generation and foreground status. The task observation had one running task and the production wake lock held; before and after it, the service was idle with zero running tasks and no wake lock held. Native observations were locked and noninteractive. The outer report records five samples with both physical panels Off, actual host close and confirmed device-process retirement. These are sampled states for this short request, not continuous panel or long-suspend evidence.

The earlier `.cache/android/account-task-116-r32-protected-20261028.json.result.json` failed with `DEADLINE_EXCEEDED` after 190,012 ms and zero submissions. At capture, `.cache/android/account-task-r32-scheduler-01.json` read `cgroup.freeze=1` and `cgroup.events` with `frozen 1` for the main PID 28936 and Agent PID 28956. The device's OEM freezer applied that state: on 2026-10-28 the installed Build 120 logged `OplusHansManager ... freeze uid: 10496 com.minnnng.dsh_android ... scene: |StrictMode-3|LcdOff` while `AgentService` was a foreground service and AMS reported `isFrozen=false`, so AMS never owned it. That freezer ignores the foreground service and is outside the App's control; `AgentService` now records suspension intervals and reports them with a failure. The r33 success and added early progress pulses are not a fix for that freeze, and the late deadline is explained by the suspension rather than by a slow model or tool.

The read-only `.cache/android/account-task-r33-power-policy.json` records `RUN_ANY_IN_BACKGROUND: allow`, no explicit `RUN_IN_BACKGROUND` record with default mode `allow`, and DSH already in the user device-idle whitelist; `settingsChanged` is false. This is the observed policy configuration, not proof that every system scheduler or freezer permits continued execution.

<a id="radio-linux-r34"></a>
### r34 active Linux call across network loss

The passing record is `.cache/android/radio-linux-116-r34-recovery-20261028.json`; the companion screen report replaces `recovery` with `screen`. The r34 archive manifest in `.cache/android/device-v116-20261028/r34/archive-manifest.json` retains the same App digest recorded above and AndroidTest SHA-256 `ab9149a554af7ba6d0cdb4f0be5a60ebca34c4a795ca356bda550e58a3e844d5`. The current account model completed one user submission, one Linux call and one final marker in 62,902 ms, with 24 durable events. History SHA-256 is `9c5a5d17c9552f7e49941b43bc76dfd2cb9bddf1a91c2deb50f620bd470df96f`.

Host readiness arrived at 13,724.261 ms. Nine offline observations ran from 18,320.3411 to 33,554.017 ms, with the enforced dwell from the first completed offline sample measuring 15,233.6717 ms. Each retained Agent PID 13213, the same runtime generation and call identity, its running parent task and the pending Linux call. The separate native offline-to-restored interval was 18,534 ms. These two clocks have different origins; neither readiness nor these sampled pending states establish when Python began executing.

The final receipt records guest UID 99480, a 40,006 ms Python wait, exit code zero, `diskCommitted: true` and `retirementConfirmed: true`; its output SHA-256 is `67ff8e8ac3df4dffcd6d440fb0cd34f07d33f2f25e7c0ff8452d25d43efd0b2e`. The same call's result and final reply matched live and durable records. Native settlement, Session archive, export release and disconnection completed without cleanup cancellation. Wi-Fi and mobile-data flags returned to their original `1` / `1`, and the outer owner confirmed host close and device-process retirement. All 29 screen samples showed both panels Off, and screen control was restored while noninteractive. Zero retry events were recorded: this run proves completion of the observed pending Linux task after connectivity restoration, not interrupted model HTTP retry, prolonged Doze survival or a suppression of the OEM freeze recorded for r32.

<a id="completion-notice-r35"></a>
### r35 real task and system completion notice

The passing result is `.cache/android/account-notice-116-r35-protected-20261028.json.result.json`; the companion screen report omits `.result.json`. The r35 archive manifest in `.cache/android/device-v116-20261028/r35/archive-manifest.json` retains the unchanged production App digest recorded above and AndroidTest SHA-256 `dc06f94ba4fc2861f8e861609e4d52350afb64127b208f5e36169eb2a2b6a926`. With `requireCompletionNotice: true`, the current `deepseek-account` / `deepseek-flash` completed one user submission and one final marker, with zero tools and 15 durable events, in 6,753 ms. Its history SHA-256 is `205e1c6f00a7d49456264f366d1d0124be688813d60e7c4f6f5aa08ec944458b`.

Exactly one active notification matched the dedicated Session tag, ID 3, `task-completed` channel and marker preview. Private visibility, auto-cancel and the App-owned content PendingIntent were confirmed; cleanup confirmed cancellation of that notification and completion of Session archive, export release and disconnection. The outer owner recorded six samples with both OLED panels Off and confirmed host and device-process retirement, then restored screen control while noninteractive. No PendingIntent was sent: this verifies real completion-notice posting and cleanup, not notification tapping, Session navigation or receipt recovery after a crash. It does not prevent the OEM freeze recorded for r32.

<a id="evidence-limits"></a>
## Evidence limits

The r33 result establishes one real account-backed echo request through the production service and its durable reply; r34 additionally establishes one pending Linux call retained across the measured outage and completed after connectivity restoration; r35 establishes a real task's system completion notice and its cleanup. All use new dedicated Sessions. They do not establish notification tapping, account-login UI or avatar rendering, reopening an older conversation, token refresh, interrupted model HTTP retry, recovery after service death, prolonged Doze operation or a fix for the OEM freeze recorded for r32. The [idle-service recovery acceptance](agent-service-recovery-driver.md) and [Build 116 upgrade record](upgrade-116-acceptance.md) own their separate observations; neither substitutes for these account-task results.
