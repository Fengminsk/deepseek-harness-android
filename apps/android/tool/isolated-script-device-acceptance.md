# Isolated script device acceptance

English | [中文](isolated-script-device-acceptance.zh.md)

## Scope and prerequisites

The test-only [`IsolatedScriptAcceptanceInstrumentation`](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/IsolatedScriptAcceptanceInstrumentation.kt) targets the App's `:agent` process on Android 10 or newer. It calls the internal [`IsolatedScriptRunController`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptRunController.kt) and binds the real isolated Service; no model-facing PTC tool is enabled. Android's [`targetProcesses`](https://developer.android.com/guide/topics/manifest/instrumentation-element) attribute selects that process. A compiled test APK does not establish device behavior.

Prepare both the matching debug App APK and the test APK before asking to use a phone. The test APK is built with `:app:assembleDebugAndroidTest` and appears at `apps/android/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk`. Run only on an idle, ordinary non-rooted test phone after the user approves the test window; installing the App APK or killing `:agent` can interrupt existing tasks. The test changes only its own App-private marker, workspace, audit journal and run receipts. It does not request a broad storage or network grant.

## Device runs

After installing the matching App and test APKs, this command is the planned normal acceptance entry. It has **not** been executed on a device:

```sh
adb shell am instrument -w -e phase normal com.minnnng.dsh_android.test/com.minnnng.dsh_android.IsolatedScriptAcceptanceInstrumentation
```

The result bundle reports `passedCount` and `failedCount`. The normal phase checks a JSON result and distinct guest UID, durable completion and duplicate-run refusal, concurrent admission and completion of two pure guests, absence of direct Node file/network and Java bridge APIs, a private marker read attempt and HTTPS `fetch` attempt returning `ReferenceError`, infinite-loop deadline, cancellation, completion while the App main thread is stalled, and Binder death after a malformed guest request. It also checks a real isolated guest reading one App-approved exact file and rejects a slash-suffixed directory grant before execution, leaving a terminal receipt. The optional file lease cases read an App-issued exact file grant, reject replayed call IDs and unauthorized edits, and terminally reject an extra path field. The network cases use a synthetic DNS resolver and transport to check an exact-host grant, rejected URLs and private DNS answers, a terminal per-call audit, and revocation during DNS before transport. These cases make no external network request and do not validate Android's actual DNS routing or TLS implementation. The marker and `fetch` checks establish the absence of those JavaScript APIs; they do **not** exercise kernel filesystem or socket denial. The main-thread case deliberately blocks the App main thread for at most 3.6 seconds and should be run only while the App is idle.

The optional process-death phases require two fresh UUIDs and an idle test phone. `kill-agent` terminates `:agent` after an `ADMITTED` receipt appears; `kill-running-agent` waits for a guest file call to reach a durable `CALL_SETTLED` audit entry before terminating `:agent`. Either instrumentation command is expected to end abnormally. Restart with `recover`, using the same `runId` and a different `recoveryRunId`; it starts a new run, checks the old receipt became `INTERRUPTED_UNCONFIRMED`, and confirms that the old ID cannot run again. The second phase confirms guest code reached the App file broker but does not prove the guest remained alive at the instant of process death. Neither phase has been executed on a device. Run them only when the user makes a phone available and no user task is active.

The host command `node apps/android/tool/acceptance-isolated-execution-approval.mjs` runs an independent JVM admission process that dies without closing its policy writer. Its successor verifies a denied recovered policy, one-use approval IDs, terminal interruption without output, duplicate-ID refusal, and refusal to publish a late completion. This is deterministic persistence coverage, not an Android Service or guest-process result.

## Acceptance boundary

Before enabling PTC, separately test denied App-private files, out-of-grant workspaces, SAF URIs, and direct sockets from the actual guest, plus granted revision-checked file edits and allowlisted HTTPS through App-owned brokers. The internal [file-call bridge](isolated-script-host-bridge.md) and opt-in [HTTPS broker](isolated-network-broker.md) require App-issued policy leases; no model-facing PTC route exists. Record Android version, package version, guest UID, result bundle, and any `RETIRE_UNCONFIRMED` receipt; do not turn a transport failure into success.
