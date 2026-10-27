# Workflow process-death acceptance on Android

This optional device test exercises a real Android process stop across two instrumentation phases. The first phase starts an isolated Binder workflow in the App's `:agent` process and holds a child-result callback after the child reservation reaches durable `LAUNCHING`. It fsyncs a run-specific marker before reporting that marker through instrumentation status; no debug `run-as` is needed. The runner observes the Agent and isolated guest PIDs, then force-stops the package and confirms both process names have no remaining PIDs. A new `:agent` process reads the same private marker and receipt. Production recovery must acquire the old process lease lock, retire only its recorded in-process child, preserve the old run as interrupted with no output, and avoid replaying callbacks. A new admission must then cancel cleanly. The test does not manually retire the new-format fixture child.

Run the package, signer and exact Agent-process manifest check without contacting a phone:

```sh
node apps/android/tool/acceptance-native-workflow-process-death-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

When the phone and this disruptive test are explicitly authorized:

```sh
node apps/android/tool/acceptance-native-workflow-process-death-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --accept-force-stop [--serial <adb-serial>] [--allow-existing]
```

The runner installs the matching APK pair with `adb install -r` and force-stops the whole App. The AndroidTest APK must be built for the same release/debug target as the App, including its shrinking configuration; a debug test APK against an R8 release target is not a valid pair. It refuses to use an existing installation without `--allow-existing`. Generated private workflow receipts remain for audit. A failed run may leave an interrupted test run; inspect its receipt before retrying. The runner never deletes user files or resets App data. Parser tests: `node --test apps/android/tool/acceptance-native-workflow-process-death-device.test.mjs`.

Legacy receipts have no process lease and are never retired automatically. Inspect only their pending identities with `adb shell am instrument -w -r -e phase inspect-legacy com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeWorkflowProcessDeathInstrumentation`. For a reviewed, exact legacy run, add `--retire-legacy-run <run-uuid>` to the authorized runner command above. This separate mode re-inspects that one run, observes the old Agent PID, force-stops the package, requires both Agent and guest processes absent, and starts a fresh instrumentation process. It writes a synced `files/workflow-legacy-retirement/<run-uuid>.json` audit before confirming only the listed children stopped. The task remains interrupted with no output. No model tool or production RPC exposes this migration, and there is no blanket reset or deletion of receipts.

The isolated service uses a per-run instance name; Android may truncate its process argv even with `ps -w`. The host therefore binds the full run UUID to ActivityManager's service process record and independently confirms its PID is live in the process list. A fixed `pidof :ptc_script` lookup is not evidence of absence. All per-run guest PIDs must disappear after the explicit package stop.

This proves the receipt behavior under an actual package process stop if the device run passes. The fixture's callback backend is synthetic; the test does not prove `AgentService`/Node startup ordering, real child-Agent side effects, arbitrary OS process-kill behavior, background longevity, or PackageManager upgrade. Those require separate device acceptance. The model-facing workflow gate remains closed.
