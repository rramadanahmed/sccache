param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$CMake,
    [Parameter(Mandatory)][string]$Ninja,
    [Parameter(Mandatory)][string]$Compiler,
    [string]$OutputDirectory = 'out-cmake-snapshot'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-Location $PSScriptRoot
$env:SCCACHE_DIR = $CacheDirectory
$env:SCCACHE_SERVER_PORT = [string]$Port
$env:SCCACHE_IDLE_TIMEOUT = '120'
$env:SCCACHE_DIRECT = 'true'
$env:SCCACHE_MSVC_PRIVATE_PDB = ''
$env:SCCACHE_MSVC_PCH_PDB = ''
$env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = '1'
$env:CL = ''
$env:_CL_ = ''
$env:CMAKE_BUILD_PARALLEL_LEVEL = '1'
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
$null = New-Item -ItemType Directory -Path "$OutputDirectory\source"
Copy-Item -LiteralPath CMakeLists.txt,pch.cpp,pch.h,seed-a.cpp,seed-b.cpp -Destination "$OutputDirectory\source"
(Get-Content -Raw "$OutputDirectory\source\seed-a.cpp").Replace(
    'long long data[17]', 'long long data[PUBLIC_PCH_VALUE + 10]') |
    Set-Content -LiteralPath "$OutputDirectory\source\seed-a.cpp"
$source = (Resolve-Path "$OutputDirectory\source").Path
$build = Join-Path (Resolve-Path $OutputDirectory).Path 'build'
function Stats([string]$Phase) {
    $json = & $Sccache --show-stats --stats-format=json
    if ($LASTEXITCODE) { throw 'Cache stats failed.' }
    $json | Set-Content -LiteralPath "$OutputDirectory\$Phase-stats.json"
    return ($json | ConvertFrom-Json).stats
}
function Build([string]$Phase) {
    $output = & $CMake --build $build --parallel 1 -- -d keeprsp 2>&1
    $code = $LASTEXITCODE
    $output | Set-Content -LiteralPath "$OutputDirectory\$Phase-build.log"
    $output
    if ($code -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw "CMake Debug build failed: $Phase" }
}
try {
    & $CMake -S $source -B $build -G Ninja '-DCMAKE_BUILD_TYPE=Debug' '-DCMAKE_NINJA_FORCE_RESPONSE_FILE=ON' "-DCMAKE_CXX_COMPILER=$Compiler" "-DCMAKE_MAKE_PROGRAM=$Ninja" "-DSCCACHE_EXECUTABLE=$Sccache" *> "$OutputDirectory\configure.log"
    if ($LASTEXITCODE) { throw 'Public CMake configure failed.' }
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $previous = Stats 'ready'
    $originalSnapshot = ''
    foreach ($phase in @('cold','creator-warm','creator-fresh','creator-changed','changed-warm')) {
        if ($phase -in @('creator-warm','changed-warm')) {
            # Trigger the producer without changing its textual compilation key.
            & $CMake -E touch "$source\pch.cpp"
            if ($LASTEXITCODE) { throw 'Public creator timestamp update failed.' }
        }
        if ($phase -eq 'creator-fresh') {
            Remove-Item -LiteralPath "$build\group.pch","$build\pch.obj","$build\pch.obj.pdb"
        }
        if ($phase -eq 'creator-changed') {
            (Get-Content -Raw "$source\pch.h").Replace('VALUE 7','VALUE 9') |
                Set-Content -LiteralPath "$source\pch.h"
        }
        if ($phase -ne 'cold') {
            # A reused linker PDB may legitimately retain old type records.
            # Fresh link outputs make this phase's type-layout audit unambiguous.
            Remove-Item -LiteralPath "$build\public_seeded_probe.exe","$build\link.pdb"
        }
        Build $phase
        $snapshotHash = (Get-FileHash "$build\snapshot.pdb").Hash
        if ($snapshotHash -ne (Get-FileHash "$build\pch.obj.pdb").Hash) {
            throw 'CMake published snapshot differs from the completed creator PDB.'
        }
        if ($phase -eq 'cold') { $originalSnapshot = $snapshotHash }
        if ($phase -in @('creator-warm','creator-fresh') -and $snapshotHash -ne $originalSnapshot) {
            throw 'Creator cache restoration changed its genuine snapshot generation.'
        }
        if ($phase -eq 'creator-changed' -and $snapshotHash -eq $originalSnapshot) {
            throw 'Creator regeneration did not invalidate its snapshot.'
        }
        python Inspect-Pdb.py "$build\pch.obj.pdb" "$build\pch.obj"
        if ($LASTEXITCODE) { throw 'CMake creator PDB/COFF mismatch.' }
        python Inspect-Pdb.py --objects-directory "$build\CMakeFiles\public_seeded_probe.dir"
        if ($LASTEXITCODE) { throw 'CMake private consumer PDB/COFF mismatch.' }
        python Inspect-Pdb.py "$build\link.pdb" --pe "$build\public_seeded_probe.exe"
        if ($LASTEXITCODE) { throw 'CMake linker PE/PDB mismatch.' }
        $types = & pdbdump.exe "$build\link.pdb" types 2>&1
        if ($LASTEXITCODE) { throw 'Native linked PDB type dump failed.' }
        $types | Set-Content -LiteralPath "$OutputDirectory\$phase-linked-types.txt"
        $alpha = @($types | Where-Object { "$_" -match 'struct PublicAlpha' -and "$_" -notmatch 'fwdref' })
        $alphaBytes = if ($phase -in @('creator-changed','changed-warm')) { 152 } else { 136 }
        if ($alpha.Count -ne 1 -or -not "$alpha".Contains("data[$alphaBytes<")) {
            throw 'Creator-dependent source debug layout is stale.'
        }
        & "$build\public_seeded_probe.exe"
        if ($LASTEXITCODE) { throw 'Public CMake executable failed.' }
        $current = Stats $phase
        $hits = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $misses = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($phase -in @('cold','creator-changed')) { 0 } else { 3 }
        if ($hits -ne $expectedHits -or $misses -ne 3 - $expectedHits) {
            throw "CMake dependency scheduling/cache behavior mismatch: $phase hits=$hits misses=$misses"
        }
        Write-Output "PASS public CMake $phase hits=$hits misses=$misses; creator -> snapshot -> both dependent consumers"
        $previous = $current
    }
    Build 'noop'
    $final = Stats 'noop'
    if ($final.compile_requests -ne $previous.compile_requests) { throw 'CMake no-op unexpectedly invoked the compiler.' }
    Write-Output 'PASS genuine snapshot dependencies, forced @rsp, warm/fresh creator triple hits and all-consumer invalidation'
} finally {
    & $Sccache --stop-server
}
