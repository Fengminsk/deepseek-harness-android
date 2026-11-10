---
kind: reference
title: Android DSH project memory
---

# Android DSH project memory

English | [中文](project-memory.zh.md)

## Summary

This record preserves project agreements, verified results and continuation entry points as of 2026-10-30. The run crossed midnight; its evidence remains in `.cache/android/build-hang-audit-20261029/`. It does not certify completion of the six migration stages. Check Git state, the actual APK and device evidence before reusing these conclusions.

## User agreements

- Push source to Gitee's `android` branch; preserve other sessions' uncommitted changes and commit only owned files or hunks.
- Keep `apps/android/build` as a real directory on the project's D drive, without a junction to C. Preserve SDKs, dependencies, runtime assets and user data; do not rewrite Git history to recover disk space.
- The current phone is not rooted; prioritize background Agent work, local files and ordinary permissions. APK ZIP, Manifest, DEX and native-library inspection does not require a Linux guest.
- Upgrade the existing App while retaining accounts, sessions and file grants; keep both physical OLED panels Off during device tests. Report builds, host tests and device acceptance separately.
- Use frosted glass, fine noise, edge highlights and restrained PS5-style lighting; the sidebar glass has no animated background light. Follow ChatGPT mobile interaction patterns and remove unnecessary explanatory copy.
- Keep reasoning chains compact, with small expanded text and blur transitions; automatic completion collapse preserves the reply position being read. Sending a message brings the new turn into view.
- Use a Chinese draggable reasoning selector; persist Default as a distinct selection instead of reopening on High. Preserve the DS account avatar and omit the resource page's bottom switching bar.
- The PC download proxy is `127.0.0.1:7897`; the phone uses FlClash, with user-reported port approximately `7890`, which must be checked before use. Do not change system permissions based on assumptions.

## Packaging and the current APK

The current ordinary App is the Linux-enabled `0.1.0+120` ARM64 Release, archived as `.cache/android/build-hang-audit-20261029/artifacts-final/pocket-harness-120-workflow-linux-release.apk`. It is 355,611,900 bytes with SHA-256 `4a341bcd539727e447e70d863b7e5f8323470fefac3a60ac22b583986cf76319`. Its embedded runtime is 240,075,953 bytes with SHA-256 `67dc2b90ea835ec84d09296be9d900516fce3ca6697cf4849197307d867c488d`. The runtime archive's 18,026 entries match the refreshed staging tree, and its bootstrap matches current source. The APK was built from the shared working tree, not a single clean commit. Instrumentation APK revisions are separate artifacts; match each report's recorded App and test digests rather than assuming the latest test APK ran an earlier check.

The audit directory's `release-startup-r2.json` and `release-startup-r3.json` record ordinary Activity launch and a ready runtime with both panels physically Off. The fixture did not start the Agent service itself. These checks did not inspect a Dart VM service or certify all UI rendering. `install-release-retained-r2.json` confirms a same-version retained-data replacement: all 93 recorded Session files totaling 3,036,289 bytes, three SAF grants and a synthetic Keystore credential survived. No App data was cleared. This is not real-account sign-in or token-refresh acceptance.

The original `debug.keystore` was recovered from the Windows Recycle Bin and its certificate verified as SHA-256 `665169a9132865c4fb863bf408b06f0a359a9abc363d054c760972248cfce8a7`. It was restored to `C:\Users\JZ_Colin\.android\debug.keystore`; `D:\JOB\CODE\Lab\deepseek-harness-android\apps\android\signing\debug.keystore` is the Git-ignored backup. This signing directory is not a cache or a cleanup target. The separately regenerated key is preserved there under a different name and must not replace the recovered identity. `signing-recovery.json` records the recovery; the original deletion cause is unverified.

The later Release stall was traced to dependency download waits, not an established Gradle-client/Kotlin-daemon lock cycle. The captured daemon stack was in an HTTPS socket read. A Kotlin daemon marker access failure was a separate permissions problem. Official dependency bytes and metadata were fetched through the configured proxy, checked against upstream checksums, and supplied through a version-filtered local Maven repository; after the missing dependencies were completed, the offline build succeeded. The initial incomplete offline attempt remains a failed record. Keep `dependency-maven-manifest.json`, thread dumps and `release-original-signature.log` in `.cache/android/build-hang-audit-20261029/`. Do not disable TLS checking, alter dependency locks or remove caches to conceal this class of failure. See the [packaging guide](flutter-packaging.md).

