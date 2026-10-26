param(
    [Parameter(Mandatory=$true)][string]$ReadelfPath,
    [Parameter(Mandatory=$true)][string]$LoaderPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$symbols = & $ReadelfPath -s $LoaderPath
if ($LASTEXITCODE -ne 0) { throw 'llvm-readelf failed for PRoot loader' }
$found = @{}
foreach ($line in $symbols) {
    if ($line -match '^\s*\d+:\s*([0-9A-Fa-f]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(_start|pokedata_workaround)\s*$') {
        $found[$Matches[2]] = [Convert]::ToInt64($Matches[1], 16)
    }
}
if (-not $found.ContainsKey('_start') -or -not $found.ContainsKey('pokedata_workaround')) {
    throw 'PRoot loader entry/workaround symbols are missing'
}
$offset = $found['pokedata_workaround'] - $found['_start']
if ([Math]::Abs($offset) -gt 65536) { throw "Unexpected PRoot workaround offset: $offset" }
[IO.File]::WriteAllText($OutputPath, "#include <unistd.h>`nconst ssize_t offset_to_pokedata_workaround = $offset;`n")
