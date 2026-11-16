# Local MSVC PCH caching with embedded debug information

Native MSVC `/Z7` builds can opt into local PCH caching with
`SCCACHE_MSVC_PCH_DETERMINISTIC=1`. This is a **deterministic-input contract**,
not automatic detection of safe PCH contents. Set it only when the creator,
PCH state and consumers do not depend on volatile inputs, including
`__DATE__`, `__TIME__` and `__TIMESTAMP__` (even through macro indirection or
deferred expansion from a PCH). Files must not change during a compilation.
Without this opt-in, active PCH compilations bypass the cache.

Use server-side mode with a local disk cache dedicated to this machine.
Remote/multi-level storage and client-side mode are rejected when this opt-in
is used for a PCH. No distributed compilation or cross-machine/cross-directory
PCH portability is supported; `SCCACHE_BASEDIRS` does not relax this restriction.

## Supported commands

Use `/c /Z7`, an explicit `/Fp` filename, and a literal named `/Yc` or `/Yu`
boundary, for example in a Visual Studio developer PowerShell:

```powershell
$env:SCCACHE_MSVC_PCH_DETERMINISTIC = '1'
sccache cl /nologo /c /Z7 /Ycstdafx.h /Fppch.pch /Fopch.obj creator.cpp
sccache cl /nologo /c /Z7 /Yustdafx.h /Fppch.pch /Foa.obj a.cpp
```

Both original flags are retained when a creator has `/Yustdafx.h /Ycstdafx.h`;
`/Yc` takes precedence in either order. Different-boundary `/Yc`+`/Yu` hybrids,
unnamed boundaries and implicit/directory `/Fp` outputs remain unsupported.
`/Y-` disables PCH use regardless of its position. An inactive `/Fp` does not
prevent ordinary object caching.

`/Zi` and `/ZI` PCH compilations remain uncached, including when `/Fd` is
present or `/Z7` is also specified. There is no compiler-PDB management.
Consumers must use a compatible genuine `/Z7` PCH; the compiler checks this
before any lookup. Linker `/DEBUG` PDB generation is unaffected.

## Cache correctness

A creator entry contains the real compiler-produced PCH and its matching OBJ.
A consumer key includes the actual binary PCH, raw source, consumed
dependencies, original flags, output paths, compiler path, working directory
and environment. Rebuild the creator when its inputs change: editing a
creator header alone does not change an already-built PCH's state.

Each lookup runs a real `/Zs /sourceDependencies` front-end pass with the
original boundary flags and `/Z7`. Creator scans use a temporary PCH output
because even `/Zs /Yc` writes a PCH. Temporary filenames and scan PCH bytes
are not key inputs. Genuine outputs are not changed by the scan.
Consumers use the original binary PCH, not `/E`, `/EP` or `/Y-` textual
preprocessing: these would read headers that `/Yu` actually ignores.
Requested `/showIncludes` and file-form `/sourceDependencies` describe the
current scan, including on hits. No warnings are disabled by the PCH path.
This front-end work is performed even on hits. Creator scans still generate
a disposable PCH, so caching does not eliminate PCH generation cost.

## Reproducible validation

With Rust 1.91.0 and MSVC available in a developer shell:

```powershell
cargo test --locked --lib --test system embedded_pch -- --nocapture
```

The native test uses its own temporary cache and loopback port. It asserts
four initial misses, eight warm/fresh hits restoring byte-identical PCH/OBJ
outputs, ignored shadow headers containing `#error`, both creator flag orders,
source/header/define/creator changes, externally regenerated PCHs, `/Y-`,
and uncached `/Zi`/`/ZI` actions. It compares dependencies with direct MSVC,
audits embedded COFF type records (no compiler-PDB type-server references),
distinct type layouts, linker PDB/PE GUID+age identities and nine program runs.
Its required hit assertions fail on unmodified upstream; `/E` failing on the
shadow header is a second negative control.
