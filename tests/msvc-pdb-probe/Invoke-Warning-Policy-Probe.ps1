param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-warning-policy'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-Location $PSScriptRoot
$env:SCCACHE_DIR = $CacheDirectory
$env:SCCACHE_SERVER_PORT = [string]$Port
$env:SCCACHE_IDLE_TIMEOUT = '120'
$env:SCCACHE_DIRECT = 'true'
$env:SCCACHE_MSVC_PRIVATE_PDB = '1'
$env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = '1'
$env:SCCACHE_MSVC_PCH_PDB = ''
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
@'
#pragma once
struct PublicWarningPch { int value; };
'@ | Set-Content -LiteralPath "$OutputDirectory\pch.h" -Encoding ascii
'#include "pch.h"' | Set-Content -LiteralPath "$OutputDirectory\pch.cpp" -Encoding ascii
@'
#include "pch.h"
int main() { PublicWarningPch value{7}; return value.value == 7 ? 0 : 1; }
'@ | Set-Content -LiteralPath "$OutputDirectory\good.cpp" -Encoding ascii
@'
#include "pch.h"
int main() { int public_unused; return 0; }
'@ | Set-Content -LiteralPath "$OutputDirectory\warning.cpp" -Encoding ascii
@'
#include "pch.h"
#error Public deliberate syntax-scan failure.
'@ | Set-Content -LiteralPath "$OutputDirectory\syntax.cpp" -Encoding ascii
$flags = @('/nologo','/c','/MDd','/Od','/Zi','/EHsc','/D_ITERATOR_DEBUG_LEVEL=2','/W4','/WX')
function Invoke-Checked([string]$Phase, [string[]]$Arguments, [string]$ExpectedFailure = '') {
    $output = & $Sccache cl.exe @flags @Arguments 2>&1
    $code = $LASTEXITCODE
    $output | Set-Content -LiteralPath "$OutputDirectory\$Phase.log"
    if ("$output" -match 'D9025') { throw "Scan-only normalization still emits D9025: $Phase $output" }
    if ($ExpectedFailure) {
        if ($code -eq 0 -or "$output" -notmatch $ExpectedFailure) {
            throw "Expected genuine compiler failure $ExpectedFailure in $Phase; exit=$code output=$output"
        }
    } elseif ($code) { throw "Unexpected compiler failure: $Phase $output" }
}
try {
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $ready = & $Sccache --show-stats --stats-format=json
    if ($LASTEXITCODE) { throw 'Cache server not responsive.' }
    $ready | Set-Content -LiteralPath "$OutputDirectory\ready-stats.json"
    Invoke-Checked 'ordinary-good' @("/Fd$OutputDirectory\ordinary.obj.pdb","/Fo$OutputDirectory\ordinary.obj","$OutputDirectory\good.cpp")
    Invoke-Checked 'creator-good' @('/Ycpch.h',"/Fp$OutputDirectory\group.pch","/Fd$OutputDirectory\creator.obj.pdb",
        "/Fo$OutputDirectory\creator.obj","$OutputDirectory\pch.cpp")
    Copy-Item -LiteralPath "$OutputDirectory\creator.obj.pdb" -Destination "$OutputDirectory\snapshot.pdb"
    (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $true
    $env:SCCACHE_MSVC_PCH_PDB = (Resolve-Path "$OutputDirectory\snapshot.pdb").Path
    $seedHash = (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash
    Invoke-Checked 'consumer-good' @('/Yupch.h',"/Fp$OutputDirectory\group.pch","/Fd$OutputDirectory\consumer.obj.pdb",
        "/Fo$OutputDirectory\consumer.obj","$OutputDirectory\good.cpp")
    foreach ($phase in @('ordinary','creator','consumer')) {
        $pchFlags = if ($phase -eq 'creator') { @('/Ycpch.h',"/Fp$OutputDirectory\failing.pch") }
            elseif ($phase -eq 'consumer') { @('/Yupch.h',"/Fp$OutputDirectory\group.pch") } else { @() }
        Invoke-Checked "$phase-syntax-error" @($pchFlags + @("/Fd$OutputDirectory\$phase-bad.obj.pdb",
            "/Fo$OutputDirectory\$phase-bad.obj","$OutputDirectory\syntax.cpp")) 'C1189'
    }
    # /WX- is valid only for discovery. A genuine warning in actual compilation
    # must still fail, not turn into a successful cache entry.
    Invoke-Checked 'actual-warning-error' @('/Yupch.h',"/Fp$OutputDirectory\group.pch",
        "/Fd$OutputDirectory\warning.obj.pdb","/Fo$OutputDirectory\warning.obj","$OutputDirectory\warning.cpp") 'C2220|C4101'
    $json = & $Sccache --show-stats --stats-format=json
    $json | Set-Content -LiteralPath "$OutputDirectory\final-stats.json"
    $stats = ($json | ConvertFrom-Json).stats
    if ($stats.compile_fails -ne 1 -or $stats.compilations -ne 3) {
        throw 'The /WX warning failure must occur in actual compilation after a successful scan.'
    }
    if ($seedHash -ne (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash) {
        throw 'Warning/error discovery modified the immutable genuine seed.'
    }
    python Inspect-Pdb.py "$OutputDirectory\consumer.obj.pdb" "$OutputDirectory\consumer.obj"
    if ($LASTEXITCODE) { throw 'Successful /WX consumer has an invalid real compiler PDB.' }
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\good.exe" "/PDB:$OutputDirectory\link.pdb" "$OutputDirectory\creator.obj" "$OutputDirectory\consumer.obj" 2>&1
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw 'Successful /WX debug link failed.' }
    python Inspect-Pdb.py "$OutputDirectory\link.pdb" --pe "$OutputDirectory\good.exe"
    if ($LASTEXITCODE) { throw 'Successful /WX PE/PDB identity mismatch.' }
    & ".\$OutputDirectory\good.exe"
    if ($LASTEXITCODE) { throw 'Successful /WX public executable failed.' }
    Write-Output 'PASS ordinary/creator/consumer successful and failing scans: zero D9025; actual /WX warning remains a real compilation failure'
} finally {
    $env:SCCACHE_MSVC_PCH_PDB = ''
    $env:SCCACHE_MSVC_PRIVATE_PDB = ''
    $env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = ''
    if (Test-Path "$OutputDirectory\snapshot.pdb") { (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $false }
    & $Sccache --stop-server
}
