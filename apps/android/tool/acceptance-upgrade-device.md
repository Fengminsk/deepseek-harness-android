# Android APK upgrade and Keystore device acceptance

English | [中文](acceptance-upgrade-device.zh.md)

## Scope and prerequisites

This test checks a real Android package-manager upgrade from an older App APK to a newer one. [`UpgradePersistenceInstrumentation.kt`](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/UpgradePersistenceInstrumentation.kt) writes a 64-byte random canary under the target App's `noBackupFilesDir` and a separately randomized synthetic value under a unique `acceptance/upgrade/<token>` `CredentialVault` reference. The newer APK must read the identical file bytes and decrypt the value with the existing Android Keystore key. The base test never uses a real account, session or user document. The optional SAF readability mode reads an existing user-granted document without changing it.

Prepare the old App APK, the newer App APK and an AndroidTest APK built from the **newer** source with the upgrade instrumentation registered. Both App APKs and the test APK must have the same signer; the newer App must increase `versionCode`. Android SDK `aapt2`, `apksigner.jar`, `adb`, and Java must be available. Authorize one device and keep it available for the whole run. The script refuses an already installed App unless `--allow-existing` is explicit; if present, its installed version must equal the old APK version. An ordinary `adb install -r` retains package data; this script never uses `pm clear`, uninstall or downgrade flags.

From the repository root, after the APKs are ready and device use is authorized:

```sh
node apps/android/tool/acceptance-upgrade-device.mjs --old-apk <old-arm64-debug.apk> --new-apk <new-arm64-debug.apk> --test-apk <new-arm64-androidTest.apk> --serial <adb-serial> --allow-existing
```

The script hashes all three APKs, checks package names, version codes, signing certificate digests and the exact test runner declaration before installation, installs the old App and newer test APK, seeds the synthetic data, performs `adb install -r` of the new App, verifies the file and decrypted value, then removes only those exact synthetic artifacts. It also compares the count and SHA-256 digest of persisted SAF read-grant identities at every phase; an empty set is accepted unless the option below requires an existing grant. Raw document URIs are never printed. A failed verification does not run cleanup. Before seed, stderr prints the test token so a retained canary can be inspected after a failed upgrade; the success JSON records the APK hashes and phase results without printing the synthetic secret.

## Optional device observations

`--require-saf-grant` requires an already installed old App, `--allow-existing`, and at least one persisted SAF read grant obtained through the App before the run. It rejects an empty grant set and any change to that set across the upgrade. This checks grant metadata, not document readability.

`--saf-readable-path <relative/path.txt>` additionally requires an already installed old App with a persisted SAF **folder** read grant and `--allow-existing`. Place a stable regular file of at most 16 MiB inside one granted folder before the run; provide its relative path within that folder. Unicode names and spaces are supported; control characters, backslashes, absolute paths, and empty or dot segments are rejected. The path is encoded before being passed to ADB. It must resolve to exactly one file across all granted folders. The probe reads the entire file in the old Agent process at seed, after the package upgrade in the new Agent process, and again at cleanup. It compares hashed grant and document identities, byte count and SHA-256 content digest. It does not write the document or print its URI, path or contents. Do not edit/move the file or change grants during the run. This option implies `--require-saf-grant`. For example:

```sh
node apps/android/tool/acceptance-upgrade-device.mjs --old-apk <old.apk> --new-apk <new.apk> --test-apk <new-androidTest.apk> --serial <adb-serial> --allow-existing --saf-readable-path upgrade-probe.txt
```

`--require-device-offline` requires Android to expose zero networks with `NET_CAPABILITY_INTERNET` during seed, verification and cleanup. Disconnect Wi-Fi, mobile data and any Internet-capable VPN before starting; USB ADB remains available. The script never changes device network settings. This checks the system's network capabilities at those checkpoints, not an offline conversation or request replay.

`--force-stop` starts a held instrumentation run in the old App's Agent process after seeding. It waits for an explicit ready status and a live matching PID, runs `am force-stop`, then requires that PID to disappear and the held instrumentation to terminate before upgrading. This deliberately stops all App processes and any active App task; use it only on a device where that interruption is acceptable. If the hold cannot be observed or stopped, the run fails rather than reporting process-death evidence.

These options can be combined with the base command. The device must remain offline for the entire run when `--require-device-offline` is set.

## Evidence boundary

A passing base result proves the device retained this App-private no-backup file and could decrypt this synthetic `CredentialVault` entry through a real package-manager upgrade. Optional results separately establish SAF grant metadata continuity, actual readability and unchanged bytes for one selected SAF file, absence of Internet-capable networks at three checkpoints, and observed Agent process termination via force-stop. The SAF mode proves this selected document only; it does not cover every grant, a real DeepSeek account session, conversation, background task recovery, device reboot, or model request behavior. Those paths require their own device acceptance. This script and its host parser tests are prepared but have not run on a phone in this change.
