# Linux guest storage capability device probe

English | [中文](acceptance-linux-guest-storage-device.zh.md)

The debug APK contains `DebugGuestStorageProbeService`, a debug-only native `openat(2)` observer and `GuestStorageProbeInstrumentation`. This runner first checks the App and AndroidTest APK fingerprints, package names, signing certificates, native observer, private isolated Service declaration and Agent-process instrumentation declaration. `--preflight-only` uses no phone. A signed preflight does not establish Android storage behavior.

After the user authorizes a device test, the runner installs both APKs and asks the synthetic instrumentation to record direct App-private path read/write, a read-only App-supplied file descriptor, child `openat` read/write using a transferred directory descriptor, sealed shared memory, and isolated temporary file/read/exec-map/exec attempts. The eight required isolation and read-only transfer observations must match. A directory FD is not accepted as a guest filesystem root unless child opens are separately proven safe; this probe requires them to be denied on the target. Temporary observations are reported individually as `allowed`, `denied`, or `untested`, not treated as an executable guest result. The fixture contains only a random marker and deletes its exact files. The runner refuses an existing installation unless `--allow-existing` is explicitly supplied for that authorized test.

```sh
node apps/android/tool/acceptance-linux-guest-storage-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --preflight-only
node apps/android/tool/acceptance-linux-guest-storage-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --serial SERIAL
node --test apps/android/tool/acceptance-linux-guest-storage-device.test.mjs
```

The [Android 16 isolated-app policy](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/private/isolated_app_all.te) permits use of already-open App data file descriptors but forbids directly opening App data files. The directory-FD observation tests whether that permission could be mistaken for rootfs traversal. The observed temporary storage and execution states will determine whether the present isolated rootfs stager is viable on the target device. Even an `allowed` temporary observation would not prove PRoot confinement, process-tree retirement, broker-only files/network, or a supported distributed Linux image. The general Linux guest and model-facing command remain unavailable until those separate gates pass.
