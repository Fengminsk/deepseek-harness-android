# 安卓版 DSH

[English](README.md) | 中文

## 概述

安卓版 DSH 面向已 Root 的安卓手机，将 DeepSeek Harness 适配为个人本地 agent（智能体）。产品目标是通过对话操作本机 shell、root 命令、文件以及 ADB 设备。

当前仓库处于初始化阶段，包含现有的 Node.js/TypeScript harness，尚未包含 Android 应用、APK 或经过真机验证的 Android root 与 ADB 集成。

## 目录

- [仓库](#repository-home)
- [开发](#development-guide)
- [许可证](#license-info)
- [开发备注：Android 产品规划](#android-product-brief)

<a id="repository-home"></a>

## 仓库

主仓库为 [Gitee 上的安卓版 DSH](https://gitee.com/minnnng/deepseek-harness-android)。`android` 分支用于 Android 开发，`master` 保留导入的基线。本地 `origin` 远端指向 Gitee，`github` 保留源码仓库，用于比较和获取更新。

本 README 介绍安卓版产品。现有包名与运行时版本仍属于导入的 harness，不代表 Android 发布版本。

<a id="run"></a>

<a id="run-from-source"></a>

<a id="development-guide"></a>

## 开发

当前仓库包含以下开发区域：

| 路径 | 用途 |
| --- | --- |
| `apps/` | 现有 CLI（命令行界面）、Web 和桌面应用 |
| `packages/` | Agent 运行时、模型接入、会话、shell 执行及其他插件 |
| `native/` | 原生运行时支持 |
| `docs/` | 运行时架构与开发文档 |

修改现有 harness 时，请阅读[开发指南](docs/development.zh.md)、[架构文档](docs/architecture.zh.md)和[仓库约定](AGENTS.md)。这些文档描述现有运行时，不是 Android 安装教程。

Android 运行时封装、后台执行和原生命令桥接仍需实现并经过真机验证，之后才能提供 APK。当前分支尚无 Android 构建或安装命令。

<a id="license-info"></a>

## 许可证

导入的 harness 保留 [MIT 许可证](LICENSE)。现有依赖的许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本分支尚未复制 FlClash 源码。引入其组件并分发 Android 应用前，需要落实其 [GPL-3.0 许可](https://github.com/chen08209/FlClash/blob/main/LICENSE)要求；当前 MIT 许可证不涵盖后续的组件集成。

<a id="android-product-brief"></a>

## 开发备注：Android 产品规划

以下内容是开发规划，不代表功能已经实现或通过真机测试。

### 本地 Agent 与设备

- 在手机上运行 agent 并执行工具。本地执行不等于离线模型推理，模型 API 接入单独配置。
- 通过原生桥接支持普通 shell 与 root 命令，提供命令输出、退出状态、取消执行和持久化执行记录。
- 对明确选中、已连接且已授权的设备执行 ADB 操作。USB 与无线连接的兼容性需经过真机验证；主机手机拥有 root 权限不代表能访问任意目标设备。
- 在应用内管理工作区、会话和文件操作。凭据、签名密钥、ADB 私钥和个人会话数据不进入 Git。

### 界面与导航

- 以 Flutter 作为 Android UI 的预定基础。实现前评估最新发布版 [FlClash](https://github.com/chen08209/FlClash) 的设计与可复用组件，再固定选用的源码版本，记录实际引入的组件及许可证。
- 以对话为主入口，提供历史会话侧栏、新建对话、常驻输入框、流式回复和可见的工具执行结果，参照 ChatGPT 手机版的交互习惯。
- 为工作区与文件、设备连接和设置提供独立页面。设置包含模型、API 接入、外观和执行权限。
- 显示执行目标与权限级别，让本机 shell、本机 root 和选中的 ADB 设备可以明确区分。

### 首个 Android 里程碑

首个真机验收目标是一条完整流程：打开对话，选择模型与执行目标，执行一条本地命令，显示输出与退出状态，再重新打开已保存的会话。随后分别验证 root 执行与已授权设备的 ADB 连接。
