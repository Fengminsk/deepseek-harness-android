---
kind: reference
title: Android Build 116 升级验收
---

# Android Build 116 升级验收

[English](upgrade-116-acceptance.md) | 中文

## 概述

本次记录的 115→116 包管理器升级保留了 47 个既有 Session 文件、三个持久 SAF 读取授权及一个选定 SAF 测试文件的可读字节。升级后的 App 也成功解密了 Keystore 支持的合成凭据。这些结果证明此 APK 对的数据保持情况；不证明用户的真实 DeepSeek 账号仍处于登录状态，也不证明既有会话已成功恢复执行。

## 目录

- [记录与产物](#record-and-artifacts)
- [保留的数据](#retained-data)
- [屏幕与退役观察](#screen-and-retirement-observations)
- [证据边界](#evidence-limits)

<a id="record-and-artifacts"></a>
## 记录与产物

本记录覆盖包名 `com.minnnng.dsh_android`、r27 Build 115 正式包及 r28 Build 116 正式包。结果仅取自 `.cache/android/upgrade-115-116-r28-20261028.result.json` 和 `.cache/android/upgrade-115-116-r28-screen-20261028.json`。[升级验收参考](acceptance-upgrade-device.zh.md)负责说明流程和可选探针；本页记录已观察到的结果，不代表新执行了一次测试。

| 产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| Build 115 App，r27 | 355,490,312 | `13b77e076bd56b7223b95899c288dee68616505f421edeb4446161bff6c225f5` |
| Build 116 App，r28 | 355,490,296 | `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41` |
| Build 115 AndroidTest，r27 | 485,352 | `793b3b755f3efafb6cb062ba05226dd5e07f559116e9509d70f82c3bdcd78072` |
| Build 116 AndroidTest，r28 | 485,356 | `74d913413f36559cb9272df2bbfe2ae1c614e8878cbd5a024010e75091399b0e` |

记录的签名证书 SHA-256 为 `665169a9132865c4fb863bf408b06f0a359a9abc363d054c760972248cfce8a7`。结果在准备阶段记录版本 115，在验证及清理阶段记录版本 116，且 `androidPackageManagerUpgradeTested: true`。各阶段记录的进程 ID 不同；仅此不能构成进程死亡验收。

<a id="retained-data"></a>
## 保留的数据

准备、验证和清理三个阶段记录的下列数量与摘要均一致。它们还将 `realSessionFilesRetained`、`safGrantMetadataRetained`、`safDocumentReadableTested`、`privateNoBackupDataTested` 和 `keystoreTested` 报告为 true。

| 观察项 | 保留结果 |
| --- | --- |
| 既有 Session 文件清单 | 47 个文件；1,417,113 字节；清单／内容 SHA-256 为 `24cee4ffe84c0b1330bd35d07b85940c2333a102e546680426664d26724ef796` |
| 持久 SAF 读取授权元数据 | 三个授权；SHA-256 为 `14bf745313f80f1acbb29610be8cfcbb6e9bb605aa6ad975007018388d457ca3` |
| 一个可读 SAF 测试文件 | 33 字节；内容 SHA-256 为 `ad313936091d58e1031045fe99bf616595cad2b1024f12f6121ce087fb981cc6`；授权根目录及文档身份的摘要也一致 |
| App 私有 no-backup 测试文件 | SHA-256 为 `c31b710acd0a92eae4f3832e58cfadf38121c68b6b4e90e7c474e0e08604ad51` |
| 解密后的合成凭据 | SHA-256 为 `b08eb006ccf087f3a4383ad2456016a4983cfaae4101c7ce8bcaac6fb7a1c20a` |

清理阶段在再次核对保留结果后报告 `cleaned: true`。该清理针对专用合成测试文件和凭据，不表示删除了用户文件、真实凭据或 Session 数据。报告不包含真实账号令牌或文档内容。

<a id="screen-and-retirement-observations"></a>
## 屏幕与退役观察

屏幕保护报告使用 schema 2，记录 `passed: true` 及子命令 `exitCode: 0`。它包含从 `2026-10-27T20:55:04.540Z` 到 `2026-10-27T20:55:52.457Z` 的 18 个采样；每个采样均将 ID 为 `0`、`2` 的两个显示面板记录为 `Off`。它还记录 `restoredWhileNonInteractive: true`。这些是显示状态采样及恢复观察；JSON 没有单独证明锁屏状态或采样间的连续显示状态。

包装器的退役结果记录 `hostProcessClosed: true`、`deviceProcessesGone: true` 和 `confirmed: true`。它同时保留 `hostStopAcknowledged: null` 与 `hostHandleReleased: false`；不能把这些字段改述为肯定确认。该结果说明验收命令及所观察目标进程的结束情况，不证明执行中的 Agent、workflow 子级或 Linux 客体已退役或恢复。

<a id="evidence-limits"></a>
## 证据边界

该凭据为合成数据。成功解密验证了这一 `CredentialVault`／Keystore 路径跨升级可用，不验证用户的 DeepSeek 登录、供应商令牌有效性、头像、认证刷新或带认证请求成功。Session 字节保留不证明会话渲染或执行：报告明确保留 `realSessionTested: false`。

本次只读取并计算了一个选定 SAF 文件的摘要；三个授权的元数据连续性不等于所有文档都已验证可读。三个阶段均报告存在三个具备 Internet 能力的网络。因此，`noInternetCapableNetworkAtCheckpoints`、`offlineSessionBehaviorTested` 和 `androidProcessDeathTested` 仍为 false。该结果不覆盖重启、中断任务、离线重放、模型执行或其他 Build 116 验收套件，也不能认证之后重新构建且摘要不同的 APK。

<a id="dev-note"></a>
## 开发备注

无。
