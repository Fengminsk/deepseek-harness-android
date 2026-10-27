---
kind: reference
title: Windows Linux guest verification
---

# Windows Linux guest verification

English | [中文](README.zh.md)

This host-only probe compiles the prepared TinyEMU sources and the production `linux_vm_engine.c` for Windows x86_64. The JVM adapter reuses `LinuxVmConsole`, passes explicit direct-memory disks, and records bounded serial diagnostics. A Windows header maps the unused network callback types to Winsock declarations; no network device or host directory is supplied to the guest. It does not compile the Android file publisher or verify Binder isolation, service retirement, Android storage permissions or App startup.

The [builder](../build-tinyemu-host.mjs) requires an existing verified TinyEMU preparation record, a local JDK and the pinned [LLVM-MinGW portable archive](https://github.com/mstorsjo/llvm-mingw/releases/tag/20260908). Put `llvm-mingw-20260908-ucrt-x86_64.zip` and its extracted directory under `.cache/android/windows-host-tools/`. Its SHA256 must be `1bcf74d06b724aeecaa6412ca85f5b26fb1da770e7cdcefa9263c9c5c3ad34b6`. No system installation or WSL is needed. The build record includes source, JNI, Java, compiler and library identities.

Run from the repository root:

```powershell
node apps/android/tool/build-tinyemu-host.mjs '--jdk=C:\path\to\jdk'
node apps/android/tool/verify-tinyemu-host.mjs smoke
node apps/android/tool/verify-tinyemu-host.mjs alpine
node apps/android/tool/verify-tinyemu-host.mjs lifecycle
```

To verify a new independent host build without changing the default build record, append `--build-record=<path-to-build.json>` to any runner command. The runner still verifies the full build record and source hashes and creates a new evidence directory.

The [runner](../verify-tinyemu-host.mjs) requires the staged development guest assets. `alpine` also requires the hash-checked image-build input. `smoke` verifies boot and workspace retention across two real guest runs. `alpine` creates an ext2 image inside the guest, installs the locked offline packages, boots that image, exercises Python/threads/randomness/SQLite/SSL/subprocesses/git/curl/file operations, then checks an independent unmounted read-only image with `e2fsck -fn`. `lifecycle` times out a running loop and cancels after confirmed guest output; neither publishes changed images. It verifies that the source image stays unchanged.

Each invocation uses a new directory under `.cache/android/tinyemu-host/runs/`. Reports contain native status, guest exit code, hashes and explicit `androidDeviceVerified: false`. Images are written only after a completed guest command and native shutdown; failure diagnostics remain available. Passing host checks does not enable any product capability or certify phone execution. The ordinary Android build excludes this provider and its images as described by the [runtime reference](../linux-vm-runtime.md) ([中文](../linux-vm-runtime.zh.md)).

`LinuxVmHost` also accepts an optional thirteenth positional argument, `startupEpochSeconds`, only for host clock-failure tests. Without it, the production console samples the host UTC clock before boot. The argument cannot be supplied through an Android tool or Binder request. An unrepresentable value must make guest clock initialization return 125 before formatting or running the payload. `freshWorkspaceUnchanged` reports whether an initially empty workspace remains entirely zeroed; failed runs still publish no images. Normal clock verification must use the default host sample and check guest time, new file timestamps and ordinary Python ZIP creation without disabling timestamp validation.

## Candidate assembly

The `alpine` report binds the successful build, runtime probe and filesystem check to the exact system image, offline package input and interpreter build record. The runner rejects native, console or package inputs that have changed since preparation. Old reports without these bindings are not eligible for candidate assembly.

After `alpine` succeeds, package the current corresponding sources, then pass its printed report path to [the candidate assembler](../stage-alpine-vm-candidate.py). Use the printed candidate directory for independent verification:

```powershell
python apps/android/tool/package-linux-vm-sources.py
python apps/android/tool/stage-alpine-vm-candidate.py --host-report <report.json> --source-manifest .cache/android/tinyemu-probe/linux-vm-corresponding-source.manifest.json
python apps/android/tool/stage-alpine-vm-candidate.py --verify <candidate-directory>
python apps/android/tool/test_linux_vm_candidate.py
```

Each candidate occupies a new directory under `.cache/android/linux-vm-candidates/`, containing `assets/linux-vm`, the separate source archive and host evidence. The system disk is the tested Alpine image; the old demonstration disk is not copied. The assembler rehashes copied files and writes `candidate.json` only after verification. A failed copy retains partial files without a success record. Existing fixtures and candidates remain unchanged.

Candidate assembly does not modify Gradle, install an APK, enable model tools or certify Android execution. The image still has no network device; the curl probe verifies local execution, not connectivity. Device lifecycle and production Agent integration remain required before release.
