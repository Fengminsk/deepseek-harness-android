---
kind: reference
title: Linux guest recovery records
---

# Linux guest recovery records

English | [中文](linux-vm-recovery.zh.md)

## Summary

The Linux guest records admission, dispatch, retirement and disk publication separately. A cold owner can report verified publication without replaying a command. Uncertain or review-required records prevent further execution in that conversation. [The runtime reference](linux-vm-runtime.md) owns model tool availability and inspection behavior.

## Contents

- [Reading recovery results](#reading-recovery-results)
- [Durable records](#durable-records)
- [Compatibility](#compatibility)
- [Verification](#verification)
- [Dev Note](#dev-note)

<a id="reading-recovery-results"></a>
## Reading recovery results

`native.linuxVm.inspect` is read-only. It does not start a guest, create storage, acknowledge a record or reopen an execution owner. Admission rejects both `blocked` and `needsReview`; querying a record never clears either condition. There is no acknowledgement or unlock operation. A reviewer must inspect the recorded effects; repeatedly submitting the command does not resolve the barrier.

| Last durable stage | Cold-owner interpretation | Further admission |
| --- | --- | --- |
| Admitted | Dispatch did not cross its durable boundary; disk publication is false | Requires review |
| Dispatched | Worker retirement and disk effects are unknown | Blocked |
| Retired | Compare the atomic disk pointer with this run and its preceding pointer digest | Requires review |
| Export prepared | Host publication is unknown, even if matching destination bytes exist | Blocked |
| Terminal | Retain explicit retirement and publication facts | Allowed only when no record requires review |

An exclusive App file lock protects disk publication. Releasing that lock does not prove an isolated worker has exited. A cold `Dispatched` record stays blocked because the current protocol has no cross-owner Binder retirement proof. An authenticated native return or Binder death can establish retirement within the original owner.

<a id="durable-records"></a>
## Durable records

[LinuxVmRecoveryStore](../android/app/src/main/java/com/minnnng/dsh_android/LinuxVmRecoveryStore.java) stores checksummed binary admission records in `runs-v2/<runId>.bin`. A run records its conversation, operation, preceding pointer digest and monotonic execution stage. It is synced before any Binder dispatch. The pointer `state-v3.bin` atomically contains the committing run identity and complete disk metadata; its referenced immutable blocks are validated before reporting a commit. Temporary files and unpublished blocks are retained.

Each record is written to a fresh sibling, file-synced, atomically renamed and directory-synced. The Android adapter also syncs new ancestor directories before admission. Failure after rename must not restore the previous stage. A pointer belonging to a retired run establishes `diskCommitted: true` even if terminal-record publication failed; a successor is refused until that recovered fact is reviewed. Inspection reports the current verified pointer, not an independent guarantee about a future power failure.

Export records publication independently: `filePublished` becomes unknown before host rename and is settled only from an explicit publication result. New `export-<runId>.json` files retain source, destination, size and hash as supplementary diagnostics; `runs-v2` is the authoritative execution record. A matching destination hash does not establish which run created it.

<a id="compatibility"></a>
## Compatibility

The reader retains existing `state.json`, `run-*.json` and `export-*.json` files. It reads the old disk pointer only when `state-v3.bin` is absent; a corrupt new pointer never falls back. Old run records lack authenticated retirement, so their terminal labels do not unlock writes. Explicit old publication facts may be reported with unknown retirement. No automatic migration, rollback, deletion or command replay occurs.

Storage is bounded: a complete scan admits at most 1,024 run records and inspection returns at most 32, prioritizing records needing review. A requested run identifier returns one matching record or verified absence only after a complete trustworthy scan. Read failure produces `status: unknown` and `requestedRunFound: null`; it cannot establish absence. Corruption, incomplete scans and invalid referenced blocks prevent new admission.

<a id="verification"></a>
## Verification

Run `node apps/android/tool/acceptance-linux-vm-recovery.mjs` from the repository root. The host runner preserves its report under `.cache/android/linux-vm-recovery-tests/` and emits `.cache/android/linux-recovery-native-contract.json` using the same Java encoder as the Android adapter. It exercises real files and atomic moves, including child-process termination after dispatch and after pointer publication. Directory fsync, Binder retirement and Android process-death behavior still require device evidence; Windows host checks do not certify those boundaries.

The separate [device lifecycle runner](linux-vm-lifecycle-device.md) prepares live cancellation, import death after retirement but before publication, and ordinary-upgrade workspace checks. Its host tests do not replace the saved reports from those device runs.

<a id="dev-note"></a>
## Dev Note

None.
