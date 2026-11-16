param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-private-pdb',
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
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
$null = New-Item -ItemType Directory -Path "$OutputDirectory\inputs", "$OutputDirectory\units"
Copy-Item -LiteralPath 'pch.h', 'a.cpp', 'b.cpp' -Destination "$OutputDirectory\inputs"
$flags = @('/nologo', '/c', '/MDd', '/Od', '/Zi', '/EHsc', '/D_ITERATOR_DEBUG_LEVEL=2')
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
function Audit-Identity([string]$Pdb, [string]$Object) {
    $output = & python Inspect-Pdb.py $Pdb $Object
    if ($LASTEXITCODE) { throw "Compiler PDB/COFF mismatch: $Object" }
    Write-Host "$output"
    return [regex]::Match("$output", '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}').Value
}
function Link-And-Audit([string]$Phase, [string[]]$Objects) {
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\$Phase.exe" "/PDB:$OutputDirectory\$Phase-link.pdb" @Objects 2>&1
    $output
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw 'Link/debug-info failure.' }
    python Inspect-Pdb.py "$OutputDirectory\$Phase-link.pdb" --pe "$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Linker PE/PDB identity mismatch.' }
    & ".\$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Public executable failed.' }
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $previous = Stats 'ready'
    $coldGuid = @{}
    $newGuid = ''
    $bHash = ''
    foreach ($phase in @('cold', 'warm-existing', 'source-changed', 'final-warm', 'fresh')) {
        if ($phase -eq 'source-changed') {
            Add-Content -LiteralPath "$OutputDirectory\inputs\a.cpp" -Value @'
struct PublicOrdinaryGeneration { long long values[9]; };
PublicOrdinaryGeneration public_ordinary_generation{{42}};
'@
        }
        foreach ($source in @('a', 'b')) {
            $object = "$OutputDirectory\units\$source.obj"
            $pdb = "$object.pdb"
            if ($phase -eq 'fresh') { Remove-Item -LiteralPath $object, $pdb }
            Compile @("/Fo$object", "/Fd$pdb", "$OutputDirectory\inputs\$source.cpp")
            $guid = Audit-Identity $pdb $object
            if ($phase -eq 'cold') {
                $coldGuid[$source] = $guid
                if ($source -eq 'b') { $bHash = (Get-FileHash $pdb).Hash }
            } elseif ($source -eq 'b') {
                if ($guid -ne $coldGuid.b -or (Get-FileHash $pdb).Hash -ne $bHash) {
                    throw 'Independent b.cpp compiler PDB was changed by another action.'
                }
            } elseif ($phase -eq 'warm-existing') {
                if ($guid -ne $coldGuid.a) { throw 'Warm a.cpp hit did not restore its original genuine identity.' }
            } elseif ($phase -eq 'source-changed') {
                if ($guid -eq $coldGuid.a) { throw 'Source miss did not generate a fresh genuine private PDB.' }
                $newGuid = $guid
            } elseif ($guid -ne $newGuid) {
                throw 'New-generation warm hit restored a mismatched compiler PDB.'
            }
        }
        Link-And-Audit $phase @("$OutputDirectory\units\a.obj", "$OutputDirectory\units\b.obj")
        if ($phase -in @('source-changed', 'final-warm', 'fresh')) {
            $types = & pdbdump.exe "$OutputDirectory\$phase-link.pdb" types 2>&1
            if ($LASTEXITCODE) { throw 'PDB type dump failed.' }
            $types | Set-Content -LiteralPath "$OutputDirectory\$phase-linked-types.txt"
            $record = @($types | Where-Object { "$_" -match 'struct PublicOrdinaryGeneration' -and "$_" -notmatch 'fwdref' })
            if ($record.Count -ne 1 -or -not "$record".Contains('values[72<')) {
                throw 'Source-change debug type did not survive the linker.'
            }
        }
        $current = Stats $phase
        $hits = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $misses = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($phase -eq 'cold') { 0 } elseif ($phase -eq 'source-changed') { 1 } else { 2 }
        if ($hits -ne $expectedHits -or $misses -ne 2 - $expectedHits) {
            throw "Unexpected ordinary private-PDB cache behavior: $phase hits=$hits misses=$misses"
        }
        $previous = $current
    }
    # Populate a real shared-PDB cache entry without opting in, then prove the
    # opt-in rejects its shared /Fd BEFORE any read/execution on the server.
    $env:SCCACHE_MSVC_PRIVATE_PDB = ''
    Compile @("/Fo$OutputDirectory\shared-a.obj", "/Fd$OutputDirectory\shared.pdb", "$OutputDirectory\inputs\a.cpp")
    Compile @("/Fo$OutputDirectory\shared-b.obj", "/Fd$OutputDirectory\shared.pdb", "$OutputDirectory\inputs\b.cpp")
    $before = Stats 'shared-loaded'
    $env:SCCACHE_MSVC_PRIVATE_PDB = '1'
    Compile @("/Fo$OutputDirectory\shared-a.obj", "/Fd$OutputDirectory\shared.pdb", "$OutputDirectory\inputs\a.cpp")
    $after = Stats 'shared-rejected'
    if ($after.requests_executed -ne $before.requests_executed -or
        $after.cache_hits.counts.'C/C++' -ne $before.cache_hits.counts.'C/C++' -or
        $after.cache_misses.counts.'C/C++' -ne $before.cache_misses.counts.'C/C++' -or
        $after.not_cached.'private PDB must be per object' -ne 1) {
        throw 'Shared /Fd reached cache lookup despite the private-PDB guard.'
    }
    python Inspect-Pdb.py "$OutputDirectory\shared.pdb" "$OutputDirectory\shared-a.obj" "$OutputDirectory\shared-b.obj"
    if ($LASTEXITCODE) { throw 'Shared-PDB fallback lost another object debug identity.' }
    Link-And-Audit 'shared-safe' @("$OutputDirectory\shared-a.obj", "$OutputDirectory\shared-b.obj")
    Write-Output 'PASS ordinary /Zi warm-existing hits, independent identities, source-change reseeding, shared /Fd rejected before reads'
} finally {
    $env:SCCACHE_MSVC_PRIVATE_PDB = ''
    & $Sccache --stop-server
}
