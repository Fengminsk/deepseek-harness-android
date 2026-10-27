# PTC process termination and SAF acceptance

English | [中文](ptc-lifecycle-device.zh.md)

## Summary

These opt-in checks test whether PTC leaves an interrupted file mutation unconfirmed and whether a revoked Android document grant stops further access. They use dedicated acceptance Sessions, UUID-derived directories and generated documents. They never reset App data or revoke a pre-existing document grant. A matching signed App and AndroidTest pair is required. The default [black acceptance window](device-runtime-acceptance.md) refuses a locked or non-interactive phone. Explicit service mode uses the [non-visual acceptance service](acceptance-foreground-service.md), including while locked, without waking or unlocking the phone. Neither mode guarantees physical screen power across installation or process termination; an external physical-power guard owns that requirement.

## Contents

- [Process termination](#process-termination)
- [Document search and revocation](#document-search-and-revocation)
- [Verification limits](#verification-limits)

## Process termination

[The host runner](acceptance-ptc-process-death-device.mjs) verifies APK identities and the real Node carrier declaration. `--preflight-only` stops before device access. Device execution requires `--accept-force-stop`; an existing installation additionally requires `--allow-existing`. Installation uses `adb install -r`. Force-stop interrupts all work in that App, so the device owner must authorize this disruptive test. The runner does not clear storage, uninstall the App or remove audit records. It waits for its owned ADB preparation process and stdio to close before publishing success; a spawn error or unconfirmed cleanup fails the run even if a recovery result was received.

The carrier selects suite `ptc-process-death`, phase `prepare` or `recover`, and one generated `caseId`. Its private home ends in that UUID; its workspace ends in `.ptc-death-<caseId>`. Recovery accepts only the existing matching configuration and resumes Session `ptc-death-<caseId>`. [The Node fixture](device-runtime-acceptance/ptc-process-death.mjs) calls the original `write` tool through the real model PTC owner, native isolated callback adapter and durable callback journal. It holds the callback after the file has been written and synced, with the journal still at `dispatch-unconfirmed`. The private ready file includes the admission token; instrumentation status exposes only case/run IDs, Agent PID and output hash.

Pass `--foreground-carrier service` to the host runner, or `-e foregroundCarrier service` when invoking instrumentation directly. The runner passes the same selection to both phases, checks the preparation carrier-ready frame, and requires the recovered carrier plus native owners to close before accepting success. Missing, conflicting or incomplete carrier evidence fails. The deliberately killed preparation process has no graceful close acknowledgement; actual PID disappearance remains mandatory. Service mode is test scheduling support, not evidence that the production Agent service survives in the background.

After readiness, the host ties the exact run UUID to ActivityManager's isolated service process and independently observes its live PID. It force-stops the App and requires both the Agent and all isolated script processes to disappear. Fresh recovery requires a different Agent PID, the original file hash and the unchanged unconfirmed journal. Rebinding the original admission must fail with `ANDROID_TOOL_REPLAY` before any native rebind or tool execution. An unresolved mutation stays unresolved; this test neither replays it nor clears user recovery blocks. The carrier only reads the native receipt: `nativeReceiptState` must be `ADMITTED` or `INTERRUPTED_UNCONFIRMED`, and `nativeOutputAbsent` must be `true`. The host preserves these observations as `nativeReceiptInspection: read-only-unconfirmed`; it does not invoke or certify the native cold-recovery transition.

## Document search and revocation

[The test provider](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/PtcSafAcceptanceProvider.kt) lives only in the AndroidTest APK. It retains `MANAGE_DOCUMENTS` and URI-grant enforcement. Its explicit control receiver requires the App's signature-level `RUNTIME_ACCEPTANCE` permission, runs under the provider UID and accepts only fixed operations plus a UUID. It creates two fixed text files, grants one generated tree to the fixed target App and returns that URI. The App persists the grant through Android's normal resolver. No command accepts an arbitrary filesystem path, document URI or target package.

The explicit control broadcast uses [`FLAG_INCLUDE_STOPPED_PACKAGES` and `FLAG_RECEIVER_FOREGROUND`](https://developer.android.com/reference/android/content/Intent#FLAG_INCLUDE_STOPPED_PACKAGES) so the test receiver can start after a guard force-stops its package and receive foreground scheduling. These flags grant no document access. A receiver-entry acknowledgement distinguishes a delivery timeout from a provider-control timeout; only the final successful response supplies the generated URI. Signature permission, provider UID and persisted-grant checks remain required.

[The native instrumentation](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/PtcSafAcceptanceInstrumentation.kt) checks bounded literal search, waits until a second search has entered the provider, releases only its generated grant and joins cancellation. It rejects a returned result after revocation, checks that subsequent read/search calls fail, removes its own provider files and compares every pre-existing persisted grant's URI and flags. An unrelated provider exception is not accepted as cancellation. The synthetic provider control remains available after revocation through the signature-protected receiver, not through a retained document read grant.

[The PTC SAF fixture](device-runtime-acceptance/ptc-saf.mjs), suite `ptc-saf`, sends search/read through original `android_files`, real `NativeIsolatedToolCallbacks` and `AppDocumentSearch`. The carrier supplies only the generated root and handles `acceptance.saf.revoke` for that exact root. The fixture requires a distinct isolated UID, one native search lifecycle, four durable callback results and refusal of both read and search after revocation. The native in-flight test and PTC test cover different assertions; neither substitutes for the other.

Both `PtcSafAcceptanceInstrumentation` and the Node carrier's `ptc-saf` suite accept `-e foregroundCarrier service`; the default remains `activity`. The native probe has a 90-second service lease. Carrier failure cancels the search owner and waits for the search worker before lease release. Successful results include carrier identity, closure and observed lock/display state. These are framework observations, not captured pixels or proof of physical panel power.

## Verification limits

Run the focused host regression with `node --import tsx/esm --test apps/android/tool/acceptance-ptc-process-death-device.test.mjs`. It actually terminates a child Node process after a real ToolRuntime write and reloads its real Session and journal in another process. Host SAF tests use the real tool/callback/search owners with an explicitly simulated Android transport. Negative controls reject corrupt markers, incomplete searches, duplicate results and evidence that names a different run. Host success does not certify Android process retirement, URI grants, Binder cancellation or release APK packaging.

## Dev Note

The service-enabled process-death and SAF checks require new matching-pair device evidence. The previous SAF device run confirmed service readiness but timed out before provider control replied; host tests and compilation do not prove the stopped-package fix resolves that device failure. Keep the model PTC acceptance decision separate until the corresponding checks pass on the phone. Retain failed fixture records for diagnosis instead of rewriting them into successful or replayable state.
