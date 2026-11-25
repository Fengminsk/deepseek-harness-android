# Adopt prism_ui at FlClash v0.9.4's pin

## Decision

Track FlClash's UI library from `chen08209/prism_ui` at `6c47901` (the revision FlClash v0.9.4 pins), vendored as a local package at `apps/android/packages/prism_ui`. Migrate the app off the adapted copies in `apps/android/lib/flclash`, which came from FlClash v0.9.2's `lib/ui`.

## Why

- FlClash v0.9.3 moved `lib/ui` out of its repository into a submodule, `plugins/prism_ui` (repository `chen08209/prism_ui`); v0.9.4 pins `6c47901`. The tree we adapted from no longer exists upstream.
- FlClash v0.9.4 dropped `material_ui` and `material_new_shapes`; the only UI dependency left is `prism_ui` via `path: plugins/prism_ui`. Tracking "the v0.9.4 set" therefore means adopting prism_ui, not another copy of `lib/ui`.
- prism_ui is now a design system rather than a bag of widgets: it defines its own `ColorScheme`, `Theme`, `ThemeData`, `VisualDensity` and `TapTargetSize`, and imports no `package:flutter/material.dart`.
- The release equivalent of the pinned commit is prism_ui 0.1.3 on pub.dev; the files in our closure are identical between the two, and the pinned commit's pubspec declares 0.1.2.

## Landed

- `apps/android/packages/prism_ui` holds the 94-file transitive closure (77 libraries and 17 part files) plus both shaders, `LICENSE` and `NOTICE`; it analyzes clean under the app's rules.
- The package keeps the upstream package name, so the glass shader loads as `packages/prism_ui/shaders/liquid_glass.frag`. `test/prism_package_test.dart` loads that shader and builds `LiquidGlass` inside a prism `Theme`.
- Provenance: `licenses/prism-source.json` records revision, seeds, file list and tree hash; `tool/runtime-lock.json` describes both sources (`flclash` corrected to the v0.9.2 revision actually in use, plus `prismUi`). Refresh steps live in `packages/prism_ui/README.md`.
- Consumers moved so far: `PocketSwitch` draws prism_ui's `Switch` at the same 52 x 32 track; `popup.dart` and `segmented_control.dart` import prism_ui's `motion.dart` and `goo.dart`, whose helpers match the adapted copies; `FloatingHeader` comes from prism_ui's `sheet_header.dart`; the app-owned glass context adapter moved to `lib/design_context.dart`. `lib/flclash` is down to 16 files from 20, with the header file reduced to the bottom-capable scrim.
- Verification loop for the visual migrations: a debug APK builds with `ANDROID_HOME` and `GRADLE_USER_HOME` set (see `tool/runtime-lock.json` for the SDK expectations) and installs on a device. Screenshots need the phone unlocked — the capture is black while the notification shade holds focus.
- `test/ui_glass_capture_test.dart` writes light and dark glass previews when `POCKET_CAPTURE_DIR` is set. Widget tests render Skia, so `LiquidGlass` falls back to its frost rather than running the shader: these previews check layout, tint and geometry, not the shader image.
- The glass migration itself is blocked on theming: prism's `liquid_glass.dart` builds styles from prism's own `ColorScheme`, while our call sites pass `material_ui`'s. Moving glass means moving the widgets that build its styles onto the bridged prism scheme first.

## Integration facts

- prism widgets resolve colors through prism's own `Theme`; without an ancestor they fall back to a default scheme, so they render but with the wrong palette.
- The app still depends on `material_ui: 1.7.0`. A bridge is required: map the app's `material_ui` `ColorScheme` into prism's `ColorScheme` and wrap prism subtrees in prism's `Theme`.
- Both copies of `liquid_glass.frag` bundle (the app's at `shaders/`, the package's at `packages/prism_ui/shaders/`) until `lib/flclash` is removed.

## Adaptation carry-over

The v0.9.2 adoption recorded 16 local changes in `licenses/flclash-source.json`. Against prism 0.1.3:

| Local adaptation | Upstream now | Action |
| --- | --- | --- |
| Motion adapter reading this app's accessibility settings | `context.disableAnimations` from `MediaQuery` | Drop; rely on the platform setting |
| Drag-back restores previous focus | `_refocusAfterDragBack` in `drag_back.dart` | Drop |
| Reduced motion in presses and segmented controls | Present in `context.disableAnimations` consumers | Re-check per call site |
| Segmented drag previews, keyboard and semantic actions | Absent | Keep as a DSH wrapper or patch |
| Round controls stay circular under drag; capsules stretch | Absent | Keep |
| Floating header scrim on a bottom edge | Absent | Keep |
| Analytic corner renderer for long panels | `LiquidGlass` takes `borderRadius`; verify | Re-evaluate against the package |
| Popup glyphs, labels and in-place retry rows | App-level content | Keep at call sites |
| Daylight micrograin, directional highlights, softer saturation | App-level look | Keep in the DSH layer |
| Regular glass dark tint alpha and card-lifted tint | `LiquidGlassStyle` exposes `tint`, `contrast`, `saturation`, `rim*` | Express as a style preset |
| Goo geometry only extracted | Package ships `GooSurface` | Re-evaluate |
| Dart 3.13 initializing formals, package imports, app-state removal | Vendoring artifacts | Disappear with the package |

## Phases

1. **Bridge.** Map `material_ui` colors into prism's `ColorScheme`, add a scope widget that installs prism's `Theme`, and test that a prism widget inside it uses the app's palette.
2. **First consumers.** Replace the menus and controls already built on the popup and button copies (`composer_commands.dart`, `chat_message_actions.dart`, `files.dart`, `workspace_files.dart`, `network_proxy_settings.dart`) with the package's widgets.
3. **Glass.** Move `LiquidGlass`, `LiquidGlassCapture`, `SurfaceScope` and `Surface` to the package with a style preset that keeps the current look; compare screenshots against the `.cache/ui-*` baselines.
4. **Routes.** Replace `SharedXPageTransition`/`SharedXPageRouteMixin` with `CardRouteMixin`/`HomeRoute`, including the drag-back integration and the route class in `lib/ui.dart`.
5. **Retire.** Delete `lib/flclash`, drop `flclash-source.json` and the `flclash` lock entry, and update the Android READMEs.

## Verification per phase

`flutter analyze` (currently 11 pre-existing infos, no errors), `flutter test test/prism_package_test.dart`, the widget tests that cover each touched page, and a screenshot comparison for the glass and daylight work.

## Risks

- Visual drift where the daylight look relied on patched internals.
- Two theme systems in one tree until `material_ui` is dropped; prism's `Theme` and Material's must nest correctly.
- Popup and drag behaviour are DSH-specific and interact with the package's gesture handling.
- The closure is hand-resolved; a new consumer may pull a file we did not vendor, which fails at analysis time.
