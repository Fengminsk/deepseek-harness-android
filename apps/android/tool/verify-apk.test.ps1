#requires -Version 7.0
<##
Integration tests using a real APK's compiled Manifest/resources and small,
synthetic ZIP payloads. The source APK is only read and never extracted.
Requires an SDK aapt2 executable; invokes the verifier as a separate process.
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceApkPath,
    [Parameter(Mandatory)][string]$ExpectedVersionName,
    [Parameter(Mandatory)][long]$ExpectedVersionCode,
    [string]$Aapt2Path = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$verifier = Join-Path $PSScriptRoot 'verify-apk.ps1'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$testParent = Join-Path $repositoryRoot '.cache/android'
[void][IO.Directory]::CreateDirectory($testParent)
$testRoot = Join-Path $testParent ('apk-verifier-test-' + [Guid]::NewGuid().ToString('N'))
# A unique CreateNew sentinel makes ownership explicit before creating fixtures.
[void][IO.Directory]::CreateDirectory($testRoot)
$owner = [IO.File]::Open((Join-Path $testRoot '.owner'), [IO.FileMode]::CreateNew)
$owner.Dispose()
$cases = [Collections.Generic.List[object]]::new()

function Invoke-Verifier([string]$Path, [string]$VersionName = $ExpectedVersionName, [long]$VersionCode = $ExpectedVersionCode) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $verifier, '-ApkPath', $Path, '-ExpectedVersionName', $VersionName, '-ExpectedVersionCode', "$VersionCode")) {
        $start.ArgumentList.Add($argument)
    }
    if ($Aapt2Path) { $start.ArgumentList.Add('-Aapt2Path'); $start.ArgumentList.Add($Aapt2Path) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Verifier test subprocess exceeded 60 seconds.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $diagnostic = $stderr.GetAwaiter().GetResult()
        if ($diagnostic.Trim()) { throw "Verifier emitted stderr: $diagnostic" }
        return @{ exitCode = $process.ExitCode; report = ($output | ConvertFrom-Json) }
    } finally { $process.Dispose() }
}

function Write-ZipEntry([IO.Compression.ZipArchive]$Zip, [string]$Name, [byte[]]$Bytes) {
    $entry = $Zip.CreateEntry($Name, [IO.Compression.CompressionLevel]::Fastest)
    $stream = $entry.Open()
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}

function New-Fixture([string]$Name, [string]$Mutation = '') {
    $path = Join-Path $testRoot "$Name.apk"
    $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew)
    $zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($metadata in $manifestResources.GetEnumerator()) { Write-ZipEntry $zip $metadata.Key $metadata.Value }
        Write-ZipEntry $zip 'assets/runtime/runtime.zip' $runtimeBytes
        $checksum = if ($Mutation -eq 'checksum') { '0' * 64 } else { $runtimeHash }
        Write-ZipEntry $zip 'assets/runtime/runtime.sha256' ([Text.Encoding]::UTF8.GetBytes("$checksum`n"))
        $abis = if ($Mutation -eq 'extra-abi') { @('arm64-v8a', 'x86_64') } else { @('arm64-v8a') }
        foreach ($abi in $abis) {
            foreach ($library in @('libflutter.so', 'libnode.so', 'libc++_shared.so', 'libdsh_runtime.so', 'libdsh_system.so', 'libpocket_file_publish.so', 'libpocket_node_cli.so', 'libpocket_require_builtin.so')) {
                if ($Mutation -eq 'missing-library' -and $library -eq 'libflutter.so') { continue }
                # Nonempty fixtures validate packaging, not native executable correctness.
                Write-ZipEntry $zip "lib/$abi/$library" ([byte[]]@(127, 69, 76, 70))
            }
        }
        if ($Mutation -eq 'duplicate') { Write-ZipEntry $zip 'assets/runtime/runtime.sha256' ([Text.Encoding]::UTF8.GetBytes($runtimeHash)) }
    } finally { $zip.Dispose(); $file.Dispose() }
    return $path
}

