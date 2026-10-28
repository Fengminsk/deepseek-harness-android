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

All 151 optional-bundle declarations have a recorded assessment; none remains `unassessed`. Their execution evidence remains `unverified` unless separately recorded. Reading configuration proves neither plugin activation nor a successful model call. The 14 `not-migrated` rows comprise eight original Node PTC/workflow declarations, three Bash declarations, native localization and two Office-authoring/dependency declarations; repeated declarations are not distinct missing user features. `core`, `ui`, `behavior` and `device` remain independent evidence claims, and file existence never changes them.

Declaration digests detect changed rows. `reviewInputs` additionally pins LF-normalized SHA-256 values for the Android bootstrap, host protection, runtime registration, Android patch, preset staging and Web patch. Changes in these files require a fresh composition review, including enable/disable and model-registration changes that the original declaration-only inventory did not cover. After review, update affected mappings, notes and hashes together; never refresh hashes merely to make the audit pass.

Installed Build 118 retains [reviewed PTC](model-ptc-readonly.md), [offline Linux with workspace transfer](linux-vm-runtime.md) and [workflow with reviewed child tools](tool-native-workflow.md). PTC composes reviewed live parent tools; workflow children inherit only their reviewed subset. Original Node PTC/workflow plugins and Linux network admission remain disabled. Scoped lifecycle checks and the [Build 116 r28 shipped-profile result](production-profile-device.md#build-116-r28) cover the documented execution paths, including a workflow child. [Real-account evidence](agent-service-task-device.md) separately covers r33 echo, r34 one pending Linux call across radio loss/restoration and r35 completion-notice posting. The [transport fixture](model-transport-recovery-device.md) verifies same-turn retry after SSE reset; the radio case recorded no model retry.

Ordinary upgrades through Build 118 retained the recorded Session bytes and SAF grants. The 117→118 r40 check retained 55 Session files totaling 1,573,622 bytes, three SAF grants and a synthetic credential; `.cache/android/upgrade-117-118-r40-20261028.log` records it. These results do not certify sign-in UI, older-conversation resumption or every later artifact. The first r28 startup timeout, r25 workflow hang and r32 process freeze remain unexplained. [Scheduled wake-up](schedule-wakeup.md) is implemented with default-off settings, exact-alarm permission and a generation-bound runtime projection; natural alarm delivery, permission changes, reboot restoration and long Doze behavior still lack device acceptance. No declaration classification or evidence level is promoted by this review.

Build 118 routes App text reads and `android_files.read` through one [request owner](../runtime/document-reads.mjs). Native `prepare/run/cancel` binds the authorized root; Binder supplies App ownership and tools supply Session/call ownership. Disconnect and runtime unload cancel those requests. The admission slot remains held until both the reader and provider-cleanup work stop. The [r40 device check](file-tool-parity.md#build-118-device-evidence) verified native text-read concurrency, cancellation, late-result rejection and owner closure using a controlled provider with a separate Android UID. It does not certify arbitrary providers, the user's file-opening UI or an earlier crash's root cause.

Build 118 r40 also passed one real `deepseek-account/deepseek-flash` submission through production AgentService: exactly one `android_ptc` call, one audited `list_agents` callback, a completed turn and matching live/durable final marker. Session archive, export release and process retirement were confirmed; 28 screen samples showed both panels Off. The result is `.cache/android/real-account-ptc-118-r40-20261028.json.result.json`. The separate `.cache/android/real-account-workflow-118-r40-20261028.json.result.json` remains failed: parent and child completed with `requiresReview=false`, but the fixture's ordinary-Session archive request for the child returned `DOMAIN_FAILED`. That failed attempt is retained independently of later results.

On the byte-identical production App, r41 corrected only the fixture cleanup API. `.cache/android/cleanup-workflow-r40-under-r41-20261028.json.result.json` confirms zero new submissions and archive of only the old dedicated child. A new complete `.cache/android/real-account-workflow-118-r41-20261028.json.result.json` passed: one real-account workflow, one child with zero tool calls, completed parent/child durable marker records, `requiresReview=false`, both Sessions archived, export released and disconnection confirmed. The outer report records six samples with both panels Off and confirmed process retirement. Only the AndroidTest APK changed, to SHA-256 `e1f3a40069d15758d51e6312b688f458f97b8835c2394dc4f7bb4cf84fbef50c`; this is no production workflow bug-fix claim or full upstream-semantic acceptance.

## Review commands

Run the inventory audit, grouped remaining-work report and focused tests from the repository root:

```powershell
node apps/android/tool/parity-audit.mjs
node apps/android/tool/parity-audit.mjs --capabilities
node --test apps/android/tool/parity-audit.test.mjs
```

The report prints declaration counts, migration classifications, evidence counts and capability groups. None is a completed-user-feature count. Failed input digests identify the source to re-read; unknown declarations or invalid related keys require a mapping review rather than removal from the ledger.

## Delivery priorities

Use `--capabilities` for the grouped work. Prioritize natural scheduled wake-up without a test-held foreground or CPU lease, then explicit Linux HTTPS approval and route evidence before enabling that model option. The existing Linux network fixture requires an interactive foreground window and cannot run under the current uninterrupted-screen-Off constraint without adaptation. Keep Office authoring/runtime dependencies, remaining terminal VT/OSC behavior and native document/UI acceptance separate from the delivered execution subset. Full original PTC/workflow semantics remain incomplete. Device operations must be serialized against one identified APK; no current success resolves the unexplained startup/freezer observations.

## Dev Note

This review records scoped evidence and does not authorize changing a runtime release control.
