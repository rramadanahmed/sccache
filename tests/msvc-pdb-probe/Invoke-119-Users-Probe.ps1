param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-119-users',
    [switch]$Direct
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-Location $PSScriptRoot
$env:SCCACHE_DIR = $CacheDirectory
$env:SCCACHE_SERVER_PORT = [string]$Port
$env:SCCACHE_IDLE_TIMEOUT = '120'
$env:SCCACHE_DIRECT = if ($Direct) { 'true' } else { 'false' }
$env:SCCACHE_MSVC_PCH_PDB = ''
$env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = '1'
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
$null = New-Item -ItemType Directory -Path "$OutputDirectory\inputs", "$OutputDirectory\users"
Copy-Item -LiteralPath 'pch.h', 'pch.cpp' -Destination "$OutputDirectory\inputs"
$prototypes = @()
$values = @()
for ($i = 1; $i -le 118; $i++) {
    $name = 'PublicType{0:D3}' -f $i
    $function = 'public_value_{0:D3}' -f $i
    $source = @"
#include "pch.h"
struct $name { long long data[$($i + 1)]; };
$name public_data_$i{{$i}};
int $function() { return static_cast<int>(public_data_$i.data[0]); }
"@
    $source | Set-Content -LiteralPath ("$OutputDirectory\inputs\user{0:D3}.cpp" -f $i) -Encoding ascii
    $prototypes += "int $function();"
    $values += "$function()"
}
$main = @"
#include "pch.h"
$($prototypes -join "`n")
int main() {
    std::vector<int> values{$($values -join ',')};
    int sum = 0;
    for (int value : values) sum += value;
    return sum == 7021 ? 0 : 1;
}
"@
$main | Set-Content -LiteralPath "$OutputDirectory\inputs\user119.cpp" -Encoding ascii
$flags = @('/nologo', '/c', '/MDd', '/Od', '/Zi', '/EHsc', '/D_ITERATOR_DEBUG_LEVEL=2')
function Stats([string]$Phase) {
    $json = & $Sccache --show-stats --stats-format=json
    if ($LASTEXITCODE) { throw 'Cache stats failed.' }
    $json | Set-Content -LiteralPath "$OutputDirectory\$Phase-stats.json"
    return ($json | ConvertFrom-Json).stats
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $null = Stats 'ready'
    & $Sccache cl.exe @flags /Ycpch.h "/Fp$OutputDirectory\group.pch" "/Fd$OutputDirectory\creator.pdb" "/Fo$OutputDirectory\pch.obj" "$OutputDirectory\inputs\pch.cpp"
    if ($LASTEXITCODE) { throw 'Creator compilation failed.' }
    $env:SCCACHE_MSVC_PCH_PDB = (Resolve-Path "$OutputDirectory\creator.pdb").Path
    $seedHash = (Get-FileHash "$OutputDirectory\creator.pdb").Hash
    $pchHash = (Get-FileHash "$OutputDirectory\group.pch").Hash
    (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $true
    $previous = Stats 'creator-cold'
    foreach ($phase in @('cold', 'warm-existing', 'fresh')) {
        $objects = @("$OutputDirectory\pch.obj")
        for ($i = 1; $i -le 119; $i++) {
            $name = 'user{0:D3}' -f $i
            $object = "$OutputDirectory\users\$name.obj"
            $pdb = "$OutputDirectory\users\$name.pdb"
            if ($phase -eq 'fresh') { Remove-Item -LiteralPath $object, $pdb }
            $output = & $Sccache cl.exe @flags /Yupch.h "/Fp$OutputDirectory\group.pch" "/Fd$pdb" "/Fo$object" "$OutputDirectory\inputs\$name.cpp" 2>&1
            if ($LASTEXITCODE) { throw "Consumer compilation failed: $phase $name $output" }
            $objects += $object
        }
        if ($seedHash -ne (Get-FileHash "$OutputDirectory\creator.pdb").Hash -or
            $pchHash -ne (Get-FileHash "$OutputDirectory\group.pch").Hash) {
            throw 'A consumer modified the immutable PCH/creator PDB.'
        }
        python Inspect-Pdb.py --objects-directory "$OutputDirectory\users"
        if ($LASTEXITCODE) { throw '119 private COFF/PDB audit failed.' }
        $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\$phase.exe" "/PDB:$OutputDirectory\$phase-link.pdb" @objects 2>&1
        if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw "Debug linking failed: $output" }
        python Inspect-Pdb.py "$OutputDirectory\$phase-link.pdb" --pe "$OutputDirectory\$phase.exe"
        if ($LASTEXITCODE) { throw 'Linker PE/PDB audit failed.' }
        $types = & pdbdump.exe "$OutputDirectory\$phase-link.pdb" types 2>&1
        if ($LASTEXITCODE) { throw 'Native PDB type dump failed.' }
        $types | Set-Content -LiteralPath "$OutputDirectory\$phase-linked-types.txt"
        $records = @($types | Where-Object { "$_" -match 'struct PublicType\d+<' -and "$_" -notmatch 'fwdref' })
        $indices = @($records | ForEach-Object { "$_".Split(':')[0] } | Select-Object -Unique)
        if ($records.Count -ne 118 -or $indices.Count -ne 118) {
            throw 'Private type servers were incorrectly collapsed in the linker PDB.'
        }
        for ($i = 1; $i -le 118; $i++) {
            $name = 'PublicType{0:D3}<' -f $i
            $record = @($records | Where-Object { "$_".Contains($name) })
            if ($record.Count -ne 1 -or -not "$record".Contains("data[$(($i + 1) * 8)<")) {
                throw "Incorrect linked type layout: $name"
            }
        }
        & ".\$OutputDirectory\$phase.exe"
        if ($LASTEXITCODE) { throw '119-user debug executable failed.' }
        $current = Stats $phase
        $hits = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $misses = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($phase -eq 'cold') { 0 } else { 119 }
        if ($hits -ne $expectedHits -or $misses -ne 119 - $expectedHits) {
            throw "Unexpected 119-user cache behavior: $phase hits=$hits misses=$misses"
        }
        Write-Output "PASS $phase /Yu consumers=119 hits=$hits misses=$misses; 119 COFF/PDBs and 118 distinct merged type layouts"
        $previous = $current
    }
} finally {
    $env:SCCACHE_MSVC_PCH_PDB = ''
    if (Test-Path "$OutputDirectory\creator.pdb") {
        (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $false
    }
    & $Sccache --stop-server
}
