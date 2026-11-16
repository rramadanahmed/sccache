param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-shadow-pch',
    [switch]$Direct,
    [switch]$ExpectLegacyFailure,
    [switch]$WarningsAsErrors
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-Location $PSScriptRoot
$env:SCCACHE_DIR = $CacheDirectory
$env:SCCACHE_SERVER_PORT = [string]$Port
$env:SCCACHE_IDLE_TIMEOUT = '120'
$env:SCCACHE_DIRECT = if ($Direct) { 'true' } else { 'false' }
$env:SCCACHE_MSVC_PRIVATE_PDB = '1'
$env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = '1'
$env:SCCACHE_MSVC_PCH_PDB = ''
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
Copy-Item -LiteralPath shadow-creator,shadow-source -Destination $OutputDirectory -Recurse
$flags = @('/nologo','/c','/MDd','/Od','/Zi','/EHsc','/D_ITERATOR_DEBUG_LEVEL=2')
if ($WarningsAsErrors) { $flags += '/WX' }
$creator = @('/Ycstdafx.h',"/Fp$OutputDirectory\group.pch","/Fd$OutputDirectory\creator.obj.pdb",
    "/Fo$OutputDirectory\creator.obj","$OutputDirectory\shadow-creator\stdafx.cpp")
$consumer = @('/Yustdafx.h',"/Fp$OutputDirectory\group.pch","/Fd$OutputDirectory\main.obj.pdb",
    "/Fo$OutputDirectory\main.obj",'/showIncludes','/sourceDependencies',"$OutputDirectory\consumer-deps.json",
    "$OutputDirectory\shadow-source\main.cpp")
