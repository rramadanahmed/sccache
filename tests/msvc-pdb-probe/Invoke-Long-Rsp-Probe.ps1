param(
    [Parameter(Mandatory)][string]$Sccache,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][int]$Port,
    [string]$OutputDirectory = 'out-long-rsp',
    [switch]$Direct,
    [switch]$ExpectBackendFailure,
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
$env:SCCACHE_MSVC_PCH_PDB = ''
$env:SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES = '1'
$env:CL = ''
$env:_CL_ = ''
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
if (Get-ChildItem -LiteralPath $OutputDirectory) { throw 'Choose a fresh owned output directory.' }
$null = New-Item -ItemType Directory -Path "$OutputDirectory\inputs", "$OutputDirectory\public includes"
Copy-Item -LiteralPath a.cpp,b.cpp -Destination "$OutputDirectory\inputs"
@'
#pragma once
#include <vector>
#include <long-public-value.h>
#define PUBLIC_PCH_VALUE PUBLIC_LONG_VALUE
inline int public_pch_value() { return PUBLIC_PCH_VALUE; }
inline const char *public_rsp_text() { return LONG_RSP_TEXT; }
'@ | Set-Content -LiteralPath "$OutputDirectory\inputs\pch.h" -Encoding utf8
'#include "pch.h"' | Set-Content -LiteralPath "$OutputDirectory\inputs\pch.cpp" -Encoding ascii
(Get-Content -Raw "$OutputDirectory\inputs\b.cpp").Replace(
    'public_a() == PUBLIC_PCH_VALUE + 4', "public_a() == PUBLIC_PCH_VALUE + 4 && public_rsp_text()[0] == 'p'") |
    Set-Content -LiteralPath "$OutputDirectory\inputs\b.cpp"
$headerDirectory = (Resolve-Path "$OutputDirectory\public includes").Path
'#define PUBLIC_LONG_VALUE 7' | Set-Content -LiteralPath "$headerDirectory\long-public-value.h" -Encoding ascii
$flags = @('/nologo','/c','/MDd','/Od','/Zi','/EHsc','/D_ITERATOR_DEBUG_LEVEL=2','/DLONG_RSP_TEXT="public value"')
if ($WarningsAsErrors) { $flags += '/WX' }
$includes = @("/I$headerDirectory")
while (($includes -join ' ').Length -lt 55100) {
    $name = ('padding-' + ('x' * 55) + '-Ω-😀-{0:D3}' -f $includes.Count)
    $directory = Join-Path $headerDirectory $name
    $null = New-Item -ItemType Directory -Path $directory
    $includes += "/I$directory"
}
function Quote-Rsp([string]$Argument) {
    $escaped = [regex]::Replace($Argument, '(\\*)"', {
        param($m) ('\' * (2 * $m.Groups[1].Value.Length + 1)) + '"'
    })
    $escaped = [regex]::Replace($escaped, '\\+$', { param($m) $m.Value + $m.Value })
    return '"' + $escaped + '"'
}
function Write-Rsp([string]$Name, [string[]]$Arguments) {
    $expanded = @($flags + $includes + $Arguments)
    $argumentUnits = ($expanded -join ' ').Length
    $text = ($expanded | ForEach-Object { Quote-Rsp $_ }) -join "`n"
    if ($argumentUnits -lt 55000) { throw 'Expanded arguments are below the required 55,000 UTF16 units.' }
    $path = "$OutputDirectory\$Name.rsp"
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot $path), $text, [Text.UnicodeEncoding]::new($false,$true))
    Write-Host "$Name expanded UTF16 units=$argumentUnits response UTF16 units=$($text.Length) arguments=$($expanded.Count)"
    return (Resolve-Path $path).Path
}
$creator = Write-Rsp 'creator' @('/Ycpch.h', "/Fp$OutputDirectory\group.pch",
    "/Fd$OutputDirectory\pch.obj.pdb", "/Fo$OutputDirectory\pch.obj", "$OutputDirectory\inputs\pch.cpp")