### Historical Debug repair

Earlier on 2026-10-29, the installed Debug APK was confirmed to lack both the Dart kernel and AOT `libapp.so`. The build-directory alias problem in output inventories was repaired, and Gradle plus independent APK content checks were added. Debug requires a valid kernel and isolate snapshot; the pinned SDK permits an empty VM snapshot. Release/Profile use AOT and do not require `kernel_blob.bin`.

The repaired historical `0.1.0+120` ARM64 Debug archive was `pocket-harness-0.1.0+120-arm64-debug-project-local.apk` under `.cache/android/flutter-startup-audit-20261029/`, SHA-256 `1bef9f079ff80ac37a70cade4aceb9ce6cf0a4ecde430a6e62c9e77f0802b63c`. It was built from the working tree, including existing uncommitted changes; the packaging repair commit alone cannot reproduce those bytes. It is not the currently installed Release.

That Debug APK passed the complete APK check, together with 38 verifier cases that reject the original missing-Dart package. Its retained-data replacement preserved hashes of 101 Session and preference files; the ordinary Dart main isolate was runnable and the Agent moved from `starting` to `ready`. This certifies that historical startup and upgrade, not every user task, file grant or background recovery. That Debug APK contained no Linux guest candidate assets; Linux acceptance at that point used a separate Release archive.

## Linux and remaining acceptance

Retain the historical Linux Release, instrumentation APK and records in `.cache/android/device-v120-20261028/r43/`, plus the complete `alpine-ic8p90k9` and `alpine-tthk3anu` candidates and corresponding sources under `.cache/android/linux-vm-candidates/`. The former matches r43; the latter is referenced by the [network acceptance guide](linux-vm-network.md). The current ordinary App is the Release identified above; candidate files alone still do not establish what an installed APK enables.

The [Build 120 acceptance record](upgrade-120-acceptance.md) preserves PTC checks and the r55 real-account `workflow-linux` success: one completed workflow, one child session, an isolated-UID `linux_exec` receipt with exit code zero, confirmed retirement and temporary cleanup. Earlier freeze, unreachable-proxy and model-argument failures remain separate failed records; later success does not erase them.

The 2026-10-29 native acceptance snapshot below uses the current Release. Reports and logs are in `.cache/android/build-hang-audit-20261029/`; `device-matrix-native.json` preserves first attempts and `device-matrix-native-rest.json` records the successful follow-up runs. Earlier failures remain distinct records.

- `device-native-saf.json` and `device-ptc-saf.json` passed their outer retirement/protection checks. The controlled provider exercised native search, in-flight revocation and text-read cancellation/late-result rejection; PTC exercised four callbacks, native search and denied reads/searches after revocation. This does not cover every external document provider or the user's interactive grant picker.
- `final-native-workflow-r2` passed five phases and twelve checks, including reserved-child retirement, cancellation, route-denial failures and cold recovery that retains an unconfirmed state. `final-workflow-lifecycle` passed the 120-second nested deadline and Binder-death/App-restart cases: children retired, uncertain results stayed marked for review, durable logs stayed unchanged and no model/callback replay occurred.
- `final-ptc-death` passed killed-dispatch recovery: the old Agent and guest stopped, the journal remained `dispatch-unconfirmed`, and native rebinds/replayed executions stayed zero. It does not turn the interrupted operation into a successful one.
- `final-linux-cancel` observed a running guest, confirmed cancellation/retirement and no disk commit. `final-linux-death` covers the specific import-retired-before-publication window: recovery preserved the journal, required review and denied automatic replay. It does not certify process death during every arbitrary guest command.
- `final-completion-r2` recovered a synthetic committed completion receipt after force-stop, suppressed invalid receipts, cleared receipts and confirmed cleanup/retirement. Its `realAgentTaskReplayTested` remains false; it is not proof that a real Agent task resumes successfully.

