---
kind: reference
title: Linux 客体设备生命周期验收
---

# Linux 客体设备生命周期验收

[English](linux-vm-lifecycle-device.md) | 中文

## 概要

[设备执行器](acceptance-linux-vm-lifecycle-device.mjs)为运行中的 Linux 取消、导入退役后的 Android 进程终止，以及普通 App 升级后的工作区保持准备证据。它使用独立的 `linux-lifecycle-<uuid>` 会话并保留记录。主机解析测试不能证明 Android 验收通过；每种模式都需要单独保存的设备报告。

## 目录

- [前提和入口](#prerequisites-and-entry-points)
- [证据和边界](#evidence-and-limits)
- [主机验证](#host-verification)
- [开发备注](#dev-note)

<a id="prerequisites-and-entry-points"></a>
## 前提和入口

使用包含 `LinuxVmLifecycleAcceptance` 的配套 [Alpine 验收 App 与 release AndroidTest 包](tinyemu-build.zh.md#alpine-acceptance-apk)，通过 `ANDROID_HOME` 或 `ANDROID_SDK_ROOT` 提供 Android SDK 工具。既有的 `LinuxVmAcceptanceInstrumentation` 分发 `lifecycle-cancel`、`lifecycle-death-prepare`、`lifecycle-death-recover`、`lifecycle-upgrade-seed` 和 `lifecycle-upgrade-verify`；每项接收规范 UUID 格式的 `token`。无需新增 manifest 注册。共享的 `AcceptanceForegroundLease` 要求手机已解锁、屏幕处于交互状态，且黑色前台窗口已绘制。它不会唤醒或解锁设备，也不会启动产品 MainActivity。

主机 CLI（命令行界面）接收 `--mode cancel|death|upgrade`、`--apk`、`--test-apk`、`--output <new-directory>`，以及可选的 `--serial` / `--adb`。实际执行必须提供 `--accept-agent-interruption`；替换已安装 App 还须提供 `--allow-existing`。Instrumentation 会替换 `:agent` 进程，因此仅在用户任务空闲时运行。`death` 模式会主动终止该真实 Android 进程。它不会强行停止整个包，也不会用主机进程终止代替设备行为。

`upgrade` 还须提供 `--new-apk` 和 `--new-test-apk`。执行器在修改设备前验证包身份、签名证书一致以及 `new.versionCode > old.versionCode`，检查已安装的初始版本，在旧 App 播种，然后用 `adb install -r` 安装两个新 APK。它不会清除数据、卸载、降级或修改权限和网络设置。两组产物都必须包含此执行器；更早的包无法播种本测试。`--preflight-only` 仅在本机读取 APK manifest 和证书，不联系 ADB；它不验证包内测试实现，也不代表设备验收成功。

`--output` 必须指定新目录。主机在 `artifacts.json` 中保留产物路径、SHA-256、签名和版本身份、token 及设备序列号，在各阶段 `.txt` 中保留已结束的 instrumentation 输出，最后生成 `report.json` 或 `failure.json`。每阶段的主机时限为 180 秒，包围生产环境 120 秒的客体时限。缺失或失败的结果不能算作通过。失败后应停止并检查保留的 token 记录；执行器没有清理、确认或解锁操作。

<a id="evidence-and-limits"></a>
## 证据和边界

| 模式 | 必需的设备证据 | 覆盖边界 |
| --- | --- | --- |
| `cancel` | 精确运行 UUID 的 service 身份、存活的隔离进程 PID、Linux 工作线程 CPU 活动、活动中的持久记录、带隔离 UID 和退役确认的原生取消结果，以及 `diskCommitted: false` | 取消运行中的原生客体，不是仅取消尚未获准的请求。原生返回确认退役；Android 仍可能列出空闲 service 进程。 |
| `death` | 真实不可变文件输入及导入命令在隔离客体中完成；`markRetired` 已同步；App 进程在磁盘捕获和发布前主动终止。不同 Android PID 打开新 Manager，报告 `interrupted`、`needsReview: true` 和 `diskCommitted: false`，拒绝后续请求且没有客体 UID，并保留原 journal 字节与源文件哈希。 | 覆盖导入的**退役 → 发布**窗口。不认证客体执行中的进程终止、导出发布、断电或 Node/Session 恢复。不会重放命令，待核对限制保持生效。 |
| `upgrade` | 旧 App 提交唯一工作区文件和持久运行记录；签名相同的新版本 App 通过丢弃式原生执行读取相同文件和哈希，并观察原先已提交的记录 | 证明该 Linux 工作区在所测普通升级中保持。不代表所有用户数据均被保持，或与全部旧镜像兼容。 |

进程终止准备直接使用生产 `LinuxVmFileInput`、`LinuxVmImageStore` 和 `LinuxVmRunner`，停在与 `LinuxVmManager.run` 相同的 `markRetired` 边界。恢复和后续请求拒绝经过新的生产 Manager。取消和升级执行同样使用该 Manager。这些是原生生命周期检查；[运行时验收套件](device-runtime-acceptance.zh.md)单独负责完整的模型 → ToolRuntime → Binder 路径，包括成功的 Linux 子任务工作流和 Python 分析检查。

只创建该 token 的独立源文件、标记和 Linux 会话。恢复不会扫描用户对话文件或改写其他会话。未完成的 fixture（测试前置数据）和待核对记录会保留供检查。客体网络、退役前导入中断、导出时进程终止及活动模型的网络恢复均不在这些检查范围内。[恢复参考](linux-vm-recovery.zh.md)定义生产环境对不确定结果的解释。

<a id="host-verification"></a>
## 主机验证

`node --test apps/android/tool/acceptance-linux-vm-lifecycle-device.test.mjs` 在不使用 ADB 的情况下检查证据解析和编排顺序。它拒绝缺失或重复结果、错误身份、缺失运行中工作线程证据、未确认退役、重放、journal 改变、相同进程 ID、哈希不符、签名不符和版本未递增的升级。其注入适配器只证明主机顺序；合成输出不会作为设备验收证据保存。

<a id="dev-note"></a>
## 开发备注

三种设备模式需要分别实际运行。新增此测试载体或通过主机测试，不会改变产品能力开关，也不会认证任何尚未运行的设备结果。
