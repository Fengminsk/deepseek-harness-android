# Android migration ledger review

English | [中文](parity-review.zh.md)

## Summary

Use the [migration ledger](parity-manifest.json) to locate remaining Android work by user capability and trace it to the original declarations. A passing audit establishes reviewed inventory coverage. It does not establish runtime behavior, device acceptance or completion of the Android release.

## Contents

- Classification
- Composition and evidence
- Review commands
- Delivery priorities

## Classification

Every declaration belongs to one capability group. Repeated services in different profiles keep separate declaration identities and share a capability group. The group's `remaining` field owns its outstanding delivery and acceptance work. Linux guest delivery has a group even though these upstream patch declarations do not describe it.

| Classification | Meaning |
| --- | --- |
| `unassessed` | No source review is recorded. |
| `partial` | An Android composition or native mapping is identified; equivalence remains incomplete or unverified. |
| `adapted` | An Android-specific adaptation is recorded; the separate evidence levels still determine its acceptance limits. |
| `not-migrated` | A required capability has no equivalent Android entrypoint, or its usable entrypoint remains disabled. |
| `upstream-disabled` | The reviewed upstream declaration already disables the feature. |
| `not-applicable` | A stated launch or platform contract does not apply to the Android native entrypoint. An explicit exclusion reason is required; related shared capabilities remain open independently. |

Alternative headless, SDK and ACP configurations are not additional missing native screens. Their shared services link to the relevant base or preset declaration. SDK office authoring and workspace dependencies remain delivery gaps because excluding the stdio launcher does not supply those capabilities. Windows PowerShell and browser development hot reload have explicit platform exclusions; Android process confinement and production upgrades retain their own requirements.

## Composition and evidence

The [Android host configuration](../runtime/host-guard.mjs) selects base, Web and Android bundle layers in that order. Web disables several host tool rows; [preset staging](stage-preset.mjs) composes portable tools and policies under the Android Agent. The optional-bundle `assessment` records inheritance, later configuration, preset composition, replacement, disabling or an unselected alternative profile. It also names the entrypoint category and related declarations.

All newly assessed optional-bundle execution evidence stays `unverified`. Reading configuration proves neither plugin activation nor a successful model call. `core`, `ui`, `behavior` and `device` remain independent manual evidence claims, and file existence never changes them. A host test cannot discharge a device requirement.

Declaration digests detect changed rows. `reviewInputs` additionally pins LF-normalized SHA-256 values for the Android bootstrap, host protection, runtime registration, Android patch, preset staging and Web patch. Changes in these files require a fresh composition review, including enable/disable and model-registration changes that the original declaration-only inventory did not cover. After review, update affected mappings, notes and hashes together; never refresh hashes merely to make the audit pass.

The current composition wires three separate capabilities behind closed source controls: [read-only PTC](model-ptc-readonly.md), [model-only workflow](tool-native-workflow.md) and [Linux execution with workspace import](linux-vm-runtime.md). They are not interchangeable: PTC invokes the reviewed live tools, workflow children analyze supplied text, and Linux runs guest shell commands without direct phone-file or network access. Their new source mappings retain the outstanding production device requirements in the ledger. Ordinary Node PTC plugins remain disabled by host protection.

## Review commands

Run the inventory audit, grouped remaining-work report and focused tests from the repository root:

```powershell
node apps/android/tool/parity-audit.mjs
node apps/android/tool/parity-audit.mjs --capabilities
node --test apps/android/tool/parity-audit.test.mjs
```

The report prints declaration counts, migration classifications, evidence counts and capability groups. None is a completed-user-feature count. Failed input digests identify the source to re-read; unknown declarations or invalid related keys require a mapping review rather than removal from the ledger.

## Delivery priorities

Use `--capabilities` for the current grouped work. Programmatic tools, workflows and the Linux guest require usable model entrypoints plus isolation and lifecycle acceptance. Files require real model calls, retained and revoked grants, and safe bounded reads. Background tasks and history require lock-screen, network-loss, process-death and ordinary-upgrade evidence. These areas can be developed independently, but installation and foreground device acceptance must be serialized against one identified APK.

## Dev Note

This review adds no device observations and does not authorize changing a runtime release control.
