# PRoot host preflight and debug-device probe gate

English | [中文](PROBE-READINESS.zh.md)

The pinned PRoot and loader are **host build artifacts**, not Android App
features. The current APK must contain neither ELF nor Alpine rootfs. Run this
non-executing host check after `build.ps1`:

```powershell
python apps/android/tool/linux-proot-candidate/probe-readiness.py --candidate-dir .cache/android/linux-proot-source/build-arm64-v8a
python -m unittest apps/android/tool/linux-proot-candidate/test_probe_readiness.py
```

The checker verifies exact SHA-256 identities, little-endian AArch64 ELF
headers, executable entry segments, and the PRoot event-pipe protocol markers.
It reports `hostIdentityAndElfReady` only; `distributionApproved`,
`apkPayloadAllowed`, and `deviceExecutionProven` remain false. It never launches
the files, copies them into Android source sets, or reads an APK.

The Android Gradle configuration rejects known candidate names and these two
exact ELF digests under renamed files in its `src` tree. The final APK verifier
rejects known guest names and the two pinned ELF digests even when the ZIP
entries have different names. Hashing is bounded to entries with the pinned
uncompressed ELF lengths. This gate cannot identify modified binaries, an
arbitrarily renamed rootfs, or candidate bytes hidden inside nested archives
such as `runtime.zip`; the distribution review remains mandatory.

The event-patched PRoot refuses to start without an OS-owned inherited pipe
descriptor `DSH_TRACEE_EVENT_FD` and canonical `DSH_TRACEE_RUN_ID`; it also
needs `PROOT_LOADER` pointing to the installed loader. Java `ProcessBuilder`
alone cannot establish that descriptor and whole-process-tree evidence. The
separate native supervisor is being developed behind a default-off build
option. Its proposed fixed diagnostic command is `/bin/true`, with no model
input, no user files, and no network. Once source/license delivery is reviewed,
the exact native pair can be packaged in a dedicated internal diagnostic build,
then installed and tested on a user-authorized device. A host preflight or a
successful Gradle build must never be presented as Linux execution proof.
