param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-creator-snapshot',
    [switch]$Direct
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-Location $PSScriptRoot
$env:SCCACHE_DIR = $CacheDirectory
$env:SCCACHE_SERVER_PORT = [string]$Port
$env:SCCACHE_IDLE_TIMEOUT = '120'
$env:SCCACHE_DIRECT = if ($Direct) { 'true' } else { 'false' }
$env:SCCACHE_MSVC_PRIVATE_PDB = '1'
$env:SCCACHE_MSVC_PCH_PDB = ''
$env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = '1'
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
$null = New-Item -ItemType Directory -Path "$OutputDirectory\inputs"
Copy-Item -LiteralPath pch.h,pch.cpp,seed-a.cpp,seed-b.cpp -Destination "$OutputDirectory\inputs"
(Get-Content -Raw "$OutputDirectory\inputs\seed-a.cpp").Replace(
    'long long data[17]', 'long long data[PUBLIC_PCH_VALUE + 10]') |
    Set-Content -LiteralPath "$OutputDirectory\inputs\seed-a.cpp"
$flags = @('/nologo','/c','/MDd','/Od','/Zi','/EHsc','/D_ITERATOR_DEBUG_LEVEL=2')
$creatorPdb = "$OutputDirectory\pch.obj.pdb"
$snapshot = "$OutputDirectory\snapshot.pdb"
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
    python Inspect-Pdb.py $creatorPdb "$OutputDirectory\pch.obj"
    if ($LASTEXITCODE) { throw 'Creator MSF7/COFF mismatch.' }
    foreach ($source in @('seed-a','seed-b')) {
        python Inspect-Pdb.py "$OutputDirectory\$source.obj.pdb" "$OutputDirectory\$source.obj"
        if ($LASTEXITCODE) { throw "Consumer MSF7/COFF mismatch: $source" }
    }
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\$Phase.exe" "/PDB:$OutputDirectory\$Phase-link.pdb" "$OutputDirectory\pch.obj" "$OutputDirectory\seed-a.obj" "$OutputDirectory\seed-b.obj" 2>&1
    $output
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw 'Creator/snapshot debug link failed.' }
    python Inspect-Pdb.py "$OutputDirectory\$Phase-link.pdb" --pe "$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Creator/snapshot PE/PDB mismatch.' }
    $types = & pdbdump.exe "$OutputDirectory\$Phase-link.pdb" types 2>&1
    if ($LASTEXITCODE) { throw 'Native PDB type dump failed.' }
    $types | Set-Content -LiteralPath "$OutputDirectory\$Phase-linked-types.txt"
    $alpha = @($types | Where-Object { "$_" -match 'struct PublicAlpha' -and "$_" -notmatch 'fwdref' })
    $beta = @($types | Where-Object { "$_" -match 'struct PublicBeta' -and "$_" -notmatch 'fwdref' })
    if ($alpha.Count -ne 1 -or $beta.Count -ne 1 -or
        -not "$alpha".Contains("data[$AlphaBytes<") -or -not "$beta".Contains('data[24<') -or
        "$alpha".Split(':')[0] -eq "$beta".Split(':')[0]) {
        throw 'Genuine private type-server debug layouts did not survive linking.'
    }
    & ".\$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Creator/snapshot public executable failed.' }
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $previous = Stats 'ready'
    $cold = @{}
    $changed = @{}
    $seedHash = ''
    foreach ($phase in @('cold','warm-existing','fresh','creator-changed','changed-warm')) {
        $snapshotBefore = if (Test-Path $snapshot) { (Get-FileHash $snapshot).Hash } else { '' }
        if ($phase -eq 'fresh') {
            # Only owned creator outputs are removed; the previous immutable
            # snapshot and private consumer outputs remain until publication.
            Remove-Item -LiteralPath "$OutputDirectory\pch.obj","$OutputDirectory\group.pch",$creatorPdb
        }
        if ($phase -eq 'creator-changed') {
            (Get-Content -Raw "$OutputDirectory\inputs\pch.h").Replace('VALUE 7','VALUE 9') |
                Set-Content -LiteralPath "$OutputDirectory\inputs\pch.h"
        }
        Compile @('/Ycpch.h',"/Fp$OutputDirectory\group.pch",
            "/Fd$creatorPdb","/Fo$OutputDirectory\pch.obj","$OutputDirectory\inputs\pch.cpp")
        # Creator processing must never write the previously published seed.
        if ($snapshotBefore -and $snapshotBefore -ne (Get-FileHash $snapshot).Hash) {
            throw 'Creator preprocessing, compilation or restore changed the published seed.'
        }
        $triple = @("$OutputDirectory\group.pch","$OutputDirectory\pch.obj",$creatorPdb)
        if ($phase -eq 'cold') {
            foreach ($path in $triple) { $cold[$path] = (Get-FileHash $path).Hash }
        } elseif ($phase -in @('warm-existing','fresh')) {
            foreach ($path in $triple) {
                if ($cold[$path] -ne (Get-FileHash $path).Hash) {
                    throw "Creator hit failed to restore complete original PCH/OBJ/PDB triple: $path"
                }
            }
        } elseif ($phase -eq 'creator-changed') {
            foreach ($path in $triple) { $changed[$path] = (Get-FileHash $path).Hash }
            if ($changed[$creatorPdb] -eq $cold[$creatorPdb]) {
                throw 'Creator miss did not generate a fresh genuine compiler PDB.'
            }
        } else {
            foreach ($path in $triple) {
                if ($changed[$path] -ne (Get-FileHash $path).Hash) {
                    throw "Changed-generation creator hit mismatched output: $path"
                }
            }
        }
        # Publication occurs only after creator success and with no running
        # readers. Copy actual bytes to a distinct file, never alias/hard-link.
        if ($snapshotBefore -ne (Get-FileHash $creatorPdb).Hash) {
            $temporary = "$snapshot.new"
            Copy-Item -LiteralPath $creatorPdb -Destination $temporary
            if (Test-Path $snapshot) { (Get-Item $snapshot).IsReadOnly = $false }
            [IO.File]::Move((Join-Path $PSScriptRoot $temporary),(Join-Path $PSScriptRoot $snapshot),$true)
            (Get-Item $snapshot).IsReadOnly = $true
        }
        $seedHash = (Get-FileHash $snapshot).Hash
        $creatorHash = (Get-FileHash $creatorPdb).Hash
        $env:SCCACHE_MSVC_PCH_PDB = (Resolve-Path $snapshot).Path
        foreach ($source in @('seed-a','seed-b')) {
            Compile @('/Yupch.h',"/Fp$OutputDirectory\group.pch",
                "/Fd$OutputDirectory\$source.obj.pdb","/Fo$OutputDirectory\$source.obj",
                "$OutputDirectory\inputs\$source.cpp")
        }
        if ($seedHash -ne (Get-FileHash $snapshot).Hash -or $creatorHash -ne (Get-FileHash $creatorPdb).Hash) {
            throw 'Consumers changed the immutable snapshot or original creator database.'
        }
        $alphaBytes = if ($phase -in @('creator-changed','changed-warm')) { 152 } else { 136 }
        Link-And-Audit $phase $alphaBytes
        $current = Stats $phase
        $hits = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $misses = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($phase -in @('cold','creator-changed')) { 0 } else { 3 }
        if ($hits -ne $expectedHits -or $misses -ne 3 - $expectedHits) {
            throw "Incorrect creator/snapshot cache behavior: $phase hits=$hits misses=$misses"
        }
        Write-Output "PASS $phase creator+2users hits=$hits misses=$misses; immutable snapshot and complete genuine debug artifacts"
        $previous = $current
    }
} finally {
    $env:SCCACHE_MSVC_PCH_PDB = ''
    $env:SCCACHE_MSVC_PRIVATE_PDB = ''
    if (Test-Path $snapshot) { (Get-Item $snapshot).IsReadOnly = $false }
    & $Sccache --stop-server
}
