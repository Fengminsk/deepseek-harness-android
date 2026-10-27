# Linux command device acceptance

English | [中文](linux-command-device-acceptance.zh.md)

## Scope

[`LinuxCommandAcceptanceInstrumentation.kt`](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/LinuxCommandAcceptanceInstrumentation.kt) checks the internal fixed Linux-style command service on an ordinary, non-rooted Android device. It tests the native service rather than the separately registered `android_linux` Agent tool, and does not establish a general Linux container. The App and AndroidTest APKs must be built from the same source revision. The device must run Android 10 or newer, have USB debugging authorized, and be available for the duration of the test. The lifecycle phase requires a debuggable App APK because its diagnostic commands cannot run in a release package.

From the repository root, after the APKs are prepared and device use is authorized, run:

```sh
node apps/android/tool/acceptance-linux-command-device.mjs --apk <arm64-debug.apk> --test-apk <arm64-androidTest.apk> --serial <adb-serial>
```

The script installs the two specified APKs with `adb install -r`, retaining existing App data. It refuses missing APKs, unauthorized or ambiguous devices, failed installation, missing instrumentation results, incomplete test lists, and a surviving fixed 30-second test child visible through `adb shell ps -A -o PID,ARGS`. It records both APK hashes and emits the phase results as JSON only after both phases pass. Do not run it against a phone that the user is actively using.

## Evidence and limits

The baseline phase compares the child process's `id -u` output with the Binder guest UID and checks it differs from the App UID. A completed command also requires the isolated service's App-private directory and direct network socket probes to be denied. SHA-256, byte count and line count now resolve to the APK-installed, fixed-argument Bionic executable; the device test verifies that APK-installed executable identity, exact results at the 64 KiB input boundary, the isolated UID and direct-child retirement. Sorting and literal filtering continue through fixed system Toybox commands, including the no-match result. The App-owned RPC manager must return the correct SHA-256 output with an isolated UID and reject test-only command IDs and an extra `cwd` field before admission. The packaged executable itself rejects unknown modes and input beyond 64 KiB; the policy duplicates that size limit before dispatch.

The lifecycle phase uses debug-only, fixed commands to exercise the APK-packaged native byte-count tool independently of the production commands, cancellation after a verified child-start Binder receipt, the guest deadline, output overflow, and isolated service death. The script scans for the fixed 30-second test child immediately after this phase; it fails if the phase takes long enough for a leaked child to exit naturally. This scan covers the named diagnostic child only. It does not establish whole-process-tree retirement for arbitrary Shell programs, package installation, an Alpine or PRoot guest, file/network broker operations, background survival, or Android package-manager upgrade. Those capabilities remain gated until their own device evidence is recorded.
The cancellation and guest-deadline assertions also require the isolated guest's terminal receipt and UID. An App-side cancellation request alone cannot establish retirement; a host deadline without that receipt is reported as unconfirmed.

Add `--image` to the same command to run the sealed-image Binder transport instrumentation after the command phases. It requires an isolated-UID success receipt and rejection of writable or digest-mismatched image snapshots. This fixture does not install or execute Alpine.

Add `--image-install-fixture` to exercise the image store on the device with synthetic inert bytes. The fixture checks partial-install rejection, restart verification, and receipt-tampering rejection, then removes only its own test directory. It neither downloads nor executes Alpine and cannot establish that a real Linux guest starts.

## Optional isolated guest storage probe

Add `--guest-storage-probe` to the same command with **matching debug App and AndroidTest APKs**. The probe service is declared only in the debug variant. It receives a random synthetic marker through a read-only file descriptor and sealed `SharedMemory`; no user file, Agent tool, network request, Alpine image, or PRoot binary is involved. It tests direct read and create attempts in a dedicated fixture under App `noBackupFilesDir`, transferred descriptor read/write, shared-memory read/write, and isolated-service `cacheDir` create/read/execute attempts. It also tries a read-only executable `mmap` of the synthetic cache file, without calling any mapped bytes. The execute attempt is solely a disposable `#!/system/bin/sh` script that exits 0. These are W^X observations, not proof that an Alpine ELF or PRoot loader can execute. The test removes its own UUID-named files, leaving existing App data untouched.

The host requires **denied** App-private direct read/create, **allowed** transferred read-only FD read, **denied** FD write, **allowed** sealed shared-memory read, and **denied** shared-memory write. A missing result, unverified isolated UID, or unexpected capability fails the probe. The three temporary-directory observations are reported individually as `allowed`, `denied`, or `untested`; they do not decide this boundary test. `untested` means the operation was not reached or its result was inconclusive, and must not be interpreted as an Android denial. In particular, an App cache directory denied to the isolated UID prevents the subsequent execute attempt; this probe then says nothing about execution from an independently brokered guest mount.

This is a device observation on the tested OS/build only. It does not establish that PRoot can mount or run Alpine, that arbitrary files can be brokered safely, or that a full guest can survive background process termination. Android officially documents that an `isolatedProcess` service has no permissions of its own, and AOSP identifies the `isolated_app` SELinux domain; those descriptions motivate the probe but do not replace it. See [Android service manifest](https://developer.android.com/guide/topics/manifest/service-element), [AOSP SELinux concepts](https://source.android.com/docs/security/features/selinux/concepts), and [Android SharedMemory API](https://developer.android.com/reference/android/os/SharedMemory).

\n