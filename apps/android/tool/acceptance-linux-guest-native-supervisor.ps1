param(
    [Parameter(Mandatory = $true)][string]$NdkRoot,
    [string]$Apk,
    [string]$LauncherCandidate,
    [string]$LoaderCandidate
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$source = Join-Path $repo 'apps/android/android/app/src/main/cpp/linux_guest_supervisor.c'
$childrenSource = Join-Path $repo 'apps/android/android/app/src/main/cpp/linux_guest_children.c'
$shaCore = Join-Path $repo 'apps/android/android/app/src/main/cpp/linux_guest_sha256_core.c'
$wasmStubs = Join-Path $repo 'apps/android/tool/linux-guest-sha256-wasm-stubs.c'
$shaTest = Join-Path $repo 'apps/android/tool/acceptance-linux-guest-sha256.mjs'
$childrenTest = Join-Path $repo 'apps/android/tool/acceptance-linux-guest-children.mjs'
$cmake = Join-Path $repo 'apps/android/android/app/src/main/cpp/CMakeLists.txt'
$outputRoot = Join-Path $repo 'apps/android/.cache/native-supervisor-acceptance'
$compiler = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android28-clang.cmd'
$llvm = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe'
$readelf = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf) -or
    -not (Test-Path -LiteralPath $llvm -PathType Leaf) -or
    -not (Test-Path -LiteralPath $readelf -PathType Leaf)) {
    throw 'Android NDK compiler/readelf unavailable'
}
$cmakeText = Get-Content -LiteralPath $cmake -Raw
$sourceText = Get-Content -LiteralPath $source -Raw
if ($cmakeText -notmatch 'option\(DSH_BUILD_LINUX_GUEST_SUPERVISOR\s+"[^"]+"\s+OFF\)' -or
    $cmakeText -notmatch 'if\(DSH_BUILD_LINUX_GUEST_SUPERVISOR\)\s+add_executable\(pocket_linux_guest_supervisor\s+EXCLUDE_FROM_ALL\s+linux_guest_supervisor\.c\s+linux_guest_sha256_core\.c\s+linux_guest_children\.c\)') {
    throw 'Native supervisor must remain an explicit, default-off CMake target'
}
if ($sourceText -notmatch 'pinned_fd\(primary,' -or
    $sourceText -notmatch 'pinned_fd\(secondary,' -or
    $sourceText -notmatch 'PROOT_LOADER=/proc/self/fd/6') {
    throw 'Candidate launcher and loader must be pinned from their opened descriptors'
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$binary = Join-Path $outputRoot 'libpocket_linux_guest_supervisor.so'
& $compiler '-std=c11' '-Wall' '-Wextra' '-Werror' '-fPIE' '-pie' '-Wl,-z,max-page-size=16384' $source $shaCore $childrenSource '-o' $binary
if ($LASTEXITCODE -ne 0) { throw "Android NDK link failed: $LASTEXITCODE" }
$headers = (& $readelf '-h' '-l' $binary) -join "`n"
if ($LASTEXITCODE -ne 0 -or $headers -notmatch 'Machine:\s+AArch64' -or
    $headers -notmatch 'Type:\s+DYN' -or
    $headers -notmatch '/system/bin/linker64' -or
    $headers -notmatch '0x4000') {
    throw 'Native supervisor ELF is not the expected ARM64 Android PIE with 16 KiB load alignment'
}
$wasm = Join-Path $outputRoot 'linux_guest_sha256_core.wasm'
& $llvm '--target=wasm32' '-O0' '-fno-builtin' '-nostdlib' '-Wl,--no-entry' '-Wl,--export=dsh_guest_sha256' '-Wl,--export-memory' '-Wl,--initial-memory=8388608' $shaCore $wasmStubs '-o' $wasm
if ($LASTEXITCODE -ne 0) { throw "SHA-256 WASM host build failed: $LASTEXITCODE" }
$childrenWasm = Join-Path $outputRoot 'linux_guest_children.wasm'
& $llvm '--target=wasm32' '-O0' '-fno-builtin' '-nostdlib' '-Wl,--no-entry' '-Wl,--export=dsh_parse_direct_children' '-Wl,--export-memory' '-Wl,--initial-memory=131072' $childrenSource '-o' $childrenWasm
if ($LASTEXITCODE -ne 0) { throw "Direct-child parser WASM host build failed: $LASTEXITCODE" }
& node $childrenTest $childrenWasm
if ($LASTEXITCODE -ne 0) { throw 'Direct-child parser vectors failed' }
if (-not $LauncherCandidate) {
    $LauncherCandidate = Join-Path $repo '.cache/android/linux-proot-source/build-arm64-v8a/libdsh_proot_candidate.so'
}
if (-not $LoaderCandidate) {
    $LoaderCandidate = Join-Path $repo '.cache/android/linux-proot-source/build-arm64-v8a/libdsh_proot_loader_candidate.so'
}
& node $shaTest $wasm $LauncherCandidate $LoaderCandidate
if ($LASTEXITCODE -ne 0) { throw 'SHA-256 vectors or candidate ELF digest verification failed' }
if ($Apk) {
    Add-Type -AssemblyName System.IO.Compression
    $resolvedApk = (Resolve-Path -LiteralPath $Apk).Path
    $archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedApk)
    try {
        if (@($archive.Entries | Where-Object { $_.FullName -match '(^|/)libpocket_linux_guest_supervisor\.so$' }).Count -ne 0) {
            throw 'Default APK unexpectedly packages the Linux guest native supervisor'
        }
    } finally { $archive.Dispose() }
}
Write-Output 'Linux guest native supervisor source/ELF/hash gate PASS; no device execution was attempted'
