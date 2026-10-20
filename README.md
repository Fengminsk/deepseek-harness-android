# DSH for Android · 安卓版 DSH

English | [中文](README.zh.md)

## Summary

DSH for Android is an Android adaptation of DeepSeek Harness for a personal agent on a rooted phone. The product goal is to connect conversations with local shell commands, root execution, files, and ADB device operations.

This repository is at the initialization stage. It contains the existing Node.js/TypeScript harness; it does not yet contain an Android application, an APK, or verified Android root and ADB integration.

## Table of Contents

- [Repository](#repository-home)
- [Development](#development-guide)
- [License](#license-info)
- [Dev Note: Android product brief](#android-product-brief)

<a id="repository-home"></a>

## Repository

The primary repository is [DSH for Android on Gitee](https://gitee.com/minnnng/deepseek-harness-android). The `android` branch owns Android development; `master` retains the imported baseline. The local `origin` remote points to Gitee, and `github` retains the source repository for comparison and fetching updates.

The README describes the Android product. Existing package names and runtime versions still belong to the imported harness and do not identify an Android release.

<a id="run"></a>

<a id="run-from-source"></a>

<a id="development-guide"></a>

## Development

The repository currently contains the following development areas:

| Path | Purpose |
| --- | --- |
| `apps/` | Existing CLI, Web, and desktop applications |
| `packages/` | Agent runtime, model access, sessions, shell execution, and other plugins |
| `native/` | Native runtime support |
| `docs/` | Runtime architecture and development documentation |

Read the [development guide](docs/development.md), [architecture](docs/architecture.md), and [repository instructions](AGENTS.md) when working on the existing harness. These documents describe the existing runtime, not an Android installation procedure.

Android runtime packaging, background execution, and the native command bridge require implementation and device validation before an APK can be offered. No Android build or installation command is available in this branch yet.

<a id="license-info"></a>

## License

The imported harness retains its [MIT license](LICENSE). Existing dependency terms are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

No FlClash source has been copied into this branch. Its [GPL-3.0 license](https://github.com/chen08209/FlClash/blob/main/LICENSE) must be accounted for before incorporating its components and distributing the Android application; the current MIT license does not cover that future integration.

<a id="android-product-brief"></a>

## Dev Note: Android product brief

The following is the development brief, not a list of implemented or device-tested features.

### Local agent and devices

- Run the agent and its tool execution on the phone. Local execution does not imply offline model inference; model API access remains a separate configuration.
- Support ordinary shell and root commands through a native bridge, with command output, exit status, cancellation, and a persistent execution history.
- Support ADB operations on explicitly selected, connected, and authorized devices. USB and wireless transport compatibility must be verified on real hardware; root access on the host phone does not grant access to every target device.
- Keep workspaces, conversations, and file operations accessible from the application. Keep credentials, signing keys, ADB private keys, and personal session data out of Git.

### Interface and navigation

- Use Flutter as the intended Android UI foundation. Evaluate the latest released [FlClash](https://github.com/chen08209/FlClash) design and reusable components before implementation, then pin the selected source version and record any imported components and their licenses.
- Use conversations as the main entry point, with a history sidebar, new conversation action, a persistent composer, streaming replies, and visible tool execution results, following the familiar ChatGPT mobile interaction pattern.
- Provide dedicated pages for workspaces and files, device connections, and settings. Settings cover models, API access, appearance, and execution permissions.
- Keep execution target and privilege level visible so that phone-local shell, phone-local root, and a selected ADB device are distinguishable.

### First Android milestone

The first device-tested milestone is one complete flow: open a conversation, select a model and execution target, run a local command, display its output and exit status, and reopen the saved conversation. Root execution and authorized ADB connections follow with their own device checks.
