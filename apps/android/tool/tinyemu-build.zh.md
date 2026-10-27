---
kind: reference
title: Android Linux 客体构建输入
---

# Android Linux 客体构建输入

[English](tinyemu-build.md) | 中文

## 概要

这些构建辅助工具准备固定的 TinyEMU 源码、官方 Alpine 软件包及对应源码。它们将构建产物写入 `.cache/android/tinyemu-probe`，不会在手机上安装软件。[运行时参考](linux-vm-runtime.zh.md)负责说明隔离、调用与真机验收。

## 目录

- [解释器](#解释器)
- [客体输入](#客体输入)
- [对应源码](#对应源码)
- [证据边界](#证据边界)

## 解释器

[源码构建器](build-tinyemu.mjs)校验[源码锁](tinyemu-source-lock.mjs)，解包全新副本，应用 [Android 补丁](patch-tinyemu.mjs)，再调用 Android NDK 编译器。其清单记录 C 源码、头文件、补丁、编译参数与动态库的哈希。无图形构建排除宿主文件系统适配器、SDL、SLIRP、curl 和 KVM。源码或补丁变化后必须重新生成预备构建清单。

## 客体输入

[软件包收集器](collect-alpine-vm-packages.py)需要带有 `cryptography` 的 Python、curl 和固定的 Alpine minirootfs。它使用该 minirootfs 内的公钥校验固定仓库索引的 RSA 签名，解析固定的 RV64 软件包闭包，并校验每个 APK 的控制段校验值与载荷哈希。[软件包锁](alpine-packages.lock.json)记录精确的软件包、依赖、架构、许可证及哈希。复用缓存仍然校验内容。未知依赖语法、多义提供者、签名失败和哈希不一致都会终止收集。

[输入组装器](build-alpine-vm-input.py)校验 minirootfs 和软件包锁，然后生成确定性的 USTAR 文件，其中仅包含 `rootfs.tar.gz`、`tools.tar` 和 `e2fs.tar`，总大小限制为 64 MiB。内层归档包含离线 APK 与不依赖宿主路径的清单。该输入供客体内构建镜像使用，既不会启用客体联网，也不会在 Windows 上执行软件包脚本。已有且内容不同的输出会被保留并拒绝覆盖。

## 对应源码

[源码收集器](collect-alpine-vm-sources.py)从固定的 rootfs 和软件包锁读取精确的 aports 提交。它收集原始归档、补丁、配置和打包脚本，不执行 APKBUILD。配方输入必须匹配 SHA512；配方和补充脚本必须匹配[源码锁](alpine-sources.lock.json)。生成的 Alpine 发行文本由其完整配方覆盖。缺失源码输入会报告为失败。

[源码打包器](package-linux-vm-sources.py)生成独立归档，包含 TinyEMU、固件与内核源码、对应补丁/配置/许可说明、Alpine 对应源码，以及 Android 嵌入源码快照。每项固定输入都会重新计算哈希。归档保留原始源码的完整许可证，清单索引成员及哈希。最终嵌入代码修改后需重新生成此产物，并随二进制发行一起提供。它不包含旧演示 rootfs，因为其中 BusyBox/glibc 的精确构建输入仍未经核验。

## 证据边界

[Windows 客体测试](linux-vm-host/README.zh.md)为本机 JVM 编译相同解释器和生产 JNI 入口，可在手机未连接时执行真实客体及镜像检查。其报告明确不代表 Android 真机验收。

[实验性 Windows ext2 构建器](build-alpine-vm-image.py)仅用于主机调查。其自带读取器检查文件内容、链接目标、inode 模式、归属、目录类型与分配计数；这些检查不属于独立文件系统验证。它不是生产镜像构建路径，也不保证文件系统元数据可复现。内核挂载、独立 e2fsck、可执行链接、磁盘写回和第二次启动需要真机证据。仅有匹配的 RV64 ELF 属性不能证明 Alpine 与旧内核兼容；Python 线程、时间、文件操作和阻塞式 `os.urandom` 需要执行测试。

## 开发说明

源码收集与归档组装不能证明 Agent 环境可用。软件包来源、NDK 编译、客体启动和实际任务执行应分别记录结果。
