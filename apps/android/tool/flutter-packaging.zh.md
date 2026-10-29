---
kind: tutorial
title: 构建 Android Flutter 安装包
---

# 构建 Android Flutter 安装包

[English](flutter-packaging.md) | 中文

## 构建

使用 [runtime-lock.json](runtime-lock.json) 固定的 Flutter 版本和 Gradle wrapper。在 `apps/android` 目录执行：

```powershell
../../.cache/flutter/bin/flutter.bat build apk --debug --target-platform android-arm64 --no-pub
```

将 `apps/android/build` 保持为项目内的真实目录。在 Windows 上，可从 `apps/android` 运行 `Get-Item build | Format-List FullName,Attributes,LinkType,Target`；正常构建目录没有 `LinkType` 和 `Target`。替换目录联接时，只移除链接并重建本地目录，不删除原目标目录。

Gradle 将构建目录解析为真实路径。若之前的 Flutter 输出清单包含目录别名，编译任务会在编译前备份并移除其 `.last_build_id` 标记。旧产物和依赖缓存均会保留；Flutter 随后记录当前输出清单，避免通过旧别名删除文件。

## 检查 APK

`assembleDebug`、`assembleProfile` 和 `assembleRelease` 任务要求包内包含 Dart 应用。Debug 要求 `kernel_blob.bin`、`isolate_snapshot_data` 和 `vm_snapshot_data`；固定版本的引擎允许 VM 快照为空。Profile 和 Release 要求 `lib/arm64-v8a/libapp.so`。所有模式均要求 `AssetManifest.bin`。缺少必需条目会使构建失败。

使用预定的版本与运行时摘要执行独立交付检查：

```powershell
./tool/verify-apk.ps1 -ApkPath build/app/outputs/flutter-apk/app-debug.apk -ExpectedVersionName 0.1.0 -ExpectedVersionCode 120 -ExpectedFlutterBuildMode debug
```

交付新打包的运行时时，应添加来自运行时打包步骤的 `-ExpectedRuntimeSha256`。已验证的 Linux 候选包还需要现有候选参数。检查器单独报告 Debug/AOT 载荷完整性；仅凭载荷形式不能区分 Profile 与 Release，也不能证明应用能够启动。

## 验证

`verify-apk.test.ps1` 使用缺失、空文件、混合载荷等合成输入，以及可选的真实正常包和损坏包验证检查器。真机启动单独检查：启动普通 App，确认 Dart isolate 和运行时状态，并保留用户数据和用户要求的屏幕保护。
