param(
    [string]$Proxy = 'http://127.0.0.1:7897',
    [string]$NdkDirectory = '',
    [string]$SourceDirectory = '',
    [string]$Cargo = 'cargo',
    [string]$Rustc = 'rustc',
    [string]$Toolchain = '1.99.1'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$repositoryRoot = (Resolve-Path (Join-Path $projectRoot '../..')).Path
if ($Proxy) {
    $env:HTTP_PROXY = $Proxy
    $env:HTTPS_PROXY = $Proxy
}
$lock = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime-lock.json') -Raw | ConvertFrom-Json).ripgrep
if ($lock.version -cne '15.0.0' -or $lock.abi -cne 'arm64-v8a' -or
    $lock.target -cne 'aarch64-linux-android' -or
    $lock.revision -cne '3a612f88b805e14aef45bfa43e25a54abc6297fc' -or
    $lock.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Pinned ripgrep identity is invalid.' }

if (-not $NdkDirectory) {
    if ($env:ANDROID_NDK_HOME) { $NdkDirectory = $env:ANDROID_NDK_HOME }
    elseif ($env:ANDROID_HOME) { $NdkDirectory = Join-Path $env:ANDROID_HOME 'ndk/28.2.13676358' }
    elseif ($env:ANDROID_SDK_ROOT) { $NdkDirectory = Join-Path $env:ANDROID_SDK_ROOT 'ndk/28.2.13676358' }
    else { throw 'Set ANDROID_HOME or pass -NdkDirectory for NDK 28.2.13676358.' }
}
$ndkProperties = Join-Path $NdkDirectory 'source.properties'
if (-not (Test-Path -LiteralPath $ndkProperties) -or
    (Get-Content -LiteralPath $ndkProperties -Raw) -notmatch 'Pkg\.Revision\s*=\s*28\.2\.13676358') {
    throw 'Android NDK 28.2.13676358 is required.'
}
$llvm = Join-Path $NdkDirectory 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$clang = Join-Path $llvm 'aarch64-linux-android28-clang.cmd'
$archiver = Join-Path $llvm 'llvm-ar.exe'
if (-not (Test-Path -LiteralPath $clang) -or -not (Test-Path -LiteralPath $archiver)) {
    throw 'Android ARM64 compiler or archiver is missing from the NDK.'
}
if (-not $SourceDirectory) {
    $SourceDirectory = Join-Path $repositoryRoot '.cache/android/toolchains/ripgrep-src'
}
if (-not (Test-Path -LiteralPath $SourceDirectory)) {
    [void][IO.Directory]::CreateDirectory((Split-Path $SourceDirectory -Parent))
    if ($Proxy) { & git -c "http.proxy=$Proxy" clone --branch $lock.version --depth 1 https://github.com/BurntSushi/ripgrep.git $SourceDirectory }
    else { & git clone --branch $lock.version --depth 1 https://github.com/BurntSushi/ripgrep.git $SourceDirectory }
    if ($LASTEXITCODE -ne 0) { throw 'Pinned ripgrep source download failed.' }
}
$revision = (& git -C $SourceDirectory rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $revision -cne $lock.revision) {
    throw "Ripgrep source revision does not match runtime-lock.json: $revision"
}
$manifest = Get-Content -LiteralPath (Join-Path $SourceDirectory 'Cargo.toml') -Raw
if ($manifest -notmatch '(?m)^name\s*=\s*"ripgrep"\s*$' -or
    $manifest -notmatch '(?m)^version\s*=\s*"15\.0\.0"(?:\s|$)') {
    throw 'Pinned ripgrep source does not declare the expected package version.'
}
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $clang
$env:CC_aarch64_linux_android = $clang
$env:AR_aarch64_linux_android = $archiver
$env:CARGO_TARGET_DIR = Join-Path $repositoryRoot '.cache/android/toolchains/ripgrep-target'
if (Test-Path -LiteralPath $Cargo -PathType Leaf) { $Cargo = (Resolve-Path -LiteralPath $Cargo).Path }
if (Test-Path -LiteralPath $Rustc -PathType Leaf) { $Rustc = (Resolve-Path -LiteralPath $Rustc).Path }
$rustVersion = & $Rustc "+$Toolchain" --version
if ($LASTEXITCODE -ne 0 -or $rustVersion -notmatch '^rustc 1\.99\.1 \(') {
    throw "Rust 1.99.1 is required for the pinned Android ripgrep build: $rustVersion"
}
Push-Location $SourceDirectory
try {
    & $Cargo "+$Toolchain" build --locked --target aarch64-linux-android --profile release-lto
    if ($LASTEXITCODE -ne 0) { throw 'Android ARM64 ripgrep compilation failed.' }
} finally { Pop-Location }
$built = Join-Path $env:CARGO_TARGET_DIR 'aarch64-linux-android/release-lto/rg'
$actualHash = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -cne $lock.sha256) {
    throw "Android ripgrep build is not byte-for-byte reproducible with the pinned toolchain: $actualHash"
}
$destinationDirectory = Join-Path $projectRoot 'android/app/src/main/jniLibs/arm64-v8a'
New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
$destination = Join-Path $destinationDirectory 'libpocket_ripgrep.so'
Copy-Item -LiteralPath $built -Destination $destination -Force
if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lock.sha256) {
    throw 'Copied Android ripgrep checksum mismatch.'
}
Write-Output "Verified Android ripgrep $($lock.version) ($($lock.abi)): $actualHash"
