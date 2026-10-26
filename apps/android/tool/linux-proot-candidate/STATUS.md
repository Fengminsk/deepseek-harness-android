# Android ARM64 PRoot build candidate

This directory is an isolated build experiment. Neither output is included in
the APK, registered as a model tool, or treated as a security boundary.
For the non-executing ELF identity check and default-off debug probe gate, see
[host preflight](PROBE-READINESS.md) ([中文](PROBE-READINESS.zh.md)).

Run `build.ps1 -Fetch` on Windows with Android NDK 28.2.13676358 and SDK CMake
3.22.1. Without `-Fetch`, place the three archives below in
`.cache/android/linux-proot-source/`. Every run checks the archive SHA-256
**before** replacing its owned extracted-source staging directory. A changed
archive fails closed. The script does not execute any downloaded source.

| Source | Version | SHA-256 | License found in source |
| --- | --- | --- | --- |
| [Termux PRoot](https://github.com/termux/proot/tree/v5.1.107.96) | 5.1.107.96 | `75f654fe60dea92dabff2bf083ae8bfe4f91baa6a1a374786a6bf391015eebaa` | GPL-2.0-or-later in source headers |
| [Samba talloc](https://www.samba.org/ftp/talloc/) | 2.4.3 | `dc46c40b9f46bb34dd97fe41f548b0e8b247b77a918576733c528e83abd854dd` | LGPL-3.0-or-later in `talloc.c`, `talloc.h`, and `LICENSE` |
| [Termux libandroid-shmem](https://github.com/termux/libandroid-shmem/tree/v0.7) | 0.7 | `1e5ff8459bc0a8c229dd8a94b27d119987e09ef3414331c2b5ebfff20b98e867` | BSD-3-Clause in `LICENSE` |

The candidate builds two AArch64 ELF files named for future native library
packaging: `libdsh_proot_candidate.so` and
`libdsh_proot_loader_candidate.so`. The loader is separate because upstream's
embedded-loader extraction would conflict with Android 10+ app-home W^X.
The app would have to launch only an APK-installed `nativeLibraryDir` path and
set `PROOT_LOADER` to the installed loader path. This wiring has **not** been
implemented. The build uses `--image-base=0x2000000000` instead of upstream's
`-Ttext` to preserve its fixed AArch64 virtual address without trying to
materialize a huge sparse file on Windows. `generate-loader-info.ps1` derives
the workaround offset from the linked loader symbols.

Open gates before APK inclusion:

1. The fixed [source bundle](SOURCE-BUNDLE.md) now covers the 16 installed
   Alpine packages and the pinned PRoot/talloc candidate inputs. Review
   file-level grants, license texts, modification notices, GPL/LGPL combination,
   binary rebuild equivalence and the actual delivery method before distribution.
2. The source-locked `libandroid-shmem` is now statically linked into this
   candidate with [private-path and bounded-retry patches](SHMEM.md), but its
   cross-instance keyed mode is disabled by default. Identify a writable,
   isolated-UID-owned 0700 directory and test it on a device before opt-in.
3. Supply a packaged 32-bit ARM loader if 32-bit guest binaries are supported.
   The current candidate targets a 64-bit guest only.
4. The candidate has a versioned [fork/clone/reap event stream](EVENTS.md) and
   an App-side parser/launch-session contract. Connect a real OS-owned pipe,
   tracer exit and durable host acknowledgement, then test every descendant on
   a device. PRoot path translation is **not** a sandbox; host-only parser
   tests do not prove the native process tree retired.
5. Perform installation and runtime acceptance on a device. There is no phone
   available for this candidate and ELF linkage alone proves no guest command
   execution or Android package manager compatibility.

Never expose this candidate as a generic model Shell or allow it to access
host app-private paths. The controlled approval/capability bridge must remain
the only route to authorized host resources.
