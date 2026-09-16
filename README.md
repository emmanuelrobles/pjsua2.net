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
| Target framework | `netstandard2.0` |
| Supported runtimes | `linux-x64`, `linux-arm64`, `win-x64`, `win-x86` |

## Prerequisites

The build is split across two hosts:

- **Linux RIDs** (`linux-x64`, `linux-arm64`, `win-x86`) build on Linux.
  `linux-arm64` is cross-compiled with `g++-aarch64-linux-gnu`; `win-x86` is
  cross-compiled with `g++-mingw-w64-i686`.
- **Windows RIDs** (`win-x64`) build on Windows with MinGW-w64 (via MSYS2).

Common prerequisites:

- [.NET SDK 10](https://dotnet.microsoft.com/) (see `global.json`)
- SWIG 4.x (`swig`)
- A C/C++ toolchain (`gcc`, `g++`, `make`)
- `libssl-dev` (enables TLS / SIPS / DTLS-SRTP)
- `perl` and `curl` (used to build OpenSSL for the cross targets)

On Debian/Ubuntu (Linux host):

```sh
sudo apt-get install -y build-essential pkg-config swig libssl-dev \
  g++-aarch64-linux-gnu g++-mingw-w64-i686 perl curl
```

On Windows (MSYS2, MINGW64 shell):

```sh
pacman -S --noconfirm mingw-w64-x86_64-gcc make swig perl curl tar
```

The `pjproject` submodule must be initialised:

```sh
git submodule update --init --recursive
```

## Build

The top-level `Makefile` drives the pipeline: it configures and builds the
`pjproject` submodule, runs SWIG to generate the C# bindings and native wrapper,
and compiles/links the native library for each configured RID. Linux RIDs are
built on Linux (arm64 cross-compiled); Windows RIDs are built on Windows via
MSYS2/MinGW-w64.

```sh
make native RIDS="linux-x64 linux-arm64 win-x86"   # on Linux
make native RIDS="win-x64"                          # on Windows (MSYS2)
```

The CI pipeline (`.forgejo/workflows/`) builds each group on its own runner and
packs the combined NuGet package into
`artifacts/CodeCrush.pjsua2.<version>.nupkg`.

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
make native RIDS=linux-x64                       # on Linux
make native RIDS="linux-x64 linux-arm64 win-x86" # on Linux
make native RIDS=win-x64                         # on Windows (MSYS2)
```

Each RID reconfigures and rebuilds pjproject for its target, so single-RID
builds are much faster than the full set. `win-x64` must be built on a Windows
host; `linux-x64`, `linux-arm64` and `win-x86` build on a Linux host.

## Package contents

```
lib/netstandard2.0/codecrush.pjsua2.dll
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
| `win-x64`     | cross-built import lib `libssl.dll.a` (MinGW)   | system `libssl-3-x64.dll`  |
| `win-x86`     | cross-built import lib `libssl.dll.a`           | system `libssl-3.dll`       |

`linux-x64` links against the system `libssl-dev` (autodetected by
`./configure`). The other targets (`linux-arm64`, `win-x64`, `win-x86`) build a
pinned OpenSSL (`OPENSSL_VERSION`, default `3.6.4`) under `build/openssl/`
purely for its headers and import/symlink libraries, then point pjproject at it
via `--with-ssl`. Only `libcrypto` + `libssl` are built (`make build_libs`) and
their dev files installed (`make install_dev`); the OpenSSL CLI, tests and docs
are skipped to keep the build fast. Because `./configure`'s OpenSSL probe is
unreliable on the Windows runner (it feeds `-I`/`-L` MSYS paths to the native
mingw64 gcc), `PJ_HAS_SSL_SOCK` is also forced to `1` in `config_site.h` and
`-lssl -lcrypto` are added to the win-x64 link flags, so TLS is compiled in
unconditionally — a missing OpenSSL surfaces as a build error rather than a
TLS-less DLL. Nothing is bundled into the package and no rpath is set, so the
library resolves OpenSSL from the system at runtime (unqualified
`libssl.so.3` / `libssl-3-x64.dll` / `libssl-3.dll` dependencies).

- The dependency is on OpenSSL **3.x** specifically (`libssl.so.3` /
  `libssl-3-x64.dll`); OpenSSL 1.1 (`libssl.so.1.1`) will not satisfy it.
- **Windows does not ship OpenSSL.** A standard OpenSSL 3.x install
  (`libssl-3-x64.dll` / `libcrypto-3-x64.dll` for 64-bit) must be reachable on
  the target machine via `PATH` or the application directory.
- The 64-bit Windows dependency uses the **standard** `libssl-3-x64.dll` name
  (the `-x64` suffix that MinGW OpenSSL appends), so any stock
  OpenSSL-for-Windows build (Win64OpenSSL, MSYS2, vcpkg, etc.) satisfies it.
  No OpenSSL is bundled, so the client's installed copy — including a
  FIPS-enabled one — is what actually loads.
- Because OpenSSL is linked dynamically and resolved from the system, host-level
  OpenSSL configuration applies at runtime: a FIPS-enabled install (where the
  FIPS provider is activated globally via `openssl.cnf`) makes TLS run in FIPS
  mode automatically.

## CI/CD

`.forgejo/workflows/build-publish.yaml` builds the Linux RIDs on the `docker`
runner and the Windows RIDs on the `windows` runner, then packs the combined
NuGet package and publishes it when a pull request is merged to `main` (or on
manual dispatch).

- `build-linux` (docker) builds `linux-x64` + `linux-arm64` + `win-x86`;
  `build-windows` (windows) builds `win-x64` via MSYS2/MinGW-w64; `pack-publish`
  collects the native libraries and packs/publishes the package.
- The OpenSSL source build under `build/openssl/` is cached between runs with
  `actions/cache`, keyed on the `Makefile` contents — so only the first build of
  a given OpenSSL version compiles from scratch.
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

- **Windows build** — built with MinGW-w64 (via MSYS2) and linked with
  `-static-libgcc -static-libstdc++` to avoid libgcc/libstdc++ runtime DLL
  dependencies. (OpenSSL itself is still linked dynamically — see
  [TLS / OpenSSL](#tls--openssl).)
- The bindings are regenerated by SWIG on every build; do not edit them by hand.
- To bump the local package version (used outside CI), change `<Version>` in
  `pjsua2.net/pjsua2.net.csproj`. CI overrides this with the tag-derived version.
