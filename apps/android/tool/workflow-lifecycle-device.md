# Real Node workflow lifecycle acceptance

English | [中文](workflow-lifecycle-device.zh.md)

## Scope

The `workflow-deadline` and `workflow-process-death` suites use the packaged Node runtime, original ToolRuntime, real in-process child Agents and native isolated workflow owner. Only the model stream is scripted; no account or paid provider call is used. Each run has a dedicated private home and Session. They neither enable production tools nor rerun the eleven ordinary workflow cases.

## Device execution

Use the matching audited App and AndroidTest APKs. The driver accepts `--suite deadline`, `--suite process-death` or `--suite all` (default). It requires the service carrier, an already locked device, explicit package-stop authorization and authorization to preserve-update an existing installation. The screen wrapper owns both physical panels; framework lock fields alone do not establish that they stayed Off.

```sh
node apps/android/tool/device-screen-protection.mjs --adb <adb-path> --serial <serial> --seconds 780 --report <screen-report.json> -- apps/android/tool/acceptance-workflow-lifecycle-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --suite all --foreground-carrier service --accept-force-stop --allow-existing
```

This command requires device execution by the release owner; host parser tests are not a device pass. The runner checks package/signing identities and the exact Agent-process instrumentation. It uses `install -r`, never clears App data, wakes the device or unlocks it. Generated Sessions, markers and native receipts remain for inspection.

## Observations

The deadline case waits for an actual child model stream and `WORKFLOW_CHILD_RESULT`. The production 120-second native deadline must produce a `TIMED_OUT` script receipt and a failed workflow with no output. The fixture's cancellation fallback is 175 seconds; if it fires, the case fails. Success also requires the child model cancelled, native child retired, release acknowledged and one durable failed Session outcome.

The death preparation waits for the same real child-result callback, flushes parent and child Sessions and fsyncs a marker containing their hashes, exact identities and process lease. The host binds the live isolated guest to the run UUID, stops the App/test packages and requires two empty full-process inventories. It joins the preparation ADB client before starting recovery in another process. Recovery uses the same private home with a fresh observer Session. Production native lease recovery must retire the old child while keeping its run interrupted and output absent. Both old Session logs must remain byte-equivalent as parsed events; no model request, callback replay or new admission is permitted. No test code retires the recorded child or writes a successful old Session end.

Failure stops dependent phases. The driver performs bounded final package retirement and retains the completed checks and failed phase separately. Missing process, lease, receipt or log evidence remains failure. These two explicit suites do not run implicitly under `all` in the ordinary runtime fixture; their reports cannot erase the separate upgrade-retention requirement.

Deadline failures retain a named failed check with bounded native settlement, callback closure/error chains, ToolRuntime error and memory/durable event summaries. A missing `run-end`, a missing `data.stopReason` and an incorrect outcome fail separately. Diagnostic reads cannot settle or retry the run, and are labelled before fixture-finally cleanup; later cleanup never converts those observations into a pass. Event summaries omit prompts and outputs. The real host child regression confirms a cancelled member event precedes exactly one durable `run-end` with `stopReason: error`; only the device run can establish native deadline behavior.

Immediate `acceptance.workflowLifecycleStage` notifications identify the child wait, native wait/return, failed diagnostic and pending/completed cleanup stages. Each complete JSON-RPC frame is at most 12 KiB, contains no callback token, and is only an observation. A later blocked cleanup still fails the unchanged overall deadline; notifications cannot mark the suite complete or replace actual process retirement.

## Host checks

```sh
node --test apps/android/tool/acceptance-workflow-lifecycle-device.test.mjs apps/android/tool/device-runtime-acceptance-report.test.mjs apps/android/tool/device-screen-protection.test.mjs
node --import tsx --test apps/android/tool/device-runtime-acceptance-workflow-model.test.mjs
```

The first command tests evidence validation, target binding, phase ordering and failure cleanup with host doubles. The second exercises real host Agents and Session persistence with a scripted provider. Neither executes Android Binder code.