The later combined runtime runs also passed outer protection and retirement: `final-runtime-ptc.json` passed all twelve selected checks, alongside the separately passed controlled SAF case; `final-runtime-workflow.json` passed eleven selected checks, alongside the separate deadline and Binder-death cases; `final-runtime-linux.json` passed six selected checks, alongside the separate import-death case. Their inner results retain `complete: false` because standalone cases and remaining inventory entries are reported separately. Do not rewrite those raw reports as globally complete: ordinary version-upgrade workflow record retention and guest networking remain open boundaries.

`final-model-transport.json` passed active model transport retry with a local SSE fixture in the shipped Android profile. `final-idle-recovery-result.json` passed locked, non-waking idle-session radio loss/restoration and restored the original Wi-Fi/data settings, both `1`; network restoration and process retirement were confirmed. That idle report explicitly has `modelRequestRetryTested: false` and `activeAgentTaskSurvivalTested: false`. These are separate tests, not evidence that a live real-account task survives radio loss.

The [screen-protection wrapper](device-screen-protection.md) now supports valueless `--keep-display-off`, or `restoreDisplayPower: false` for programmatic callers. This avoids releasing overrides into AOD during consecutive tests. It still requires physical `Off`, stable topology, noninteractive state and confirmed retirement. Successful retention reports `retainedWhileNonInteractive: true` and `restoredWhileNonInteractive: false`; overrides remain active until explicitly released. The startup and `final-*` native runs above recorded this retained-Off state. Do not change system AOD preferences or describe retained overrides as normal restoration.

Continue from the [capability inventory](parity-manifest.json), [model PTC/Linux reference](model-ptc-linux.md) and [natural-alarm test](schedule-wakeup-device.md). Final real-account, `radio-linux` and natural-wake retests await explicit user authorization after automatic approval review blocked them; they are not recorded as passed. Permission changes, ordinary cross-version upgrades and workflow-record retention, reboot/extended Doze recovery, general Linux networking, unrestricted PTC/workflow and complete UI interaction remain separate acceptance boundaries. The same-version retained-data replacement above does not close the cross-version upgrade boundary. A ready alarm projection or corrected test APK is not natural wake-up evidence. Inventory counts describe declarations, not user features.

## Cleanup and retained evidence

This cleanup uses an explicit file inventory for obsolete Android APKs, superseded Linux candidates and generated assets, old source-package copies and noncurrent Flutter compiler caches. Alpine `.apk` files are guest dependencies, not Android release history, and are retained. Emulator data, screenshots, session exports, WIP files, Git, dependencies and current runtime assets are outside the cleanup scope.

Before deleting candidate directories, copy their small JSON, logs and notices into `.cache/cleanup-audit-20261029/candidate-evidence/` and verify their hashes. Original acceptance reports and packaging diagnostics remain available; after old APK bytes are removed, historical acceptance describes the recorded run and does not promise that those old packages remain installable. Exact targets, recovered space and retained-file checks are recorded in that directory's `cleanup-plan.json` and `cleanup-result.json`.

## Verification and continuation

Packaging checks inspect the actual APK; filenames, `debuggable` and old build directories do not establish completeness. When the host sandbox blocks SDK access, use an explicit SDK tool path and the required host execution permission instead of weakening product validation.

During the earlier Debug packaging repair, quick documentation checks passed 21 cases; full documentation checks passed 38 with five failures involving missing JSDoc and stale persistence catalogs. Those historical results remain under `.cache/android/flutter-startup-audit-20261029/`. Later `runtime-final-doc-sync.log` in `.cache/android/build-hang-audit-20261029/` records 43 passed, zero failed and zero skipped for its then-current tree. The runtime artifact build passed seven gates and the following aggregate build check passed two. The focused Flutter UI run passed 357 tests after correcting premature folding of unresolved tools; analysis retained eleven information-level notices and no errors or warnings. These are host checks, not a full device UI signoff, and later edits require the applicable gates again.

## Dev Note

Package, upgrade or pursue adjacent tasks only when requested. Date and scope memory updates, link existing authoritative records, and keep pending acceptance separate from completed work.
