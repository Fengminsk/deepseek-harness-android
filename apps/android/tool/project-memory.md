---
kind: reference
title: Android DSH project memory
---

# Android DSH project memory

English | [中文](project-memory.zh.md)

## Summary

This record preserves project agreements, verified results and continuation entry points as of 2026-10-29. It does not certify completion of the six migration stages. Check Git state, the actual APK and device evidence before reusing these conclusions.

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

On 2026-10-29, the installed Debug APK was confirmed to lack both the Dart kernel and AOT `libapp.so`. The build-directory alias problem in output inventories was repaired, and Gradle plus independent APK content checks were added. Debug requires a valid kernel and isolate snapshot; the pinned SDK permits an empty VM snapshot. Release/Profile use AOT and do not require `kernel_blob.bin`. See the [packaging guide](flutter-packaging.md).

The retained ordinary App is `0.1.0+120` arm64 Debug, archived as `pocket-harness-0.1.0+120-arm64-debug-project-local.apk` under the project's `.cache/android/flutter-startup-audit-20261029/`. Its SHA-256 is `1bef9f079ff80ac37a70cade4aceb9ce6cf0a4ecde430a6e62c9e77f0802b63c`. It was built from the working tree, including existing uncommitted changes; the packaging repair commit alone cannot reproduce those exact bytes.

The complete APK check passed, together with 38 verifier cases that reject the original missing-Dart package. After a retained-data replacement, hashes of 101 session and preference files matched, the ordinary Dart main isolate was runnable and the Agent moved from `starting` to `ready`. This certifies that startup and upgrade, not every user task, file grant or background recovery. This Debug APK contains no Linux VM candidate assets; Linux acceptance used the separate Release archive below.

## Linux and remaining acceptance

Retain the Linux Release, instrumentation APK and records in `.cache/android/device-v120-20261028/r43/`, plus the complete `alpine-ic8p90k9` and `alpine-tthk3anu` candidates and corresponding sources under `.cache/android/linux-vm-candidates/`. The former matches r43; the latter is referenced by the [network acceptance guide](linux-vm-network.md). Candidate presence does not establish that the ordinary App enables Linux.

The [Build 120 acceptance record](upgrade-120-acceptance.md) preserves PTC checks and the r55 real-account `workflow-linux` success: one completed workflow, one child session, an isolated-UID `linux_exec` receipt with exit code zero, confirmed retirement and temporary cleanup. Earlier freeze, unreachable-proxy and model-argument failures remain separate failed records; later success does not erase them.

Continue from the [capability inventory](parity-manifest.json), [model PTC/Linux reference](model-ptc-linux.md) and [natural-alarm test](schedule-wakeup-device.md). SAF revocation/search, natural alarm firing, permission revocation, reboot/extended Doze recovery, general Linux networking and unrestricted PTC/workflow must not be marked complete from the evidence above. Inventory counts describe declarations, not user features.

## Cleanup and retained evidence

This cleanup uses an explicit file inventory for obsolete Android APKs, superseded Linux candidates and generated assets, old source-package copies and noncurrent Flutter compiler caches. Alpine `.apk` files are guest dependencies, not Android release history, and are retained. Emulator data, screenshots, session exports, WIP files, Git, dependencies and current runtime assets are outside the cleanup scope.

Before deleting candidate directories, copy their small JSON, logs and notices into `.cache/cleanup-audit-20261029/candidate-evidence/` and verify their hashes. Original acceptance reports and packaging diagnostics remain available; after old APK bytes are removed, historical acceptance describes the recorded run and does not promise that those old packages remain installable. Exact targets, recovered space and retained-file checks are recorded in that directory's `cleanup-plan.json` and `cleanup-result.json`.

## Verification and continuation

Packaging checks inspect the actual APK; filenames, `debuggable` and old build directories do not establish completeness. When the host sandbox blocks SDK access, use an explicit SDK tool path and the required host execution permission instead of weakening product validation.

During the packaging repair, quick documentation checks passed 21 cases; full documentation checks passed 38 with five existing failures involving missing JSDoc and stale persistence catalogs. Source and device evidence remains under `.cache/android/flutter-startup-audit-20261029/`; subsequent changes require rechecking the affected claims.

## Dev Note

Package, upgrade or pursue adjacent tasks only when requested. Date and scope memory updates, link existing authoritative records, and keep pending acceptance separate from completed work.
