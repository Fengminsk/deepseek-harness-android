# Pocket Harness

English | [中文](README.zh.md)

## Summary

Pocket Harness brings an on-device Agent to Android, with conversations, authorized files, ordinary shell commands and an optional original Web interface. Model inference uses a configured online API; the phone does not need root, Termux or a computer to host the packaged runtime.

This branch contains a development preview, not the completed Android migration. The Flutter interface and theme settings are available; runtime integration, complete native management pages and joint App/Web acceptance remain in progress.

## Table of Contents

- [Repository](#repository-home)
- [Current preview](#current-preview)
- [Development](#development-guide)
- [License](#license-info)

<a id="repository-home"></a>
## Repository

The primary repository is [Pocket Harness on Gitee](https://gitee.com/minnnng/deepseek-harness-android), on the `android` branch. Internal DSH package names and the Android application ID remain stable across the product rename.

<a id="current-preview"></a>
## Current preview

The App provides a conversation home, history sidebar, file browser, model credential form, advanced configuration editor, Web access controls and diagnostics. **Settings → Appearance and theme** independently controls light/dark/system mode, theme color, system colors, color style, pure black backgrounds, glass quality, text size and reduced motion. Theme choices are stored locally and do not require the Agent service or a browser.

The interface incorporates pinned liquid glass, typography, shape, color and page transition components. The App retains the original Web frontend as an optional interface. The product requires Web access to be off on first installation and controlled from the App; enabling Web must not create a second Agent runtime.

App and Web share the core session controller. Native schema forms and the advanced editor preserve credentials and detect concurrent edits. Account authorization, complete management coverage, import/export and the full device acceptance matrix remain unfinished. Root, device ADB control and offline model inference are outside this preview. Do not treat a successful APK build as evidence that these operations have passed on a phone.

<a id="run"></a>

<a id="run-from-source"></a>

<a id="development-guide"></a>
## Development

The Android application and its packaging instructions are in [apps/android](apps/android/README.md). The existing Agent core remains under `packages/`; the architecture and repository rules are in [docs/architecture.md](docs/architecture.md) and [AGENTS.md](AGENTS.md).

Build outputs, API keys, credentials, device screenshots and personal sessions stay outside version control. Preview APKs use the development signing key and are not production releases.

<a id="license-info"></a>
## License

The Android application is distributed under [GPL-3.0](apps/android/LICENSE). Component source versions and license files are recorded in [the Android component manifest](apps/android/licenses/flclash-source.json). The imported core retains its [MIT license](LICENSE); other dependency terms remain in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
