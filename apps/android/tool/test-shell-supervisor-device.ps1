param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$NdkDirectory,
    [string]$Adb = 'adb'
)

$ErrorActionPreference = 'Stop'
if ($Serial -notmatch '^emulator-[0-9]+$') { throw 'Only an isolated Android emulator is accepted.' }
if ((& $Adb -s $Serial shell getprop ro.kernel.qemu).Trim() -ne '1') {
    throw 'The target is not an Android emulator.'
}
$abi = (& $Adb -s $Serial shell getprop ro.product.cpu.abi).Trim()
$target = switch ($abi) {
    'x86_64' { 'x86_64-linux-android28-clang.cmd' }
    'arm64-v8a' { 'aarch64-linux-android28-clang.cmd' }
    default { throw "Unsupported emulator ABI: $abi" }
}
$compiler = Join-Path $NdkDirectory "toolchains/llvm/prebuilt/windows-x86_64/bin/$target"
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'NDK compiler is unavailable.' }
$appRoot = Split-Path $PSScriptRoot -Parent
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $appRoot '../..'))
$outputRoot = Join-Path $repositoryRoot '.cache/android/shell-supervisor-device'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$env:TEMP = $outputRoot
$env:TMP = $outputRoot
$helper = Join-Path $outputRoot 'shell-supervisor'
$fixture = Join-Path $outputRoot 'shell-fault'
& $compiler -Wall -Wextra -Werror -fPIE -pie '-Wl,-z,max-page-size=16384' -o $helper (Join-Path $appRoot 'android/app/src/main/cpp/shell_supervisor.c')
if ($LASTEXITCODE -ne 0) { throw 'Shell supervisor cross-compilation failed.' }
& $compiler -Wall -Wextra -Werror -fPIE -pie -o $fixture (Join-Path $PSScriptRoot 'shell-supervisor-fault.c')
if ($LASTEXITCODE -ne 0) { throw 'Shell fault fixture cross-compilation failed.' }
$remoteHelper = '/data/local/tmp/dsh-shell-supervisor-probe'
$remoteFixture = '/data/local/tmp/dsh-shell-fault-probe'
& $Adb -s $Serial push $helper $remoteHelper | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not copy Shell supervisor to emulator.' }
& $Adb -s $Serial push $fixture $remoteFixture | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not copy Shell fault fixture to emulator.' }
& $Adb -s $Serial shell "chmod 700 $remoteHelper $remoteFixture" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare emulator test executables.' }

$ack = (& $Adb -s $Serial shell "$remoteFixture $remoteHelper ack-fail") -join "`n"
if ($LASTEXITCODE -ne 0 -or $ack -notmatch '^ACK_FAIL parent=[0-9]+ helper=[0-9]+ sentinel=0\s*$') {
    throw "Closed startup acknowledgement allowed execution or fixture failed: $ack"
}
$quick = (& $Adb -s $Serial shell "$remoteFixture $remoteHelper quick") -join "`n"
if ($LASTEXITCODE -ne 0 -or $quick -notmatch '^quickQUICK_EXIT=0\s*$') {
    throw "Ordinary supervised Shell exit failed: $quick"
}

$stdoutPath = Join-Path $outputRoot 'hold.out'
$stderrPath = Join-Path $outputRoot 'hold.err'
$parentId = $null
$helperId = $null
$descendantId = $null
$adbProcess = Start-Process -FilePath $Adb -ArgumentList "-s $Serial shell `"$remoteFixture $remoteHelper hold`"" `
    -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
try {
    $ready = ''
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if (Test-Path -LiteralPath $stdoutPath) {
            $ready = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        }
        if ($ready -match 'READY parent=([0-9]+) helper=([0-9]+) descendant=([0-9]+)') { break }
        if ($adbProcess.HasExited) { throw "Hold fixture exited before readiness: $ready" }
        Start-Sleep -Milliseconds 100
    }
    if ($ready -notmatch 'READY parent=([0-9]+) helper=([0-9]+) descendant=([0-9]+)') {
        throw "Hold fixture did not become ready: $ready"
    }
    $parentId = [int]$Matches[1]
    $helperId = [int]$Matches[2]
    $descendantId = [int]$Matches[3]
    $before = (& $Adb -s $Serial shell 'ps -A -o PID,PPID,PGID,STAT,NAME') -join "`n"
    if (($before -notmatch "(?m)^\s*$helperId\s+$parentId\s+$helperId\s+S") -or
        ($before -notmatch "(?m)^\s*$descendantId\s+$helperId\s+$helperId\s+S")) {
        throw "Parent-alive negative control failed: $before"
    }
    $outputLink = (& $Adb -s $Serial shell "readlink /proc/$descendantId/fd/1").Trim()
    if ($outputLink -ne '/dev/null') { throw "Descendant output was not closed: $outputLink" }

    & $Adb -s $Serial shell "kill -9 $parentId" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not inject parent SIGKILL.' }
    $quiescent = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $after = (& $Adb -s $Serial shell 'ps -A -o PID,PPID,PGID,STAT,NAME') -join "`n"
        $helperLive = $after -match "(?m)^\s*$helperId\s+\d+\s+$helperId\s+[^Z]"
        $descendantLive = $after -match "(?m)^\s*$descendantId\s+\d+\s+$helperId\s+[^Z]"
        if (-not $helperLive -and -not $descendantLive) { $quiescent = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $quiescent) { throw 'Parent SIGKILL left a live Shell process group.' }
    [pscustomobject]@{ serial = $Serial; abi = $abi; ackFailureBlockedCommand = $true;
        ordinaryCommandCompleted = $true;
        parentAlivePreservedClosedOutputDescendant = $true; parentSigkillClearedGroup = $true }
} finally {
    if ($parentId) { & $Adb -s $Serial shell "kill -9 $parentId" 2>$null | Out-Null }
    if (-not $adbProcess.HasExited) { Stop-Process -Id $adbProcess.Id -Force }
}
