# Locked AgentService recovery acceptance

[中文](agent-service-recovery-driver.zh.md)

`acceptance-agent-service-recovery-device.mjs` drives the installed production `AgentServiceRecoveryInstrumentation` through real ADB. `agent-service-recovery-driver.mjs` owns the stage sequence, network restoration and retirement. The fixture starts the production AgentService, creates a dedicated Session, and verifies its unchanged event count and SHA-256 across offline and restored connectivity. It makes no model request. A pass does not establish active Agent task survival, request retry, or persistence across a killed service.

## Entry and protection

Use an already locked, noninteractive phone with an initially validated network. The driver reads `dumpsys power` and the scoped `KeyguardServiceDelegate` before instrumentation. It refuses interactive, unlocked, ambiguous or unavailable state. It never sends wake, sleep or unlock input. `--no-wake` documents this mandatory behavior; omitting it does not enable waking.

```powershell
node apps/android/tool/device-screen-protection.mjs --adb D:\Programs\adb\adb.exe --serial <serial> --seconds 420 --report <screen-report.json> -- apps/android/tool/acceptance-agent-service-recovery-device.mjs --accept-network-toggle-and-lock --no-wake --report <recovery-report.json>
```

The screen wrapper binds `--adb` and `--serial` to its own target. This entry runs in the wrapper's process through an awaited import, not through its killable Node child path. Guard cancellation reaches the driver as an AbortSignal; physical panel protection is reapplied immediately, while the guard waits for the driver's independent cleanup before resetting display control. The generic child launcher explicitly rejects this entry. Standalone invocation requires explicit `--adb`, `--serial`, `--report` and the network-toggle consent flag, and handles SIGINT/SIGTERM through the same cleanup owner. Use the wrapper to obtain physical screen protection.

## Evidence and restoration

Before starting instrumentation, the adapter reserves a new report and writes an immutable `<report>.original.json` containing the device serial, random token and exact `wifi_on` / `mobile_data` configuration flags. Existing reports and snapshots are not overwritten. Both flags must be `0` or `1`, with at least one enabled. The screen and recovery report paths must differ. This configuration snapshot does not claim which subscription or transport supplies validated connectivity; the original native fixture separately observes Android's validated network count.

Every observation must retain the original Session ID, runtime generation, event count and digest, and report `locked=true`, `interactive=false`. The production Agent PID must remain the same. Network evidence schema 2 records anonymous network handles, SDK-known transport enums, INTERNET / VALIDATED / VPN / NOT_SUSPENDED flags, the App default network and separate aggregate counts. It omits capability object dumps, SSIDs, IP addresses and UID lists. `RecoveryNetworkEvidence.java`, included only in AndroidTest, classifies INTERNET + VALIDATED + non-VPN networks without restricting transport; Ethernet, USB and other internet transports count too. The host recomputes every count from the supplied facts.

Before restoring connectivity, both saved network flags must actually read disabled and no non-VPN INTERNET network may remain. An IMS network without INTERNET or a persistent validated VPN overlay does not establish usable underlying internet, but both remain visible in the evidence. Unknown capabilities and unvalidated non-VPN INTERNET networks also block offline acceptance, since lack of validation does not establish lack of access. Initial and restored checkpoints require at least one INTERNET + VALIDATED non-VPN network and no unknown capabilities. These are Android capability observations, not an HTTP probe or a paid model request. The final native result must be unique and successful with the same Session evidence; its ADB process must actually close successfully.

Each ADB command has an eight-second deadline and up to 3.5 seconds of additional close observation. Cancellation of a dispatched `svc` mutation waits for that command's bounded settlement; it does not race an immediate restore against an abandoned mutation. A failed mutation receipt leaves the network outcome unknown, even if later flags happen to match. Independent cleanup attempts both original flags, checks exact readback for up to 15 seconds plus bounded command latency, then force-stops App and test packages, waits up to 20 seconds for actual host close, and checks full App/test/isolated-service process names for up to 20 seconds plus command latency. No data is cleared. Instrumentation has a separate 330-second host deadline.

Cleanup does not inherit the cancelled work signal. The driver reports network restoration, host close and device retirement separately; any failure yields `result: unknown`. Reports preserve the failing phase, last checkpoint and network facts, bounded nested execution/cleanup/cancellation causes, and native failure causes when available. An unclosed child is unreferenced only after bounded cleanup and remains explicitly unretired. Unknown restoration or retirement prevents the screen wrapper from resetting panel overrides. Failed report persistence preserves these facts in the thrown error and prints a fallback JSON diagnostic. Hard host termination or unavailable USB cannot be made recoverable by an in-process `finally`; use the immutable snapshot to restore the exact original flags after reconnecting, and verify device processes and panel state before resuming work.

## Host checks

```powershell
node --test apps/android/tool/recovery-network-evidence.test.mjs apps/android/tool/agent-service-recovery-driver.test.mjs apps/android/tool/device-screen-protection.test.mjs
```

These keyless tests exercise parsing, cancellation, partial changes, ambiguous receipts, exact restoration and retirement through controlled IO. The network test compiles and executes the actual AndroidTest Java classifier on a host JVM. They are not device acceptance evidence or an Android APK build. A real report is emitted by the ADB adapter with `evidence: device-adb`; preserve failed reports and use a new report path for each device attempt.
