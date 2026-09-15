# pjsua2.net

.NET bindings for [PJSUA2](https://docs.pjsip.org/en/latest/reference/pjsua2/book/index.html)
(the high-level C++ SIP/telephony API from [PJSIP](https://www.pjsip.org/)), generated with
SWIG and shipped as a NuGet package that bundles the native library.

The managed assembly exposes the `pjsua2` namespace and the native
`libpjsua2.so` / `pjsua2.dll` is included under `runtimes/<rid>/native/`, so
consumers only need to reference the NuGet package.

| | |
| --- | --- |
| NuGet package ID | `CodeCrush.pjsua2` |
| Managed namespace / assembly | `pjsua2` |
| Target framework | `net10.0` |
| Supported runtimes | `linux-x64`, `linux-arm64`, `win-x64`, `win-x86` |

## Prerequisites

- [.NET SDK 10](https://dotnet.microsoft.com/) (see `global.json`)
- SWIG 4.x (`swig`)
- A C/C++ toolchain (`gcc`, `g++`, `make`)
- `libssl-dev` (enables TLS / SIPS / DTLS-SRTP)
- `perl` and `curl` (used to cross-build OpenSSL for the cross targets)
- For `linux-arm64`: `g++-aarch64-linux-gnu`
- For `win-x64`: `g++-mingw-w64-x86-64`
- For `win-x86`: `g++-mingw-w64-i686`

On Debian/Ubuntu:

```sh
sudo apt-get install -y build-essential pkg-config swig libssl-dev \
  g++-aarch64-linux-gnu g++-mingw-w64-x86-64 g++-mingw-w64-i686 \
  perl curl
```

The `pjproject` submodule must be initialised:

```sh
git submodule update --init --recursive
```

## Build

The top-level `Makefile` drives the full pipeline: it configures and builds the
`pjproject` submodule, runs SWIG to generate the C# bindings and native wrapper,
compiles/links the native library for each runtime, and builds/packs the .NET
project.

```sh
make            # build native libraries (all RIDs) + managed assembly
make pack       # build everything and produce the .nupkg in artifacts/
```

The NuGet package is written to `artifacts/CodeCrush.pjsua2.<version>.nupkg`.

### Make targets

| Target          | Description |
| ---             | --- |
| `all`           | Native libraries + managed assembly (default) |
| `native`        | SWIG bindings + native library for every configured RID |
| `pack`          | Everything, then `dotnet pack` into `artifacts/` |
| `dotnet-build`  | `dotnet build` the managed project |
| `configure`     | Run pjproject's `./configure` for the host target |
| `pjproject`     | Build the pjproject static libraries for the host target |
| `clean`         | Remove generated bindings / native / NuGet artifacts |
| `distclean`     | `clean` + full `make clean` of the pjproject tree |

### Overridable variables

| Variable        | Default                            | Description |
| ---             | ---                                | --- |
| `RIDS`          | `linux-x64 linux-arm64 win-x64 win-x86` | Runtimes to build |
| `CONFIGURATION` | `Release`                          | dotnet build configuration |
| `JOBS`          | `$(nproc)`                         | Parallel pjproject build jobs |
| `NAMESPACE`     | `pjsua2`                           | C# namespace for the bindings |
| `OPENSSL_VERSION` | `3.6.4`                          | OpenSSL release cross-built for the cross targets |

### Building a specific RID

```sh
make native RIDS=linux-x64
make native RIDS=linux-arm64
make native RIDS="linux-x64 linux-arm64"
make pack   RIDS="linux-x64 win-x64"
```

Each RID reconfigures and rebuilds pjproject for its target, so single-RID
builds are much faster than the full set.

## Package contents

```
lib/net10.0/pjsua2.dll
runtimes/linux-x64/native/libpjsua2.so
runtimes/linux-arm64/native/libpjsua2.so
runtimes/win-x64/native/pjsua2.dll
runtimes/win-x86/native/pjsua2.dll
```

The native library is linked statically against all pjproject components, but
links OpenSSL **dynamically** — see [TLS / OpenSSL](#tls--openssl) below.

## TLS / OpenSSL

TLS (SIPS, DTLS-SRTP, SRTP keying) is enabled for **every** runtime. OpenSSL is
always linked **dynamically**, so at runtime the native library uses the
OpenSSL installed on the target system:

| RID           | Link-time OpenSSL                               | Runtime OpenSSL             |
| ---           | ---                                             | ---                         |
| `linux-x64`   | host `libssl.so.3` (native)                     | system OpenSSL              |
| `linux-arm64` | cross-built dev files (headers + symlink libs)  | system `libssl.so.3`        |
| `win-x64`     | cross-built import lib `libssl.dll.a`           | system `libssl-3-x64.dll`   |
| `win-x86`     | cross-built import lib `libssl.dll.a`           | system `libssl-3.dll`       |

The cross targets (`linux-arm64`, `win-x64`, `win-x86`) have no OpenSSL at build
time, so the Makefile cross-builds a pinned OpenSSL (`OPENSSL_VERSION`, default
`3.6.4`) under `build/openssl/` purely for its headers and import/symlink
libraries, then points pjproject at it via `--with-ssl`. Only the dev files are
used at link time — nothing is bundled into the package and no rpath is set, so
the library resolves OpenSSL from the system at runtime (unqualified
`libssl.so.3` / `libssl-3-x64.dll` dependencies).

- The dependency is on OpenSSL **3.x** specifically (`libssl.so.3` /
  `libssl-3-x64.dll`); OpenSSL 1.1 (`libssl.so.1.1`) will not satisfy it.
- **Windows does not ship OpenSSL.** An OpenSSL 3.x build
  (`libssl-3-x64.dll` / `libcrypto-3-x64.dll`) must be reachable on the target
  machine via `PATH` or the application directory.
- Because `linux-x64` links the system OpenSSL dynamically, host-level OpenSSL
  configuration (e.g. FIPS mode) applies there.

## CI/CD

`.forgejo/workflows/build-publish.yaml` builds all runtimes and publishes the
NuGet package when a pull request is merged to `main` (or on manual dispatch).

- Versioning is derived from the source branch name and the latest `vX.Y.Z` tag:
  - `feature/*` bumps **minor**
  - `fix/*` bumps **patch**
  - `major/*` bumps **major**
- The package is pushed to the Forgejo NuGet feed using the
  `NUGET_USERNAME` / `NUGET_PASSWORD` secrets and the
  `NUGET_SOURCE` variable.
- The merged commit is tagged `vX.Y.Z`.

## Project structure

```
.
├── Makefile                       # native + bindings + pack pipeline
├── pjsua2.net/
│   ├── pjsua2.net.csproj          # managed project (package id CodeCrush.pjsua2)
│   ├── bindings/                  # generated C# bindings (git-ignored)
│   ├── native/                    # generated SWIG wrapper + per-RID objects (git-ignored)
│   └── runtimes/<rid>/native/     # linked native libraries (git-ignored)
├── pjproject/                     # PJSIP submodule
└── .forgejo/workflows/            # CI pipeline
```

## Notes and caveats

- **Windows cross-compilation** — built with MinGW-w64 via
  `-static-libgcc -static-libstdc++` to avoid libgcc/libstdc++ runtime DLL
  dependencies. (OpenSSL itself is still linked dynamically — see
  [TLS / OpenSSL](#tls--openssl).)
- The bindings are regenerated by SWIG on every build; do not edit them by hand.
- To bump the local package version (used outside CI), change `<Version>` in
  `pjsua2.net/pjsua2.net.csproj`. CI overrides this with the tag-derived version.
