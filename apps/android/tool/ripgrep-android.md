# Android glob/grep runtime

The original DSH `@deepseek-ai/dsh-tool-fs-search` plugin supplies the Agent's
`glob` and `grep` tools. It uses `@vscode/ripgrep` on desktop; that dependency
does not contain an Android executable. The Android carrier resolves only that
package import to the pinned Android arm64 ripgrep build. The original tool
schemas, direct `argv` subprocess invocation, `--no-config`, output limits,
spill behavior, 30-second timeout, caller cancellation, and `SEARCH_*` error
classification remain in the original package.

The executable is ripgrep 15.0.0 from
[`BurntSushi/ripgrep`](https://github.com/BurntSushi/ripgrep), commit
`3a612f88b805e14aef45bfa43e25a54abc6297fc`. Its SHA-256 is pinned in
[`runtime-lock.json`](runtime-lock.json). The App includes the upstream
`COPYING`, `LICENSE-MIT`, and `UNLICENSE` plus an attribution notice under
`android/app/src/main/assets/licenses/ripgrep/`.

Build the binary from a **Visual Studio Developer PowerShell** with Rust 1.99.1
and Android NDK 28.2.13676358 installed:

```powershell
rustup toolchain install 1.99.1
rustup target add aarch64-linux-android --toolchain 1.99.1
./apps/android/tool/build-ripgrep.ps1 -NdkDirectory "$env:ANDROID_HOME/ndk/28.2.13676358"
```

The script clones the tagged upstream source into ignored `.cache/android`,
verifies its full commit and Cargo package version, compiles its locked Rust
dependencies for Android API 28 using the NDK linker, and compares the output
SHA-256 with the pinned value. It copies only the verified result to the
ignored `jniLibs/arm64-v8a/libpocket_ripgrep.so`. The `.so` suffix is for
Android's native-library installation and executable mount; the file is a PIE
process executable, not a JNI library. No binary is picked from `PATH`. The
source and toolchain must be fetched on a new build host, but the build does
not require untracked files from another developer's machine. Pass `-Proxy ''`
to use direct network access rather than the repository's default local proxy.

Run `stage-runtime.ts` **after** building this executable. Staging checks the
ELF architecture and pinned hash, then writes an identity descriptor beside
the Android module. `pack-runtime.ps1` rejects a missing or changed executable
or descriptor. Gradle packages the original bytes, and `verify-apk.ps1`
checks the APK's native library hash and upstream license assets. A failed
check blocks delivery; it must not be treated as search being available.

On the device, the binary can search only paths readable by the App UID, such
as the Session working directory and App-private files. Android SAF
`content://` documents need a materialized Session file before `glob` or
`grep` can search them. The search tools do not grant extra file permissions.
The current host test is:

```powershell
node --test apps/android/tool/ripgrep-android.test.mjs
```

An APK package check proves identity and inclusion, not successful Android
process launch or end-to-end Agent search. Those still require a device run.
