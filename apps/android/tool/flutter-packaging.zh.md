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

## 排查 Windows 构建停顿

直接运行 Gradle wrapper 时添加 `--console=plain --info`。最后打印的任务不能说明正在等待什么：`mergeReleaseNativeLibs` 可能正在通过 HTTPS 解析 Flutter 引擎 JAR。停止进程前，对本轮构建自己的客户端和 daemon 执行 `jcmd <pid> Thread.print`，区分下载 socket 读取与循环锁等待；不要停止无关的 IDE daemon。

Kotlin 在用户目录 daemon 标记文件上抛出 `AccessDeniedException`，属于单独的文件访问失败。修改编译器设置前，先以所需的宿主权限重试。PowerShell 中带点的参数要整体加引号，例如 `'-Pkotlin.compiler.execution.strategy=in-process'`；若提示找不到 `.compiler.execution.strategy=in-process` 任务，说明参数根本没有传到编译器。

直连下载停滞时，为本次构建配置 HTTP/HTTPS 代理。Java 报 TLS 握手失败时，保留证书检查，通过配置的代理验证同一官方依赖。本地 Maven 仓库必须保留原始 POM/module 元数据、核验上游摘要，并精确限定依赖版本。只有所有必需产物和元数据齐备时，`--offline` 才能成功；仅把 JAR 复制到 Gradle 文件存储不会登记其缓存元数据。

## 检查 APK

`assembleDebug`、`assembleProfile` 和 `assembleRelease` 任务要求包内包含 Dart 应用。Debug 要求 `kernel_blob.bin`、`isolate_snapshot_data` 和 `vm_snapshot_data`；固定版本的引擎允许 VM 快照为空。Profile 和 Release 要求 `lib/arm64-v8a/libapp.so`。所有模式均要求 `AssetManifest.bin`。缺少必需条目会使构建失败。

使用预定的版本与运行时摘要执行独立交付检查：

```powershell
./tool/verify-apk.ps1 -ApkPath build/app/outputs/flutter-apk/app-debug.apk -ExpectedVersionName 0.1.0 -ExpectedVersionCode 120 -ExpectedFlutterBuildMode debug
```

交付新打包的运行时时，应添加来自运行时打包步骤的 `-ExpectedRuntimeSha256`。已验证的 Linux 候选包还需要现有候选参数。检查器单独报告 Debug/AOT 载荷完整性；仅凭载荷形式不能区分 Profile 与 Release，也不能证明应用能够启动。

## 验证

`verify-apk.test.ps1` 使用缺失、空文件、混合载荷等合成输入，以及可选的真实正常包和损坏包验证检查器。真机启动单独检查：启动普通 App，确认 Dart isolate 和运行时状态，并保留用户数据和用户要求的屏幕保护。
