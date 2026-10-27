---
description: "Records a persistence type transition and its compatibility acknowledgement."
kind: persistence-change
---

# 2026-10-27-file-mutation-receipt

English | [中文](2026-10-27-file-mutation-receipt.zh.md)

## Summary

Add file-mutation-receipt attribution to completed write and edit effects retained through cancellation or observation failure.

## Table of Contents

- [Declaration](#declaration)
- [Compatibility](#compatibility)
- [Verification](#verification)
- [Dev Note](#dev-note)

<a id="declaration"></a>
## Declaration

```yaml persistence-change
schemaVersion: 1
id: 2026-10-27-file-mutation-receipt
baseline: false
changes:
  - root: "event:agent/inbox/spliced"
    previous: "2026-10-13-user-rpc-principal"
    after: "91fcc85353cef9f2c2ebb8a76eb52694affac7a3ae3309ae2abb369482d1f1ab"
    decision: same-version
  - root: "event:developer/message"
    previous: "2026-10-13-user-rpc-principal"
    after: "5ad5f4d16858c46356484ed60c991589b8494392c4a594ab1be5507690ac306d"
    decision: same-version
  - root: "event:session/title-llm-request"
    previous: "2026-10-13-user-rpc-principal"
    after: "d5742f81b66fa3c622e956454759928c15ebe15fe51db181c6fd5b4e339aa337"
    decision: same-version
  - root: "event:user/message"
    previous: "2026-10-13-user-rpc-principal"
    after: "ba40e93e4d66bcbf056e030b8f6ad36148b200312f68ebe7539cce7857d2eead"
    decision: same-version
```

<a id="compatibility"></a>
## Compatibility

Existing message and queued-input records remain readable without modification. The new source kind attributes an ordinary user-role text context; it adds no replay operation, permission, validation requirement or required plugin. The producer records the complete canonical path and operation only after the filesystem provider succeeds. Current and older readers preserve unknown source kinds and their JSON metadata without installing the producer, so the receipt text remains readable and does not cause file changes on replay. Its absence retains previous behavior. ToolRuntime may still discard body contexts when post-execution policy explicitly blocks a result; this receipt does not override that decision. The Session format version is unchanged.

<a id="verification"></a>
## Verification

pnpm exec vitest run packages/fs/tool-fs/tests/integration.spec.ts: 38 passed, including actual disk mutations followed by cancellation or throwing fs/observed listeners and ordinary success. The five receipt assertions failed before the producer change. pnpm exec vitest run packages/fs/tool-fs/tests/tools.spec.ts: 99 passed. pnpm exec vitest run packages/session/session-persistence-jsonl/tests/native-source-admission.spec.ts -t 'preserves external attribution': 4 passed across read/write handles and plain/Zstandard files, preserving external source metadata and stored bytes without the producer. pnpm exec tsc -b packages/fs/tool-fs passed. No device or released-binary execution is claimed.

<a id="dev-note"></a>
## Dev Note

None.
