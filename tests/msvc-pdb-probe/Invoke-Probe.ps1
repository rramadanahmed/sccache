param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-fixed',
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
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) {
    throw 'Choose a fresh owned output directory.'
}
$flags = @('/nologo', '/c', '/MDd', '/Od', '/Zi', '/EHsc', '/D_ITERATOR_DEBUG_LEVEL=2')
$null = New-Item -ItemType Directory -Path "$OutputDirectory\inputs"
Copy-Item -LiteralPath 'pch.h', 'pch.cpp', 'a.cpp', 'b.cpp' -Destination "$OutputDirectory\inputs"
function Compile([string[]]$Arguments) {
    & $Sccache cl.exe @flags @Arguments
    if ($LASTEXITCODE) { throw "Compilation failed: $Arguments" }
}
function Audit([string]$Pdb, [string[]]$Objects) {
    python Inspect-Pdb.py $Pdb @Objects
    if ($LASTEXITCODE) { throw "MSF7/COFF audit failed: $Pdb" }
}
function Link-Probe([string]$Name, [string[]]$Objects) {
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\$Name.exe" "/PDB:$OutputDirectory\$Name-link.pdb" @Objects 2>&1
    $output
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') {
        throw "Link/debug-info failure: $Name"
    }
    python Inspect-Pdb.py "$OutputDirectory\$Name-link.pdb" --pe "$OutputDirectory\$Name.exe"
    if ($LASTEXITCODE) { throw 'MSF7/PE linker PDB identity mismatch.' }
    & ".\$OutputDirectory\$Name.exe"
    if ($LASTEXITCODE) { throw "Public executable failed: $Name" }
}
function Stats([string]$Phase) {
    & $Sccache --show-stats --stats-format=json |
        Set-Content -LiteralPath "$OutputDirectory\$Phase-stats.json"
    if ($LASTEXITCODE) { throw 'Cache stats failed.' }
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    Stats 'ready'
    foreach ($source in @('a', 'b')) {
        Compile @("/Fd$OutputDirectory\unit-$source.pdb", "/Fo$OutputDirectory\unit-$source.obj", '/Fpunused.pch', "$OutputDirectory\inputs\$source.cpp")
        Audit "$OutputDirectory\unit-$source.pdb" @("$OutputDirectory\unit-$source.obj")
    }
    Link-Probe 'unit-cold' @("$OutputDirectory\unit-a.obj", "$OutputDirectory\unit-b.obj")
    Stats 'unit-cold'
    foreach ($source in @('a', 'b')) {
        Compile @("/Fd$OutputDirectory\unit-$source.pdb", "/Fo$OutputDirectory\unit-$source.obj", '/Fpunused.pch', "$OutputDirectory\inputs\$source.cpp")
        Audit "$OutputDirectory\unit-$source.pdb" @("$OutputDirectory\unit-$source.obj")
    }
    Stats 'unit-warm-existing'
    foreach ($source in @('a', 'b')) {
        Remove-Item -LiteralPath "$OutputDirectory\unit-$source.obj", "$OutputDirectory\unit-$source.pdb"
        Compile @("/Fd$OutputDirectory\unit-$source.pdb", "/Fo$OutputDirectory\unit-$source.obj", '/Fpunused.pch', "$OutputDirectory\inputs\$source.cpp")
        Audit "$OutputDirectory\unit-$source.pdb" @("$OutputDirectory\unit-$source.obj")
    }
    Link-Probe 'unit-fresh' @("$OutputDirectory\unit-a.obj", "$OutputDirectory\unit-b.obj")
    Stats 'unit-fresh'

    foreach ($phase in @('cold', 'warm-existing', 'fresh', 'header-changed')) {
        if ($phase -in @('fresh', 'header-changed')) {
            # This is the entire owned PCH group, including all dependent objects.
            Remove-Item -LiteralPath "$OutputDirectory\group.pch", "$OutputDirectory\group.pdb",
                "$OutputDirectory\pch.obj", "$OutputDirectory\pch-a.obj", "$OutputDirectory\pch-b.obj"
        }
        if ($phase -eq 'header-changed') {
            (Get-Content -Raw -LiteralPath "$OutputDirectory\inputs\pch.h").Replace('VALUE 7', 'VALUE 9') |
                Set-Content -LiteralPath "$OutputDirectory\inputs\pch.h"
        }
        Compile @('/Ycpch.h', "/Fp$OutputDirectory\group.pch", "/Fd$OutputDirectory\group.pdb", "/Fo$OutputDirectory\pch.obj", "$OutputDirectory\inputs\pch.cpp")
        foreach ($source in @('a', 'b')) {
            Compile @('/Yupch.h', "/Fp$OutputDirectory\group.pch", "/Fd$OutputDirectory\group.pdb", "/Fo$OutputDirectory\pch-$source.obj", "$OutputDirectory\inputs\$source.cpp")
        }
        Audit "$OutputDirectory\group.pdb" @("$OutputDirectory\pch.obj", "$OutputDirectory\pch-a.obj", "$OutputDirectory\pch-b.obj")
        Link-Probe "pch-$phase" @("$OutputDirectory\pch.obj", "$OutputDirectory\pch-a.obj", "$OutputDirectory\pch-b.obj")
        Stats "pch-$phase"
    }
    $beforeChange = Get-Content -Raw -LiteralPath "$OutputDirectory\pch-fresh-stats.json" | ConvertFrom-Json
    $afterChange = Get-Content -Raw -LiteralPath "$OutputDirectory\pch-header-changed-stats.json" | ConvertFrom-Json
    if ($afterChange.stats.cache_misses.counts.'C/C++' -ne $beforeChange.stats.cache_misses.counts.'C/C++' + 1) {
        throw 'Changing a PCH header must invalidate its creator cache key.'
    }

    foreach ($source in @('a', 'b', 'a')) {
        Compile @("/Fd$OutputDirectory\shared.pdb", "/Fo$OutputDirectory\shared-$source.obj", "$OutputDirectory\inputs\$source.cpp")
    }
    Audit "$OutputDirectory\shared.pdb" @("$OutputDirectory\shared-a.obj", "$OutputDirectory\shared-b.obj")
    Link-Probe 'shared-safe' @("$OutputDirectory\shared-a.obj", "$OutputDirectory\shared-b.obj")
    Stats 'final'
    $stats = Get-Content -Raw -LiteralPath "$OutputDirectory\final-stats.json" | ConvertFrom-Json
    if ($stats.stats.cache_hits.counts.'C/C++' -lt 3) {
        throw 'Expected two non-PCH hits and one complete PCH-creator hit.'
    }
    Write-Output 'PASS cold/warm/fresh outputs, original /Zi /MDd PCH, shared-PDB safety, real debug linking and execution'
} finally {
    & $Sccache --stop-server
}
