# MSVC PCH and PDB validation

These are standalone Windows probes using only the synthetic sources in this
directory. They supplement the Rust tests; they are not automatically run by
`cargo test`.

Use an x64 MSVC developer PowerShell with `cl.exe`, `link.exe`, Python 3 and
`pdbdump.exe` on `PATH`. The PCH probes require MSVC source-dependency JSON
version 1.2. The CMake probe also needs CMake 4.3 or newer and Ninja.
Qualification used MSVC 14.42 amd64.

## Required upstream checks

From the repository root, using the toolchain selected by upstream CI
(Rust 1.91.0 for this branch's base):

```powershell
cargo +1.91.0 fmt -- --check
cargo +1.91.0 clippy --locked --all-targets -- -D warnings -A unknown-lints -A clippy::type_complexity -A clippy::new-without-default
cargo +1.91.0 test --locked --lib --bins --tests
cargo +1.91.0 test --locked --no-default-features --lib compiler::msvc::test -- --test-threads=1
cargo +1.91.0 build --locked --no-default-features --bin sccache
```

Keep cross-platform, feature-matrix and real-compiler checks separate from the
local results. A successful test executable may skip unavailable CUDA, HIP or
other compiler coverage; it does not prove those compilers were exercised.

## Real MSVC checks

Run each probe in a fresh PowerShell child so it cannot change the calling
shell's compiler/cache environment. Use a fresh cache/output path for each run
and an unused loopback port. Do not clear an existing shared cache.
The scripts stop their own cache server in `finally`.

From the repository root, capture absolute tool paths before the scripts change
their working directory:

```powershell
$sccache = (Resolve-Path .\target\debug\sccache.exe).Path
$probe = (Resolve-Path .\tests\msvc-pdb-probe).Path
$run = [Guid]::NewGuid().ToString('N')
$cacheRoot = Join-Path $env:TEMP "sccache-public-$run"

$checks = @(
    'Invoke-Probe.ps1',
    'Invoke-Seeded-Probe.ps1',
    'Invoke-119-Users-Probe.ps1',
    'Invoke-Private-Pdb-Probe.ps1',
    'Invoke-Creator-Snapshot-Probe.ps1',
    'Invoke-Shadow-Pch-Probe.ps1',
    'Invoke-Long-Rsp-Probe.ps1'
)
$port = 49100 # Choose an unused range on this machine.
foreach ($check in $checks) {
    foreach ($direct in @($false, $true)) {
        $port++
        $name = "$([IO.Path]::GetFileNameWithoutExtension($check))-$direct-$run"
        $arguments = @(
            '-NoProfile', '-File', (Join-Path $probe $check),
            '-Sccache', $sccache,
            '-CacheDirectory', (Join-Path $cacheRoot $name),
            '-Port', "$port", '-OutputDirectory', "out-$name"
        )
        if ($direct) { $arguments += '-Direct' }
        if ($check -in @('Invoke-Shadow-Pch-Probe.ps1', 'Invoke-Long-Rsp-Probe.ps1')) {
            $arguments += '-WarningsAsErrors'
        }
        & pwsh @arguments
        if ($LASTEXITCODE) { throw "Probe failed: $name" }
    }
}

foreach ($check in @('Invoke-Fallback-Probe.ps1', 'Invoke-Warning-Policy-Probe.ps1')) {
    $port++
    $name = "$([IO.Path]::GetFileNameWithoutExtension($check))-$run"
    & pwsh -NoProfile -File (Join-Path $probe $check) -Sccache $sccache `
        -CacheDirectory (Join-Path $cacheRoot $name) -Port $port -OutputDirectory "out-$name"
    if ($LASTEXITCODE) { throw "Probe failed: $name" }
}

$cmake = (Get-Command cmake.exe).Source
$ninja = (Get-Command ninja.exe).Source
$compiler = (Get-Command cl.exe).Source
$port++
& pwsh -NoProfile -File "$probe\Invoke-CMake-Snapshot-Probe.ps1" `
    -Sccache $sccache -CacheDirectory (Join-Path $cacheRoot 'cmake') -Port $port `
    -CMake $cmake -Ninja $ninja -Compiler $compiler -OutputDirectory "out-cmake-$run"
if ($LASTEXITCODE) { throw 'CMake snapshot probe failed.' }
```

If `CARGO_TARGET_DIR` is customized, use its actual binary path instead.

## Acceptance criteria

- An existing shared compiler PDB is rejected before cache lookup, so restoring
  another translation unit cannot roll its type records back.
- Ordinary private object/PDB pairs and creator PCH/object/PDB triples survive
  warm-existing and removed-output restoration. Creator success precedes
  immutable snapshot publication.
- All 119 PCH consumers produce 119 warm-existing hits and 119 fresh-output
  hits in each cache mode, with no modification of the immutable creator state.
- Source, consumed header, PCH and seed changes invalidate the appropriate
  entries. An ignored consumer-local shadow `stdafx.h` does not replace the
  actual PCH state or enter its dependency set.
- Expanded response files exceed 55,000 UTF-16 units. Renaming a response file
  preserves the key; changing its effective arguments invalidates the key.
- Unsupported options remain non-cacheable. Client-side fallback requires a
  genuine preseeded private PDB; sccache's miss-only seeding is insufficient.
- Discovery emits no D9025 from overriding `/WX`. Actual compilation still
  fails on a real warning selected as an error.
- Compiler PDB/COFF and linker PDB/PE GUID/age identities match, divergent type
  layouts remain distinct, and the linked programs return their expected
  results. No `/Z7` substitution, fabricated identities or suppressed missing-PDB
  diagnostics are accepted.
- CMake schedules creator, snapshot and consumers correctly after creator
  changes; its final no-op issues no compile requests.

The semantic dependency mode is an explicit deterministic-input contract.
Volatile macro aliases or token-pasting hidden inside a PCH are outside it.
Hits still perform a real syntax/dependency scan. Distributed or cross-machine
PCH portability and clang-cl PCH caching are not enabled.
