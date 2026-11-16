[![Build Status](https://github.com/mozilla/sccache/workflows/ci/badge.svg)](https://github.com/mozilla/sccache/actions?query=workflow%3Aci)
[![Crates.io](https://img.shields.io/crates/v/sccache.svg)](https://crates.io/crates/sccache)
[![Matrix](https://img.shields.io/matrix/sccache:mozilla.org)](https://chat.mozilla.org/#/room/#sccache:mozilla.org)
![Crates.io](https://img.shields.io/crates/l/sccache)

[![CodeCov](https://codecov.io/gh/mozilla/sccache/branch/main/graph/badge.svg)](https://codecov.io/gh/mozilla/sccache)


sccache - Shared Compilation Cache
==================================

sccache is a [ccache](https://ccache.dev/)-like compiler caching tool. It is used as a compiler wrapper and avoids compilation when possible, storing cached results either on [local disk](docs/Local.md) or in one of [several cloud storage backends](#storage-options). Multi-level caching with automatic backfill is supported for hierarchical cache architectures (see [Multi-Level Cache](docs/MultiLevel.md)).

sccache includes support for caching the compilation of Assembler, C/C++ code, [Rust](docs/Rust.md), as well as NVIDIA's CUDA using [nvcc](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html), and [clang](https://llvm.org/docs/CompileCudaWithLLVM.html), [AMD's ROCm HIP](https://rocm.docs.amd.com/projects/HIP/en/latest/index.html).

sccache also provides [icecream](https://github.com/icecc/icecream)-style distributed compilation (automatic packaging of local toolchains) for all supported compilers (including Rust). The distributed compilation system includes several security features that icecream lacks such as authentication, transport layer encryption, and sandboxed compiler execution on build servers. See [the distributed quickstart](docs/DistributedQuickstart.md) guide for more information.

sccache is also available as a [GitHub Actions](https://github.com/marketplace/actions/sccache-action) to facilitate the deployment using GitHub Actions cache.

---

Table of Contents (ToC)
=======================

* [Installation](#installation)
* [Usage](#usage)
* [Build Requirements](#build-requirements)
* [Build](#build)
  * [Profile-guided optimization](docs/PGO.md)
* [Separating caches between invocations](#separating-caches-between-invocations)
* [Overwriting the cache](#overwriting-the-cache)
* [Debugging](#debugging)
* [Interaction with GNU `make` jobserver](#interaction-with-gnu-make-jobserver)
* [Known Caveats](#known-caveats)
* [Storage Options](#storage-options)
  * [Multi-Level (Hierarchical Caching)](docs/MultiLevel.md)
  * [Local](docs/Local.md)
  * [S3](docs/S3.md)
  * [R2](docs/S3.md#R2)
  * [Redis](docs/Redis.md)
  * [Memcached](docs/Memcached.md)
  * [Google Cloud Storage](docs/Gcs.md)
  * [Azure](docs/Azure.md)
  * [GitHub Actions](docs/GHA.md)
  * [WebDAV (Ccache/Bazel/Gradle compatible)](docs/Webdav.md)
  * [Alibaba OSS](docs/OSS.md)
  * [Tencent Cloud Object Storage](docs/COS.md)

---

## Installation

There are prebuilt x86-64 binaries available for Windows, Linux (a portable binary compiled against musl), and macOS [on the releases page](https://github.com/mozilla/sccache/releases/latest). Several package managers also include sccache packages, you can install the latest release from source using cargo, or build directly from a source checkout.

### macOS

On macOS sccache can be installed via [Homebrew](https://brew.sh/):

```bash
brew install sccache
```

or via [MacPorts](https://www.macports.org/):

```bash
sudo port install sccache
```

### Windows

On Windows, sccache can be installed via [scoop](https://scoop.sh/):

```
scoop install sccache
```
or `winget`:

```
winget install Mozilla.sccache
```

### Via cargo

If you have a Rust toolchain installed you can install sccache using cargo. **Note that this will compile sccache from source which is fairly resource-intensive. For CI purposes you should use prebuilt binary packages.**

```bash
cargo install sccache --locked
```

Or, using [cargo-binstall](https://github.com/cargo-bins/cargo-binstall) to install a prebuilt binary:

```bash
cargo binstall sccache
```

### With Nix

Sccache is available in nixpkgs, so if you don't need the latest version you can use that:

```nix
buildInputs = [ pkgs.sccache ];
```

We also provide a flake with an overlay for getting the latest version:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sccache = {
      url = "github:mozilla/sccache";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sccache, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ sccache.overlays.default ];
      };
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ pkgs.sccache ];
      };
    };
}
```

Or use it directly from the flake without the overlay:

```bash
nix run github:mozilla/sccache -- --help
nix shell github:mozilla/sccache
```

---

Usage
-----

Running sccache is like running ccache: prefix your compilation commands with it, like so:

```bash
sccache gcc -o foo.o -c foo.c
```

If you want to use sccache for caching Rust builds you can define `build.rustc-wrapper` in the
[cargo configuration file](https://doc.rust-lang.org/cargo/reference/config.html).  For example, you can set it globally
in `$HOME/.cargo/config.toml` by adding:

```toml
[build]
rustc-wrapper = "/path/to/sccache"
```

Note that you need to use cargo 1.40 or newer for this to work.

Alternatively you can use the environment variable `RUSTC_WRAPPER`:

```bash
export RUSTC_WRAPPER=/path/to/sccache
cargo build
```

sccache supports gcc, clang, MSVC, rustc, [NVCC](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html), [NVC++](https://docs.nvidia.com/hpc-sdk//compilers/hpc-compilers-user-guide/index.html), [hipcc](https://rocm.docs.amd.com/projects/HIP/en/latest/index.html), and [Wind River's diab compiler](https://www.windriver.com/products/development-tools/#diab_compiler). Both gcc and msvc support Response Files, read more about their implementation [here](docs/ResponseFiles.md).

With MSVC `/Zi` or `/ZI`, ordinary caching requires an explicit, non-directory
`/Fd` whose PDB does not already exist. An existing PDB may contain types from
other translation units, so sccache bypasses preprocessing and cache lookup in
that case. Use a unique compiler PDB per non-PCH translation unit; rebuilds can
remove that unit's owned object/PDB pair before invoking sccache. Never remove a
shared compiler PDB to obtain a cache hit.

Ordinary non-PCH `/Zi` actions and independently owned `/Yc` creators can opt into warm-existing hits with
`SCCACHE_MSVC_PRIVATE_PDB=1`. Every `/Fd` must be independently owned and match
its `/Fo` with the extension replaced by `.pdb` or with `.pdb` appended.
Shared or directory `/Fd` paths are rejected before cache lookup, even with
this opt-in. Hits restore only the owning object/PDB pair. Misses remove only
that private PDB before cl generates a fresh genuine database, avoiding
unhashed incremental state from an earlier source generation. It does not
enable unseeded `/Yu`; seeded `/Yu` continues to use its genuine seed rather
than the private-PDB reset.

Local MSVC `/Yc` creators with an explicit `/Fp` can cache the PCH, object, and
compiler PDB together. Preprocessing hashes the full textual input with PCH
generation disabled, while actual compilation retains `/Yc`. Ordinary `/Yu`
consumers sharing the creator's PDB are not cached. Rebuild those consumers
after restoring a creator's artifacts. An inactive `/Fp` alone does not prevent
caching, including when `/Y-` disables PCH operations. As in cl, `/Yc` takes
precedence over `/Yu` regardless of option order.
Serialize operations that share a PCH compiler PDB; a missing PDB alone is not
proof that concurrently starting compilations have independent outputs.

For warm-existing `/Yc` hits, `SCCACHE_MSVC_PRIVATE_PDB=1` requires the same
per-object `/Fd` ownership plus an explicit `/Fp` output distinct from its
object, compiler PDB and any configured seed snapshot. Hits restore the full
PCH/OBJ/PDB triple; misses reset only the owned creator PDB. The creator must
not write a seed currently consumed by other compilations. After successful
creator completion, publish a genuine copy to a distinct immutable snapshot
path, with no consumers running during publication. Consumers must depend on
both PCH and snapshot and all rerun after either changes; changed bytes
invalidate their cache keys even when old private consumer outputs remain.
Neither misses nor hits publish or change the snapshot inside sccache.

For local `/Yu` caching with genuine compiler PDBs, opt in using
`SCCACHE_MSVC_PCH_PDB=<immutable-creator-PDB-path>` and
`SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES=1`:

* The creator must finish producing the matching `/Fp` PCH and real `/Fd` PDB
  before any consumers run. Keep that PDB immutable throughout the consumer
  generation; it may be read-only. No consumer may write the seed path.
* Give each consumer a unique `/Fo` and `/Fd`: the PDB path must be the object
  path with its extension replaced by `.pdb`, or the object path plus `.pdb`.
  For example `/Foobj/a.obj /Fdobj/a.obj.pdb`. No output aliases or shared PDBs.
* Each miss atomically copies the genuine seed into the consumer's writable
  private PDB, then runs the original `/Yu /Zi /Fd` compilation. Hits restore
  only that consumer's object/PDB pair, even if its previous outputs exist.
  GUIDs are copied faithfully, never fabricated or rewritten.
* Every lookup runs a real `/Zs /Yu /Fp /sourceDependencies` syntax-only scan,
  using a separate private PDB genuinely seeded from the immutable snapshot.
  Cache keys hash the binary PCH, seed, original raw source and full bytes of
  actually consumed post-PCH headers, plus compilation and preprocessor flags.
  No object is emitted by the scan. Hits skip code generation, not this scan.
* `/E` and `/EP` ignore MSVC PCH state even without `/Y-`. They can expand a
  different same-named header beside a consumer source. Consumers therefore
  never use those switches or `/Y-`; only creators use textual preprocessing.
  Shadow headers ignored by actual `/Yu` are not scan inputs or cache inputs.
* The source-dependency opt-in declares deterministic consumer inputs: no
  volatile macro expansions such as `__TIME__`, `__DATE__` or `__TIMESTAMP__`
  hidden in PCH macro aliases or token-pasting. Raw dependency hashes cannot
  observe those values. Directly observed time macros conservatively prevent
  key reuse, but this is not a general PCH macro-state volatility detector.
  Without the explicit opt-in, consumers remain non-cacheable.
* The scan validates MSVC source-dependency JSON version 1.2 and the actual
  source/PCH paths, rejects module dependencies, and disables generic textual
  preprocessor manifests for consumers. Requested `/showIncludes` and
  `/sourceDependencies` outputs reflect the real post-PCH dependency set.
* MSVC discovery uses one `/WX-` after removing overridden `/WX`/`/WX-`
  switches from the scan-only vector, avoiding D9025 on failing scans.
  Actual compilation retains the original warning-as-error switches and
  per-warning policies. This also applies to ordinary/creator preprocessing;
  clang-cl behavior is unchanged.
* Build dependencies must include both the PCH and seed PDB. When either is
  regenerated, rerun every dependent consumer; changed input contents cause
  misses and private-PDB reseeding. Other consumers' private outputs are never
  overwritten. Do not merge compiler PDBs.

This strategy was execution-tested with MSVC 14.42, including private PDBs that
share their genuine creator GUID but assign different records to the same type
indices. The real linker correctly merged their distinct types by type server.
Distributed PCH compilation and cross-machine PCH portability are not enabled.
Other unsupported compiler options retain their normal non-cacheable behavior;
if bypassing sccache for a private-PDB consumer, seed its PDB before running cl.

In particular, a non-cacheable argument is not a cache miss:
`server::check_compiler` returns `UnhandledCompile`, and
`commands::handle_compile_result` runs the original compiler command on the
client without entering the MSVC miss-time seeding path. A server disconnect
before `CompileFinished` can take the same local fallback. A zero exit status
does not expose whether this occurred.

A wrapper that must support such fallback should validate effective `/Yu`,
`/Fo` and private `/Fd` after response-file and `CL`/`_CL_` expansion, then
atomically seed that owned PDB **before every sccache invocation**. Invalidate
only its owned object before seeding; do not touch creator/shared outputs.
Hits subsequently restore the matching private pair; misses may harmlessly
reseed it; non-cacheable actions execute the original compiler with a genuine
seed already present. Return sccache's exact exit status and never run a second
compiler based on a post-hoc statistics check. Alternatively, an upstream
ownership-only seeding hook belongs immediately before the client fallback
spawn, not in cache eligibility parsing. Unsupported flags must remain
non-cacheable, and ambiguous/shared output ownership must fail closed.
For a lost `CompileFinished` after `CompileStarted`, do not assume the server
compiler has stopped: a PDB-sensitive client should fail closed unless prior
job termination is established, rather than launch a simultaneous retry.
Wrapper preseeding alone does not fix that separate client-retry race.

On Windows, MSVC preprocessing and actual local compilation use an owned
UTF-16LE response file when the expanded command would exceed a conservative
32,000-unit process limit. Quoting preserves spaces, quotes, trailing
backslashes and non-BMP characters. Each file lives through the complete child
execution and is then removed. Cache parsing/hashing and command introspection
still use expanded arguments, not generated response-file names.

A launcher with a 55,000-unit argument list must itself call
`sccache cl.exe @owned.rsp`, not expand that list into CreateProcess arguments
or bypass sccache based only on length. Preserve the original response file,
or write a correctly quoted owned UTF-16LE file, and keep it until the entire
sccache invocation (including possible client-side fallback) finishes.
`Invoke-Long-Rsp-Probe.ps1` proves >55,000 expanded UTF16 units with genuine
PCH/seed/private PDBs, warm/fresh hits, renamed input response files and
changed-content cache misses.

`tests/msvc-pdb-probe/CMakeLists.txt` is an executable public integration example:
it registers PCH/OBJ/private-PDB creator outputs, a post-success snapshot-copy
rule and consumer `OBJECT_DEPENDS`, appends
`/Fd<OBJECT>.pdb` to `CMAKE_CXX_COMPILE_OBJECT`, and supplies the target-specific
seed using a `cmake -E env` compiler launcher. Apply equivalent dependency and
path ownership rules when using CMake's generated PCH rules.

The public Windows probes in `tests/msvc-pdb-probe` are `Invoke-Probe.ps1`
(ordinary/shared-PDB safety), `Invoke-Seeded-Probe.ps1` (seeded `/Yu`, source/PCH/
seed invalidation and divergent type merging), and `Invoke-119-Users-Probe.ps1`
(119 actual `/Yu` consumers). From an MSVC developer environment, pass
`-Sccache`, a private `-CacheDirectory`, an unused `-Port`, and a fresh
`-OutputDirectory`; `-Direct` enables direct/preprocessor mode. They compile
serially with `/MDd /Od /Zi`, validate compiler MSF7/COFF and linker MSF7/PE
identities, and execute the linked probes. Seeded probes also use MSVC's
`pdbdump.exe` to validate merged type layouts.
`Invoke-Private-Pdb-Probe.ps1` covers ordinary opt-in warm hits and independent
source changes; `Invoke-Fallback-Probe.ps1` proves `/FA` remains non-cacheable
and its original-compiler `/Yu` fallback needs genuine wrapper preseeding.
`Invoke-Warning-Policy-Probe.ps1` verifies zero D9025 on successful and failing
discovery in all three MSVC contexts, while actual `/WX` still rejects a
genuine C4101 warning. Shadow and long-response probes additionally accept
`-WarningsAsErrors` to run their complete fidelity gates with original `/WX`.
`Invoke-Creator-Snapshot-Probe.ps1` verifies warm-existing and removed-output
creator triple restoration, immutable snapshot publication, and invalidation
of all consumers after creator changes.
`Invoke-CMake-Snapshot-Probe.ps1` exercises the same lifecycle through actual
CMake/Ninja producer, snapshot and consumer dependencies, forced response
files and a final no-op. It additionally requires `-CMake`, `-Ninja` and
`-Compiler` paths.
`Invoke-Shadow-Pch-Probe.ps1` uses a real creator's `stdafx.h` and a different
consumer-local `stdafx.h` with `#error` and contrary macros. It checks cold/
warm/fresh hits, ignored shadow changes, actual source/header changes and
creator regeneration, including real compiler/linker debug identities and
runtime macro-selected values.

If you don't [specify otherwise](#storage-options), sccache will use a local disk cache.

sccache works using a client-server model, where the server runs locally on the same machine as the client. The client-server model allows the server to be more efficient by keeping some state in memory. The sccache command will spawn a server process if one is not already running, or you can run `sccache --start-server` to start the background server process without performing any compilation.

By default sccache server will listen on `127.0.0.1:4226`, you can specify environment variable `SCCACHE_SERVER_PORT` to use a different port or `SCCACHE_SERVER_UDS` to listen on unix domain socket. Abstract unix socket is also supported as long as the path is escaped following the [format](https://doc.rust-lang.org/std/ascii/fn.escape_default.html). For example:

```
% env SCCACHE_SERVER_UDS=$HOME/sccache.sock sccache --start-server # unix socket
% env SCCACHE_SERVER_UDS=\\x00sccache.sock sccache --start-server # abstract unix socket
```

You can run `sccache --stop-server` to terminate the server. It will also terminate after (by default) 10 minutes of inactivity.

Running `sccache --show-stats` will print a summary of cache statistics.

Some notes about using `sccache` with [Jenkins](https://jenkins.io) are [here](docs/Jenkins.md).

To use sccache with cmake, provide the following command line arguments to cmake 3.4 or newer:

```
-DCMAKE_C_COMPILER_LAUNCHER=sccache
-DCMAKE_CXX_COMPILER_LAUNCHER=sccache
```

The process for using sccache with MSVC and cmake, depends on which version of cmake you're using. **For versions of cmake 3.24 and earlier**, to generate PDB files for debugging with MSVC, you can use the [`/Z7` option](https://docs.microsoft.com/en-us/cpp/build/reference/z7-zi-zi-debug-information-format?view=msvc-160). Alternatively, the `/Zi` option together with `/Fd` can work if `/Fd` names a different PDB file name for each object file created. Note that CMake sets `/Zi` by default, so if you use CMake, you can use `/Z7` by adding code like this in your CMakeLists.txt:

```cmake
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  string(REPLACE "/Zi" "/Z7" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
  string(REPLACE "/Zi" "/Z7" CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG}")
elseif(CMAKE_BUILD_TYPE STREQUAL "Release")
  string(REPLACE "/Zi" "/Z7" CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE}")
  string(REPLACE "/Zi" "/Z7" CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE}")
elseif(CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
  string(REPLACE "/Zi" "/Z7" CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO}")
  string(REPLACE "/Zi" "/Z7" CMAKE_C_FLAGS_RELWITHDEBINFO "${CMAKE_C_FLAGS_RELWITHDEBINFO}")
endif()
```

By default, sccache will fail your build if it fails to successfully communicate with its associated server. To have sccache instead gracefully failover to the local compiler without stopping, set the environment variable `SCCACHE_IGNORE_SERVER_IO_ERROR=1`.

**For versions of cmake 3.25 and later**, to compile with MSVC, you have to use the new `CMAKE_MSVC_DEBUG_INFORMATION_FORMAT` option, meant to configure the `-Z7` flag.  Additionally, you must set the cmake policy number 0141 to the NEW setting:
```cmake
set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<$<CONFIG:Debug,RelWithDebInfo>:Embedded>")
cmake_policy(SET CMP0141 NEW)
```

Example configuration where we automatically look for `sccache` in the `PATH`:
```cmake
find_program(SCCACHE sccache REQUIRED)

set(CMAKE_C_COMPILER_LAUNCHER ${SCCACHE})
set(CMAKE_CXX_COMPILER_LAUNCHER ${SCCACHE})
set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<$<CONFIG:Debug,RelWithDebInfo>:Embedded>")
cmake_policy(SET CMP0141 NEW)
```

Alternatively, if configuring cmake with MSVC on the command line, assuming that sccache is on the default search path:

```
cmake -DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded -DCMAKE_POLICY_CMP0141=NEW [...]
```

And you can build code as usual without any additional flags in the command line, which is useful for IDEs.


---

Build Requirements
------------------

sccache is a [Rust](https://www.rust-lang.org/) program. Building it requires `cargo` (and thus`rustc`). sccache currently requires **Rust 1.91.0**. We recommend you install Rust via [Rustup](https://rustup.rs/).

Build
-----

If you are building sccache for non-development purposes make sure you use `cargo build --release` to get optimized binaries:

```bash
cargo build --release [--no-default-features --features=s3|redis|gcs|memcached|azure|gha|webdav|oss|cos]
```

The list of features can be found in the `Cargo.toml` file, `[features]` section.

By default, `sccache` builds with support for all storage backends, but individual backends may be disabled by resetting the list of features and enabling all the other backends. Refer the [Cargo Documentation](http://doc.crates.io/manifest.html#the-features-section) for details on how to select features with Cargo.

### Profile-guided optimization

The official release binaries are built with profile-guided optimization (PGO), which makes sccache itself faster on every compilation it wraps. `scripts/build-pgo.sh` builds sccache this way:

```bash
rustup component add llvm-tools
./scripts/build-pgo.sh
```

**Packagers are encouraged to build sccache with PGO too.** See [docs/PGO.md](docs/PGO.md) for the options, and for how to plug the profile into an existing packaging recipe.

### Building portable binaries

When building with the `dist-server` feature, `sccache` will depend on OpenSSL, which can be an annoyance if you want to distribute portable binaries. It is possible to statically link against OpenSSL using the `openssl/vendored` feature.

#### Linux

Build with `cargo` and use `ldd` to check that the resulting binary does not depend on OpenSSL anymore.

#### macOS

Build with `cargo` and use `otool -L` to check that the resulting binary does not depend on OpenSSL anymore.

#### Windows

On Windows, the binary might also depend on a few MSVC CRT DLLs that are not available on older Windows versions.

It is possible to statically link against the CRT using a `.cargo/config.toml` file with the following contents.

```toml
[target.x86_64-pc-windows-msvc]
rustflags = ["-Ctarget-feature=+crt-static"]
```

Build with `cargo` and use `dumpbin /dependents` to check that the resulting binary does not depend on MSVC CRT DLLs anymore.

When statically linking with OpenSSL, you will need Perl available in your `$PATH`.

---

Separating caches between invocations
-------------------------------------

In situations where several different compilation invocations
should not reuse the cached results from each other,
one can set `SCCACHE_C_CUSTOM_CACHE_BUSTER` to a unique value
that'll be mixed into the hash.
`MACOSX_DEPLOYMENT_TARGET` and `IPHONEOS_DEPLOYMENT_TARGET` variables
already exhibit such reuse-suppression behaviour.
There are currently no such variables for compiling Rust.

---

Overwriting the cache
---------------------

In situations where the cache contains broken build artifacts, it can be necessary to overwrite the contents in the cache. That can be achieved by setting the `SCCACHE_RECACHE` environment variable.

---

Debugging
---------

You can set the `SCCACHE_ERROR_LOG` environment variable to a path and set `SCCACHE_LOG` to get the server process to redirect its logging there (including the output of unhandled panics, since the server sets `RUST_BACKTRACE=1` internally).

    SCCACHE_ERROR_LOG=/tmp/sccache_log.txt SCCACHE_LOG=debug sccache

You can also set these environment variables for your build system, for example

    SCCACHE_ERROR_LOG=/tmp/sccache_log.txt SCCACHE_LOG=debug cmake --build /path/to/cmake/build/directory

Alternatively, if you are compiling locally, you can run the server manually in foreground mode by running `SCCACHE_START_SERVER=1 SCCACHE_NO_DAEMON=1 sccache`, and send logging to stderr by setting the [`SCCACHE_LOG` environment variable](https://docs.rs/env_logger/0.7.1/env_logger/#enabling-logging) for example. This method is not suitable for CI services because you need to compile in another shell at the same time.

    SCCACHE_LOG=debug SCCACHE_START_SERVER=1 SCCACHE_NO_DAEMON=1 sccache

---

Interaction with GNU `make` jobserver
-------------------------------------

sccache provides support for a [GNU make jobserver](https://www.gnu.org/software/make/manual/html_node/Job-Slots.html). When the server is started from a process that provides a jobserver, sccache will use that jobserver and provide it to any processes it spawns. (If you are running sccache from a GNU make recipe, you will need to prefix the command with `+` to get this behavior.) If the sccache server is started without a jobserver present it will create its own with the number of slots equal to the number of available CPU cores.

This is most useful when using sccache for Rust compilation, as rustc supports using a jobserver for parallel codegen, so this ensures that rustc will not overwhelm the system with codegen tasks. Cargo implements its own jobserver ([see the information on `NUM_JOBS` in the cargo documentation](https://doc.rust-lang.org/stable/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-build-scripts)) for rustc to use, so using sccache for Rust compilation in cargo via `RUSTC_WRAPPER` should do the right thing automatically.

---

Normalizing Paths with `SCCACHE_BASEDIRS`
-----------------------------------------

By default, sccache requires absolute paths to match for cache hits. To enable cache sharing across different build directories, you can set `SCCACHE_BASEDIRS` to strip a base directory from paths before hashing:

```bash
export SCCACHE_BASEDIRS=/home/user/project
```

You can also specify multiple base directories by separating them by `;` on Windows hosts and by `:` on any other operating system. When multiple directories are provided, the longest matching prefix is used:

```bash
export SCCACHE_BASEDIRS="/home/user/project:/home/user/workspace"
```

Path matching is **case-insensitive** on Windows and **case-sensitive** on other operating systems.

Base directories are stripped from the preprocessed source and from the compiler arguments alike. The arguments matter because a flag can name the tree it is building: `-ffile-prefix-map=/home/user/project=.` makes the object file independent of where the tree is checked out, but the flag itself is not, and it is hashed verbatim.

In an argument only the places that are expected to spell a pathname are considered: the whole argument, the value of an option written with an `=` (either half of a prefix map), and the value glued to a short option such as `-I`. A base directory appearing anywhere else is left alone, so a definition the compiler bakes into the output verbatim, `-DROOT="/home/user/project"`, still counts. A match also has to end where a path component ends, so a sibling `/home/user/project-docs` is not one.

For Rust, base directories are also stripped from the working directory, from the `CARGO_*` environment variables such as `CARGO_MANIFEST_DIR`, and from the variables a crate reads with `env!` or `option_env!`, such as a build script's `OUT_DIR`. A hit then returns a crate compiled in another directory: its debug info and panic messages name that directory unless `--remap-path-prefix` maps it away, and so does any `env!("CARGO_MANIFEST_DIR")` the crate keeps.

This is similar to ccache's `CCACHE_BASEDIR` and helps when:
* Building the same project from different directories
* Sharing cache between CI jobs with different checkout paths
* Multiple developers working with different username paths
* Working with multiple project checkouts simultaneously

**Note:** Only absolute paths are supported. Relative paths will prevent server from starting.

You can also configure this in the sccache config file:

```toml
# Single directory
basedirs = ["/home/user/project"]

# Or multiple directories
basedirs = ["/home/user/project", "/home/user/workspace"]
```

---

Known Caveats
-------------

### General

* By default, absolute paths to files must match to get a cache hit. To work around this, use `SCCACHE_BASEDIRS` (see above) to normalize paths before hashing.

### Rust

* Crates that invoke the system linker cannot be cached. This includes `bin`, `dylib`, `cdylib`, and `proc-macro` crates. You may be able to improve compilation time of large `bin` crates by converting them to a `lib` crate with a thin `bin` wrapper.
* Incrementally compiled crates cannot be cached. By default, in the debug profile Cargo will use incremental compilation for workspace members and path dependencies. [You can disable incremental compilation.](https://doc.rust-lang.org/cargo/reference/profiles.html#incremental) sccache exits with an error if `CARGO_INCREMENTAL=1` is set; `SCCACHE_ALLOW_INCREMENTAL=1` lets the build proceed, leaving only those crates uncached.

[More details on Rust caveats](/docs/Rust.md)

### C++20 Modules

sccache has partial support for C++20 named modules when using **Clang**. The following flags are supported:

* `-fmodule-file=<path>` and `-fmodule-file=<name>=<path>` - importing precompiled module interfaces
* `-fmodule-output=<path>` - generating module interface output alongside object files
* `--precompile` - compiling module interface units
* `-fmodules-reduced-bmi` - generating reduced BMI files

The following module-related flags are **not supported** and will bypass the cache:

* `-fmodules` and `-fcxx-modules` - Clang header modules (not C++20 named modules)
* `-fprebuilt-implicit-modules` and `-fprebuilt-module-path` - implicit module discovery

With **clang-cl**, `-fmodule-file=[<name>=]<path>` and `-x c++-module` together with `-fmodule-output=<path>` are supported, but not through `-Xclang` or `-clang:`.

**GCC** and **MSVC** C++20 modules are not yet supported. Compilations using `-fmodules-ts` (GCC) or `/interface`, `/ifcOutput`, etc. (MSVC) will bypass the cache.

### User Agent

* Requests sent to your storage option of choice will have a user agent header indicating the current sccache version, e.g. `sccache/0.8.2`.

Storage Options
---------------

* [Local](docs/Local.md)
* [S3](docs/S3.md)
* [R2](docs/S3.md#R2)
* [Redis](docs/Redis.md)
* [Memcached](docs/Memcached.md)
* [Google Cloud Storage](docs/Gcs.md)
* [Azure](docs/Azure.md)
* [GitHub Actions](docs/GHA.md)
* [WebDAV (Ccache/Bazel/Gradle compatible)](docs/Webdav.md)
* [Alibaba OSS](docs/OSS.md)
* [Tencent Cloud Object Storage](docs/COS.md)