function Assert-Rejected([string]$Name, [hashtable]$Outcome, [string]$ErrorPattern) {
    if ($Outcome.exitCode -eq 0 -or $Outcome.report.success) { throw "$Name was incorrectly accepted." }
    if (-not (@($Outcome.report.errors) -match $ErrorPattern)) { throw "$Name did not report its specific failure: $($Outcome.report.errors -join '; ')" }
    $cases.Add(@{ name = $Name; passed = $true })
}

try {
    $manifestResources = @{}
    $source = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $SourceApkPath).Path)
    try {
        foreach ($name in @('AndroidManifest.xml', 'resources.arsc')) {
            $entry = $source.GetEntry($name)
            if ($null -eq $entry) { throw "The source APK lacks $name." }
            $input = $entry.Open()
            $buffer = [IO.MemoryStream]::new()
            try { $input.CopyTo($buffer); $manifestResources[$name] = $buffer.ToArray() }
            finally { $input.Dispose(); $buffer.Dispose() }
        }
    } finally { $source.Dispose() }

    $runtimeBuffer = [IO.MemoryStream]::new()
    $runtimeZip = [IO.Compression.ZipArchive]::new($runtimeBuffer, [IO.Compression.ZipArchiveMode]::Create, $true)
    try { Write-ZipEntry $runtimeZip 'index.js' ([Text.Encoding]::UTF8.GetBytes('export {};')) }
    finally { $runtimeZip.Dispose() }
    $runtimeBytes = $runtimeBuffer.ToArray()
    $runtimeBuffer.Dispose()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $runtimeHash = [BitConverter]::ToString($sha.ComputeHash($runtimeBytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }

    $baseline = New-Fixture 'valid'
    $beforeHash = (Get-FileHash -LiteralPath $baseline -Algorithm SHA256).Hash
    $outcome = Invoke-Verifier $baseline
    if ($outcome.exitCode -ne 0 -or -not $outcome.report.success) { throw "Valid fixture rejected: $($outcome.report.errors -join '; ')" }
    if ($outcome.report.manifest.versionCode -ne $ExpectedVersionCode -or $outcome.report.manifest.versionName -cne $ExpectedVersionName -or -not $outcome.report.manifest.label) { throw 'Manifest evidence is incomplete.' }
    if ($outcome.report.runtime.sha256 -cne $runtimeHash) { throw 'Runtime hash did not identify the nested ZIP bytes.' }
    if ((Get-FileHash -LiteralPath $baseline -Algorithm SHA256).Hash -cne $beforeHash) { throw 'Verifier changed its input APK.' }
    $cases.Add(@{ name = 'valid APK with actual compiled Manifest and unchanged input'; passed = $true })
    Assert-Rejected 'runtime checksum mismatch' (Invoke-Verifier (New-Fixture 'bad-checksum' 'checksum')) 'Embedded runtime SHA256 mismatch'
    Assert-Rejected 'missing Flutter engine' (Invoke-Verifier (New-Fixture 'missing-library' 'missing-library')) 'Required native library.*libflutter\.so'
    Assert-Rejected 'unexpected ABI with complete native libraries' (Invoke-Verifier (New-Fixture 'extra-abi' 'extra-abi')) 'Unexpected ABI: x86_64'
    Assert-Rejected 'Manifest versionName mismatch' (Invoke-Verifier $baseline 'wrong-version') 'Version name mismatch'
    Assert-Rejected 'Manifest versionCode mismatch' (Invoke-Verifier $baseline $ExpectedVersionName ($ExpectedVersionCode + 1)) 'Version code mismatch'
    Assert-Rejected 'duplicate runtime checksum entry' (Invoke-Verifier (New-Fixture 'duplicate' 'duplicate')) 'Duplicate ZIP entry'
    @{ success = $true; cases = $cases.ToArray() } | ConvertTo-Json -Depth 5
} finally {
    # Only remove this invocation's uniquely owned fixture directory.
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $allowedParent = [IO.Path]::GetFullPath($testParent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath (Join-Path $resolvedRoot '.owner') -PathType Leaf)) {
        throw 'Refusing to clean a test directory outside the owned fixture root.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
