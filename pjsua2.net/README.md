# CodeCrush.pjsua2

.NET bindings for [PJSUA2](https://docs.pjsip.org/en/latest/reference/pjsua2/book/index.html),
the high-level object-oriented SIP / multimedia API from
[PJSIP](https://www.pjsip.org/).

The bindings are generated from the PJSUA2 C++ API using SWIG and expose the
`pjsua2` namespace. The native `libpjsua2.so` / `pjsua2.dll` is bundled in the
package, so no separate native installation is required.

## Installation

```
dotnet add package CodeCrush.pjsua2
```

## Supported runtimes

| Runtime | Native library |
| --- | --- |
| `linux-x64` | `libpjsua2.so` |
| `linux-arm64` | `libpjsua2.so` |
| `win-x64` | `pjsua2.dll` |
| `win-x86` | `pjsua2.dll` |

## Quick start

```csharp
using pjsua2;

var ep = new Endpoint();
ep.libCreate();

var epConfig = new EpConfig();
epConfig.logConfig.level = 5;
epConfig.logConfig.consoleLevel = 4;
ep.libInit(epConfig);

var tcfg = new TransportConfig();
tcfg.port = 5080;
ep.transportCreate(pjsip_transport_type_e.PJSIP_TRANSPORT_UDP, tcfg);
ep.transportCreate(pjsip_transport_type_e.PJSIP_TRANSPORT_TCP, tcfg);

ep.libStart();

// ... place/receive calls ...

ep.libDestroy();
```

Subclass the `director`-enabled types (for example `Account`, `Call`, `Buddy`,
`LogWriter`) to receive callbacks. See the PJSUA2 documentation for the full API.

## Notes

- The generated bindings require `AllowUnsafeBlocks` — they are compiled into the
  shipped assembly already, so consumers do not need to change their settings.
- This package is licensed under GPL-2.0-or-later, matching PJSIP.
