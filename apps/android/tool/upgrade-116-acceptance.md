---
kind: reference
title: Android Build 116 upgrade acceptance
---

# Android Build 116 upgrade acceptance

English | [中文](upgrade-116-acceptance.zh.md)

## Summary

The recorded 115→116 package-manager upgrade retained 47 existing Session files, three persisted SAF read grants and the readable bytes of one selected SAF test file. The upgraded App also decrypted a synthetic Keystore-backed credential. These results establish retention for this APK pair; they do not establish that the user's real DeepSeek account remained logged in or that an existing conversation resumed successfully.

## Contents

- [Record and artifacts](#record-and-artifacts)
- [Retained data](#retained-data)
- [Screen and retirement observations](#screen-and-retirement-observations)
- [Evidence limits](#evidence-limits)

<a id="record-and-artifacts"></a>
## Record and artifacts

This record covers package `com.minnnng.dsh_android`, the r27 Build 115 release and the r28 Build 116 release. Its only result sources are `.cache/android/upgrade-115-116-r28-20261028.result.json` and `.cache/android/upgrade-115-116-r28-screen-20261028.json`. The [upgrade acceptance reference](acceptance-upgrade-device.md) owns the procedure and optional probes; this page records their observed result, not a new test run.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Build 115 App, r27 | 355,490,312 | `13b77e076bd56b7223b95899c288dee68616505f421edeb4446161bff6c225f5` |
| Build 116 App, r28 | 355,490,296 | `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41` |
| Build 115 AndroidTest, r27 | 485,352 | `793b3b755f3efafb6cb062ba05226dd5e07f559116e9509d70f82c3bdcd78072` |
| Build 116 AndroidTest, r28 | 485,356 | `74d913413f36559cb9272df2bbfe2ae1c614e8878cbd5a024010e75091399b0e` |

The recorded signing certificate SHA-256 is `665169a9132865c4fb863bf408b06f0a359a9abc363d054c760972248cfce8a7`. The result records version 115 at seed and 116 at verify and cleanup, with `androidPackageManagerUpgradeTested: true`. It records distinct phase process IDs; this alone is not a process-death acceptance test.

<a id="retained-data"></a>
## Retained data

The seed, verify and cleanup records agree on every count and digest below. They also report `realSessionFilesRetained`, `safGrantMetadataRetained`, `safDocumentReadableTested`, `privateNoBackupDataTested` and `keystoreTested` as true.

| Observation | Retained result |
| --- | --- |
| Existing Session inventory | 47 files; 1,417,113 bytes; inventory/content SHA-256 `24cee4ffe84c0b1330bd35d07b85940c2333a102e546680426664d26724ef796` |
| Persisted SAF read-grant metadata | Three grants; SHA-256 `14bf745313f80f1acbb29610be8cfcbb6e9bb605aa6ad975007018388d457ca3` |
| One readable SAF test file | 33 bytes; content SHA-256 `ad313936091d58e1031045fe99bf616595cad2b1024f12f6121ce087fb981cc6`; hashed grant-root and document identities also match |
| App-private no-backup canary | SHA-256 `c31b710acd0a92eae4f3832e58cfadf38121c68b6b4e90e7c474e0e08604ad51` |
| Synthetic credential after decryption | SHA-256 `b08eb006ccf087f3a4383ad2456016a4983cfaae4101c7ce8bcaac6fb7a1c20a` |

The cleanup phase reports `cleaned: true` after rechecking the retained observations. That cleanup applies to the dedicated synthetic canary and credential; it is not a claim that user files, real credentials or Session data were deleted. The report contains no real account token or document contents.

<a id="screen-and-retirement-observations"></a>
## Screen and retirement observations

The screen-protection report has schema 2, `passed: true` and child command `exitCode: 0`. It contains 18 samples from `2026-10-27T20:55:04.540Z` to `2026-10-27T20:55:52.457Z`; every sample reports both display panels, IDs `0` and `2`, as `Off`. It records `restoredWhileNonInteractive: true`. These are sampled display and restoration observations; the JSON does not separately attest the keyguard state or continuous display state between samples.

The wrapper's retirement result records `hostProcessClosed: true`, `deviceProcessesGone: true` and `confirmed: true`. It also retains `hostStopAcknowledged: null` and `hostHandleReleased: false`; do not convert those fields into positive acknowledgements. This result concerns closure of the acceptance command and observed target processes. It does not prove retirement or recovery of an in-flight Agent, workflow child or Linux guest.

<a id="evidence-limits"></a>
## Evidence limits

The credential is synthetic. Successful decryption verifies this `CredentialVault`/Keystore path across the upgrade, not the user's DeepSeek login, provider token validity, avatar, refreshed authentication or a successful authenticated request. Session byte retention does not prove conversation rendering or execution: the report explicitly keeps `realSessionTested: false`.

Only one selected SAF file was read and hashed; metadata continuity for three grants is not readability coverage for every document. All three phases report three Internet-capable networks. Accordingly, `noInternetCapableNetworkAtCheckpoints`, `offlineSessionBehaviorTested` and `androidProcessDeathTested` remain false. The result does not cover reboot, interrupted work, offline replay, model execution or other Build 116 acceptance suites. It cannot certify a later rebuilt APK with a different hash.

<a id="dev-note"></a>
## Dev Note

None.
