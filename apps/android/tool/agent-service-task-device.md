---
kind: reference
title: Production AgentService account-task acceptance
---

# Production AgentService account-task acceptance

English | [中文](agent-service-task-device.zh.md)

## Summary

This acceptance checks whether the installed App can use its current DeepSeek account and default model to complete and persist one background request while the phone stays locked. It uses the production AgentService and its existing home, creates one dedicated Session, and checks the actual assistant reply. Build 116 r33 completed this check in 5,051 ms; the retained r32 timeout and process-freeze observations remain unresolved.

## Contents

- [Admission and account use](#admission-and-account-use)
- [Completion and persistence](#completion-and-persistence)
- [Cleanup and screen protection](#cleanup-and-screen-protection)
- [Build 116 device observations](#build-116-observations)
- [Evidence limits](#evidence-limits)

<a id="admission-and-account-use"></a>
## Admission and account use

The [device adapter](acceptance-agent-service-task-device.mjs) requires explicit `acceptRealAccountRequest: true`; the [instrumentation](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskAcceptanceInstrumentation.kt) independently requires the matching argument. The request uses the existing account and can consume its quota. The device must already be locked and noninteractive, and the production runtime must report no running, queued or waiting tasks, background jobs or package operations before admission.

The current default provider must be `deepseek-account`, and its model must appear exactly once in the account's available model catalog. Missing credentials or an unavailable default do not select a replacement. The fixture ensures a newly created Session, gives it a dedicated title, rechecks the default, and submits with `selectModel: false`. It does not change the global model selection or account settings.

Each run uses independent random identifiers for the case, Session, request and export. It submits one user message asking for a unique marker and forbidding tools or file reads. This restriction is a prompt and an acceptance condition, not a sandbox: production tool callbacks remain available, and detecting a tool attempt cannot undo its effects. Any observed `tool/*` event or assistant tool-call block rejects acceptance. One user submission does not imply one provider HTTP request; retries and other provider traffic are not counted by this fixture.

<a id="completion-and-persistence"></a>
## Completion and persistence

Before, during and after the task, the fixture requires the same production AgentService PID and runtime generation, a ready runtime, and a foreground service reported by ActivityManager. During execution it must observe its own Session as running and a fresh native background summary with a positive running count. Foreground service status does not mean a visible Activity: the fixture launches no Activity and adds no wake lock. The App's existing background power policy still applies.

The [evidence validator](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt) requires one user message with the submitted request ID and prompt, the selected account model in every recorded request header, one uninterrupted assistant message whose text matches the marker, and one completed first turn. Reasoning blocks are allowed; tool-call blocks are rejected. The received `task.completed` notification must identify the same turn and end sequence. A successful send acknowledgement alone is insufficient.

The fixture compares `session.read` with a flushed `session.export.prepare` result for its own Session, without descendants. It reads only its own canonical UUID-named ZIP in the App export cache, checks the Session ID, and requires a single `session.v4.jsonl` entry within a one-MiB bound. The selected user, request, turn and assistant events must agree between live and durable records. The result retains counts and a digest, not account secrets or the assistant's raw text.

<a id="cleanup-and-screen-protection"></a>
## Cleanup and screen protection

Work has a 300-second total budget, with readiness bounded by 120 seconds from entry and the turn wait bounded by 120 seconds. Cleanup has a separate allowance of at most 60 seconds. If a submitted task has not settled, cleanup first awaits `session.ensure` as an admission barrier, then cancels only that Session and confirms that it has no running, queued or waiting work. It archives the dedicated Session, releases only its own export, and unregisters and unbinds its Messenger connection. It does not clear data, stop the service or modify other Sessions.

Success requires settlement, archive, export release and disconnection, without a cleanup cancellation. Cleanup failure invalidates success. Failures retain bounded codes and exception types rather than account details, model text or arbitrary error messages. The [host checks](acceptance-agent-service-task-host.mjs) compile the instrumentation and exercise the evidence helper, including the original Session export format; they do not establish a real account request or device success.

Native locked/noninteractive observations and parser success do not establish physical panel state or process retirement. The outer device owner must use [screen protection](device-screen-protection.md), preserve its panel observations, close its owned host process, and confirm device retirement before reporting the run as accepted. The adapter explicitly returns `physicalPanelEvidence` and `processRetirement` as requiring that outer owner. No wake, unlock or radio-change operation belongs to this fixture.

<a id="build-116-observations"></a>
## Build 116 device observations

The r33 result is `.cache/android/account-task-116-r33-protected-20261028.json.result.json`; the outer report omits `.result.json`. The archived pair is recorded in `.cache/android/device-v116-20261028/r33/archive-manifest.json`: App SHA-256 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`, AndroidTest SHA-256 `b5086aff18d3fcebc02b64de02016627bbeda2e7152d5af04661bb6c55af4a21`. The production App is unchanged from the [116 upgrade record](upgrade-116-acceptance.md).

The real current default `deepseek-account` / `deepseek-flash` completed one submitted user message in dedicated Session `android-account-acceptance-97a23b00-607e-4dbc-b490-1bbdad59361d`; the whole acceptance took 5,051 ms. Its single assistant marker and completed turn matched the live and durable records, with zero tool calls and 15 durable events; history SHA-256 is `3f43f1b8b036079893f7fd8f43c3bcf28c652d3e2b4088ec3af8d80fcf9eb265`. Settlement, export release, Session archive and disconnection succeeded without cleanup cancellation.

AgentService retained PID 6299 and the same runtime generation and foreground status. The task observation had one running task and the production wake lock held; before and after it, the service was idle with zero running tasks and no wake lock held. Native observations were locked and noninteractive. The outer report records five samples with both physical panels Off, actual host close and confirmed device-process retirement. These are sampled states for this short request, not continuous panel or long-suspend evidence.

The earlier `.cache/android/account-task-116-r32-protected-20261028.json.result.json` failed with `DEADLINE_EXCEEDED` after 190,012 ms and zero submissions. At capture, `.cache/android/account-task-r32-scheduler-01.json` read `cgroup.freeze=1` and `cgroup.events` with `frozen 1` for the main PID 28936 and Agent PID 28956. The actor that applied the freeze is unknown. The r33 success and added early progress pulses do not demonstrate a fix for that freeze or explain the r32 timeout.

The read-only `.cache/android/account-task-r33-power-policy.json` records `RUN_ANY_IN_BACKGROUND: allow`, no explicit `RUN_IN_BACKGROUND` record with default mode `allow`, and DSH already in the user device-idle whitelist; `settingsChanged` is false. This is the observed policy configuration, not proof that every system scheduler or freezer permits continued execution.

<a id="evidence-limits"></a>
## Evidence limits

The r33 result establishes one real account-backed request through the production service and its durable reply in a new dedicated Session. It does not establish account-login UI or avatar rendering, reopening an older conversation, token refresh, active-request survival through network loss, recovery after service death, or prolonged Doze operation. The [idle-service recovery acceptance](agent-service-recovery-driver.md) and [Build 116 upgrade record](upgrade-116-acceptance.md) own their separate observations; neither substitutes for this account-task result.
