---
kind: reference
title: Android Linux guest build inputs
---

# Android Linux guest build inputs

English | [中文](tinyemu-build.zh.md)

## Summary

These build helpers prepare pinned TinyEMU sources, official Alpine packages and corresponding sources. They write build artifacts under `.cache/android/tinyemu-probe`; they do not install software on the phone. [The runtime reference](linux-vm-runtime.md) owns isolation, invocation and device acceptance.

## Contents

- [Interpreter](#interpreter)
- [Guest inputs](#guest-inputs)
- [Corresponding sources](#corresponding-sources)
- [Evidence limits](#evidence-limits)

## Interpreter

[The source builder](build-tinyemu.mjs) validates [the source lock](tinyemu-source-lock.mjs), extracts a fresh copy, applies [the Android patch](patch-tinyemu.mjs), and invokes the Android NDK compiler. Its manifest hashes C sources, headers, patch, compiler settings and shared library. The headless build excludes host filesystem adapters, SDL, SLIRP, curl and KVM. A changed source or patch requires regeneration of the prepared build manifest.

## Guest inputs

[The package collector](collect-alpine-vm-packages.py) requires Python with `cryptography`, curl and the pinned Alpine minirootfs. It verifies the pinned repository index's RSA signature using keys from that minirootfs, resolves the fixed RV64 package closure, and verifies each APK control checksum and payload hash. [The package lock](alpine-packages.lock.json) records exact packages, dependencies, architectures, licenses and hashes. Cache reuse still verifies content. Unknown dependency syntax, ambiguous providers, signature failure and hash mismatch stop collection.

[The input assembler](build-alpine-vm-input.py) verifies the minirootfs and package lock, then creates a deterministic USTAR file containing only `rootfs.tar.gz`, `tools.tar` and `e2fs.tar`, with a 64 MiB limit. The nested archives contain offline APKs and a path-independent manifest. This input supplies guest-side image construction; it neither enables guest network access nor executes package scripts on Windows. An existing different output is preserved and rejected.

## Corresponding sources

[The source collector](collect-alpine-vm-sources.py) reads exact aports revisions from the pinned rootfs and package lock. It collects original archives, patches, configurations and packaging scripts without executing APKBUILD. Recipe inputs must match SHA512; recipes and supplementary scripts must match [the source lock](alpine-sources.lock.json). Generated Alpine release text is covered by its complete recipe. Missing source inputs are reported as failures.

[The source packager](package-linux-vm-sources.py) assembles a separate archive containing TinyEMU, firmware and kernel source, their patches/configuration/notices, Alpine corresponding sources, and a snapshot of the Android embedding sources. Every locked input is rehashed. The archive retains full original source licenses; its manifest indexes members and hashes. Regenerate this artifact after final embedding edits and deliver it alongside the binary distribution. It excludes the old demo rootfs, whose exact BusyBox/glibc build inputs remain unverified.

The version 2 inventory includes the offline image builders, guest build/probe scripts, production console initialization, native embedding, image store, file transfer and host verification tools. Project files keep their repository-relative layout under `project/`; this is not the complete Android App source tree. Verification checks every archive member against its hash, the locked upstream source closure and the current project inputs. It rejects missing or stale build files before [Alpine candidate assembly](linux-vm-host/README.md#candidate-assembly). Repackaging retains the previous archive and its manifest under the previous archive digest.

## Evidence limits

The [Windows guest probe](linux-vm-host/README.md) compiles the same interpreter and production JNI entry for a local JVM, allowing real guest execution and image checks without a connected phone. Its reports explicitly exclude Android device acceptance.

[The experimental Windows ext2 builder](build-alpine-vm-image.py) is a host investigation artifact. Its own reader checks file bytes, link targets, inode modes, ownership, directory types and allocation counters; those checks are not independent filesystem validation. It is not the production image-construction route and does not promise reproducible filesystem metadata. Kernel mounting, independent e2fsck, executable links, disk writeback and a second boot require device evidence. Matching RV64 ELF attributes alone does not establish Alpine compatibility with the older kernel; Python threading, time, file operations and blocking `os.urandom` need execution tests.

## Dev note

Source collection and archive assembly do not establish a usable Agent environment. Keep package source verification, NDK compilation, guest boot and actual task execution as separate results.
