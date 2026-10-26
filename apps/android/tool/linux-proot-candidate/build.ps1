param(
    [string]$SourceCache = (Join-Path $PSScriptRoot '..\..\..\..\.cache\android\linux-proot-source'),
    [string]$SdkRoot = '',
    [switch]$Fetch
)

$ErrorActionPreference = 'Stop'
$SourceCache = [IO.Path]::GetFullPath($SourceCache)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
if (-not $SourceCache.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SourceCache must remain inside this repository'
}
if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    $localProperties = Join-Path $PSScriptRoot '..\..\android\local.properties'
    if (-not (Test-Path $localProperties)) { throw 'Pass -SdkRoot or configure android/local.properties' }
    $sdkLine = Get-Content $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
    if (-not $sdkLine) { throw 'Android SDK directory is not configured' }
    # Flutter writes Java-properties escapes such as C\:/ and C:\\Users.
    $SdkRoot = (($sdkLine -replace '^sdk\.dir=', '').Replace('\:', ':')).Replace('\\', '\')
}
$SdkRoot = [IO.Path]::GetFullPath($SdkRoot)

$sources = @(
    @{ Name='PRoot'; File='v5.1.107.96.zip'; Url='https://github.com/termux/proot/archive/v5.1.107.96.zip'; Sha='75f654fe60dea92dabff2bf083ae8bfe4f91baa6a1a374786a6bf391015eebaa'; Folder='proot-5.1.107.96' },
    @{ Name='talloc'; File='talloc-2.4.3.tar.gz'; Url='https://ftp.samba.org/pub/talloc/talloc-2.4.3.tar.gz'; Sha='dc46c40b9f46bb34dd97fe41f548b0e8b247b77a918576733c528e83abd854dd'; Folder='talloc-2.4.3' },
    @{ Name='libandroid-shmem'; File='libandroid-shmem-v0.7.tar.gz'; Url='https://github.com/termux/libandroid-shmem/archive/refs/tags/v0.7.tar.gz'; Sha='1e5ff8459bc0a8c229dd8a94b27d119987e09ef3414331c2b5ebfff20b98e867'; Folder='libandroid-shmem-0.7' }
)
New-Item -ItemType Directory -Path $SourceCache -Force | Out-Null
if (((Get-Item -LiteralPath $SourceCache -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Refusing a reparse-point source cache'
}
foreach ($source in $sources) {
    $archive = Join-Path $SourceCache $source.File
    if (-not (Test-Path -LiteralPath $archive)) {
        if (-not $Fetch) { throw "$($source.Name) source missing: $archive (use -Fetch to download)" }
        Invoke-WebRequest -Uri $source.Url -OutFile $archive -TimeoutSec 120
    }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $source.Sha) { throw "$($source.Name) source SHA-256 mismatch: $actual" }
}

$extracted = Join-Path $SourceCache 'verified-extracted'
$marker = Join-Path $extracted '.dsh-proot-candidate-staging'
if (Test-Path -LiteralPath $extracted) {
    $resolved = [IO.Path]::GetFullPath($extracted)
    if (-not $resolved.StartsWith($SourceCache + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $marker) -or
        (((Get-Item -LiteralPath $extracted -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Refusing to replace an unowned source directory: $extracted"
    }
    Remove-Item -LiteralPath $extracted -Recurse -Force
}
New-Item -ItemType Directory -Path $extracted -Force | Out-Null
[IO.File]::WriteAllText($marker, 'Only this build script owns this extracted source staging directory.')
foreach ($source in $sources) {
    $folder = Join-Path $extracted $source.Folder
    $archive = Join-Path $SourceCache $source.File
    if ($source.File.EndsWith('.zip')) { Expand-Archive -LiteralPath $archive -DestinationPath $extracted }
    else { & tar -xf $archive -C $extracted; if ($LASTEXITCODE -ne 0) { throw "tar failed for $archive" } }
    if (-not (Test-Path $folder)) { throw "Expected source tree missing: $folder" }
}
& python (Join-Path $PSScriptRoot 'patch-proot-events.py') (Join-Path $extracted 'proot-5.1.107.96')
if ($LASTEXITCODE -ne 0) { throw 'Versioned PRoot tracee event patch failed' }
& python (Join-Path $PSScriptRoot 'patch-shmem-private.py') (Join-Path $extracted 'proot-5.1.107.96') (Join-Path $extracted 'libandroid-shmem-0.7')
if ($LASTEXITCODE -ne 0) { throw 'Private-key shared memory source patch failed' }

$cmakeRoot = Join-Path $SdkRoot 'cmake\3.22.1\bin'
$cmake = Join-Path $cmakeRoot 'cmake.exe'
$ninja = Join-Path $cmakeRoot 'ninja.exe'
$ndk = Join-Path $SdkRoot 'ndk\28.2.13676358'
foreach ($tool in @($cmake, $ninja, (Join-Path $ndk 'build\cmake\android.toolchain.cmake'))) {
    if (-not (Test-Path $tool)) { throw "Required Android build tool missing: $tool" }
}
$build = Join-Path $SourceCache 'build-arm64-v8a'
$cmakePath = { param($value) $value.Replace('\', '/') }
& $cmake -S $PSScriptRoot -B $build -G Ninja "-DCMAKE_MAKE_PROGRAM=$(& $cmakePath $ninja)" "-DCMAKE_TOOLCHAIN_FILE=$(& $cmakePath (Join-Path $ndk 'build\cmake\android.toolchain.cmake'))" '-DANDROID_ABI=arm64-v8a' '-DANDROID_PLATFORM=android-29' "-DPROOT_SOURCE=$(& $cmakePath (Join-Path $extracted 'proot-5.1.107.96'))" "-DTALLOC_SOURCE=$(& $cmakePath (Join-Path $extracted 'talloc-2.4.3'))" "-DSHMEM_SOURCE=$(& $cmakePath (Join-Path $extracted 'libandroid-shmem-0.7'))"
if ($LASTEXITCODE -ne 0) { throw 'PRoot candidate configure failed' }
& $cmake --build $build --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'PRoot candidate build failed' }
Write-Output "Candidate outputs only: $build"
