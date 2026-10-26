# Source and notice review for the fixed candidate

This records **where to review** notices in the exact source bundle. The
`license` value in an Alpine `APKBUILD` or installed-package database is
metadata, not a review of every source unit or a legal distribution decision.
The source-only ZIP is locked by `CORRESPONDING-SOURCE-MANIFEST.json`; its
presence does not change `distributionApproved: false`.

| Origin / input | Pinned source and recipe evidence in ZIP | Notice evidence found | Unresolved review |
| --- | --- | --- | --- |
| PRoot 5.1.107.96 | `upstream/proot/v5.1.107.96.zip`; candidate build/event patch files | `proot-5.1.107.96/COPYING` (GPLv2 text); representative core/loader files explicitly grant GPL-2.0-or-later; `src/extension/sysvipc/sysvipc_sys.h` carries glibc LGPL-2.1-or-later notice for copied definitions | The current CMake glob selects 66 PRoot C files; 31 have no explicit GPL notice in their first 2 KiB. Review their grants/provenance, the glibc-derived header and the chosen GPL version with statically linked talloc; preserve patch notices and source/install offer. |
| talloc 2.4.3 | `upstream/talloc/talloc-2.4.3.tar.gz` | `talloc-2.4.3/LICENSE` (LGPLv3 text only), `talloc.c` and `talloc.h` headers explicitly grant LGPL-3.0-or-later | Resolve combined-work/relinking method and source/notice delivery; include applicable GPLv3 text because LGPLv3 incorporates it by reference. |
| libandroid-shmem 0.7 | `upstream/libandroid-shmem/libandroid-shmem-v0.7.tar.gz` (source-locked, now statically linked) | `libandroid-shmem-0.7/LICENSE` resembles BSD-3-Clause but third condition literally retains `{organization}` | Resolve unexpanded term with copyright holders/provenance without silently changing it; preserve actual notice and exact private-key-path patch with any distributed binary. |
| `alpine-base` 3.24.3-r0 | `alpine/aports/alpine-base/APKBUILD`, pinned commit `ee92350c...` | APKBUILD declares MIT; no standalone license text in this one-file recipe directory | Resolve exact project copyright/notice and include required license text with any binary distribution. |
| `alpine-baselayout` 3.7.2-r1 | 17 pinned aports files, `protocols-6.4` and `services-6.4` distfiles | APKBUILD declares GPL-2.0-only; no standalone GPL text in recipe directory | Review origin files, both distfiles' provenance/notices and supply applicable license text. |
| `alpine-keys` 2.6-r0 | APKBUILD and 18 public keys | APKBUILD declares MIT; no standalone MIT text in recipe directory | Check key provenance and exact project copyright/notice; include required license text. |
| `apk-tools` 3.0.8-r0 | APKBUILD, `repo-hash-sha1.patch`, source tarball | Source tarball `apk-tools-v3.0.8/LICENSE`; APKBUILD declares GPL-2.0-only | Review actual compiled files, patch and notice placement. |
| `busybox` 1.37.0-r31 | APKBUILD, configuration, 44 patches and adjacent files, source tarball | Source tarball `busybox-1.37.0/LICENSE`; APKBUILD declares GPL-2.0-only | Audit configuration, applied patches, applets/subpackages and full notices. |
| `ca-certificates` 20261020-r0 | APKBUILD, post-deinstall/trigger and source tarball | APKBUILD declares MPL-2.0 AND MIT; `certdata.txt` header invokes MPL-2.0, but tarball has no standalone license text | Identify MIT-covered code/data, preserve MPL/MIT notices and supply applicable license texts. |
| `musl` 1.2.6-r3 | APKBUILD, CVE/compatibility patches and source tarball | Source tarball `musl-1.2.6/COPYRIGHT`; APKBUILD declares MIT; `musl-utils` installed metadata also lists BSD/GPL terms | Review utilities' separate grants and exact file-level attribution. |
| `openssl` 3.5.9-r0 | APKBUILD, `auxv.patch`, post-install and exact SHA-512-matched OpenSSL release tarball | Source tarball `openssl-3.5.9/LICENSE.txt`; APKBUILD declares Apache-2.0 | Review upstream/additional bundled notices, FIPS-related packaging and patch. |
| `pax-utils` 1.3.9-r1 | APKBUILD and source tarball | Source tarball `pax-utils-1.3.9/COPYING`; APKBUILD declares GPL-2.0-only | Review actual compiled files and complete notices. |
| `zlib` 1.3.2-r1 | APKBUILD, `CVE-2026-85091.patch`, source tarball | Source tarball `zlib-1.3.2/LICENSE`; APKBUILD declares Zlib | Review contrib components included in binary and patch. |

The Alpine source lock records all **ten** exact `c:` aports commits and all
**16** installed packages. `source-bundle.py --verify` checks recipe/distfile
hashes locally; `assemble-corresponding-source.py --verify` checks every ZIP
member. Neither script rebuilds Alpine packages, compares rebuilt binaries,
includes an aarch64 compiler/abuild environment, or establishes license
compatibility. Those are remaining release gates in `DISTRIBUTION.md`.
