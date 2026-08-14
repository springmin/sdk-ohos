# Compatibility Agent Instructions

Guidance for changes under `src/Compatibility` — the API-compatibility tooling
(ApiCompat, GenAPI, ApiDiff) used to validate the SDK's and runtime's public API
surface against prior releases.

## Where things live

| Project | Role |
|---------|------|
| `ApiCompat/` | Binary/source API compatibility validation. `Microsoft.DotNet.ApiCompat.Shared` holds the shared comparison engine; `Microsoft.DotNet.ApiCompat.Task` is the MSBuild task; `Microsoft.DotNet.ApiCompat.Tool` is the CLI tool. `Microsoft.DotNet.ApiCompatibility` contains the core comparison logic; `Microsoft.DotNet.PackageValidation` validates package identity/versioning. |
| `GenAPI/` | Generates reference assemblies from source projects: `Microsoft.DotNet.GenAPI` (core) + `GenAPI.Task` (MSBuild task) + `GenAPI.Tool` (CLI tool). Has its own `README.md`. |
| `ApiDiff/` | Computes textual API diffs between two assemblies (`Microsoft.DotNet.ApiDiff` tool). |
| `Microsoft.DotNet.ApiSymbolExtensions/` | Shared helpers for walking/mapping API symbols, used by all of the above. |

Each area follows the same pattern: a library with the core logic, an MSBuild
task project, and a CLI tool project, with its own `.slnf` filter
(`apicompat.slnf`, `genapi.slnf`, `compatibility.slnf`).

## Conventions & gotchas

- **Multi-targets `$(SdkTargetFramework)` and `net472`** (and other legacy TFMs
  for some packages), so new code must stay .NET Framework-compatible — no
  .NET-only APIs, mirroring `src/Tasks`.
- **Baseline-driven design:** ApiCompat compares against baseline
  `PackageValidation`/reference assemblies; GenAPI produces the reference
  assemblies that shipping `*.Ref` packages are built from. Changing public API
  requires the corresponding baseline/reference updates.
- **Packages are shipped to NuGet** (`Microsoft.DotNet.ApiCompat`,
  `Microsoft.DotNet.GenAPI`, etc.) and are also consumed inside the SDK build —
  be careful changing behavior that validation depends on.
- Diagnostic/rules behavior is tested against real product assemblies; keep
  rule changes covered.

## Tests

- `test/Compatibility/` holds per-tool test projects (`ApiCompat/`, `ApiDiff/`,
  `GenAPI/`, `Microsoft.DotNet.ApiSymbolExtensions.Tests/`), each with `.Tests`
  and `.IntegrationTests` projects.
- Integration tests exercise the tools against real assemblies; some rows run
  under full (desktop) MSBuild when `TestFullMSBuild=true`.
- Run with the bootstrap SDK:
  `./.dotnet/dotnet test test/Compatibility/ApiCompat/Microsoft.DotNet.ApiCompat.Tests/Microsoft.DotNet.ApiCompat.Tests.csproj --filter "FullyQualifiedName~X"`.
