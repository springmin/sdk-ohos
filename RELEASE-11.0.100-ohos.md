# .NET SDK 11.0.100-dev for HarmonyOS (linux-ohos-arm64) — Release

**Release Date:** 2026-08-20
**SDK Version:** 11.0.100-dev
**Runtime Version:** 11.0.0-dev (built from the `feature/ohos-10.0.11` / `feature/ohos-cross-runtime` runtime branches)
**Target RID:** `linux-ohos-arm64` (HarmonyOS, aarch64, musl libc)
**Artifact:** `dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz` (163 MB)

## Overview

This is a cross-compiled .NET SDK targeting HarmonyOS (OpenHarmony) on aarch64.
It is built from the upstream `dotnet/sdk` main branch (merged through commit
`c0fb107a54`) plus the `linux-ohos` cross-compilation support. The SDK ships a
complete runnable layout: muxer + hostfxr + SDK toolset + shared runtime.

## Artifacts

| Artifact | Size | Description |
|---|---|---|
| `dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz` | 163 MB | Full SDK tarball (muxer, SDK, runtime) |
| `Microsoft.NETCore.App.Host.linux-ohos-arm64` nupkg | — | Apphost pack |
| `Microsoft.NETCore.App.Runtime.linux-ohos-arm64` nupkg | — | Runtime pack |
| `Microsoft.DotNet.ILCompiler` + `runtime.linux-ohos-arm64.Microsoft.DotNet.ILCompiler` nupkgs | 43 MB | NativeAOT compiler toolchain |
| `Microsoft.NETCore.App.Runtime.NativeAOT.linux-ohos-arm64` nupkg | 25 MB | NativeAOT runtime (19 static libs) |

## Features

- **Full managed CLI** (`dotnet build`, `restore`, `publish`, `test`, `run`, ...)
- **NativeAOT support** for `linux-ohos-arm64` (`PublishAot=true`)
- **RID graph injected**: `linux-ohos-arm64 → linux-ohos → linux-arm64 → linux → unix-arm64 → unix → any → base`
- **musl-based** — matches HarmonyOS libc (`/lib/ld-musl-aarch64.so.1`)

## Verification

Verified under `qemu-aarch64` with the musl loader:

```
Host:
  Version:      11.0.0-dev
  Architecture: arm64
  RID:          linux-ohos-arm64

.NET SDKs installed:
  11.0.100-dev [redist/Release/dotnet/sdk]

.NET runtimes installed:
  Microsoft.NETCore.App 11.0.0-dev [redist/Release/dotnet/shared/Microsoft.NETCore.App]
```

NativeAOT cross-compilation smoke test: `ilc` (x64 host) + `libclrjit_universal_arm64_x64.so`
produced an `ARM aarch64` relocatable object from a hello-world IL assembly.

## Known Limitations

- **No ASP.NET Core runtime bundled** (`IncludeAspNetCoreRuntime=false`; the
  aspnetcore repo has not produced a linux-ohos runtime pack).
- **No `aspnetcoretools`** (dev-certs, user-jwts, user-secrets — NativeAOT tools
  not available for ohos).
- **No Kerberos / Negotiate** (`libSystem.Net.Security.Native.so` omitted —
  HarmonyOS lacks krb5/gssapi).
- **No LTTNG EventPipe provider** (`libcoreclrtraceptprovider.so` omitted).
- **Partial ReadyToRun** (no PGO data for ohos; startup slightly slower, full
  functionality).
- **Offline NuGet restore requires a local feed** — the runtime packs are
  versioned `11.0.0-dev`, not on public feeds.

## Usage

```bash
# Extract the SDK
tar xzf dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz -C /opt/dotnet-ohos
export DOTNET_ROOT=/opt/dotnet-ohos
export PATH=$DOTNET_ROOT:$PATH

# Check
dotnet --info

# Build an app for HarmonyOS
dotnet new console -o hello
cd hello
dotnet publish -c Release -r linux-ohos-arm64 --self-contained

# NativeAOT publish (experimental)
dotnet publish -c Release -r linux-ohos-arm64 -p:PublishAot=true
```

## Branches

- `feature/ohos-cross-sdk` — SDK 11.0.100-dev cross-compilation work
- `feature/ohos-cross-sdk-10.0` — SDK 10.0.110-dev port (based on `release/10.0.1xx`)
- `release/11.0.100-ohos` — this release branch

## Building From Source

See `docs/plans/2026-08-14-sdk-ohos-cross-compile.md` for the full build
instructions, problem log, and verification details.
