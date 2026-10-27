# Non-visual runtime acceptance

[中文](acceptance-foreground-service.zh.md)

This reference describes the optional service carrier for [packaged Node tool acceptance](device-runtime-acceptance.md). Its host checks validate ownership and cleanup; Android scheduling while locked remains a device acceptance requirement. It does not establish production `AgentService` survival.

## Selection and evidence

`NativeRuntimeToolsAcceptanceInstrumentation` accepts `foregroundCarrier=activity|service`; omission selects `activity`. The explicit `service` value selects a release-acceptance-only, non-exported service in `:agent`, with no launcher entry. Its `specialUse` foreground-service declaration identifies instrumented runtime acceptance. The lease adopts only the instrumentation permission needed for foreground-service launch from the background. It starts neither an Activity, Flutter, the product service nor the product Node profile. The existing carrier still prepares its isolated fixture home and launches the packaged fixture Node engine.

Service mode creates a silent, low-importance notification without a content intent and holds only a timed partial wake lock. It never changes display settings, requests screen wake/unlock, or captures pixels. Reports include `foregroundCarrier` and framework observations `deviceStateBefore`, `deviceStateReady`, `deviceStateAfter`: interactive/keyguard/device lock state and display IDs/states. These observations do not prove physical panel power; the [host screen guard](device-screen-protection.md) owns that evidence. Activity mode retains its drawn, focused black-window requirement and pixel check.

## Ownership and failure

The signature-protected status/close broadcasts carry one UUID and the Agent process PID. Readiness requires successful foreground promotion and an acquired CPU lease. Another token cannot replace or release that owner. Normal close waits for `onDestroy` after wake-lock release and foreground removal; a stop request alone is insufficient. The service uses `START_NOT_STICKY`, so it cannot restart an abandoned fixture automatically.

The service lease permits the suite budget plus 120 seconds of startup and 60 seconds of margin. Expiry notifies instrumentation to fail and close the real native owners, keeping the foreground/CPU resources for at most 120 further seconds of cleanup. The wake lock has that hard time bound, always at most two hours. Android `onTimeout`, unexpected destruction or exhaustion of cleanup time also fails the fixture; they cannot prove owner retirement. Service-mode startup timeout likewise returns through instrumentation cleanup instead of finishing directly from the watchdog. An unresponsive owner cannot produce success.

Instrumentation closes workflow, PTC, Linux and document-search owners before releasing its service lease and finishing. `nativeOwnersClosed` records whether those close operations returned successfully. `nodeProcessRetired` remains `false`: interrupting the Java worker does not stop embedded Node. The external host guard must force-stop the owned test packages and inspect the process list for final process retirement. Killing or updating the package can remove this service; it provides no pixel or continuous-display protection during those transitions.

## Host verification

`node apps/android/tool/acceptance-foreground-service.mjs` compiles the same resource owner and executes it on a JVM. Barrier-controlled threads verify that readiness follows actual resource acquisition and closure follows actual release/destruction. Negative cases cover foreign tokens, partial startup, failed resource release, deadlines, unexpected destruction and malformed leases. Android framework classes compile separately against SDK 36; these checks do not verify foreground-service permission grants, OEM scheduling or physical displays on a phone.