function Stats([string]$Phase) {
    $json = & $Sccache --show-stats --stats-format=json
    if ($LASTEXITCODE) { throw 'Cache stats failed.' }
    $json | Set-Content -LiteralPath "$OutputDirectory\$Phase-stats.json"
    return ($json | ConvertFrom-Json).stats
}
function Audit-And-Link([string]$Phase, [int]$Expected, [int]$ExpectedBytes, [bool]$ChangedCreator) {
    python Inspect-Pdb.py "$OutputDirectory\main.obj.pdb" "$OutputDirectory\main.obj"
    if ($LASTEXITCODE) { throw 'Shadow consumer MSF7/COFF mismatch.' }
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\$Phase.exe" "/PDB:$OutputDirectory\$Phase-link.pdb" "$OutputDirectory\creator.obj" "$OutputDirectory\main.obj" 2>&1
    $output
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw 'Shadow consumer debug link failed.' }
    python Inspect-Pdb.py "$OutputDirectory\$Phase-link.pdb" --pe "$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Shadow consumer PE/PDB mismatch.' }
    $types = & pdbdump.exe "$OutputDirectory\$Phase-link.pdb" types 2>&1
    if ($LASTEXITCODE) { throw 'Shadow consumer native PDB type dump failed.' }
    $types | Set-Content -LiteralPath "$OutputDirectory\$Phase-linked-types.txt"
    $record = @($types | Where-Object { "$_" -match 'struct PublicShadowPostPchType' -and "$_" -notmatch 'fwdref' })
    if ($record.Count -ne 1 -or -not "$record".Contains("bytes[$ExpectedBytes<")) {
        throw 'Post-PCH macro-dependent native debug type layout is stale.'
    }
    if ($ChangedCreator -and "$types" -notmatch 'creator_generation') {
        throw 'Regenerated genuine PCH type state was lost from compiler/linker debug information.'
    }
    & ".\$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE -ne $Expected) {
        throw "Expected public macro-selected result $Expected, actual=$LASTEXITCODE"
    }
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $null = Stats 'ready'
    & $Sccache cl.exe @flags @creator
    if ($LASTEXITCODE) { throw 'Genuine public creator failed.' }
    Copy-Item -LiteralPath "$OutputDirectory\creator.obj.pdb" -Destination "$OutputDirectory\snapshot.pdb"
    (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $true
    $env:SCCACHE_MSVC_PCH_PDB = (Resolve-Path "$OutputDirectory\snapshot.pdb").Path
    $seedHash = (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash
    $creatorHash = (Get-FileHash "$OutputDirectory\creator.obj.pdb").Hash
    $pchHash = (Get-FileHash "$OutputDirectory\group.pch").Hash
    if ($ExpectLegacyFailure) {
        Copy-Item -LiteralPath "$OutputDirectory\creator.obj.pdb" -Destination "$OutputDirectory\main.obj.pdb"
        & cl.exe @flags @consumer
        if ($LASTEXITCODE) { throw 'The original native /Yu did not ignore the shadow header.' }
        python Inspect-Pdb.py "$OutputDirectory\main.obj.pdb" "$OutputDirectory\main.obj"
        if ($LASTEXITCODE) { throw 'Native public consumer has an invalid real PDB.' }
        $output = & $Sccache cl.exe @flags @consumer 2>&1
        $code = $LASTEXITCODE
        $output | Set-Content -LiteralPath "$OutputDirectory\legacy-failure.log"
        if ($code -eq 0 -or "$output" -notmatch 'C1189|shadow header') {
            throw 'Expected legacy /Y- preprocessing to fail despite successful genuine /Yu compilation.'
        }
        Write-Output 'PASS negative control: real /Yu succeeds; legacy cache preprocessing wrongly expands shadow #error'
        return
    }
    $previous = Stats 'creator-cold'
    $sourceOffset = 0
    $headerValue = 11
    $changedCreator = $false
    foreach ($phase in @('cold','warm-existing','shadow-changed','source-changed',
                         'dependency-changed','creator-regenerated','final-warm','fresh')) {
        if ($phase -eq 'shadow-changed') {
            @'
#error The changed shadow must STILL never be expanded.
#include "PublicMissingShadowOnly.h"
#define PUBLIC_SHADOW_VALUE 123
'@ | Set-Content -LiteralPath "$OutputDirectory\shadow-source\stdafx.h"
        }
        if ($phase -eq 'source-changed') {
            (Get-Content -Raw "$OutputDirectory\shadow-source\main.cpp").Replace(
                'static_cast<int>(public_shadow_value.value);',
                'static_cast<int>(public_shadow_value.value) + 1;') |
                Set-Content -LiteralPath "$OutputDirectory\shadow-source\main.cpp"
            $sourceOffset = 1
        }
        if ($phase -eq 'dependency-changed') {
            (Get-Content -Raw "$OutputDirectory\shadow-source\selected-after.h").Replace('VALUE 11','VALUE 13') |
                Set-Content -LiteralPath "$OutputDirectory\shadow-source\selected-after.h"
            $headerValue = 13
        }
        if ($phase -eq 'creator-regenerated') {
            (Get-Content -Raw "$OutputDirectory\shadow-creator\stdafx.h").Replace(
                'long long value;', 'long long value; char creator_generation[2];') |
                Set-Content -LiteralPath "$OutputDirectory\shadow-creator\stdafx.h"
            & $Sccache cl.exe @flags @creator
            if ($LASTEXITCODE) { throw 'Real creator regeneration failed.' }
            if ($seedHash -ne (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash) {
                throw 'Creator processing changed the immutable old snapshot before publication.'
            }
            Copy-Item -LiteralPath "$OutputDirectory\creator.obj.pdb" -Destination "$OutputDirectory\snapshot.new"
            (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $false
            [IO.File]::Move(
                (Join-Path $PSScriptRoot "$OutputDirectory\snapshot.new"),
                (Join-Path $PSScriptRoot "$OutputDirectory\snapshot.pdb"), $true)
            (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $true
            $newSeed = (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash
            $newPch = (Get-FileHash "$OutputDirectory\group.pch").Hash
            if ($seedHash -eq $newSeed -or $pchHash -eq $newPch) {
                throw 'Expected genuine new PCH and seed generations.'
            }
            $seedHash = $newSeed
            $pchHash = $newPch
            $creatorHash = (Get-FileHash "$OutputDirectory\creator.obj.pdb").Hash
            $changedCreator = $true
        }
        if ($phase -eq 'fresh') { Remove-Item -LiteralPath "$OutputDirectory\main.obj","$OutputDirectory\main.obj.pdb" }
        $output = & $Sccache cl.exe @flags @consumer 2>&1
        $code = $LASTEXITCODE
        $output | Set-Content -LiteralPath "$OutputDirectory\$phase-output.log"
        if ($code) { throw "PCH-aware cache action failed: $phase $output" }
        if ("$output" -notmatch 'selected-after.h' -or "$output" -match 'including file:.*shadow-source[\\/]stdafx.h') {
            throw 'Cached /showIncludes does not reflect genuine post-PCH dependencies.'
        }
        $deps = Get-Content -Raw "$OutputDirectory\consumer-deps.json" | ConvertFrom-Json
        if ("$($deps.Data.Includes)" -notmatch 'selected-after.h' -or
            "$($deps.Data.Includes)" -match 'shadow-source[\\/]stdafx.h') {
            throw 'Source dependency JSON expanded the shadow header or lost the selected post-PCH include.'
        }
        if ($seedHash -ne (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash -or
            $creatorHash -ne (Get-FileHash "$OutputDirectory\creator.obj.pdb").Hash -or
            $pchHash -ne (Get-FileHash "$OutputDirectory\group.pch").Hash) {
            throw 'PCH-aware scanning modified creator/PCH/immutable seed artifacts.'
        }
        $expected = $headerValue + $sourceOffset
        Audit-And-Link $phase $expected $headerValue $changedCreator
        $current = Stats $phase
        $hits = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $misses = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($phase -in @('cold','source-changed','dependency-changed','creator-regenerated')) { 0 } else { 1 }
        $expectedMisses = if ($phase -eq 'creator-regenerated') { 2 } else { 1 - $expectedHits }
        if ($hits -ne $expectedHits -or $misses -ne $expectedMisses) {
            throw "Incorrect PCH-aware dependency key: $phase hits=$hits misses=$misses"
        }
        Write-Output "PASS $phase hits=$hits misses=$misses; original PCH macro/type state; post-PCH value=$expected"
        $previous = $current
    }
} finally {
    $env:SCCACHE_MSVC_PCH_PDB = ''
    $env:SCCACHE_MSVC_PRIVATE_PDB = ''
    $env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = ''
    if (Test-Path "$OutputDirectory\snapshot.pdb") { (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $false }
    & $Sccache --stop-server
}
