# Optional Android shared-memory mode in the ARM64 candidate

English | [中文](SHMEM.zh.md)

The pinned Termux PRoot source already implements per-PRoot System V IPC when
`--sysvipc` is used without libandroid-shmem sharing. The library is needed for
its separate cross-instance keyed sharing mode, not for an ordinary shell.
Its upstream implementation constructs key symlinks under `_PATH_TMP`, which is
not a validated writable location for an Android isolated UID. Its key-creation
loop could also retry without a bound.

`build.ps1` verifies the pinned PRoot, talloc, and libandroid-shmem archives,
extracts them into its owned cache, then applies `patch-shmem-private.py`. That
patch rejects source revisions other than the two fixed SHA-256 values. It
replaces `_PATH_TMP` with `DSH_SHMEM_KEY_DIR`, requires the named directory to
be absolute, owned by the process UID, a real directory rather than a final
symlink, and inaccessible to group/others. Key creation stops after 32 tries.
The PRoot source is changed so cross-instance sharing is **off by default**;
it needs both `DSH_ENABLE_LIBANDROID_SHMEM` and `DSH_SHMEM_KEY_DIR`, and still
honors `PROOT_DONT_SHARE_LIBANDROID_SHMEM`. The candidate statically links the
patched library, with Android `libandroid` and `liblog` as runtime dependencies.

This is a **compile and source reproducibility result**, not a working Android
IPC claim or confinement feature. There is no App launcher to set a private
directory, and an isolated process may be unable to use App-private storage.
The current directory check does not resolve every parent component against a
trusted directory descriptor. A future launcher must supply a per-run private
directory that the isolated UID can actually use, validate it without path
races, keep the mode disabled unless the user-approved run needs this behavior,
and prove denial and cleanup on a normal non-root device. The keyed mode must
not be exposed to an Agent until those checks and process-tree retirement pass.

Host check: `python -m unittest apps.android.tool.linux-proot-candidate.test_patch_shmem_private`.
Build output stays in `.cache/android/linux-proot-source/build-arm64-v8a/` and
is never packaged in the APK.
