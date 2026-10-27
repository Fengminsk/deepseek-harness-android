#requires -Version 7.0
<##
Read-only delivery gate. Manifest metadata comes from aapt2, not Gradle outputs.
Example: ./verify-apk.ps1 -ApkPath app.apk -ExpectedVersionName 0.1.0 -ExpectedVersionCode 19
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApkPath,
    [Parameter(Mandatory)][string]$ExpectedVersionName,
    [Parameter(Mandatory)][long]$ExpectedVersionCode,
    [string[]]$ExpectedAbi = @('arm64-v8a'),
    [string]$ExpectedPackageName = 'com.minnnng.dsh_android',
    [string]$ExpectedRuntimeSha256 = '',
    [string]$ExpectedPackagedLinuxUtilitySha256 = '',
    [string]$ExpectedLinuxCandidate = '',
    [string]$ExpectedLinuxCandidateSha256 = '',
    [string]$ExpectedLinuxNativeLibrary = '',
    [string]$PythonPath = 'python',
    [string]$Aapt2Path = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$failures = [Collections.Generic.List[string]]::new()
$requiredLibraries = @(
    'libflutter.so', 'libnode.so', 'libc++_shared.so',
    'libdsh_runtime.so', 'libdsh_system.so', 'libpocket_file_publish.so',
    'libpocket_ptc_script.so',
    'libpocket_node_cli.so', 'libpocket_terminal_helper.so', 'libpocket_shell_supervisor.so',
    'libpocket_require_builtin.so', 'libpocket_ripgrep.so'
)
$result = [ordered]@{
    schemaVersion = 1
    success = $false
    apk = $null
    manifest = $null
    abi = [ordered]@{ expected = @($ExpectedAbi); actual = @(); requiredLibraries = $requiredLibraries; libraries = @{} }
    runtime = $null
    linuxGuestPayload = [ordered]@{ present = $false; entries = @() }
    linuxVmCandidate = $null
    aapt2 = $null
    errors = @()
}

function Resolve-Aapt2 {
    if ($Aapt2Path) {
        if (-not (Test-Path -LiteralPath $Aapt2Path -PathType Leaf)) { throw 'The specified aapt2 executable does not exist.' }
        return (Resolve-Path -LiteralPath $Aapt2Path).Path
    }
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($sdkRoot in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if ($sdkRoot) { $roots.Add($sdkRoot) }
    }
    $properties = Join-Path (Split-Path $PSScriptRoot -Parent) 'android/local.properties'
    if (Test-Path -LiteralPath $properties -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($properties)) {
            if ($line -match '^\s*sdk\.dir\s*[=:]\s*(.*?)\s*$') {
                # Java properties escape backslashes, separators, spaces and Unicode.
                $sdkRoot = [regex]::Replace($Matches[1], '\\(u[0-9a-fA-F]{4}|.)', {
                    param($match)
                    $escaped = $match.Groups[1].Value
                    if ($escaped.StartsWith('u') -and $escaped.Length -eq 5) {
                        return [string][char][Convert]::ToInt32($escaped.Substring(1), 16)
                    }
                    switch -CaseSensitive ($escaped) {
                        't' { return "`t" }; 'r' { return "`r" }; 'n' { return "`n" }; 'f' { return "`f" }
                        default { return $escaped }
                    }
                })
                if (-not [IO.Path]::IsPathRooted($sdkRoot)) {
                    $sdkRoot = Join-Path (Split-Path $properties -Parent) $sdkRoot
                }
                $roots.Add($sdkRoot)
            }
        }
    }
    $executable = if ($IsWindows) { 'aapt2.exe' } else { 'aapt2' }
    foreach ($sdkRoot in ($roots | Select-Object -Unique)) {
        $buildTools = Join-Path $sdkRoot 'build-tools'
        if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }
        $versions = Get-ChildItem -LiteralPath $buildTools -Directory | Sort-Object -Descending -Property @{
            Expression = { $version = [version]'0.0'; [void][version]::TryParse(($_.Name -split '-')[0], [ref]$version); $version }
        }, Name
        foreach ($versionDirectory in $versions) {
            $candidate = Join-Path $versionDirectory.FullName $executable
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    throw 'aapt2 was not found. Pass -Aapt2Path or configure ANDROID_HOME, ANDROID_SDK_ROOT, or android/local.properties.'
}

