param([string]$Proxy = 'http://127.0.0.1:7897')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$repositoryRoot = (Resolve-Path (Join-Path $projectRoot '../..')).Path
$runtimeLock = Get-Content (Join-Path $PSScriptRoot 'runtime-lock.json') -Raw | ConvertFrom-Json
$cacheDirectory = Join-Path $repositoryRoot '.cache/android'
$archivePath = Join-Path $cacheDirectory "nodejs-mobile-android-$($runtimeLock.node.mobileVersion).zip"
$runtimeDirectory = Join-Path $cacheDirectory "nodejs-mobile-$($runtimeLock.node.mobileVersion)"
New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null
if (-not (Test-Path -LiteralPath $archivePath)) {
    & curl.exe --fail --location --silent --show-error --proxy $Proxy $runtimeLock.node.url --output $archivePath
    if ($LASTEXITCODE -ne 0) { throw 'Android Node runtime download failed.' }
}
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $runtimeLock.node.sha256) {
    throw "Android Node archive checksum mismatch: $actualHash"
}
if (-not (Test-Path -LiteralPath $runtimeDirectory)) {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $runtimeDirectory
}
$nativeDestination = Join-Path $projectRoot 'android/app/src/main/jniLibs/arm64-v8a'
$builtinDirectory = Join-Path $repositoryRoot '.cache/references/require-builtin'
if (-not (Test-Path -LiteralPath $builtinDirectory)) {
    & git -c "http.proxy=$Proxy" clone --no-checkout $runtimeLock.requireBuiltin.repository $builtinDirectory
    if ($LASTEXITCODE -ne 0) { throw 'require-builtin source download failed.' }
    & git -C $builtinDirectory checkout --detach $runtimeLock.requireBuiltin.revision
    if ($LASTEXITCODE -ne 0) { throw 'require-builtin source checkout failed.' }
}
$builtinRevision = & git -C $builtinDirectory rev-parse HEAD
if ($builtinRevision -ne $runtimeLock.requireBuiltin.revision) { throw 'require-builtin source revision does not match runtime-lock.json' }
$addonArchive = Join-Path $cacheDirectory "node-addon-api-$($runtimeLock.nodeAddonApi.version).tgz"
$addonDirectory = Join-Path $cacheDirectory "node-addon-api-$($runtimeLock.nodeAddonApi.version)"
if (-not (Test-Path -LiteralPath $addonArchive)) {
    & curl.exe --fail --location --silent --show-error --proxy $Proxy $runtimeLock.nodeAddonApi.url --output $addonArchive
    if ($LASTEXITCODE -ne 0) { throw 'node-addon-api header download failed.' }
}
if ((Get-FileHash -LiteralPath $addonArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtimeLock.nodeAddonApi.sha256) {
    throw 'node-addon-api header archive checksum mismatch.'
}
if (-not (Test-Path -LiteralPath (Join-Path $addonDirectory 'napi.h'))) {
    New-Item -ItemType Directory -Force -Path $addonDirectory | Out-Null
    & tar -xzf $addonArchive -C $addonDirectory --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw 'node-addon-api header extraction failed.' }
}
New-Item -ItemType Directory -Force -Path $nativeDestination | Out-Null
Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'bin/arm64-v8a/libnode.so') -Destination $nativeDestination
Write-Output "Verified Android Node $($runtimeLock.node.mobileVersion): $actualHash"
