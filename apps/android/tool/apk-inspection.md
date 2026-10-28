# Built-in APK inspection

English | [中文](apk-inspection.zh.md)

## Summary

The Android App inspects uploaded APK structure through `android_attachments` with `action="inspect_apk"`. It reads Manifest declarations, DEX metadata and native-library metadata without Linux, shell commands or code execution. Each request uses a file already referenced by the current Agent session and checks attachment integrity before returning entry contents. The result describes selected structures, not a signature verification, decompilation or packing verdict.

## Table of Contents

- [Requests and results](#requests-and-results)
- [Pagination](#pagination)
- [Limits and integrity](#limits-and-integrity)
- [Failures and interpretation](#failures-and-interpretation)
- [Validation](#validation)
- [Dev Note](#dev-note)

-----

## Requests and results
<a id="requests-and-results"></a>

Call `android_attachments` with `action="list"` first. Reuse its exact `attachmentId` and `name` in an `inspect_apk` request. A caller cannot select another session or an App-private path. The [attachment tool](../runtime/tool-android-attachments.mjs) retains the existing ToolRuntime permission checks.

| `part` | Selected information | Default `limit` | Maximum `limit` |
| --- | --- | --- | --- |
| `summary` (default) | ZIP directory counts and parsed Manifest declarations | 16 | 100 |
| `manifest` | Manifest package, version, SDK, permissions, components and application flags | 16 | 100 |
| `dex` | Root `classes*.dex` entries: headers, tables and bounded descriptor/string samples | 1 | 4 |
| `native` | `lib/<ABI>/*.so` entries: ELF architecture, dependencies and bounded symbol samples | 1 | 4 |

`summary` does not inspect every DEX or library. Request those parts separately. `contains` is a literal entry-name filter for `dex` and `native`; it does not filter Manifest declarations. Do not supply `encoding` to `inspect_apk`.

For `dex` and `native`, `sampleLimit` accepts 0–16 and defaults to 16. Zero omits descriptor, symbol and other sampled arrays while retaining parsed headers, counts and coverage. Header and table-range checks remain; sampled descriptor and name checks decrease with the sample limit and do not certify omitted entries. Smaller samples help fit a PTC callback's 48 KiB reply limit; Manifest and summary requests reject this parameter.

## Pagination
<a id="pagination"></a>

For code parts, `offset` indexes matching entries rather than file bytes. Follow the response's `nextOffset` until it is `null`. Reduce `limit` when the selected page exceeds the byte budgets.

Manifest results contain independent `nextComponentOffset` and `nextPermissionOffset` fields inside `results[].analysis`. Follow the cursor for the list being collected; `null` ends that list only. The public request has one `offset` and one `limit`, applied to both lists, so continuing one list may repeat rows from the other. There is no combined Manifest continuation cursor.

## Limits and integrity
<a id="limits-and-integrity"></a>

The [entry reader](../runtime/apk-entry-reader.mjs) retains only selected records and decompresses them in memory. `inspect_apk` creates no extracted files, does not materialize the attachment and does not execute its code.

| Scope | Limit |
| --- | --- |
| Referenced attachment | 256 MiB |
| ZIP central directory | 8 MiB and 20,000 entries |
| Decoded `AndroidManifest.xml` | 4 MiB |
| Selected entries per request | At most 4 |
| Selected compressed payloads combined | 64 MiB |
| Selected decoded payloads combined | 128 MiB |
| Concurrent APK inspections per attachment-tool owner | 1 |
| Request cancellation deadline | 60 seconds |

The tool verifies the complete attachment's declared size and SHA-256 before directory analysis. Reading selected entries performs another complete stream hash check. Successful entry decoding checks local headers against the directory, exact decoded length, consumed compressed input and CRC32. The result also includes the decoded entry's SHA-256. These checks detect inconsistent bytes; they do not authenticate an APK publisher.

The reader rejects duplicate names or record offsets, overlapping records, encrypted or unsupported compression, excessive compression ratios and invalid bounds. Only stored and deflated entries are decoded; split archives and ZIP64 are unsupported. Cancellation, timeout and tool unloading stop pending work, and unloading waits for active reads to settle. Byte budgets describe selected content, not a process RSS limit or a hard preemption guarantee for synchronous parsing.

## Failures and interpretation
<a id="failures-and-interpretation"></a>

A selected entry that fails format parsing or CRC verification can return `status="unparsed"` with a coded diagnostic while other entries remain readable. Unsupported Manifest formats return `status="unsupported"`; unresolved or shortened values remain explicit in partial results. Attachment corruption, ambiguous archive layout, I/O failures and cancellation fail the request instead of producing a successful analysis. Preserve those distinctions when presenting coverage.

Manifest resource references are not resolved. A missing component `exported` declaration remains `null` with `source="not-declared"`; it is not inferred from SDK defaults or intent filters. Declared permissions do not establish runtime grants or component reachability. DEX strings and ELF symbols are bounded samples, and unavailable or truncated data is reported explicitly.

All descriptors, names and strings are untrusted attachment data. The [inspection coordinator](../runtime/apk-inspection.mjs) reports coverage for the directory and selected entries only. It does not verify APK signing schemes, decompile code, scan for malware or establish the presence or absence of packing. A parser error or a loading-related string alone is not evidence of application hardening.

-----

## Validation
<a id="validation"></a>

Host checks exercise the parsers, bounded decompression and the real ToolRuntime attachment entry. The Manifest suite includes an independently generated official `aapt2` fixture. Run these checks from the repository root:

```sh
node --test apps/android/tool/apk-manifest.test.mjs apps/android/tool/apk-entry-reader.test.mjs apps/android/tool/apk-code.test.mjs
node --import tsx --test --test-name-pattern=APK apps/android/tool/model-attachments.test.mjs
node apps/android/tool/generate-apk-device-fixture.mjs --check
```

The ToolRuntime fixture creates its own temporary session and attachment. The [device APK helper](device-runtime-acceptance/apk-inspection.mjs) shares synthetic metadata builders with the host suite and checks two DEX bodies, 32/64-bit ELF dependencies and symbols, decoded hashes/CRC, pagination, metadata-only sampling and rejection of an over-budget declaration before a successful retry. Its negative controls reject directory-only output, altered ELF dependencies and incorrectly accepted oversized input. Run the helper through the existing `ptc` suite with the [protected device runner](device-screen-protection.md); the test APK must include `apk-inspection.mjs` and `apk-code-fixture.json`. These synthetic metadata files are not the original FlClash APK and are not executed or installed.

Recorded device PTC evidence covers binary Manifest parsing and recovery from an oversized callback (`.cache/android/ptc-r15-protected-20261028.json.result.json`). The r42 device report (`.cache/android/ptc-119-r42-protected-20261028.json.result.json`) also records `current-session-apk-through-native-ptc-callback` passing in 1,391 ms through the real attachment tool and native PTC callback. Its synthetic fixture passed both DEX body checks, 32/64-bit ELF checks, decoded hashes/CRC, pagination, metadata-only sampling, oversized entry/page rejection and a successful retry. This is synthetic-fixture device evidence, not a phone analysis of the original FlClash APK, code execution or signature verification.

The same r42 PTC suite was incomplete: nine checks passed, two cancellation checks failed and two checks remained unverified. The instrumentation reported `nodeProcessRetired=false`; the outer runner subsequently confirmed process retirement. The APK result does not establish successful suite-wide cancellation or teardown, general phone memory behavior, or attachment UI acceptance.

The separate original-attachment host report (`.cache/android/apk-inspection-original-host.json`) inspected the cached FlClash APK's Manifest, one DEX and all ten native libraries through ToolRuntime. Existing user attachments are not inputs to the regression commands above.

## Dev Note
<a id="dev-note"></a>

<details>
<summary>Working context</summary>

None.

</details>
