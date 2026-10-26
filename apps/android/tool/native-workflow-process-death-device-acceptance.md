# Workflow process-death acceptance on Android

This optional debug-device test exercises a real Android process stop across two instrumentation phases. The first phase starts an isolated Binder workflow in the App's `:agent` process and holds a child-result callback after the child reservation reaches durable `LAUNCHING`. The runner reads a synced, run-specific marker through debug `run-as`, observes the Agent and isolated guest PIDs, then force-stops the package and confirms both process names have no remaining PIDs. A new `:agent` process reads the same receipt. It must mark the old run and child interrupted without replaying callbacks, reject a new workflow before child retirement, and keep the old output absent. Only after the host has observed both old processes stopped does the test explicitly retire that fixture child and verify a new admission can be cancelled. The old run remains review-required.

Run the package, signer and exact Agent-process manifest check without contacting a phone:

```sh
node apps/android/tool/acceptance-native-workflow-process-death-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

When a debug phone and this disruptive test are explicitly authorized:

```sh
node apps/android/tool/acceptance-native-workflow-process-death-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --accept-force-stop [--serial <adb-serial>] [--allow-existing]
```

The runner installs the matching APK pair with `adb install -r`, requires debug `run-as`, and force-stops the whole App. It refuses to use an existing installation without `--allow-existing`. Use a development installation: the generated, private workflow receipts remain for audit. A failed run may leave an interrupted, unretired test child; inspect its receipt before retrying. The runner never deletes user files or resets App data. Parser tests: `node --test apps/android/tool/acceptance-native-workflow-process-death-device.test.mjs`.

This proves the receipt behavior under an actual package process stop if the device run passes. The fixture's callback backend is synthetic; the test does not prove `AgentService`/Node startup ordering, real child-Agent side effects, arbitrary OS process-kill behavior, background longevity, or PackageManager upgrade. Those require separate device acceptance. The model-facing workflow gate remains closed.
