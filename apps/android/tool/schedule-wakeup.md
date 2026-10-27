# Android scheduled wake-up

English | [中文](schedule-wakeup.zh.md)

## Summary

Scheduled wake-up lets Android start the existing Agent service when a saved reminder is due. It is disabled by default and requires the user's exact-alarm permission. Android stores only a wake-up index; the original schedule service still decides which reminder is active, submits its input and records its outcome. Registering an alarm does not confirm task delivery.

## Table of Contents

- [Enablement and status](#enablement-and-status)
- [Projection and ownership](#projection-and-ownership)
- [Alarm delivery and recovery](#alarm-delivery-and-recovery)
- [Process and boot limits](#process-and-boot-limits)
- [Validation](#validation)
- [Dev Note](#dev-note)

-----

## Enablement and status
<a id="enablement-and-status"></a>

The [background settings section](../lib/schedule_wake_settings.dart) separates the enable preference from Android authorization and the observed alarm state. Opening Android's exact-alarm settings never enables scheduling. Enabling without permission is rejected without saving the preference; disabling invalidates the current alarm token. Status reads do not register alarms or change settings. The permission check uses `canScheduleExactAlarms()`; registration uses an immutable `PendingIntent` with `setExactAndAllowWhileIdle(RTC_WAKEUP, ...)`, subject to Android's [exact-alarm requirements](https://developer.android.com/develop/background-work/services/alarms).

The native status distinguishes an unknown or unavailable catalog, an empty ready catalog, scheduled delivery, a wake in progress, missing permission and an operational error. A durable write failure closes wake admission for that controller instance because its result can be unknown. Missing storage starts disabled; unreadable or corrupt existing storage is retained, reports a fixed error and disables this feature without failing Agent startup. Explicit restoration rereads the stored record; it does not replace a corrupt record with an empty one.

## Projection and ownership
<a id="projection-and-ownership"></a>

The [runtime projection owner](../runtime/native-schedule-wakeup.mjs), registered by the Android profile, subscribes before reading the original schedule catalog. It sends the active count and earliest due time, or an explicit unavailable state. It excludes prompts, reminder IDs, Session IDs and account data. A read crossed by a committed schedule change cannot rearm its obsolete result. An unconfirmed native update stops further projection writes; local cancellation does not establish that Android cancelled a write already dispatched.

The [controller](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeupController.kt) accepts only the current service generation and increasing revision. A new generation invalidates older RPCs without deleting a future alarm; ordinary unbinding also retains that alarm. Every replan durably invalidates the old token before cancelling its Android registration and creates a new token before arming. The record is an index, not task authority: neither the projection nor the receiver submits model input, changes reminder contents or replays an uncertain core operation. The original scheduler's persistence and submission sequence remains unchanged.

## Alarm delivery and recovery
<a id="alarm-delivery-and-recovery"></a>

The [receiver](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeupReceiver.kt) and [Android owner](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeup.kt) run in `:agent`. A matching token must still be enabled, authorized and due before the receiver durably changes it to `waking`. Duplicate claims fail. The Service then rechecks that same `waking` token; a direct Service intent cannot claim a merely scheduled alarm.

An alarm may have registered successfully immediately before its process dies, leaving a token-bearing `pending` record. Its actual delivery can claim that record directly after cold start, without a prior restore call. A cancellation-pending record without a current token cannot claim; an explicit registration-error record also remains rejected. Restoration cancels tracked old registrations before retrying the persisted desired time. `armedAtMs` is the actual alarm target, the later of the due time and the current wall clock; a backwards clock change cannot make an old token immediately eligible before that target.

After a successful claim, the Android owner requests a partial wake lock with a 120-second timeout and starts the existing foreground Agent service. This bounds the startup handoff rather than granting an indefinite task lease. The owner releases it after a fresh background observation shows the due obligation has cleared and either the normal task wake lock is held or the task state is idle/attention. Disabling, service shutdown and startup failure also release it; expiry records a fixed failure. Foreground-service admission, runtime startup and vendor scheduling can still fail. The handoff does not itself prove that a reminder ran or that the device remained continuously runnable.

On terminal runtime failure, `AgentService.reportFailure` invokes the [handoff cleanup](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeupHandoff.kt) before process teardown. It checks the service generation, attempts to record `runtime_unavailable` for the current handoff token and explicitly releases that handoff in `finally`. A persistence failure cannot skip release or interrupt the failure path's process retirement. An obsolete generation cannot release a newer handoff, and an obsolete token cannot invalidate a newer future alarm.

## Process and boot limits
<a id="process-and-boot-limits"></a>

An Android alarm can outlive ordinary process death. System force-stop is different: Android 15 and later cancel the package's pending intents and keep it stopped until user interaction removes that state. A force-stop test therefore cannot stand in for natural alarm delivery after process death. The implementation does not bypass stopped state or change system/vendor allowlists. See Android's [stopped-state behavior](https://developer.android.com/about/versions/15/behavior-changes-all#stopped-state).

The index uses credential-encrypted App storage, and the receiver is not direct-boot aware. Restoration waits until the user has unlocked once after boot; `BOOT_COMPLETED` then provides the manifest-receiver path. Relocking after that first unlock does not make credential-encrypted storage unavailable. Package replacement, clock/time-zone changes and an exact-alarm permission grant also reconcile the stored hint. A manifest `USER_UNLOCKED` filter is not an independent restoration path: Android sends that action only to dynamically registered receivers. These are [Direct Boot](https://developer.android.com/privacy-and-security/direct-boot) and [broadcast](https://developer.android.com/reference/android/content/Intent#ACTION_USER_UNLOCKED) limits, not guarantees of timely vendor delivery.

## Validation
<a id="validation"></a>

The host runner compiles the production Kotlin controller, handoff helper and `RuntimeLifecycle` with Android's JSON implementation and runs deterministic storage, alarm and concurrency substitutes:

```powershell
node apps/android/tool/acceptance-schedule-wakeup-host.mjs
```

Use `node apps/android/tool/acceptance-schedule-wakeup-host.mjs --handoff-only` to execute only the five terminal-handoff checks; it does not rerun the 23 controller checks.

Device acceptance still needs an authorized dedicated reminder with a confirmed native alarm, ordinary Agent process termination, and actual alarm-driven startup while locked with both physical panels Off. No test-held CPU lease or foreground test carrier may keep the target alive during the waiting interval. Evidence must bind the due alarm to the new Agent process and the original scheduler's durable task outcome. Cancellation and replacement must reject stale tokens without submitting work. Permission revocation/grant and reboot restoration require their own evidence; they cannot be inferred from a passing process-death case. Any fixture cleans only its own reminder and restores its changed preference. No natural-alarm device result is recorded here.

## Dev Note
<a id="dev-note"></a>

Host validation record: 23 controller checks passed, with the report at `.cache/android/schedule-wakeup-host-mETBIN/report.json`. A separate `--handoff-only` run passed five checks against the real controller and `RuntimeLifecycle`, recorded in `.cache/android/schedule-wakeup-host-pWZLbA/handoff-report.json`. The existing terminal failure path already called `killProcess`, which releases OS-held wake locks when the process dies. The added cleanup records the generation-bound failure and explicitly releases the handoff before exit; these checks do not establish a prior 120-second lock leak.

The [projection tests](native-schedule-wakeup.test.mjs) passed 29 checks. The [settings tests](../test/schedule_wake_settings_test.dart) plus [background settings tests](../test/background_settings_test.dart) have 31 previously passing checks and one separately passing error-priority regression, for 32 checks in total; the full set of 32 was not rerun together.

The [schedule profile smoke](smoke-schedule.mjs) passed in 17.781 seconds through the production bootstrap and original `schedule_create` tool/API. The log `.cache/android/schedule-wakeup-profile-smoke-fixed.log` records empty → created → rescheduled → deleted → empty, with projection revisions 1, 2, 3 and 4. A separate near-term reminder produced one durable delivery receipt identifying exactly one inserted input in its owning Session, then became inactive. The native alarm bridge was a mock: `kind="protocol-only"` and `systemAlarmsRegistered=0`. This verifies the host profile's original scheduler and projection path, not an Android alarm registration or natural device wake. None of these host results establishes long-Doze survival or a fix for earlier intermittent process freezes.
