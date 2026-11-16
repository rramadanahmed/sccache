param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-fallback'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-Location $PSScriptRoot
$env:SCCACHE_DIR = $CacheDirectory
$env:SCCACHE_SERVER_PORT = [string]$Port
$env:SCCACHE_IDLE_TIMEOUT = '120'
$env:SCCACHE_MSVC_PRIVATE_PDB = '1'
$env:SCCACHE_MSVC_PCH_PDB = ''
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
$flags = @('/nologo', '/c', '/MDd', '/Od', '/Zi', '/EHsc', '/D_ITERATOR_DEBUG_LEVEL=2')
function Consumer([string]$Name, [string]$Source) {
    & $Sccache cl.exe @flags /FA "/Fa$OutputDirectory\$Name.asm" /Yupch.h "/Fp$OutputDirectory\group.pch" "/Fd$OutputDirectory\$Name.obj.pdb" "/Fo$OutputDirectory\$Name.obj" $Source 2>&1
}
function Seed-Owned-Consumer([string]$Name) {
    $object = "$OutputDirectory\$Name.obj"
    $pdb = "$object.pdb"
    if (Test-Path -LiteralPath $object) { Remove-Item -LiteralPath $object }
    $temporary = "$pdb.seed-copy"
    Copy-Item -LiteralPath "$OutputDirectory\creator.pdb" -Destination $temporary
    (Get-Item -LiteralPath $temporary).IsReadOnly = $false
    [IO.File]::Move((Join-Path $PSScriptRoot $temporary), (Join-Path $PSScriptRoot $pdb), $true)
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    & $Sccache cl.exe @flags /Ycpch.h "/Fp$OutputDirectory\group.pch" "/Fd$OutputDirectory\creator.pdb" "/Fo$OutputDirectory\pch.obj" pch.cpp
    if ($LASTEXITCODE) { throw 'Genuine creator failed.' }
    $env:SCCACHE_MSVC_PCH_PDB = (Resolve-Path "$OutputDirectory\creator.pdb").Path
    (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $true
    $seedHash = (Get-FileHash "$OutputDirectory\creator.pdb").Hash
    $output = Consumer 'a' 'a.cpp'
    $unseededExit = $LASTEXITCODE
    $output | Set-Content -LiteralPath "$OutputDirectory\unseeded-fallback.log"
    if ($unseededExit -eq 0 -or "$output" -notmatch 'C2859') {
        throw 'Expected real C2859 from unseeded non-cacheable /Yu fallback.'
    }
    foreach ($source in @('a', 'b')) {
        # This synthetic wrapper owns the precise paths. A real wrapper must
        # first establish effective /Yu, /Fo and /Fd after response/env expansion.
        Seed-Owned-Consumer $source
        $output = Consumer $source "$source.cpp"
        $code = $LASTEXITCODE
        $output | Set-Content -LiteralPath "$OutputDirectory\$source-seeded-fallback.log"
        if ($code) { throw "Seeded original-compiler fallback failed: $source" }
        if (-not (Test-Path "$OutputDirectory\$source.asm")) { throw 'Original /FA output was not produced.' }
        python Inspect-Pdb.py "$OutputDirectory\$source.obj.pdb" "$OutputDirectory\$source.obj"
        if ($LASTEXITCODE) { throw 'Fallback private COFF/PDB mismatch.' }
    }
    if ($seedHash -ne (Get-FileHash "$OutputDirectory\creator.pdb").Hash) {
        throw 'Fallback modified the immutable creator PDB.'
    }
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\fallback.exe" "/PDB:$OutputDirectory\link.pdb" "$OutputDirectory\pch.obj" "$OutputDirectory\a.obj" "$OutputDirectory\b.obj" 2>&1
    $output
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw 'Fallback debug link failed.' }
    python Inspect-Pdb.py "$OutputDirectory\link.pdb" --pe "$OutputDirectory\fallback.exe"
    if ($LASTEXITCODE) { throw 'Fallback PE/PDB mismatch.' }
    & ".\$OutputDirectory\fallback.exe"
    if ($LASTEXITCODE) { throw 'Fallback public executable failed.' }
    $json = & $Sccache --show-stats --stats-format=json
    $json | Set-Content -LiteralPath "$OutputDirectory\final-stats.json"
    $stats = ($json | ConvertFrom-Json).stats
    $nonCacheableFa = [int]$stats.not_cached.'/FA' + [int]$stats.not_cached.'-FA'
    if ($nonCacheableFa -ne 3 -or $stats.cache_hits.counts.'C/C++' -gt 0) {
        throw 'Expected three real non-cacheable /FA client fallbacks, not cache hits.'
    }
    Write-Output "PASS exact non-cacheable /Yu path: unseeded C2859 exit=$unseededExit; wrapper preseed gives genuine PDBs + original /FA outputs and successful execution"
} finally {
    $env:SCCACHE_MSVC_PRIVATE_PDB = ''
    $env:SCCACHE_MSVC_PCH_PDB = ''
    if (Test-Path "$OutputDirectory\creator.pdb") {
        (Get-Item "$OutputDirectory\creator.pdb").IsReadOnly = $false
    }
    & $Sccache --stop-server
}
