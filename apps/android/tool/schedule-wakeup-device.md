# Natural schedule-wake acceptance

[中文](schedule-wakeup-device.zh.md)

This test checks whether an Android alarm starts a new production AgentService process and delivers a reminder to its original Session. It requires the user to grant exact-alarm permission, enable scheduled wake-up, and leave the App main process and AgentService running before locking the phone. The test does not open settings, grant permission, launch an Activity, or wake the display. Missing prerequisites are `needsUserAction`, never natural-wake success.

## Entry and evidence

The [driver](acceptance-schedule-wakeup-device.mjs) owns display protection in the same process. Run it directly; the general acceptance-child wrapper force-stops the package during cleanup and would cancel its alarms. All four instrumentation phases use `am instrument --no-restart` and require the existing main PID. Ordinary instrumentation completion can force-stop the package, so omitting this option invalidates the observation.

```powershell
node apps/android/tool/acceptance-schedule-wakeup-device.mjs --adb C:/Android/platform-tools/adb.exe --serial DEVICE --report .cache/android/schedule-status.json --mode status
node apps/android/tool/acceptance-schedule-wakeup-device.mjs --adb C:/Android/platform-tools/adb.exe --serial DEVICE --report .cache/android/schedule-natural.json --mode run --accept-real-account-request true
```

For consecutive tests that must keep the OLED panels dark, append `--keep-display-off true` to either command (also supported by `cleanup`). After confirmed fixture retirement, the guard puts the phone to sleep, verifies noninteractive state and every physical panel Off, and retains the power override. It reports `retainedWhileNonInteractive=true` and does not call `power-reset`. Omit this option to keep the existing behavior of restoring system display control after cleanup. This driver's option requires the explicit value `true`.

These device commands are pending validation. `status` reads prerequisites only. `run` admits the current available `deepseek-account` default model with no fallback, creates one random dedicated Session, and asks for exactly one 180-second `schedule_create`. It requires no other active reminder or task, verifies the saved creation events and matching native armed time, releases its binding, and ordinarily kills only the checked Agent PID. It never force-stops the package or changes provider settings, credentials, wake preferences, or permissions. There is one human submission, but model follow-up and automatic title generation can make more than one network request.

Before signalling the Agent, the fixture unbinds, saves its retirement record, checks that the original Binder endpoint still responds, and requires its PID, UID and complete process name to agree in both ActivityManager process and service records. It performs no disk write between this final identity check and signalling. It confirms disappearance only when `Os.kill(pid, 0)` returns `ESRCH`; permission denial or another failed probe remains unconfirmed. It does not depend on cross-process `/proc` file visibility. Fixed retirement substeps distinguish RPC, disconnect, identity, record persistence, signal and disappearance failures without exposing exception text.

During natural waiting, no instrumentation, test service, binding, or test CPU lease remains. The host observes full process names and current service state. Success requires the old Agent to remain absent before the due time, then a different Agent PID whose current ServiceRecord start intent is `SCHEDULE_WAKE`. A historical log line is insufficient. `observe` binds only the already-running service without `BIND_AUTO_CREATE`; it checks the exact reminder receipt, original scheduler message framing, unchanged creation history, completed second turn, and matching durable final marker.

## Cleanup and limitations

Cleanup cancels only its own unfinished task, deletes only its UUID-owned reminder, archives only its Session, and cancels only its completion notice. The synthetic owner record stays in App-private storage; reports retain its hash. Failure or cancellation uses an independent bounded cleanup interval. If the service is absent, cleanup does not restart it and reports unconfirmed retirement; an operator can rerun `--mode cleanup --case-id UUID` after the user has opened the App. Existing records and failed reports are preserved.

Retirement means the fixture instrumentation and host ADB clients have exited and its own task has settled. The pre-existing App main process remains; the report explicitly sets `mainPreserved=true` and `wholeAppRetired=false`. By default, the display guard requires locked, noninteractive state and physical Off on every internal panel before releasing its override. Unknown retirement cannot authorize that release or a confirmed retained-Off result. Keeping the override does not turn a failed task into acceptance success.

A failed read-only `status` remains failed even when independent cleanup confirms no active instrumentation, closed fixture ADB clients, and the unchanged main PID. That confirmation retires only the fixture; it neither establishes natural delivery nor stops the App. Failed task cleanup additionally requires its own task-settlement evidence before retirement can be confirmed.

Failure reports retain the runner-owned `result` through screen-protection `AggregateError` wrappers. Fixed `hostStage` values distinguish `main-query`, `idle-preflight`, and `instrument`, plus passive natural-wait and cleanup operations. `failureCode` and `nativeFailureCode` preserve the primary error; `cleanupFailureCode`, optional `cleanupNativeFailureCode`, and `cleanupHostStage` record independent cleanup failure. Optional `lastProgress` contains only the matching case's fixed native `phase`, `stage`, and bounded `elapsedMs`; missing progress does not establish where native execution stopped. Diagnostics exclude exception prose, stacks, and raw ADB output and do not change deadlines or acceptance requirements.

## Host verification

```powershell
node --test apps/android/tool/acceptance-schedule-wakeup-device.test.mjs
node apps/android/tool/acceptance-schedule-wakeup-device-host.mjs
```

The host runner compiles the AndroidTest carrier without Gradle and checks the actual Kotlin event validator using the original schedule framing and LLM message factories. It uses no account or device. These checks do not establish natural alarm delivery, permission revocation, reboot recovery, or long-term background reliability. Natural-wake device acceptance remains pending.
