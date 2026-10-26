# Isolated PTC callback device acceptance

English | [中文](acceptance-ptc-callback-device.zh.md)

This opt-in instrumentation phase exercises the internal PTC Binder relay on a physical Android device. It does not register a model-facing tool. The test guest calls `list_agents` with `{scope:"children"}` through `IsolatedScriptService`; a private test transport returns an empty child list. The assertions require a distinct isolated UID, one exact callback and joined close, a durable completed receipt, cancellation before execution with no callback or replay, and rejection of a forged callback response without a successful receipt.

The private transport is a **fixture**, not the production first-party `list_agents` definition. It cannot prove the Node `ToolRuntime` registration identity, active parent Agent, or App review policy. Those properties require the separate host-side model PTC review tests. The production `AgentService` sends tool callback frames to Node with `native.toolCallback`; this instrumentation intentionally does not start a parent Agent or register a model tool. Do not report this phase as an end-to-end production ToolRuntime result.

Build a matching App APK and AndroidTest APK first. Preflight verifies both APK SHA-256 fingerprints, package names, equal signing certificate, and the exact `:agent` instrumentation declaration without using a device:

```sh
node apps/android/tool/acceptance-ptc-callback-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --preflight-only
```

When the user has authorized a device test and ADB is available, omit `--preflight-only`. Use `--serial SERIAL` if more than one device is connected. The runner refuses an already installed App unless `--allow-existing` is explicitly supplied; installing can change App state. The runner prints `result: pass` only after installation and all three device assertions pass. A preflight pass is not device evidence.

```sh
node apps/android/tool/acceptance-ptc-callback-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --serial SERIAL
```

Run the parser checks with `node --test apps/android/tool/acceptance-ptc-callback-device.test.mjs`. This checks output rejection, not the Android Binder behavior.
