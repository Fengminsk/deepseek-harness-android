# Android completion receipt crash acceptance

[中文](task-completion-device-acceptance.zh.md) | English

`TaskCompletionCrashInstrumentation` runs in the App's `:agent` process with generated Session IDs. Its hold phase sends a synthetic successful-completion signal through `TaskCompletionNotifications`, waits until the end-sequence watermark and matching pending receipt are committed, and blocks the main thread before the notification can display. The runner immediately force-stops that process, starts a fresh Agent process, and requires one matching notification, removal of the committed receipt, unchanged watermark, and suppression of stale and malformed synthetic receipts. Cleanup removes only the generated preference keys and notification. This acceptance interrupts the App process and requires an authorized development installation with completion notifications enabled.

After building the App and AndroidTest APKs from the same source and signer, inspect their package and instrumentation identity without a phone:

```sh
node apps/android/tool/acceptance-task-completion-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

After the user authorizes device time, run the device phase. The runner refuses an existing installation unless `--allow-existing` is supplied; that flag permits an in-place APK install and force-stop of the current App process, retaining App data. On Android 13 or newer, grant notification permission in the App first. The runner never grants it or clears App data. The held main thread must be stopped promptly to avoid an ANR.

```sh
node apps/android/tool/acceptance-task-completion-device.mjs --apk <app.apk> --test-apk <androidTest.apk> [--serial <adb-serial>] [--allow-existing]
```

`node --test apps/android/tool/acceptance-task-completion-device.test.mjs` checks strict manifest, crash-window status, fresh-process result, and failure parsing. The device run proves receipt delivery after one forced Agent-process death. It does not start a real model task or prove that Android restarted Session work without replay. Run `node apps/android/tool/task-recovery-smoke.mjs` for the original Android-profile Session no-replay host case, then separately verify a real task under lock-screen, network loss, Service destruction, and notification-permission changes before claiming the full background acceptance. A failed device run prints its generated token; synthetic receipts may remain for inspection, and rerunning with that token is intentionally unsupported.
