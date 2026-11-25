# prism_ui (vendored)

FlClash's UI library, copied from `https://github.com/chen08209/prism_ui` at the
revision FlClash v0.9.4 pins (`6c47901`), and depended on by this app through
`path: packages/prism_ui`.

`licenses/prism-source.json` records the revision, the seed components, the
resolved file list and a tree hash. `LICENSE` and `NOTICE` come from upstream;
the library is GPL-3.0-only and its NOTICE lists the Apache-2.0 and MIT parts.

## What is vendored

Only the transitive closure of the components this app uses: seeds plus every
`package:prism_ui/`, relative and `part` file they reach. Files outside that
closure are absent, so the package is not a complete copy of upstream.

The `pubspec.yaml` here keeps upstream's name (the glass shader is loaded as
`packages/prism_ui/shaders/liquid_glass.frag`, which needs that package name),
sets `publish_to: none`, and depends only on what the closure imports.

## Refreshing

1. Check which revision the FlClash release we track pins:
   `git ls-tree <flclash-tag> -- plugins/prism_ui`.
2. Check out that revision of prism_ui.
3. Re-copy the closure of the seeds above (imports, relative imports/exports and
   `part` files), both shaders, `LICENSE` and `NOTICE`.
4. Regenerate `licenses/prism-source.json` (file list and tree hash) and update
   the `prismUi` entry in `tool/runtime-lock.json`.
5. Run `flutter analyze` and `flutter test test/prism_package_test.dart`.
