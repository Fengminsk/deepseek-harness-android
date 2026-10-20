# Pocket Harness

[English](README.md) | 中文

## 概述

Pocket Harness 把本地 Agent 带到 Android，提供对话、授权文件、普通 Shell 命令与可选的原版 Web 界面。模型推理使用配置的在线 API；手机运行内嵌服务不依赖 Root、Termux 或电脑。

本分支提供开发预览，并未完成全部 Android 迁移。Flutter 界面和主题设置已提供；运行时联调、完整原生管理页面以及 App/Web 共同操作验收仍在进行中。

## 目录

- [仓库](#repository-home)
- [当前预览](#current-preview)
- [开发](#development-guide)
- [许可证](#license-info)

<a id="repository-home"></a>
## 仓库

主仓库是 Gitee 上的 [Pocket Harness](https://gitee.com/minnnng/deepseek-harness-android)，开发分支为 `android`。产品改名不改变内部 DSH 包名和 Android 应用 ID。

<a id="current-preview"></a>
## 当前预览

App 提供对话首页、历史侧栏、文件浏览、模型凭据表单、高级配置编辑、Web 访问控制和诊断入口。**设置 → 外观与主题** 可独立配置浅色／深色／跟随系统、主题色、系统配色、配色风格、纯黑背景、玻璃效果等级、字号和减少动画。主题设置在本机保存，不依赖 Agent 服务或浏览器。

界面引入了固定版本的液态玻璃、字体、形状、配色与页面过渡组件。App 保留原版 Web 前端作为可选入口。产品要求首次安装关闭 Web，由 App 控制开启；启用 Web 不应创建另一套 Agent 运行时。

App 与 Web 共用核心会话控制器。原生配置表单与高级编辑器保护凭据并检查并发修改。账号授权、完整管理能力、导入导出和完整真机验收矩阵尚未完成。Root、设备 ADB 控制和离线模型推理不在当前预览范围。APK 构建成功不代表这些操作已经通过手机验证。

<a id="run"></a>

<a id="run-from-source"></a>

<a id="development-guide"></a>
## 开发

Android 应用与打包说明位于 [apps/android](apps/android/README.zh.md)。现有 Agent 核心位于 `packages/`；架构与仓库约定位于 [docs/architecture.md](docs/architecture.zh.md) 和 [AGENTS.md](AGENTS.md)。

构建产物、API Key、凭据、设备截图和个人会话不进入版本控制。预览 APK 使用开发签名，不是正式生产发布。

<a id="license-info"></a>
## 许可证

Android 应用按 [GPL-3.0](apps/android/LICENSE) 分发。组件源码版本与许可证记录在 [Android 组件清单](apps/android/licenses/flclash-source.json) 中。导入的核心保留 [MIT 许可证](LICENSE)；其他依赖条款见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
