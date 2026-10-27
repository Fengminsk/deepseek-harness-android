---
kind: reference
title: Android Linux VM execution
---

# Android Linux VM execution

English | [中文](linux-vm-runtime.zh.md)

## Summary

The optional Android carrier embeds TinyEMU's RISC-V interpreter in an isolated Android service. It boots a Linux kernel and runs a supplied shell script; it does not execute that script with the App UID. Ordinary builds exclude the VM native provider and guest images and do not require prepared TinyEMU sources. An explicit [Alpine acceptance build](tinyemu-build.md#alpine-acceptance-apk) enables the carrier and a verified candidate image; requests to an excluded provider report that it is unavailable. Model registration is separately controlled by `LINUX_VM_DEVICE_ACCEPTED` in [the runtime entry](../runtime/index.mjs). Its closed state must not be represented as an available model capability.

## Contents

- [Execution](#execution)
- [Workspace file import](#workspace-file-import)
- [Guest artifact export](#guest-artifact-export)
- [Persistence and failures](#persistence-and-failures)
- [Build and evidence](#build-and-evidence)

## Execution

[The native provider](../android/app/src/main/cpp/linux_vm_engine.c) receives only BIOS, kernel and disk memory mappings. The guest has 128 MiB RAM, a VirtIO console and a block device. Host filesystems, network devices, SDL, KVM and Node APIs are absent. The service checks that its isolated UID cannot read App storage or create a network socket before booting.

`linux_exec` accepts `command` and `timeoutMs`; the registered Agent supplies the conversation identity. Scripts have a 32 KiB UTF-8 limit, start in `/workspace`, and have a maximum 120-second boot-and-execution deadline. Console output is capped at 64 KiB with explicit truncation. A completed shell may return a nonzero exit code. The native result records timeout, cancellation, retirement and disk publication separately.

The active ToolRuntime execution resolves the Agent's current `sandboxPolicy`. A missing policy or unregistered Agent is rejected. The host supplies `persistChanges` separately from model arguments: read-only sessions discard guest disk changes, while writable sessions may commit them after a completed command. The Node owner rejects a completed receipt whose `diskCommitted` disagrees with that policy.

## Workspace file import

`linux_import` accepts `source`, `destination` and optional `timeoutMs`. Source names are relative to the current Agent working directory; destinations are relative to the guest's `/workspace`. Absolute paths, parent traversal, URI schemes and model-selected sessions or persistence flags are rejected. Only regular files up to 64 MiB inside both the App workspace and the current session workspace are accepted. Attachments require the separate authorized materialization step before import.

The tool rechecks the live Agent and writable session policy after file resolution. [The native file reader](../android/app/src/main/kotlin/com/minnnng/dsh_android/LinuxVmFileInput.kt) checks the opened descriptor's actual path against the App workspace before reading. A successful import receipt includes the canonical App-relative `source`, guest-relative `destination`, `bytes` and `sha256`. A failed import command does not commit its disk changes. Import requires a writable policy; read-only sessions can still inspect an existing guest through `linux_exec` without retaining changes.

## Guest artifact export

`linux_export` copies one regular guest file of at most 64 MiB into the current Agent workspace. `source` is relative to guest `/workspace`; `destination` is relative to the Agent working directory. It uses the same Android write authorization as attachment materialization, including protected workspace metadata, and requires a writable session. The tool checks App and session containment and refuses existing destinations; native descriptor-relative operations and no-replace publication own the final race check. Export does not save temporary guest disk changes.

A successful result requires `filePublished: true`, `diskCommitted: false`, matching source and destination, byte count and SHA-256. The tool adds `file_path` for the existing file browser and presentation tools. A publication that succeeds before a later synchronization error is `outcome_uncertain`, even though `filePublished` is true; the owner closes and the caller must inspect the existing destination instead of automatically retrying. [The device fixture](device-runtime-acceptance/linux.mjs) reads its dedicated exported file, compares its content hash and checks no-overwrite and read-only denials.

## Persistence and failures

[The image store](../android/app/src/main/kotlin/com/minnnng/dsh_android/LinuxVmImageStore.kt) verifies packaged images and maps a separate 128 MiB `/workspace` volume for each conversation. The workspace survives replacement of the packaged system image; customizations outside it belong to that system image's version. After guest retirement, [the block store](../android/app/src/main/java/com/minnnng/dsh_android/LinuxVmBlockStore.java) syncs only changed 64 KiB content blocks, then atomically publishes one pointer covering both disks. It does not rewrite whole disk images for every command. Interrupted or cancelled snapshots retain the previous pointer. Cancellation and publication share an owner lock, so cancellation cannot undo an already published pointer.

All virtual CPUs execute in the isolated process, without host child processes. Native return or that process's Binder death establishes retirement. User cancellation and owner disposal request cancellation while preserving the original execution RPC until its independent deadline. A final receipt retains the real `diskCommitted` state and reports `cancelRequested`, including publication that won a cancellation race. Missing or invalid final receipts close the Node execution owner as `outcome_uncertain` and prevent automatic retry, even when the cancellation acknowledgement confirms process retirement. A stopped or unknown invocation retains a run record; its output is not treated as command success.

Linux tools attach a bounded `android-linux-receipt` context to the real ToolRuntime result. It retains the native run identity and publication facts when caller cancellation normalizes the tool result to `ABORTED`. Unknown results use the structured `HarnessError` code `linux-vm/outcome-uncertain`; unknown publication remains `null`, never inferred as false from a cancellation acknowledgement. AgentLoop records contexts arriving after cancellation in the Session's `agent/inbox/spliced` events and presents them to the model on its next turn. This audit contains no shell output or command text. Host regressions cover both the cancelled canonical result and the actual Session event sequence.

## Build and evidence

[The source builder](build-tinyemu.mjs) verifies the [pinned official inputs](tinyemu-source-lock.mjs), applies [the embedding patch](patch-tinyemu.mjs), and records compiler, source and output hashes. [CMake](../android/app/src/main/cpp/linux_vm.cmake) consumes that prepared source and rebuilds the JNI provider. [The Alpine release verifier](linux-vm-release.py) checks candidate freshness before merging assets and checks the final APK against its disk, source record and compiled provider. The separate legacy `-PdshLinuxGuestFixture=true` path retains the restricted boot fixtures for investigation; it cannot be combined with Alpine selection and is not an Alpine release.

[Node owner tests](native-linux-vm.test.mjs), [real ToolRuntime registration tests](tool-linux-vm.test.mjs), and [console framing tests](../android/app/src/test/java/com/minnnng/dsh_android/LinuxVmConsoleTest.java) cover their own host paths. [Device instrumentation](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/LinuxVmAcceptanceInstrumentation.kt) owns kernel boot, actual command execution, disk retention and interruption evidence. Compilation and host tests do not substitute for its device results.

## Dev note

The fixed `android_linux` utility tool and this VM have separate implementations. Neither tool supplies Root or ADB privileges. Guest networking remains absent. An Android path is never a guest mount merely because it appears in a script; `linux_import` and `linux_export` are explicit authorized copy operations.
