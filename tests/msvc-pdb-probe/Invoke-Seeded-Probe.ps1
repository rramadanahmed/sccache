param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-seeded-cache',
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
$null = New-Item -ItemType Directory -Path "$OutputDirectory\inputs"
Copy-Item -LiteralPath 'pch.h', 'pch.cpp', 'seed-a.cpp', 'seed-b.cpp' -Destination "$OutputDirectory\inputs"
$flags = @('/nologo', '/c', '/MDd', '/Od', '/Zi', '/EHsc', '/D_ITERATOR_DEBUG_LEVEL=2')
$creator = @('/Ycpch.h', "/Fp$OutputDirectory\group.pch", "/Fd$OutputDirectory\creator.pdb",
    "/Fo$OutputDirectory\pch.obj", "$OutputDirectory\inputs\pch.cpp")
function Compile([string[]]$Arguments) {
    & $Sccache cl.exe @flags @Arguments
    if ($LASTEXITCODE) { throw "Compilation failed: $Arguments" }
}
function Stats([string]$Phase) {
    $json = & $Sccache --show-stats --stats-format=json
    if ($LASTEXITCODE) { throw 'Cache stats failed.' }
    $json | Set-Content -LiteralPath "$OutputDirectory\$Phase-stats.json"
    return ($json | ConvertFrom-Json).stats
}
function Link-And-Audit([string]$Phase, [int]$AlphaBytes) {
    python Inspect-Pdb.py "$OutputDirectory\creator.pdb" "$OutputDirectory\pch.obj"
    if ($LASTEXITCODE) { throw 'Creator COFF/PDB mismatch.' }
    foreach ($source in @('seed-a', 'seed-b')) {
        python Inspect-Pdb.py "$OutputDirectory\$source.pdb" "$OutputDirectory\$source.obj"
        if ($LASTEXITCODE) { throw "Private COFF/PDB mismatch: $source" }
    }
    $objects = @("$OutputDirectory\pch.obj", "$OutputDirectory\seed-a.obj", "$OutputDirectory\seed-b.obj")
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\$Phase.exe" "/PDB:$OutputDirectory\$Phase-link.pdb" @objects 2>&1
    $output
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw 'Link/debug-info failure.' }
    python Inspect-Pdb.py "$OutputDirectory\$Phase-link.pdb" --pe "$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Linker PE/PDB mismatch.' }
    $types = & pdbdump.exe "$OutputDirectory\$Phase-link.pdb" types 2>&1
    if ($LASTEXITCODE) { throw 'Native PDB type dump failed.' }
    $types | Set-Content -LiteralPath "$OutputDirectory\$Phase-linked-types.txt"
    $alpha = @($types | Where-Object { "$_" -match 'struct PublicAlpha' -and "$_" -notmatch 'fwdref' })
    $beta = @($types | Where-Object { "$_" -match 'struct PublicBeta' -and "$_" -notmatch 'fwdref' })
    if ($alpha.Count -ne 1 -or $beta.Count -ne 1 -or
        -not "$alpha".Contains("data[$AlphaBytes<") -or -not "$beta".Contains('data[24<') -or
        "$alpha".Split(':')[0] -eq "$beta".Split(':')[0]) {
        throw 'Distinct private type-server records were not correctly merged into linker PDB.'
    }
    & ".\$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Public executable failed.' }
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $null = Stats 'ready'
    Compile $creator
    $env:SCCACHE_MSVC_PCH_PDB = (Resolve-Path "$OutputDirectory\creator.pdb").Path
    $seedHash = (Get-FileHash "$OutputDirectory\creator.pdb").Hash
    $pchHash = (Get-FileHash "$OutputDirectory\group.pch").Hash
    (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $true
    $alphaBytes = 136
    $previous = Stats 'creator-cold'
    foreach ($phase in @('cold', 'warm-existing', 'fresh', 'source-changed',
                         'creator-recreated', 'seed-updated', 'final-warm')) {
        if ($phase -eq 'fresh') {
            Remove-Item -LiteralPath "$OutputDirectory\seed-a.obj", "$OutputDirectory\seed-a.pdb",
                "$OutputDirectory\seed-b.obj", "$OutputDirectory\seed-b.pdb"
        }
        if ($phase -eq 'source-changed') {
            (Get-Content -Raw -LiteralPath "$OutputDirectory\inputs\seed-a.cpp").Replace('data[17]', 'data[23]') |
                Set-Content -LiteralPath "$OutputDirectory\inputs\seed-a.cpp"
            $alphaBytes = 184
        }
        if ($phase -eq 'creator-recreated') {
            # Keep old private consumer outputs: the new creator identity must
            # invalidate their keys and reseed them on misses, not overwrite a shared PDB.
            (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $false
            Remove-Item -LiteralPath "$OutputDirectory\pch.obj", "$OutputDirectory\group.pch",
                "$OutputDirectory\creator.pdb"
            & cl.exe @flags @creator
            if ($LASTEXITCODE) { throw 'Genuine creator regeneration failed.' }
            if ($seedHash -eq (Get-FileHash "$OutputDirectory\creator.pdb").Hash) {
                throw 'Expected a new genuine creator PDB identity.'
            }
            $seedHash = (Get-FileHash "$OutputDirectory\creator.pdb").Hash
            $pchHash = (Get-FileHash "$OutputDirectory\group.pch").Hash
            (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $true
        }
        if ($phase -eq 'seed-updated') {
            # Genuine compiler update between generations changes seed bytes
            # only. The PCH, consumer sources and /Yu arguments stay identical.
            (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $false
            & cl.exe @flags "/Fd$OutputDirectory\creator.pdb" "/Fo$OutputDirectory\seed-update.obj" "$OutputDirectory\inputs\pch.cpp"
            if ($LASTEXITCODE) { throw 'Genuine seed-PDB update failed.' }
            if ($seedHash -eq (Get-FileHash "$OutputDirectory\creator.pdb").Hash) {
                throw 'Expected genuine compiler PDB bytes to change.'
            }
            $seedHash = (Get-FileHash "$OutputDirectory\creator.pdb").Hash
            (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $true
        }
        foreach ($source in @('seed-a', 'seed-b')) {
            Compile @('/Yupch.h', "/Fp$OutputDirectory\group.pch", "/Fd$OutputDirectory\$source.pdb",
                "/Fo$OutputDirectory\$source.obj", "$OutputDirectory\inputs\$source.cpp")
        }
        if ($seedHash -ne (Get-FileHash "$OutputDirectory\creator.pdb").Hash -or
            $pchHash -ne (Get-FileHash "$OutputDirectory\group.pch").Hash) {
            throw 'A consumer or preprocessing step modified its immutable creator inputs.'
        }
        Link-And-Audit $phase $alphaBytes
        $current = Stats $phase
        $hitDelta = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $missDelta = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($phase -in @('warm-existing', 'fresh', 'final-warm')) { 2 }
            elseif ($phase -eq 'source-changed') { 1 } else { 0 }
        if ($hitDelta -ne $expectedHits -or $missDelta -ne 2 - $expectedHits) {
            throw "Unexpected cache behavior: $phase hits=$hitDelta misses=$missDelta"
        }
        $previous = $current
    }
    Write-Output 'PASS /Yu cold/warm/fresh hits, divergent type merging, source/PCH/seed invalidation and immutable creator inputs'
} finally {
    $env:SCCACHE_MSVC_PCH_PDB = ''
    if (Test-Path "$OutputDirectory\creator.pdb") {
        (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $false
    }
    & $Sccache --stop-server
}
