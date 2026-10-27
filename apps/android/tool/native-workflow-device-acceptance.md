# Private workflow Binder acceptance on Android

This optional device run exercises the internal App-owned workflow admission route. `NativeWorkflowAcceptanceInstrumentation` runs in the App's `:agent` process and starts real isolated Binder guests. Its seven cases check ordered callbacks and durable completion; durable guest-reported failure; malformed DSL outcomes requiring review; child reservation, result and retirement; pre-execution cancellation; the 120-second cap and a 5.5-second callback within a 12-second deadline; and cancellation while a child result is pending, followed by retirement and a fresh App owner that does not replay the result. The last case also checks that a child reserved before activation is retired after a confirmed callback close and cancellation. The tests use generated IDs and no user files or network grants. Durable test receipts remain in the App's private directory, so use a development installation.

After both APKs have been built from the same source and signer, and the phone is available for an authorized test:

Run the package and manifest preflight without touching a phone:

```sh
node apps/android/tool/acceptance-native-workflow-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

When device testing is authorized:

```sh
node apps/android/tool/acceptance-native-workflow-device.mjs --apk <app.apk> --test-apk <androidTest.apk> [--serial <adb-serial>] [--allow-existing]
```

The runner verifies the APK package names, matching signing certificate and exact AndroidTest manifest entry before installing with `adb install -r`, which retains App data. The test must target the same release/debug build and shrinking configuration as the App. It refuses missing or ambiguous device authorization, and refuses an already installed App unless `--allow-existing` explicitly authorizes using that installation. All seven instrumentation assertions must pass exactly once. The in-flight cancellation case now requires a confirmed `CANCELLED` receipt, worker and child retirement, and no late output; an unconfirmed result no longer satisfies it. Workflow fixtures use a real-shaped `android-…` Session ID and verify that settlement preserves it. Host parser tests: `node --test apps/android/tool/acceptance-native-workflow-device.test.mjs`.

A compiled probe is not device evidence. The fresh App owner assertion reconstructs an owner inside the same running App process; the separate [process-death acceptance](native-workflow-process-death-device-acceptance.md) tests an actual package stop. Even a pass here does not establish original DSH workflow body semantics, safe child-agent activation, process-kill recovery or arbitrary file and network access. The model-facing workflow gate remains closed.