function Get-ApkBadging([string]$Executable, [string]$Path) {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('dump', 'badging', $Path)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'aapt2 timed out after 30 seconds.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $diagnostic = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            # Do not emit the APK's strings or resources in error output.
            throw "aapt2 failed with exit code $($process.ExitCode). Check that the APK has a valid compiled AndroidManifest.xml and resources."
        }
        return $output
    } finally { $process.Dispose() }
}

function Get-StreamSha256([IO.Stream]$Stream) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Get-BoundedStreamSha256([IO.Stream]$Stream, [long]$ExpectedBytes) {
    # ZIP metadata is untrusted. Never inflate more than the pinned ELF size.
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer = [byte[]]::new(65536)
    $remaining = $ExpectedBytes
    try {
        while ($remaining -gt 0) {
            $count = $Stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
            if ($count -le 0) { throw 'Candidate ZIP entry ended before its declared length.' }
            $hasher.AppendData($buffer, 0, $count)
            $remaining -= $count
        }
        if ($Stream.Read($buffer, 0, 1) -ne 0) { throw 'Candidate ZIP entry exceeded its declared length.' }
        return [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    } finally { $hasher.Dispose() }
}

try {
    if ($ExpectedLinuxCandidate) {
        if ($ExpectedLinuxCandidateSha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $ExpectedLinuxNativeLibrary) {
            throw 'An Alpine candidate requires its selected SHA256 and the build stripped native library.'
        }
    } elseif ($ExpectedLinuxCandidateSha256 -or $ExpectedLinuxNativeLibrary) {
        throw 'Linux candidate arguments must be supplied together.'
    }
    if ($ExpectedVersionCode -lt 1) { throw 'ExpectedVersionCode must be positive.' }
    if ($ExpectedRuntimeSha256 -and $ExpectedRuntimeSha256 -cnotmatch '^[a-fA-F0-9]{64}$') {
        throw 'ExpectedRuntimeSha256 must be a 64-character hexadecimal SHA256 digest.'
    }
    if ($ExpectedPackagedLinuxUtilitySha256 -and $ExpectedPackagedLinuxUtilitySha256 -cnotmatch '^[a-fA-F0-9]{64}$') {
        throw 'ExpectedPackagedLinuxUtilitySha256 must be a 64-character hexadecimal SHA256 digest.'
    }
    if ($ExpectedAbi.Count -eq 0 -or @($ExpectedAbi | Where-Object { $_ -notmatch '^[a-zA-Z0-9_-]+$' }).Count -gt 0) {
        throw 'ExpectedAbi must contain one or more Android ABI names.'
    }
    $path = (Resolve-Path -LiteralPath $ApkPath).Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'ApkPath must identify a file.' }
    # Keep this handle open throughout verification, prohibiting replacement/writes on Windows.
    $file = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $result.apk = [ordered]@{ path = $path; bytes = $file.Length; sha256 = Get-StreamSha256 $file }
        $file.Position = 0
        $zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $entries = [Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
            foreach ($entry in $zip.Entries) {
                if (-not $entries.TryAdd($entry.FullName, $entry)) { $failures.Add("Duplicate ZIP entry: $($entry.FullName)") }
            }
            # Guest execution has separate distribution and device gates.
            # Detect known names plus the two pinned ELF digests under any name.
            # Only entries with the exact small ELF lengths are inflated.
            $guestNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($entry in @($zip.Entries | Where-Object {
                -not $_.FullName.EndsWith('/') -and $_.FullName -match '(?i)(?:^|/)(?:libdsh_proot(?:_loader)?_candidate\.so|libpocket_linux_guest_supervisor\.so|libpocket_proot\.so|alpine-minirootfs[^/]*|(?:lib)?proot(?:[-_.][^/]*)?\.so|rootfs\.tar(?:\.gz)?)$'
            })) { [void]$guestNames.Add($entry.FullName) }
            $candidateHashes = @{
                1334216 = 'c22cdb13c5de4b6e0022f7ede7a5ca0bf88675d4b674aa339a885b96d8b26f7f'
                9952 = 'c5e85afb7599bd82f2419fb054d597514d5c9578954288bef0c5320cd8b63fbf'
            }
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName.EndsWith('/') -or $guestNames.Contains($entry.FullName)) { continue }
                $pinnedHash = $candidateHashes[[int]$entry.Length]
                if (-not $pinnedHash) { continue }
                $stream = $entry.Open()
                try { $actual = Get-BoundedStreamSha256 $stream $entry.Length }
                finally { $stream.Dispose() }
                if ($actual -ceq $pinnedHash) { [void]$guestNames.Add($entry.FullName) }
            }
            $guestEntries = @($guestNames | Sort-Object)
            $result.linuxGuestPayload = [ordered]@{ present = $guestEntries.Count -gt 0; entries = $guestEntries }
            foreach ($guestEntry in $guestEntries) {
                $failures.Add("Linux guest payload is not approved for this APK: $guestEntry")
            }
            $vmEntries = @($zip.Entries | Where-Object {
                $_.FullName -cmatch '^assets/linux-vm/' -or $_.FullName -cmatch '/libpocket_linux_vm\.so$'
            })
            if ($ExpectedLinuxCandidate) {
                $audit = & $PythonPath (Join-Path $PSScriptRoot 'linux-vm-release.py') verify-apk `
                    --candidate $ExpectedLinuxCandidate --candidate-sha256 $ExpectedLinuxCandidateSha256 `
                    --apk $path --native-library $ExpectedLinuxNativeLibrary 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Alpine APK verification failed: $($audit -join [Environment]::NewLine)" }
                $result.linuxVmCandidate = ($audit -join [Environment]::NewLine) | ConvertFrom-Json
            } elseif ($vmEntries.Count -gt 0) {
                $failures.Add('Linux VM assets or provider require an explicit verified Alpine candidate.')
            }
            if (-not $entries.ContainsKey('AndroidManifest.xml')) { $failures.Add('AndroidManifest.xml is missing.') }
            $nativeEntries = @($zip.Entries | Where-Object { $_.FullName -cmatch '^lib/[^/]+/' })
            $actualAbi = @($nativeEntries | ForEach-Object { ($_.FullName -split '/')[1] } | Sort-Object -Unique)
            $result.abi.actual = $actualAbi
            foreach ($abi in $actualAbi) {
                if ($ExpectedAbi -cnotcontains $abi) { $failures.Add("Unexpected ABI: $abi") }
                $libraries = @($nativeEntries | Where-Object { ($_.FullName -split '/')[1] -ceq $abi -and $_.Name } | ForEach-Object { $_.Name } | Sort-Object -Unique)
                $result.abi.libraries[$abi] = $libraries
                foreach ($library in $requiredLibraries) {
                    $entryName = "lib/$abi/$library"
                    if (-not $entries.ContainsKey($entryName) -or $entries[$entryName].Length -eq 0) {
                        $failures.Add("Required native library missing or empty: $entryName")
                    }
                }
            }
            foreach ($abi in $ExpectedAbi) {
                if ($actualAbi -cnotcontains $abi) { $failures.Add("Expected ABI is missing: $abi") }
            }
            if ($ExpectedPackagedLinuxUtilitySha256) {
                $utilityEntryName = 'lib/arm64-v8a/libpocket_linux_utility.so'
                if (-not $entries.ContainsKey($utilityEntryName) -or $entries[$utilityEntryName].Length -eq 0) {
                    $failures.Add("Packaged Linux utility missing or empty: $utilityEntryName")
                } else {
                    $utilityStream = $entries[$utilityEntryName].Open()
                    try { $utilityHash = Get-StreamSha256 $utilityStream } finally { $utilityStream.Dispose() }
                    if ($utilityHash -cne $ExpectedPackagedLinuxUtilitySha256.ToLowerInvariant()) {
                        $failures.Add('Packaged Linux utility checksum mismatch.')
                    }
                }
            }
            $ripgrepLock = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime-lock.json') -Raw | ConvertFrom-Json).ripgrep
            $ripgrepEntryName = 'lib/arm64-v8a/libpocket_ripgrep.so'
            if ($ripgrepLock.abi -cne 'arm64-v8a' -or $ripgrepLock.sha256 -cnotmatch '^[a-f0-9]{64}$') {
                $failures.Add('Pinned Android ripgrep identity is invalid.')
            } elseif ($entries.ContainsKey($ripgrepEntryName)) {
                $ripgrepStream = $entries[$ripgrepEntryName].Open()
                try { $ripgrepHash = Get-StreamSha256 $ripgrepStream } finally { $ripgrepStream.Dispose() }
                if ($ripgrepHash -cne $ripgrepLock.sha256) { $failures.Add('Packaged Android ripgrep checksum mismatch.') }
            }
            foreach ($notice in @('NOTICE.txt', 'COPYING', 'LICENSE-MIT', 'UNLICENSE')) {
                $noticeEntry = "assets/licenses/ripgrep/$notice"
                if (-not $entries.ContainsKey($noticeEntry) -or $entries[$noticeEntry].Length -eq 0) {
                    $failures.Add("Ripgrep license or attribution is missing: $noticeEntry")
                }
            }
            $runtimeName = 'assets/runtime/runtime.zip'
            $checksumName = 'assets/runtime/runtime.sha256'
            if (-not $entries.ContainsKey($runtimeName) -or -not $entries.ContainsKey($checksumName)) {
                $failures.Add('The embedded runtime archive or its SHA256 file is missing.')
            } else {
                $runtimeEntry = $entries[$runtimeName]
                $runtimeStream = $runtimeEntry.Open()
                try { $runtimeHash = Get-StreamSha256 $runtimeStream } finally { $runtimeStream.Dispose() }
                $expectedHash = $null
                if ($entries[$checksumName].Length -gt 1024) {
                    $failures.Add('The embedded runtime SHA256 file exceeds 1024 bytes.')
                } else {
                    $checksumStream = $entries[$checksumName].Open()
                    $reader = [IO.StreamReader]::new($checksumStream)
                    try { $checksum = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
                    if ($checksum -notmatch '^[a-fA-F0-9]{64}$') { $failures.Add('The embedded runtime SHA256 file is invalid.') }
                    else { $expectedHash = $checksum.ToLowerInvariant() }
                }
                $result.runtime = [ordered]@{ path = $runtimeName; bytes = $runtimeEntry.Length; sha256 = $runtimeHash; expectedSha256 = $expectedHash }
                if ($runtimeEntry.Length -eq 0) { $failures.Add('The embedded runtime archive is empty.') }
                if ($expectedHash -and $runtimeHash -cne $expectedHash) { $failures.Add('Embedded runtime SHA256 mismatch.') }
                if ($ExpectedRuntimeSha256 -and $runtimeHash -cne $ExpectedRuntimeSha256.ToLowerInvariant()) {
                    $failures.Add('Embedded runtime differs from the trusted build archive.')
                }
            }
        } finally { $zip.Dispose() }

        $result.aapt2 = Resolve-Aapt2
        $badging = Get-ApkBadging $result.aapt2 $path
        $packageLine = [regex]::Match($badging, '(?m)^package:\s+(.+)$')
        if (-not $packageLine.Success) { throw 'aapt2 did not return package metadata.' }
        $attributes = @{}
        foreach ($attribute in [regex]::Matches($packageLine.Groups[1].Value, "([A-Za-z][A-Za-z0-9]*)='([^']*)'")) {
            $attributes[$attribute.Groups[1].Value] = $attribute.Groups[2].Value
        }
        $versionCode = 0L
        if (-not [long]::TryParse($attributes['versionCode'], [ref]$versionCode)) { throw 'aapt2 returned an invalid versionCode.' }
        $label = [regex]::Match($badging, "(?m)^application-label:'(.*)'\r?$")
        if (-not $label.Success) { throw 'aapt2 did not return the application label.' }
        $result.manifest = [ordered]@{ packageName = $attributes['name']; versionName = $attributes['versionName']; versionCode = $versionCode; label = $label.Groups[1].Value }
        if ($attributes['name'] -cne $ExpectedPackageName) { $failures.Add("Package name mismatch: expected $ExpectedPackageName, actual $($attributes['name']).") }
        if ($attributes['versionName'] -cne $ExpectedVersionName) { $failures.Add("Version name mismatch: expected $ExpectedVersionName, actual $($attributes['versionName']).") }
        if ($versionCode -ne $ExpectedVersionCode) { $failures.Add("Version code mismatch: expected $ExpectedVersionCode, actual $versionCode.") }
    } finally { $file.Dispose() }
} catch { $failures.Add($_.Exception.Message) }

$result.success = $failures.Count -eq 0
$result.errors = @($failures.ToArray())
$result | ConvertTo-Json -Depth 8
if (-not $result.success) { exit 1 }
exit 0
