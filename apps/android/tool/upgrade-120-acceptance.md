---
kind: reference
title: Build 120 upgrade and execution acceptance
---

# Build 120 upgrade and execution acceptance

English | [中文](upgrade-120-acceptance.zh.md)

## Summary

Build 120 r43 is installed over the existing App with its data retained. It fixes confirmed callback cancellation being reported as uncertain retirement; the [nested PTC/Linux evidence](model-ptc-linux.md#verification) records the device results. This is scoped execution and upgrade evidence, not completion of the Android migration.

## Artifacts and upgrade

The archive is `.cache/android/device-v120-20261028/r43`. The release APK has 355,537,108 bytes and SHA-256 `56316b0ad4215d5808e85d5bf6d993f105f8783b686c2f9311fe431df146385a`; AndroidTest has 649,441 bytes and SHA-256 `5ee3f7e566b97dc33ef5f1c3844579234587afb2ee6d1ce522114c4f420ec3ce`. PackageManager reports version `0.1.0+120` and the existing signing identity. The archive checks embedded runtime and fixture bytes against source; package, 26 instrumentation entries, DEX linkage and the separate SAF-provider linkage checks passed. These static checks do not substitute for execution.

`.cache/android/upgrade-119-120-r43-20261028.log` records the ordinary 119-to-120 replacement: 67 Session files totaling 1,846,034 bytes, three SAF grants and the synthetic Keystore credential retained identical hashes. The canary was removed afterward. The preceding 118-to-119 record is `.cache/android/upgrade-118-119-r42-20261028.log`. Neither check proves readability of every retained document or resumption of a user's interrupted task.

## Execution and remaining checks

`.cache/android/ptc-120-r43-protected-20261028.json.result.json` records twelve executed PTC checks passing, with zero failures. The separate SAF revocation/search check remains unverified in this suite, so `complete` is false. The enclosing report records 71 samples with both physical panels Off and confirmed test-process retirement. The r42 cancellation failures remain retained; the [APK inspection reference](apk-inspection.md) separately describes its successful synthetic-body check.

The real-account `workflow-linux` r42 attempt remains failed: the strict parameter check rejected a different spelling of slash escapes, and `.cache/android/workflow-linux-r42-diagnostic-under-120-r43-20261028.json.result.json` is a read-only diagnosis with zero new submissions, not a workflow acceptance. The [account acceptance reference](agent-service-task-device.md#programmatic) records the revision: the fixture decodes the reviewed wrapper, compares parsed child arguments and reports a bounded provider code for a failed turn; the rebuilt AndroidTest (SHA-256 `fbe87fff10147b7d2b7620c686211849fe05215c59c454da7313216157ed98fc`, unchanged production App) passes 135 host assertions. Device attempts retained their failures: the r44 attempt stalled on the OEM screen-off freezer (`cgroup.freeze=1` while AMS reported `isFrozen=false`) and failed after 319,535 ms; r45 through r49 submitted once and failed with `SESSION_FAILED` and provider code `TRANSPORT` because an App-side network proxy was enabled without a reachable proxy; r51 hit the 120-second turn bound during a slow cold start; and r54 was rejected because the model wrote a different program. `.cache/android/real-account-workflow-linux-120-r55-protected-20261028.json.result.json` then passed in 33,178 ms with one completed workflow run, one child Session, an isolated `linux_exec` receipt (guest UID 99,028 against App UID 10,496, exit zero, confirmed retirement and temporary cleanup) and confirmed parent and child archive. The r42 freeze left no surviving vendor log; the reproduced signature matches the OEM freezer recorded for r32. The diagnostic of that older case found one workflow run and no persisted member record, which does not establish that no child was ever created or authorize child cleanup.

The [natural alarm driver](schedule-wakeup-device.md) now retains bounded failure stages and independently verifies test-client retirement after read-only status failures. `.cache/android/schedule-natural-status-119-r42-stages-20261028.json` successfully read exact-alarm permission as allowed, but the App enable preference as false, with zero active reminders. It submitted no task and preserved the original main process. Earlier status deadlines remain recorded; later success does not explain them. Natural delivery, permission revocation and reboot restoration remain unverified.

## Validation limits

Focused callback, native bridge, lifecycle, account-evidence and driver checks passed, along with the staged-runtime smoke and release build. Full repository lint failed with 16 diagnostics in 12 unchanged package files; `.cache/android/ptc-closure-120-lint-baseline.json` records that each file matches its HEAD blob. No Android file was reported by that lint run. This is not a full-lint pass, and those unrelated package files were not changed.

## Dev Note

Retain the failing and successful reports separately. Source-only checks, synthetic APK metadata and display samples do not certify all providers, the original file-opening UI, long Doze operation, unrestricted Node PTC/workflow, Linux networking or all six migration stages.
