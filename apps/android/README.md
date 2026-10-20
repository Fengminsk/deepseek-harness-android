# Pocket Harness for Android

English | [中文](README.zh.md)

## Summary

This directory contains the Flutter App, a Kotlin foreground service and an embedded ARM64 Node runtime. The current artifact is a development preview for Android 9 or newer; runtime and App/Web integration still require device acceptance.

## Table of Contents

- [Build the preview](#build)
- [Runtime and storage](#runtime)
- [Interface and themes](#interface)
- [Verification limits](#verification)

<a id="build"></a>
## Build the preview

Use PowerShell 7 on Windows with Node 24, the repository's pnpm version, JDK 17, Android SDK 36, NDK 28.2.13676358 and CMake 3.22.1. Flutter and native dependency versions are pinned in [tool/runtime-lock.json](tool/runtime-lock.json). Place the pinned Flutter checkout in the repository's ignored `.cache/flutter` directory and configure the Android SDK before continuing.

Run the following from the repository root after `pnpm install`. The deploy command creates a new staging directory; retain that directory for subsequent App-only builds. Recreate it from a fresh deployment when the dependency lock changes. The following install restores workspace development dependencies after pnpm deploy.

```powershell
pnpm.cmd run build:artifacts
pnpm.cmd --filter dsh-python-runtime-closure deploy --legacy --prod --config.allow-unused-patches=true --config.node-linker=hoisted --config.auto-install-peers=false --config.link-workspace-packages=true --config.hoist-workspace-packages=false .cache/android/runtime-bundle
pnpm.cmd install --offline --frozen-lockfile --prod=false --ignore-scripts
node node_modules/tsx/dist/cli.mjs apps/android/tool/stage-runtime.ts
./apps/android/tool/prepare-native.ps1
node apps/android/tool/smoke-runtime.mjs
./apps/android/tool/pack-runtime.ps1
```

The native preparation script uses `http://127.0.0.1:7897` by default; supply `-Proxy` to select a different proxy. It verifies the Node archive checksum and the source revision used for the Android require-builtin addon. The staging smoke runs on the host and does not establish Android compatibility.

Run these commands from `apps/android`. The APK is written to `build/app/outputs/flutter-apk/app-debug.apk`; it uses the development signing key. Configure Gradle's HTTP/HTTPS proxy if the local network requires one.

```powershell
../../.cache/flutter/bin/flutter.bat pub get
../../.cache/flutter/bin/flutter.bat analyze --no-pub
../../.cache/flutter/bin/flutter.bat test --no-pub
../../.cache/flutter/bin/flutter.bat build apk --debug --target-platform android-arm64 --no-pub
```

<a id="runtime"></a>
## Runtime and storage

The foreground service owns one Node instance in a private Android process. Flutter uses Binder and JSON-RPC over a local socket pair; it does not use a localhost HTTP server. Large Binder responses use read-only shared memory. The packaged runtime launches through the named `android` dsh profile and stores its workspace and sessions in app-private storage. API credentials use Android Keystore-backed encryption; authorized document trees use persisted Storage Access Framework grants.

Web preferences are separate from browser-editable runtime settings. The App controls the listener, scope and port; network callbacks select an explicit Wi-Fi/Ethernet IPv4 address, and an unavailable LAN address produces a waiting state. Credential rotation keeps the Agent context intact. These lifecycle paths remain subject to joint App/Web device tests.

Shell commands run with the application's existing UID and Android permissions. This is not a per-command read-only or workspace-only sandbox. Root, ADB control, boot autostart and offline model inference are not implemented.

**Approvals and questions** and Android notifications present the same pending DSH requests as Web. Approval buttons send the existing `allowed-once` and `rejected` outcomes. Simple questions can use notification options or direct text replies; complex questions open the matching App page. The original question controller owns waiting, continuation and cancellation. Notification transport tokens do not grant additional permissions. Old or already answered notifications cannot reply again, and an unconfirmed submission keeps its draft without automatic replay. The App exposes system notification permission and channel settings.

**Background tasks** shows running Agent sessions, pending interaction links and an explicit stop action. A successful cancellation request remains shown as stopping until the core reports idle. This page does not yet manage the separate DSH subprocess job catalog. Leaving the page does not cancel work; Android can still stop the process.

<a id="interface"></a>
## Interface and themes

The conversation home, sidebar and settings use native Flutter pages. **Appearance and theme** stores display mode, palette, color style, pure black mode, glass quality, text scaling and reduced motion in Android preferences independently of the Agent process. System reduced-motion settings take precedence. Headers and the conversation composer float above a full-height scroll viewport; content insets make the first and last items reachable without cutting off the viewport. Pages compose the imported FlClash components through `lib/ui.dart`; Material primitives are only used with the shared component styles.

Actual glass shaders, backdrop sampling, elastic press/drag springs, grouped buttons, segmented controls, switches, dashboard cards, filled inputs, superellipse shapes, typography, color generation and page motion are adapted from the revision in [licenses/flclash-source.json](licenses/flclash-source.json). The App is covered by [LICENSE](LICENSE); dependency license files are retained under `licenses/`. Internal package names and the application ID do not change with the Pocket Harness display name.

<a id="verification"></a>
## Verification limits

The focused Flutter tests cover retained message drafts, saved message rendering, theme persistence, failed theme saves, theme controls without an Agent service, press/drag/release and cancellation, reduced motion, full-height scrolling behind floating controls, keyboard insets, enlarged text, credential-preserving configuration edits and concurrent-edit conflicts. The host smoke drives the real Agent through a local model stub, an Android tool response and a second model step; closing Web during that step leaves the task running. It also checks browser authentication, connection closure and credential rotation. These checks do not establish a real provider/tool round trip on Android.

The embedded runtime has started on an ARM64 Android device. Notification code compiles, and host tests cover original DSH approvals/questions, competing Web/App answers, cancellation, timed continuation, stale notification tokens and retained drafts. Lock-screen actions, direct replies and notification permissions still require device testing. Account authorization, complete management coverage, import/export, service recovery and detached-USB acceptance remain unfinished. Schema-driven forms and the advanced editor are available inside the App; complex configuration still uses JSON input. Device screenshots, diagnostic logs, personal sessions and generated APKs are local-only artifacts, excluded from Git.
