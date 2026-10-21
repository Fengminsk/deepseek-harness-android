param([string]$StagingDirectory = '', [string]$AssetsDirectory = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$repositoryRoot = (Resolve-Path (Join-Path $projectRoot '../..')).Path
$staging = if ($StagingDirectory) { (Resolve-Path -LiteralPath $StagingDirectory).Path } else { Join-Path $repositoryRoot '.cache/android/runtime-bundle' }
$assets = if ($AssetsDirectory) { [IO.Path]::GetFullPath($AssetsDirectory) } else { Join-Path $projectRoot 'android/app/src/main/assets/runtime' }
if (-not (Test-Path -LiteralPath (Join-Path $staging 'android/package-manager/packages.json')) -or
    -not (Test-Path -LiteralPath (Join-Path $staging 'android/package-manager/pnpm/bin/pnpm.mjs'))) {
    throw 'Bundled pnpm and local core packages are missing. Run stage-runtime.ts before packaging.'
}
New-Item -ItemType Directory -Force -Path $assets | Out-Null
$archive = Join-Path $assets 'runtime.zip'
$temporary = Join-Path $assets 'runtime.zip.partial'
Add-Type -AssemblyName System.IO.Compression
$file = [IO.File]::Open($temporary, [IO.FileMode]::Create)
$zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entry in Get-ChildItem -LiteralPath $staging -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($staging, $entry.FullName).Replace('\', '/')
        if ($relative -match '/(\.bin|test|tests|fixtures|coverage)/' -or $relative -match '\.(exe|dll|dylib|node|a|pdb|map|ts|tsbuildinfo)$') { continue }
        $target = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Fastest)
        $input = [IO.File]::OpenRead($entry.FullName)
        $output = $target.Open()
        try { $input.CopyTo($output) } finally { $input.Dispose(); $output.Dispose() }
    }
} finally { $zip.Dispose(); $file.Dispose() }
Move-Item -LiteralPath $temporary -Destination $archive -Force
$checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $assets 'runtime.sha256'), $checksum + "`n")
Write-Output "Runtime archive SHA256: $checksum"
Write-Output "Runtime archive bytes: $((Get-Item -LiteralPath $archive).Length)"
