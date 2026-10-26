# Fixed Linux guest source evidence

This directory's source tools are for the **fixed candidate** audited in
`DISTRIBUTION.md`. They do not authorize adding PRoot, a loader, or Alpine to
the Android APK. The source ZIP itself contains no built PRoot ELF, Android
APK, or Alpine rootfs binary archive.

## Binary-to-source identification

The exact Alpine 3.24.3 aarch64 minirootfs SHA-256 is
`4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50`.
Its `lib/apk/db/installed` database supplies package names, installed
versions, origin names, licenses **as package metadata**, and the 40-character
aports commit in each `c:` field. The scripts reject a rootfs with any other
bytes or a package inventory other than the fixed 16 packages / ten origins.

| Origin | Binary version | aports commit from installed database |
| --- | --- | --- |
| alpine-base | 3.24.3-r0 | `ee92350c8a4509152dc91c693814215a884c07c3` |
| alpine-baselayout | 3.7.2-r1 | `60a7585bbab2fa0f762504eb617dbca90216e31f` |
| alpine-keys | 2.6-r0 | `b9f23becced4d7b3ccc0fa0f28530243ccd314a0` |
| apk-tools | 3.0.8-r0 | `4588b452722bd4800efdc6cce4f6e980e02a997f` |
| busybox | 1.37.0-r31 | `c3ef5d10e6ef6528852c51f0564963e2f8c1be19` |
| ca-certificates | 20261020-r0 | `e78f5987166c6ffbe23f6472e2e8f040298fe2da` |
| musl | 1.2.6-r3 | `8f79d39391b46d6dbf1800fb68b8212a21d5ee2e` |
| openssl | 3.5.9-r0 | `29b9ec24b1b5b39aeef51fa2a044210e2ec5258e` |
| pax-utils | 1.3.9-r1 | `c61801eeacb3ffcd9c2025b09e402153bb93fb39` |
| zlib | 1.3.2-r1 | `0afa2da0e8c8051c6f8f64a7a388e5a259904245` |

`source-bundle.py --fetch` retrieves each origin's exact-commit `APKBUILD` and
adjacent recipe files from [official Alpine aports](https://git.alpinelinux.org/aports/).
It checks the `pkgver` against the installed binary and validates every local
patch/input and every downloaded upstream archive against the SHA-512 entry
in that `APKBUILD`. Upstream archives are fetched from
`https://distfiles.alpinelinux.org/distfiles/v3.24/` using their checksum-keyed
filenames. The OpenSSL 3.5.9 archive uses the [official OpenSSL release URL](https://www.openssl.org/source/openssl-3.5.9.tar.gz)
because that Alpine distfiles transfer stalled here; it must match the same
fixed-commit APKBUILD SHA-512 before entering the cache. The lock records each official URL, SHA-256 and, for distfiles,
APKBUILD SHA-512. These checks bind source bytes to the recipe; they are not a
rebuild comparison against the exact packaged binaries.

The candidate PRoot, talloc, and libandroid-shmem archives have
independent fixed sizes and SHA-256 values in `verify-distribution.py` and
`build.ps1`. They come from the respective Termux and Samba release URLs
recorded in the source manifest. The source ZIP includes those unmodified
archives plus this directory's candidate CMake/build scripts, generated-file
recipe, event and private-shmem patch scripts, and integration source. The
candidate statically links talloc and libandroid-shmem. Its keyed shared-memory
mode remains disabled by default and has no proven isolated-UID private path;
see [the shared-memory gate](SHMEM.md).

## Reproduce and inspect

From the repository root, with Python 3.11+ and the already pinned candidate
inputs under `.cache/android/linux-proot-source/` and rootfs under
`.cache/android/linux-rootfs-prototype/`:

```powershell
python apps/android/tool/linux-proot-candidate/verify-distribution.py
python apps/android/tool/linux-proot-candidate/source-bundle.py --fetch
python apps/android/tool/linux-proot-candidate/source-bundle.py --verify
python apps/android/tool/linux-proot-candidate/assemble-corresponding-source.py --assemble
python apps/android/tool/linux-proot-candidate/assemble-corresponding-source.py --verify
```

The fetch tool is resumable. It never extracts or executes fetched material;
it rejects a single file over 90 MiB or more than 250 MiB newly fetched in one
run. A failed origin is reported in `.cache/android/linux-guest-source-bundle/partial.json`
while other origins continue. Only a fully verified ten-origin run writes the
immutable `SOURCE-BUNDLE-LOCK.json`. The assembly tool then writes a
deterministic source-only ZIP and `CORRESPONDING-SOURCE-MANIFEST.json`, which
lists the hash and byte count of every member and the ZIP itself. A rerun
verifies existing bytes instead of replacing the lock or archive.

The PRoot build remains `build.ps1`/`CMakeLists.txt`: Windows PowerShell,
Android NDK for arm64-v8a/API 29, CMake, Ninja and the exact downloaded inputs.
For Alpine packages, use the locked `APKBUILD`, adjacent files and SHA-512
verified distfile with Alpine's `abuild` in an aarch64 build environment pinned
to the same aports revision. The source bundle supplies inputs and recipes;
it does not itself reproduce an Alpine build environment, compiler versions,
binary byte-for-byte comparison, or all installation information.

## Remaining release gates

Before any guest payload is shipped, review actual source-file license grants,
copyright and modification notices, the PRoot/talloc combination and
relinking route, Alpine package notices, build/install scripts, and the
specific distribution method. Compare rebuilt outputs with the candidate
binary and package set, then bind the reviewed source artifact to the **exact**
published APK and make recipients' source access concrete. Separately prove
guest execution, filesystem/network isolation and Android lifecycle behavior.
No script in this directory changes `distributionApproved: false`.