$a = Write-Rsp 'a' @('/Yupch.h', "/Fp$OutputDirectory\group.pch",
    "/Fd$OutputDirectory\a.obj.pdb", "/Fo$OutputDirectory\a.obj", "$OutputDirectory\inputs\a.cpp")
$b = Write-Rsp 'b' @('/Yupch.h', "/Fp$OutputDirectory\group.pch",
    "/Fd$OutputDirectory\b.obj.pdb", "/Fo$OutputDirectory\b.obj", "$OutputDirectory\inputs\b.cpp")
function Compile-Rsp([string]$Response) {
    & $Sccache cl.exe "@$Response"
    if ($LASTEXITCODE) { throw "Long response-file compiler invocation failed: $Response" }
}
function Stats([string]$Phase) {
    $json = & $Sccache --show-stats --stats-format=json
    if ($LASTEXITCODE) { throw 'Cache stats failed.' }
    $json | Set-Content -LiteralPath "$OutputDirectory\$Phase-stats.json"
    return ($json | ConvertFrom-Json).stats
}
function Audit-And-Link([string]$Phase) {
    foreach ($source in @('a','b')) {
        python Inspect-Pdb.py "$OutputDirectory\$source.obj.pdb" "$OutputDirectory\$source.obj"
        if ($LASTEXITCODE) { throw 'Long response-file COFF/PDB mismatch.' }
    }
    $output = & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\$Phase.exe" "/PDB:$OutputDirectory\$Phase-link.pdb" "$OutputDirectory\pch.obj" "$OutputDirectory\a.obj" "$OutputDirectory\b.obj" 2>&1
    $output
    if ($LASTEXITCODE -or "$output" -match 'LNK4205|LNK4099|LNK4111') { throw 'Long response-file debug linking failed.' }
    python Inspect-Pdb.py "$OutputDirectory\$Phase-link.pdb" --pe "$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Long response-file PE/PDB mismatch.' }
    & ".\$OutputDirectory\$Phase.exe"
    if ($LASTEXITCODE) { throw 'Long response-file public executable failed.' }
}
try {
    if ($ExpectBackendFailure) {
        & cl.exe "@$creator"
        if ($LASTEXITCODE) { throw 'Native cl could not consume the public long response file.' }
        python Inspect-Pdb.py "$OutputDirectory\pch.obj.pdb" "$OutputDirectory\pch.obj"
        if ($LASTEXITCODE) { throw 'Native long-command creator PDB invalid.' }
    }
    & $Sccache --start-server
    if ($LASTEXITCODE) { throw 'Cache server failed.' }
    $null = Stats 'ready'
    if (-not $ExpectBackendFailure) { Compile-Rsp $creator }
    Copy-Item -LiteralPath "$OutputDirectory\pch.obj.pdb" -Destination "$OutputDirectory\snapshot.pdb"
    $env:SCCACHE_MSVC_PCH_PDB = (Resolve-Path "$OutputDirectory\snapshot.pdb").Path
    if ($ExpectBackendFailure) {
        $output = & $Sccache cl.exe "@$a" 2>&1
        $code = $LASTEXITCODE
        $output | Set-Content -LiteralPath "$OutputDirectory\backend-failure.log"
        if ($code -eq 0 -or "$output" -notmatch 'os error 206|filename or extension is too long|command line is too long') {
            throw "Expected expanded CreateProcess length failure; exit=$code output=$output"
        }
        $null = Stats 'backend-failure'
        Write-Output "PASS negative proof: native cl @55k.rsp works; fixed pre-response backend @rsp fails expanded CreateProcess with exit=$code"
        return
    }
    (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $true
    $seedHash = (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash
    $creatorHash = (Get-FileHash "$OutputDirectory\pch.obj.pdb").Hash
    $pchHash = (Get-FileHash "$OutputDirectory\group.pch").Hash
    $previous = Stats 'creator-cold'
    foreach ($phase in @('cold','warm-existing','fresh')) {
        if ($phase -eq 'warm-existing') {
            Copy-Item -LiteralPath $a -Destination "$OutputDirectory\renamed-a.rsp"
            Copy-Item -LiteralPath $b -Destination "$OutputDirectory\renamed-b.rsp"
            $a = (Resolve-Path "$OutputDirectory\renamed-a.rsp").Path
            $b = (Resolve-Path "$OutputDirectory\renamed-b.rsp").Path
        }
        if ($phase -eq 'fresh') {
            Remove-Item -LiteralPath "$OutputDirectory\a.obj","$OutputDirectory\a.obj.pdb",
                "$OutputDirectory\b.obj","$OutputDirectory\b.obj.pdb"
        }
        Compile-Rsp $a
        Compile-Rsp $b
        if ($seedHash -ne (Get-FileHash "$OutputDirectory\snapshot.pdb").Hash -or
            $creatorHash -ne (Get-FileHash "$OutputDirectory\pch.obj.pdb").Hash -or
            $pchHash -ne (Get-FileHash "$OutputDirectory\group.pch").Hash) {
            throw 'Long response-file preprocessing/restore modified creator inputs.'
        }
        Audit-And-Link $phase
        $current = Stats $phase
        $hits = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $misses = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($phase -eq 'cold') { 0 } else { 2 }
        if ($hits -ne $expectedHits -or $misses -ne 2 - $expectedHits) { throw 'Incorrect long response-file cache behavior.' }
        $previous = $current
    }
    @'
struct PublicLongVariant { int values[PROBE_VARIANT]; };
PublicLongVariant public_long_variant{{7}};
int main() {
    return sizeof(public_long_variant) == sizeof(int) * PROBE_VARIANT
        && public_long_variant.values[0] == 7 ? 0 : 1;
}
'@ | Set-Content -LiteralPath "$OutputDirectory\inputs\plain.cpp" -Encoding ascii
    $lastVariant = $null
    foreach ($variant in @(1,2,2)) {
        $plain = Write-Rsp 'plain' @("/DPROBE_VARIANT=$variant",
            "/Fd$OutputDirectory\plain.obj.pdb", "/Fo$OutputDirectory\plain.obj",
            "$OutputDirectory\inputs\plain.cpp")
        Compile-Rsp $plain
        python Inspect-Pdb.py "$OutputDirectory\plain.obj.pdb" "$OutputDirectory\plain.obj"
        if ($LASTEXITCODE) { throw 'Expanded-content variant COFF/PDB mismatch.' }
        & link.exe /nologo /DEBUG /INCREMENTAL:NO "/OUT:$OutputDirectory\plain.exe" "/PDB:$OutputDirectory\plain-link.pdb" "$OutputDirectory\plain.obj"
        if ($LASTEXITCODE) { throw 'Expanded-content variant link failed.' }
        python Inspect-Pdb.py "$OutputDirectory\plain-link.pdb" --pe "$OutputDirectory\plain.exe"
        if ($LASTEXITCODE) { throw 'Expanded-content variant PE/PDB mismatch.' }
        & ".\$OutputDirectory\plain.exe"
        if ($LASTEXITCODE) { throw 'Expanded-content variant executable failed.' }
        $current = Stats "variant-$variant-$($previous.compile_requests)"
        $hits = $current.cache_hits.counts.'C/C++' - $previous.cache_hits.counts.'C/C++'
        $misses = $current.cache_misses.counts.'C/C++' - $previous.cache_misses.counts.'C/C++'
        $expectedHits = if ($lastVariant -eq $variant) { 1 } else { 0 }
        if ($hits -ne $expectedHits -or $misses -ne 1 - $expectedHits) {
            throw 'Changed contents of the same input @rsp did not affect the expanded cache key.'
        }
        $previous = $current
        $lastVariant = $variant
    }
    Write-Output 'PASS >=55k UTF16 @rsp cold/warm/fresh real cache hits, original PCH/seed/private PDBs, quoting and debug identities'
} finally {
    $env:SCCACHE_MSVC_PCH_PDB = ''
    $env:SCCACHE_MSVC_PRIVATE_PDB = ''
    if (Test-Path "$OutputDirectory\snapshot.pdb") { (Get-Item "$OutputDirectory\snapshot.pdb").IsReadOnly = $false }
    & $Sccache --stop-server
}
