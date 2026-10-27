# Linux guest distribution gate

This is an engineering checklist for the **fixed candidate**, not a legal opinion
or approval to ship it. At the time of this audit, neither the PRoot candidate
nor Alpine minirootfs is inside the APK. The separate source-lock and APK scan
can be run with:

```powershell
python apps/android/tool/linux-proot-candidate/verify-distribution.py --apk .cache/android/pocket-harness-0.1.0+84-arm64-debug.apk
python -m unittest discover -s apps/android/tool/linux-proot-candidate -p 'test_*.py'
```

The script checks the three exact PRoot build-input archives, their license
files, the pinned Alpine archive and its installed-package database. It rejects
the **known candidate payload names** in an APK. It deliberately prints
`distributionApproved: false` even when those checks pass. Renaming or
re-encoding a payload is outside this scan; it is not a general license scanner.
The separate [APK verifier and host preflight](PROBE-READINESS.md) additionally
reject these two *exact* ELF digests if renamed at the APK's top level; neither
check covers arbitrary modified or nested payloads.

## What the pinned source actually contains

| Artifact | Evidence in the fixed archive | Distribution work |
| --- | --- | --- |
| Termux PRoot 5.1.107.96 | `COPYING` contains GPLv2; representative core/loader headers state GPL-2.0-or-later. `src/extension/sysvipc/sysvipc_sys.h` attributes definitions to glibc under LGPL-2.1-or-later. Of the 66 C files selected by the candidate CMake glob, 31 have no explicit GPL header in their first 2 KiB. | Establish the license grant and source of every compiled unit, including copied header definitions, before choosing a license version for the linked executable. Preserve notices, exact source, build procedure and modifications. |
| Samba talloc 2.4.3 | `talloc.c` and `talloc.h` state LGPL-3.0-or-later; `LICENSE` contains LGPLv3. The candidate **statically links** `talloc.c`. | Resolve the GPLv2-or-later/LGPLv3 combination, preserve both notices, provide corresponding source and a modification/relinking route required by the selected terms. The current build is not a reviewed distribution. |
| Termux libandroid-shmem 0.7 | `LICENSE` resembles BSD-3-Clause and names two copyright holders, but its third condition literally says `{organization}`. | Resolve that unexpanded upstream placeholder with the copyright holders or another reliable record of the upstream license terms before relying on a precise license classification; do not silently rewrite their terms. The candidate statically links the patched source, so preserve its actual notice and exact changes if distributed. Its keyed runtime mode is disabled by default. |
| Alpine 3.24.3 aarch64 minirootfs | `./lib/apk/db/installed` lists 16 packages from ten source origins and several licenses. | Treat the archive as a collection of separate binary packages. Resolve corresponding source, packaging recipes/patches, copyright/license notices and the exact package versions before bundling the archive. |

The Alpine installed database reports these origins and licenses:

| Origin | Installed packages | License metadata |
| --- | --- | --- |
| `alpine-baselayout` | `alpine-baselayout`, `alpine-baselayout-data` | GPL-2.0-only |
| `alpine-keys` | `alpine-keys` | MIT |
| `alpine-base` | `alpine-release` | MIT |
| `apk-tools` | `apk-tools`, `libapk` | GPL-2.0-only |
| `busybox` | `busybox`, `busybox-binsh`, `ssl_client` | GPL-2.0-only |
| `ca-certificates` | `ca-certificates-bundle` | MPL-2.0 AND MIT |
| `openssl` | `libcrypto3`, `libssl3` | Apache-2.0 |
| `musl` | `musl`, `musl-utils` | MIT; MIT AND BSD-2-Clause AND GPL-2.0-or-later |
| `pax-utils` | `scanelf` | GPL-2.0-only |
| `zlib` | `zlib` | Zlib |

The minirootfs does **not** itself contain the complete package build recipes
or corresponding source. Alpine says its
[aports tree](https://wiki.alpinelinux.org/wiki/Aports_tree) contains the
`APKBUILD` recipes and that they are absent from built `tar.gz` images. Its
[packaging guide](https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package)
also says the package license metadata must be checked against source headers
and license files. The installed database is an inventory, not sufficient proof
of each upstream license or the matching source revision.

## Current decision for diagnostic and release APKs

The candidate source bundle is useful rebuild evidence, but it does not clear
binary conveyance. Keep PRoot, its loader and Alpine out of any APK sent to a
tester or user while the file-level grants, libandroid-shmem notice, complete
applicable license texts, corresponding-source delivery and actual relinking
method are unresolved. A debug label alone does not resolve these distribution
conditions. A strictly local compile with no binary transfer is a different
activity; whether a particular transfer is conveyance depends on its facts.
The [GNU license FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#v2v3Compatibility)
confirms that GPLv2-or-later can be selected as GPLv3, and its
[static-linking explanation](https://www.gnu.org/licenses/gpl-faq.en.html#LGPLStaticVsDynamic)
describes relinking material for LGPL libraries. The upstream
[BSD-3-Clause text](https://opensource.org/license/bsd-3-clause) requires binary
notice reproduction; the pinned shmem file's literal placeholder needs its own
review. These references inform this engineering gate; they do not decide the
App/PRoot combined-work question.

## Required release evidence before adding any guest payload

1. Freeze the exact APK build, PRoot/loader ELF hashes, rootfs hash, source
   archives, dependency graph and all modifications. Include the candidate
   `build.ps1`, CMake configuration, generated-file recipe, any patches, and
   exact compiler/toolchain assumptions in the corresponding source package.
2. Resolve the PRoot/talloc license combination against every compiled unit,
   including the copied glibc definitions in `sysvipc_sys.h`. The talloc archive
   contains LGPLv3 text, which incorporates GPLv3 by reference; ensure the
   conveyed license set includes the applicable GPLv3 and LGPLv2.1 texts too.
   The [GNU compatibility matrix](https://www.gnu.org/licenses/gpl-faq.en.html#AllCompatibility)
   shows that GPLv2-or-later and LGPLv3 can be combined under GPLv3, subject to
   the actual source grants. The [LGPLv3 combined-work terms](https://www.gnu.org/licenses/lgpl-3.0.html#section4)
   and [GPLv3 source terms](https://www.gnu.org/licenses/gpl-3.0.html#section6)
   govern the chosen distribution method. Do not infer that a lone upstream URL
   or a zip hash satisfies these obligations.
3. For each Alpine origin above, acquire and pin the matching upstream source,
   Alpine `APKBUILD`, patches and configuration for its **installed** version.
   Preserve notices and an actionable way for APK recipients to obtain the
   corresponding source on the terms used to distribute the binary. The
   [GPLv2 object-code clause](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html#SEC3)
   explicitly includes build and installation scripts in complete source.
4. Keep the license texts, copyright/modification notices and source access
   directions visible with the APK distribution. Check any additional licenses
   in built PRoot units and the whole Alpine package set. Review the app/PRoot
   integration boundary; process separation alone is not a blanket legal
   conclusion about combined works.
5. Only then update the APK gate to recognize an intentional guest payload,
   bind that exact payload hash to the reviewed source bundle, and verify the
   published APK and source are available together. Treat Android guest
   execution, tracee retirement, filesystem/network brokerage, and device
   acceptance as **separate** technical gates.

The current fixed-URL installer is not linked to a user action or model tool.
It does not make the APK contain Alpine. If runtime download becomes a feature,
review its user-facing source/license information and platform obligations as
a separate distribution decision. Do not use that design as an assumed
workaround for redistribution obligations.
