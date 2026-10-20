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

The foreground service owns one Node instance in a private Android process. Flutter uses Binder and JSON-RPC over a dedicated local socket pair; it does not use a localhost HTTP server. Standard output and error go to the private runtime log, independently of the protocol socket. Large Binder responses use read-only shared memory. The packaged runtime launches through the named `android` dsh profile and stores its workspace and sessions in app-private storage. API credentials use Android Keystore-backed encryption; authorized document trees use persisted Storage Access Framework grants.

Web preferences are separate from browser-editable runtime settings. The App controls the listener, scope and port; network callbacks select an explicit Wi-Fi/Ethernet IPv4 address, and an unavailable LAN address produces a waiting state. Credential rotation keeps the Agent context intact. These lifecycle paths remain subject to joint App/Web device tests.

The Android Shell tool requests approval for each command through the original DSH tool pipeline. Only `allowed-once` permits execution; rejection, cancellation and the `never` approval policy do not. Commands run with the application's existing UID and Android permissions, without a read-only or workspace-only OS sandbox. This per-command policy belongs to the Android tool and does not describe the desktop default. Root, ADB control, boot autostart and offline model inference are not implemented.

**Approvals and questions** and Android notifications present the same pending DSH requests as Web. Approval buttons send the existing `allowed-once` and `rejected` outcomes. Simple questions can use notification options or direct text replies; complex questions open the matching App page. The original question controller owns waiting, continuation and cancellation. Notification transport tokens do not grant additional permissions. Old or already answered notifications cannot reply again, and an unconfirmed submission keeps its draft without automatic replay. The App exposes system notification permission and channel settings.

**Background tasks** shows running Agent sessions, pending interaction links and an explicit stop action. A successful cancellation request remains shown as stopping until the core reports idle. The subprocess page follows the original job catalog and byte-cursor output stream, with bounded output retention and explicit stop requests. Leaving either page does not cancel work; Android can still stop the process.

**Automations** uses the original schedule catalog, task edits, deletion and delivery history. The App filters tasks, edits active tasks' names, prompts and timing rules, and links back to their conversations. Creation opens a conversation for the Agent's existing scheduling tools; the App does not add pause or run-now operations. Edits compare the original task record and retain the draft on conflict or an unconfirmed result. Delivery history records reminders reaching a conversation, not completed model work.

**The chat plus menu** follows DSH's Add and Commands groups and the runtime's actual command catalog. Android currently disables desktop sandbox permission presets; no substitute permission menu is fabricated. Session creation, files and non-model commands work before credentials are configured. Files use the system document picker and original session-scoped upload receipts; failed uploads retain the selected files for retry. Images are not yet enabled in this preview. Commands execute through the original command service. ZIP export uses the original session-log format and a system save picker.

**Authorized files** supports single documents, folders, paged UTF-8 reads and grant revocation. The App and Agent share literal text search within persisted SAF grants, with optional case sensitivity and bounded reading, traversal and execution time. Results identify skipped files and incomplete searches; an empty partial result does not establish that no match exists. Cancellation waits for the native search to settle. Document authorization does not turn a `content://` URI into a Shell path.

**Tool activity cards** pair calls and results within their original turn and step, including nested PTC calls. They distinguish missing results, failures and interruptions without treating Agent idle as a tool result. Shell cards show recorded commands, stdout, stderr, exit codes and timeout status; file cards show paths and readable results. Unknown tools retain complete raw details, loaded on expansion. Expanded cards keep their state as results arrive.

**Session models** distinguishes the current selection from an unapplied draft, with explicit selection marks and model-specific reasoning options. A blank conversation inherits the original catalog default; an unavailable saved route remains visible. The App initializes the conversation before editing, observes the original model projection, checks for changes before applying and reads back the service's normalized result. Errors retain the draft and require verification before replaying an uncertain write. The original `selectModel` API has no atomic compare-and-set operation: these checks detect observed conflicts but cannot prevent every competing write between checking and applying.

**Account and configuration** pages use the original account and model services. Sign-in opens the official authorization page in an Android Custom Tab; its temporary loopback listener only serves the authorization callback and does not enable Web. The completion page's `dsh://open` link returns to the native account page without credentials or a login-state change; the original account service confirms login. Successful login invokes the original default-model initialization rules; an initialization failure preserves the signed-in account and offers a separate retry. Profile, balance and notices load independently. Model/provider credentials and defaults have native editors. Asynchronous model failures remain visible in the matching conversation after reconnecting. Plugin management reads the real inventory and operation receipts, but online installation remains unavailable because the packaged Android runtime does not include pnpm.

**Diagnostics** distinguishes service startup or failure from an unconfirmed account state. Active subscription diagnostics expose only the interface name, delivery stage and received sequence; they exclude request parameters, response contents and transport identifiers. Copying or refreshing these observations does not retry business operations. The page can explicitly restart the service process; the UI waits for the actual ready event before reporting recovery.

<a id="interface"></a>
## Interface and themes

The conversation home, sidebar and settings use native Flutter pages. **Appearance and theme** stores display mode, palette, color style, pure black mode, glass quality, text scaling and reduced motion in Android preferences independently of the Agent process. System reduced-motion settings take precedence. Headers and the conversation composer float above a full-height scroll viewport; content insets make the first and last items reachable without cutting off the viewport. Pages compose the imported FlClash components through `lib/ui.dart`; Material primitives are only used with the shared component styles.

Actual glass shaders, backdrop sampling, elastic press/drag springs, grouped buttons, segmented controls, switches, dashboard cards, filled inputs, superellipse shapes, typography, color generation and page motion are adapted from the revision in [licenses/flclash-source.json](licenses/flclash-source.json). The chat plus menu uses the imported FlClash popup's anchor expansion and press-hold-drag selection: releasing over an item selects it, while cancellation performs no action. The App is covered by [LICENSE](LICENSE); dependency license files are retained under `licenses/`. Internal package names and the application ID do not change with the Pocket Harness display name.

<a id="verification"></a>
## Verification limits

Flutter tests cover retained drafts, themes, floating controls, popup drag selection, accessibility sizing, tool pairing, automation edits and model-selection recovery. Host tests exercise original scheduling operations, Shell approval outcomes and the shared file-search lifecycle. The host smoke drives the real Agent through a local model stub, an Android tool response and a second model step; closing Web during that step leaves the task running. It also checks browser authentication, connection closure and credential rotation. These checks do not establish a real provider/tool round trip on Android.

The embedded runtime, official account authorization and profile/balance reads have run on an ARM64 Android device with Web disabled. Local Web authentication and stopping its listener have also been checked on that device. The device document picker reaches the upload step. Fixing inaccessible-parent directory synchronization exposed a second persistence failure: the device denies hard-link creation in app-private storage. Attachment upload remains under repair. The return link and account default-model initialization have passed device checks with the dedicated protocol socket. Popup opening, closing and press-drag selection, and switching Flash to Pro and back with page re-entry, have passed device checks. Automation, tool-card, SAF-search and Shell-approval changes still await device acceptance. Pending-account recovery paths, lock-screen actions, service recovery and detached-USB behavior also require phone acceptance. Complete management coverage and configuration import/export remain unfinished; complex configuration still uses JSON input. Device screenshots, diagnostic logs, personal sessions and generated APKs are local-only artifacts, excluded from Git.
