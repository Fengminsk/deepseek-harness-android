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
    [string]$Aapt2Path = '',
    [string]$CandidateDir = '',
    [string]$WorkingDebugApkPath = '',
    [string]$WorkingAotApkPath = '',
    [string]$BrokenFlutterApkPath = ''
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

function Invoke-Verifier([string]$Path, [string]$VersionName = $ExpectedVersionName, [long]$VersionCode = $ExpectedVersionCode, [string]$RuntimeSha256 = '', [string]$FlutterMode = '') {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $verifier, '-ApkPath', $Path, '-ExpectedVersionName', $VersionName, '-ExpectedVersionCode', "$VersionCode")) {
        $start.ArgumentList.Add($argument)
    }
    if ($Aapt2Path) { $start.ArgumentList.Add('-Aapt2Path'); $start.ArgumentList.Add($Aapt2Path) }
    if ($RuntimeSha256) { $start.ArgumentList.Add('-ExpectedRuntimeSha256'); $start.ArgumentList.Add($RuntimeSha256) }
    if ($FlutterMode) { $start.ArgumentList.Add('-ExpectedFlutterBuildMode'); $start.ArgumentList.Add($FlutterMode) }
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
        foreach ($resource in $pinnedResources.GetEnumerator()) { Write-ZipEntry $zip $resource.Key $resource.Value }
        Write-ZipEntry $zip 'assets/runtime/runtime.zip' $runtimeBytes
        $checksum = if ($Mutation -eq 'checksum') { '0' * 64 } else { $runtimeHash }
        Write-ZipEntry $zip 'assets/runtime/runtime.sha256' ([Text.Encoding]::UTF8.GetBytes("$checksum`n"))
        $debug = $Mutation -notin @('no-flutter', 'aot', 'empty-aot', 'multi-abi-missing-aot')
        $aot = $Mutation -in @('aot', 'empty-aot', 'mixed-flutter', 'multi-abi-missing-aot')
        if ($debug) {
            foreach ($asset in @('kernel_blob.bin', 'vm_snapshot_data', 'isolate_snapshot_data')) {
                if ($Mutation -ceq "missing-$asset") { continue }
                $bytes = [byte[]]@(if ($asset -cne 'vm_snapshot_data' -and $Mutation -cne "empty-$asset") { 1; 2; 3; 4 })
                Write-ZipEntry $zip "assets/flutter_assets/$asset" $bytes
            }
        }
        $abis = if ($Mutation -in @('extra-abi', 'multi-abi-missing-aot')) { @('arm64-v8a', 'x86_64') } else { @('arm64-v8a') }
        foreach ($abi in $abis) {
            if ($aot -and -not ($Mutation -ceq 'multi-abi-missing-aot' -and $abi -ceq 'x86_64')) {
                $bytes = [byte[]]@(if ($Mutation -cne 'empty-aot') { 127; 69; 76; 70 })
                Write-ZipEntry $zip "lib/$abi/libapp.so" $bytes
            }
            if ($abi -cne 'arm64-v8a') { Write-ZipEntry $zip "lib/$abi/libpocket_ripgrep.so" ([byte[]]@(127, 69, 76, 70)) }
            foreach ($library in @('libflutter.so', 'libnode.so', 'libc++_shared.so', 'libdsh_runtime.so', 'libdsh_system.so', 'libpocket_file_publish.so', 'libpocket_ptc_script.so', 'libpocket_node_cli.so', 'libpocket_terminal_helper.so', 'libpocket_shell_supervisor.so', 'libpocket_require_builtin.so')) {
                if ($Mutation -eq 'missing-library' -and $library -eq 'libflutter.so') { continue }
                if ($Mutation -eq 'missing-terminal-helper' -and $library -eq 'libpocket_terminal_helper.so') { continue }
                if ($Mutation -eq 'missing-shell-supervisor' -and $library -eq 'libpocket_shell_supervisor.so') { continue }
                # Nonempty fixtures validate packaging, not native executable correctness.
                Write-ZipEntry $zip "lib/$abi/$library" ([byte[]]@(127, 69, 76, 70))
            }
        }
        if ($Mutation -eq 'guest-proot') { Write-ZipEntry $zip 'lib/arm64-v8a/libdsh_proot_candidate.so' ([byte[]]@(127, 69, 76, 70)) }
        if ($Mutation -eq 'guest-supervisor') { Write-ZipEntry $zip 'lib/arm64-v8a/libpocket_linux_guest_supervisor.so' ([byte[]]@(127, 69, 76, 70)) }
        if ($Mutation -eq 'guest-rootfs') { Write-ZipEntry $zip 'assets/guest/alpine-minirootfs-3.24.3-aarch64.tar.gz' ([byte[]]@(31, 139, 8, 0)) }
        if ($Mutation -eq 'vm-provider') { Write-ZipEntry $zip 'lib/arm64-v8a/libpocket_linux_vm.so' ([byte[]]@(127, 69, 76, 70)) }
        if ($Mutation -eq 'vm-assets') { Write-ZipEntry $zip 'assets/linux-vm/manifest.json' ([Text.Encoding]::UTF8.GetBytes('{}')) }
        if ($Mutation -eq 'guest-renamed-proot') { Write-ZipEntry $zip 'assets/guest/opaque.bin' $candidateProotBytes }
        if ($Mutation -eq 'guest-renamed-loader') { Write-ZipEntry $zip 'assets/guest/opaque-loader.bin' $candidateLoaderBytes }
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
    $candidateProotBytes = [byte[]]@()
    $candidateLoaderBytes = [byte[]]@()
    if ($CandidateDir) {
        $probePath = Join-Path $CandidateDir 'libdsh_proot_candidate.so'
        $loaderPath = Join-Path $CandidateDir 'libdsh_proot_loader_candidate.so'
        if ((Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                'c22cdb13c5de4b6e0022f7ede7a5ca0bf88675d4b674aa339a885b96d8b26f7f' -or
            (Get-FileHash -LiteralPath $loaderPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                'c5e85afb7599bd82f2419fb054d597514d5c9578954288bef0c5320cd8b63fbf') {
            throw 'CandidateDir does not contain the pinned ELF pair.'
        }
        $candidateProotBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $probePath).Path)
        $candidateLoaderBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $loaderPath).Path)
    }
    $manifestResources = @{}
    $pinnedResources = @{}
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
        # The pinned native ripgrep identity is checked by content hash, so a
        # valid synthetic APK must carry the actual bytes from the source APK.
        foreach ($name in @('lib/arm64-v8a/libpocket_ripgrep.so',
                'assets/licenses/ripgrep/NOTICE.txt', 'assets/licenses/ripgrep/COPYING',
                'assets/licenses/ripgrep/LICENSE-MIT', 'assets/licenses/ripgrep/UNLICENSE')) {
            $entry = $source.GetEntry($name)
            if ($null -eq $entry) { throw "The source APK lacks $name." }
            $input = $entry.Open()
            $buffer = [IO.MemoryStream]::new()
            try { $input.CopyTo($buffer); $pinnedResources[$name] = $buffer.ToArray() }
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
    if (-not $outcome.report.flutterDartPayload.complete -or $outcome.report.flutterDartPayload.kind -cne 'debug') { throw 'Debug payload was not recognized.' }
    $vm = @($outcome.report.flutterDartPayload.debugAssets | Where-Object { $_.path -ceq 'assets/flutter_assets/vm_snapshot_data' })
    if ($vm.Count -ne 1 -or -not $vm[0].present -or $vm[0].bytes -ne 0) { throw 'Legitimate empty VM snapshot was not retained.' }
    if ((Get-FileHash -LiteralPath $baseline -Algorithm SHA256).Hash -cne $beforeHash) { throw 'Verifier changed its input APK.' }
    $cases.Add(@{ name = 'valid APK with actual compiled Manifest and unchanged input'; passed = $true })
    foreach ($mode in @('debug')) {
        $selected = Invoke-Verifier $baseline -FlutterMode $mode
        if ($selected.exitCode -ne 0 -or -not $selected.report.success -or $selected.report.flutterDartPayload.expectedBuildMode -cne $mode) { throw 'Explicit Debug mode was rejected.' }
        $cases.Add(@{ name = 'explicit Debug accepts present empty VM snapshot'; passed = $true })
    }
    $aotFixture = New-Fixture 'misleading-debug-name' 'aot'
    foreach ($mode in @('', 'profile', 'release')) {
        $selected = Invoke-Verifier $aotFixture -FlutterMode $mode
        if ($selected.exitCode -ne 0 -or -not $selected.report.success -or $selected.report.flutterDartPayload.kind -cne 'aot') { throw "AOT payload rejected for '$mode': $($selected.report.errors -join '; ')" }
        $cases.Add(@{ name = "AOT payload accepted with optional mode '$mode' regardless of filename"; passed = $true })
    }
    Assert-Rejected 'Debug payload cannot satisfy Release mode' (Invoke-Verifier $baseline -FlutterMode 'release') 'Flutter Dart payload mode mismatch'
    Assert-Rejected 'Debug payload cannot satisfy Profile mode' (Invoke-Verifier $baseline -FlutterMode 'profile') 'Flutter Dart payload mode mismatch'
    Assert-Rejected 'AOT payload cannot satisfy Debug mode' (Invoke-Verifier $aotFixture -FlutterMode 'debug') 'Flutter Dart payload mode mismatch'
    Assert-Rejected 'invalid explicit Flutter mode' (Invoke-Verifier $baseline -FlutterMode 'production') 'ExpectedFlutterBuildMode must be'
    $noFlutter = New-Fixture 'no-flutter' 'no-flutter'
    Assert-Rejected 'no Dart payload fails automatic mode' (Invoke-Verifier $noFlutter) 'Flutter Dart payload is missing'
    Assert-Rejected 'no Dart payload fails Debug mode' (Invoke-Verifier $noFlutter -FlutterMode 'debug') 'Required Flutter Debug asset missing'
    Assert-Rejected 'Release requires libapp.so' (Invoke-Verifier $noFlutter -FlutterMode 'release') 'Required Flutter AOT library missing or empty'
    foreach ($asset in @('kernel_blob.bin', 'vm_snapshot_data', 'isolate_snapshot_data')) {
        Assert-Rejected "missing $asset" (Invoke-Verifier (New-Fixture "missing-$asset" "missing-$asset")) "Required Flutter Debug asset missing: assets/flutter_assets/$([regex]::Escape($asset))"
    }
    foreach ($asset in @('kernel_blob.bin', 'isolate_snapshot_data')) {
        Assert-Rejected "empty $asset" (Invoke-Verifier (New-Fixture "empty-$asset" "empty-$asset")) "Required Flutter Debug asset empty: assets/flutter_assets/$([regex]::Escape($asset))"
    }
    Assert-Rejected 'empty AOT image' (Invoke-Verifier (New-Fixture 'empty-aot' 'empty-aot')) 'Required Flutter AOT library missing or empty'
    Assert-Rejected 'AOT must cover every packaged ABI' (Invoke-Verifier (New-Fixture 'partial-aot' 'multi-abi-missing-aot')) 'Required Flutter AOT library missing or empty: lib/x86_64/libapp.so'
    Assert-Rejected 'mixed Debug and AOT payloads' (Invoke-Verifier (New-Fixture 'mixed-flutter' 'mixed-flutter')) 'Flutter Dart payload mixes Debug snapshots and AOT'
    Assert-Rejected 'runtime checksum mismatch' (Invoke-Verifier (New-Fixture 'bad-checksum' 'checksum')) 'Embedded runtime SHA256 mismatch'
    Assert-Rejected 'missing Flutter engine' (Invoke-Verifier (New-Fixture 'missing-library' 'missing-library')) 'Required native library.*libflutter\.so'
    Assert-Rejected 'missing terminal helper' (Invoke-Verifier (New-Fixture 'missing-terminal-helper' 'missing-terminal-helper')) 'Required native library.*libpocket_terminal_helper\.so'
    Assert-Rejected 'missing shell supervisor' (Invoke-Verifier (New-Fixture 'missing-shell-supervisor' 'missing-shell-supervisor')) 'Required native library.*libpocket_shell_supervisor\.so'
    Assert-Rejected 'unexpected ABI with complete native libraries' (Invoke-Verifier (New-Fixture 'extra-abi' 'extra-abi')) 'Unexpected ABI: x86_64'
    Assert-Rejected 'Manifest versionName mismatch' (Invoke-Verifier $baseline 'wrong-version') 'Version name mismatch'
    Assert-Rejected 'Manifest versionCode mismatch' (Invoke-Verifier $baseline $ExpectedVersionName ($ExpectedVersionCode + 1)) 'Version code mismatch'
    Assert-Rejected 'duplicate runtime checksum entry' (Invoke-Verifier (New-Fixture 'duplicate' 'duplicate')) 'Duplicate ZIP entry'
    Assert-Rejected 'unreviewed PRoot candidate' (Invoke-Verifier (New-Fixture 'guest-proot' 'guest-proot')) 'Linux guest payload is not approved'
    Assert-Rejected 'unreviewed guest supervisor' (Invoke-Verifier (New-Fixture 'guest-supervisor' 'guest-supervisor')) 'Linux guest payload is not approved'
    Assert-Rejected 'unreviewed Alpine rootfs' (Invoke-Verifier (New-Fixture 'guest-rootfs' 'guest-rootfs')) 'Linux guest payload is not approved'
    Assert-Rejected 'VM provider without candidate selection' (Invoke-Verifier (New-Fixture 'vm-provider' 'vm-provider')) 'explicit verified Alpine candidate'
    Assert-Rejected 'VM assets without candidate selection' (Invoke-Verifier (New-Fixture 'vm-assets' 'vm-assets')) 'explicit verified Alpine candidate'
    if ($CandidateDir) {
        Assert-Rejected 'renamed PRoot candidate' (Invoke-Verifier (New-Fixture 'guest-renamed-proot' 'guest-renamed-proot')) 'Linux guest payload is not approved'
        Assert-Rejected 'renamed PRoot loader' (Invoke-Verifier (New-Fixture 'guest-renamed-loader' 'guest-renamed-loader')) 'Linux guest payload is not approved'
    }
    $trusted = Invoke-Verifier $baseline $ExpectedVersionName $ExpectedVersionCode $runtimeHash
    if ($trusted.exitCode -ne 0 -or -not $trusted.report.success) { throw 'Matching trusted runtime digest was rejected.' }
    $cases.Add(@{ name = 'trusted runtime digest matches packaged runtime'; passed = $true })
    Assert-Rejected 'trusted runtime digest mismatch' (Invoke-Verifier $baseline $ExpectedVersionName $ExpectedVersionCode ('0' * 64)) 'Embedded runtime differs from the trusted build archive'
    # Real artifacts are read intact. Their independent version/Linux candidate
    # failures are reported separately and never reclassified as Flutter failures.
    foreach ($artifact in @(
        @{ path = $WorkingDebugApkPath; mode = 'debug'; kind = 'debug' },
        @{ path = $WorkingAotApkPath; mode = 'release'; kind = 'aot' }
    )) {
        if (-not $artifact.path) { continue }
        $actual = Invoke-Verifier $artifact.path -FlutterMode $artifact.mode
        if (-not $actual.report.flutterDartPayload.complete -or $actual.report.flutterDartPayload.kind -cne $artifact.kind) {
            throw "Actual $($artifact.kind) APK failed Flutter verification: $($actual.report.flutterDartPayload.errors -join '; ')"
        }
        $cases.Add(@{ name = "actual $($artifact.kind) APK Flutter payload"; passed = $true; apkSha256 = $actual.report.apk.sha256;
            flutterDartPayload = $actual.report.flutterDartPayload; fullApkAccepted = $actual.report.success; otherErrors = @($actual.report.errors) })
    }
    if ($BrokenFlutterApkPath) {
        $actual = Invoke-Verifier $BrokenFlutterApkPath
        Assert-Rejected 'actual missing-Dart APK fails' $actual 'Flutter Dart payload is missing'
        if ($actual.report.flutterDartPayload.complete -or $actual.report.flutterDartPayload.kind -cne 'missing') { throw 'Actual broken APK did not report its missing Dart payload.' }
    }
    @{ success = $true; cases = $cases.ToArray() } | ConvertTo-Json -Depth 8
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
