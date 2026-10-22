param([string]$StagingDirectory = '', [string]$AssetsDirectory = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$repositoryRoot = (Resolve-Path (Join-Path $projectRoot '../..')).Path
$staging = if ($StagingDirectory) { (Resolve-Path -LiteralPath $StagingDirectory).Path } else { Join-Path $repositoryRoot '.cache/android/runtime-bundle' }
$assets = if ($AssetsDirectory) { [IO.Path]::GetFullPath($AssetsDirectory) } else { Join-Path $projectRoot 'android/app/src/main/assets/runtime' }
# Build from the same original client artifacts used by the repository Web app.
# This is a document-only packaged surface, independent of the Web listener.
& node (Join-Path $PSScriptRoot 'build-document-preview.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Document preview build failed; APK assets were not updated.' }
$previewSource = Join-Path $repositoryRoot '.cache/android/document-preview'
$previewTarget = Join-Path (Split-Path $assets -Parent) 'document-preview'
$previewManifest = Get-Content -LiteralPath (Join-Path $previewSource 'asset-manifest.json') -Raw | ConvertFrom-Json
if (-not $previewManifest.assets -or $previewManifest.composition -ne 'document-only') { throw 'Document asset inventory is missing.' }
# Replace only this generated asset directory so old renderer chunks cannot
# survive a new inventory. Reject links before deleting or copying any files.
$assetRoot = [IO.Path]::GetFullPath((Split-Path $assets -Parent))
$previewTarget = [IO.Path]::GetFullPath($previewTarget)
if ($previewTarget -ne (Join-Path $assetRoot 'document-preview')) { throw 'Invalid document asset output directory.' }
$cursor = $previewTarget
while ($cursor) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Document asset output cannot contain symbolic links.'
    }
    $cursor = Split-Path $cursor -Parent
}
foreach ($asset in $previewManifest.assets) {
    if ($asset.path -match '(^/|\\|(^|/)\.\.?(/|$)|:)' -or -not $asset.path) { throw 'Invalid document asset path.' }
    $source = Join-Path $previewSource $asset.path
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset.sha256) { throw 'Document asset changed during packaging.' }
}
if (Test-Path -LiteralPath $previewTarget) {
    if ((Resolve-Path -LiteralPath $previewTarget).Path -ne (Join-Path $assetRoot 'document-preview')) { throw 'Document asset output resolved outside the intended directory.' }
    if (Get-ChildItem -LiteralPath $previewTarget -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Document assets contain symbolic links.' }
    Remove-Item -LiteralPath $previewTarget -Recurse -Force
}
foreach ($asset in $previewManifest.assets) {
    $source = Join-Path $previewSource $asset.path
    $target = Join-Path $previewTarget $asset.path
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $source -Destination $target -Force
}
Copy-Item -LiteralPath (Join-Path $previewSource 'asset-manifest.json') -Destination (Join-Path $previewTarget 'asset-manifest.json') -Force
if (-not (Test-Path -LiteralPath (Join-Path $staging 'android/package-manager/packages.json')) -or
    -not (Test-Path -LiteralPath (Join-Path $staging 'android/package-manager/pnpm/bin/pnpm.mjs'))) {
    throw 'Bundled pnpm and local core packages are missing. Run stage-runtime.ts before packaging.'
}
if (-not (Test-Path -LiteralPath (Join-Path $staging 'android/image-runtime.json'))) {
    throw 'Official Sharp WASM runtime is missing. Run stage-runtime.ts before packaging.'
}
$imageRuntime = Get-Content -LiteralPath (Join-Path $staging 'android/image-runtime.json') -Raw | ConvertFrom-Json
if ($imageRuntime.sharp -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid staged Sharp version.' }
foreach ($suffix in @('js', 'wasm')) {
    $codec = Join-Path $staging "node_modules/@img/sharp-wasm32/lib/sharp-wasm32-$($imageRuntime.sharp).node.$suffix"
    if (-not (Test-Path -LiteralPath $codec -PathType Leaf) -or (Get-Item -LiteralPath $codec).Length -eq 0) {
        throw "Sharp WASM payload is missing or empty: $suffix"
    }
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
