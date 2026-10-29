---
kind: tutorial
title: Build Android Flutter packages
---

# Build Android Flutter packages

English | [中文](flutter-packaging.zh.md)

## Build

Use the Flutter revision in [runtime-lock.json](runtime-lock.json) and the Gradle wrapper. Run from `apps/android`:

```powershell
../../.cache/flutter/bin/flutter.bat build apk --debug --target-platform android-arm64 --no-pub
```

Keep `apps/android/build` as a real directory inside the project. On Windows, check `Get-Item build | Format-List FullName,Attributes,LinkType,Target` from `apps/android`; a normal build directory has no `LinkType` or `Target`. Replacing a junction requires removing only the link and recreating the local directory, without deleting its former target.

Gradle resolves the build directory to its physical path. When an earlier Flutter output inventory contains directory aliases, the compile task backs up and removes only its `.last_build_id` marker before compilation. It preserves the old output files and dependency caches; Flutter then records the current output inventory without deleting files through stale aliases.

## Check the APK

The `assembleDebug`, `assembleProfile` and `assembleRelease` tasks require a packaged Dart application. Debug requires `kernel_blob.bin`, `isolate_snapshot_data` and `vm_snapshot_data`; the pinned engine permits an empty VM snapshot. Profile and Release require `lib/arm64-v8a/libapp.so`. All modes require `AssetManifest.bin`. A missing required entry fails assembly.

Run the independent delivery check against the intended version and runtime digest:

```powershell
./tool/verify-apk.ps1 -ApkPath build/app/outputs/flutter-apk/app-debug.apk -ExpectedVersionName 0.1.0 -ExpectedVersionCode 120 -ExpectedFlutterBuildMode debug
```

Add `-ExpectedRuntimeSha256` from runtime packaging when delivering a newly packed runtime. Verified Linux candidate packages also require the existing candidate arguments. The verifier reports Debug/AOT payload completeness separately; payload shape alone cannot distinguish Profile from Release or prove application startup.

## Verification

`verify-apk.test.ps1` exercises the verifier against synthetic missing, empty and mixed payloads, plus optional real working and broken APKs. Device startup is a separate check: launch the ordinary App, confirm its Dart isolate and runtime state, and preserve user data and the requested screen protection.
