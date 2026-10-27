---
kind: reference
title: Linux guest device lifecycle acceptance
---

# Linux guest device lifecycle acceptance

English | [中文](linux-vm-lifecycle-device.zh.md)

## Summary

[The device runner](acceptance-linux-vm-lifecycle-device.mjs) prepares evidence for live Linux cancellation, Android process death after import retirement, and workspace retention across an ordinary App upgrade. It uses dedicated `linux-lifecycle-<uuid>` sessions and preserves their records. Host parser tests do not establish Android acceptance; each mode requires its own saved device report.

## Contents

- [Prerequisites and entry points](#prerequisites-and-entry-points)
- [Evidence and limits](#evidence-and-limits)
- [Host verification](#host-verification)
- [Dev Note](#dev-note)

<a id="prerequisites-and-entry-points"></a>
## Prerequisites and entry points

Use a matched [Alpine acceptance App and release AndroidTest pair](tinyemu-build.md#alpine-acceptance-apk) containing `LinuxVmLifecycleAcceptance`, with Android SDK tools available through `ANDROID_HOME` or `ANDROID_SDK_ROOT`. The existing `LinuxVmAcceptanceInstrumentation` dispatches `lifecycle-cancel`, `lifecycle-death-prepare`, `lifecycle-death-recover`, `lifecycle-upgrade-seed`, and `lifecycle-upgrade-verify`; each takes a canonical UUID `token`. No new manifest registration is required. The default `AcceptanceForegroundLease` requires an already unlocked, interactive phone and a drawn black foreground window. Explicit `-e foregroundCarrier service` selects the existing [acceptance-only service](acceptance-foreground-service.md), which can run while locked with no visual window. Neither carrier wakes or unlocks the device or launches the product's MainActivity.

The host CLI accepts `--mode cancel|death|upgrade`, `--apk`, `--test-apk`, `--output <new-directory>`, and optional `--serial` / `--adb` / `--foreground-carrier activity|service`. Carrier selection defaults to `activity` and is passed unchanged to every phase. Actual execution requires `--accept-agent-interruption`; replacing an installed App also requires `--allow-existing`. Instrumentation replaces the `:agent` process, so run only when user tasks are idle. The `death` mode intentionally kills that actual Android process. It does not force-stop the whole package or use host process termination as a substitute.

For `upgrade`, also supply `--new-apk` and `--new-test-apk`. The runner validates package identity, identical signing certificates and `new.versionCode > old.versionCode` before device mutation, checks the currently installed initial version, seeds the old App, and installs both new APKs with `adb install -r`. It never clears data, uninstalls, downgrades or alters permissions/network settings. Both artifact pairs must include this runner; a pair predating it cannot seed the test. `--preflight-only` reads local APK manifests and certificates without contacting ADB; it does not verify the packaged test implementation or establish device success.

`--output` must name a new directory. The host preserves artifact paths, SHA-256, signing/version identity, token and serial in `artifacts.json`, each completed instrumentation stream in its phase `.txt`, and a final `report.json` or `failure.json`. Each phase has a 180-second host bound around the production 120-second guest limit. An absent or failed result is not a pass. On failure, stop and inspect the retained token's records; the runner has no cleanup, acknowledgement or unlock operation.

The service lease is bounded to 180 seconds per phase. Its failure reaches the same cancellation path as loss of the black window; the probe waits for real native retirement and cancellation work before closing the carrier. Successful phases require native-owner closure and the carrier's destruction acknowledgement. The deliberate death marker requires readiness only; a killed process cannot supply a graceful close acknowledgement. Reports preserve carrier identity and framework lock/display observations, which do not prove pixel colour or physical panel power. An external physical-power guard must cover installation, death and recovery transitions when continuous screens-Off protection is required. This test service does not establish production Agent background survival.

<a id="evidence-and-limits"></a>
## Evidence and limits

| Mode | Required device evidence | Coverage boundary |
| --- | --- | --- |
| `cancel` | Exact run UUID service identity, live isolated PID, Linux worker CPU activity, active durable record, cancelled native result with isolated UID and confirmed retirement, and `diskCommitted: false` | Cancels a running native guest, not merely an unadmitted request. Native return establishes retirement; an empty service process may remain listed by Android. |
| `death` | Real immutable file input and import command complete in the isolated guest; `markRetired` is synced; the App process kills itself before disk capture/publication. A different Android PID opens a new Manager, reports `interrupted`, `needsReview: true`, and `diskCommitted: false`, rejects a successor without a guest UID, and preserves original journal bytes and source hash. | Covers the **retired → publication** import window. It does not certify process death during guest execution, export publication, power loss, or Node/Session recovery. No command is replayed and the review barrier remains. |
| `upgrade` | Old App commits a unique workspace file and durable run; newer same-signer App reads the exact file/hash through a discard-only native execution and observes the original committed run | Proves this Linux workspace survives the tested ordinary upgrade. It does not establish preservation of all user data or compatibility with every older image. |

The death preparation uses the production `LinuxVmFileInput`, `LinuxVmImageStore` and `LinuxVmRunner` directly to stop at the same `markRetired` boundary as `LinuxVmManager.run`. Recovery and successor refusal go through a new production Manager. Cancellation and upgrade execution also use that Manager. These are native lifecycle checks; [the runtime acceptance suite](device-runtime-acceptance.md) separately owns the full model → ToolRuntime → Binder path, including the successful Linux child workflow and Python analysis checks.

Only the token's dedicated source file, marker and Linux session are created. Recovery does not scan user conversation files or rewrite other sessions. Incomplete fixtures and review-required records remain for inspection. Guest networking, interrupted import before retirement, export process death, and active-model network recovery remain outside these checks. [The recovery reference](linux-vm-recovery.md) defines the production interpretation of uncertain outcomes.

<a id="host-verification"></a>
## Host verification

`node --test apps/android/tool/acceptance-linux-vm-lifecycle-device.test.mjs` checks evidence parsing and orchestration order without ADB. It rejects missing/duplicate results, wrong identities, absent live-worker evidence, unconfirmed retirement, replay, a changed journal, identical process IDs, hash mismatches, signer mismatches and non-increasing upgrade versions. Its injected adapter proves host sequencing only; synthetic outputs are not saved as device acceptance evidence.

The test-only observer accepts duplicate service displays only when their ServiceRecord and complete ProcessRecord identities agree. It requires the exact `TID CMD TIME` columns, one `isolated-linux-vm` worker (or its kernel-truncated `isolated-linux-` name), and positive CPU time on that worker; another thread's CPU does not count. Shell dispatch and pipe reading share an 8-second bound, followed by at most 1 second to confirm reader and descriptor-closer exit; late descriptors are closed and unconfirmed cleanup fails. Bounded status messages identify guest discovery, worker CPU and cancellation stages. Run `node apps/android/tool/acceptance-linux-guest-observation.mjs` for the actual parser and thread-owner checks, and `python apps/android/tool/acceptance-linux-guest-observation-icu.py --icu-library <ICU4C-library> --symbol-suffix <version>` for source-regex compatibility. JVM or host ICU success does not establish Android pipe behavior or device cancellation.

<a id="dev-note"></a>
## Dev Note

The three device modes require separate actual runs. Adding this harness or passing its host tests does not change product capability gates or certify any pending device result.
