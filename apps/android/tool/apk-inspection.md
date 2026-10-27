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
```

The ToolRuntime fixture creates its own temporary session and attachment. These host checks do not certify Android packaging, device memory behavior or the phone's attachment UI; Android device acceptance remains pending. Existing user attachments are not inputs to these regression commands.

## Dev Note
<a id="dev-note"></a>

<details>
<summary>Working context</summary>

None.

</details>
