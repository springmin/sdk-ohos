# dotnet/sdk — Project Knowledge Base

**Generated:** 2026-08-14
**Commit:** ebe7798197
**Branch:** main

## OVERVIEW

The .NET SDK repository: produces the `dotnet` CLI driver plus the MSBuild tasks,
targets, resolvers, templates, and workloads shared between the CLI and Visual Studio.
Build output is a complete runnable `dotnet` at
`artifacts/bin/redist/<Configuration>/dotnet` (`Debug` by default). ~11.7k files,
~1M LOC C#.

**Authoritative agent guide:** `.github/copilot-instructions.md` is the canonical,
maintained repo-wide instruction file (architecture claims, guardrails, dependency
policy, coding style, testing). This AGENTS.md is the structural index; treat
copilot-instructions.md as the source of truth when the two differ. Sub-area depth
lives in each directory's own AGENTS.md (see NOTES).

## STRUCTURE

```
sdk/
├── src/                     # product source (26 areas, see WHERE TO LOOK)
├── test/                    # tests + shared harness (see test/AGENTS.md)
├── eng/                     # Arcade infra; eng/common is vendored — never edit
├── template_feed/           # in-box project/item templates
├── documentation/           # developer guide, specs, area docs
├── build/                   # build helper scripts (Helix env, resx source gen)
├── benchmarks/              # BenchmarkDotNet micro-benchmarks
├── scripts/                 # one-off dev scripts (conditional-test scopes, etc.)
├── sdk.slnx                 # full solution (XML .slnx format; no root .sln)
├── cli.slnf, tasks.slnf, containers.slnf, TemplateEngine.slnf, source-build.slnf
├── build.sh / build.cmd     # primary build entry (Arcade wrapper)
├── restore.sh/.cmd, test.sh/.cmd
├── Directory.Build.props / .targets / Directory.Packages.props   # repo-wide MSBuild
├── global.json              # pins bootstrap SDK + Arcade
└── NuGet.config             # approved feeds (blocks automation-managed — don't edit)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| `dotnet` CLI commands | `src/Cli/` | managed + NativeAOT entry points; `src/Cli/AGENTS.md` |
| MSBuild tasks & targets | `src/Tasks/Microsoft.NET.Build.Tasks/` | ships `Microsoft.NET.Sdk`; `src/Tasks/AGENTS.md` |
| NETSDK diagnostics | `src/Tasks/Common/Resources/Strings.resx` | append-only, next-available code |
| SDK resolvers | `src/Resolvers/` | `src/Resolvers/AGENTS.md` |
| Web/Razor/Blazor/StaticWebAssets | `src/WebSdk/`, `src/RazorSdk/`, `src/BlazorWasmSdk/`, `src/WasmSdk/`, `src/StaticWebAssetsSdk/` | SWA has AGENTS.md |
| Container publish | `src/Containers/` | `src/Containers/AGENTS.md` |
| `dotnet watch` / Hot Reload | `src/Dotnet.Watch/` | `src/Dotnet.Watch/AGENTS.md` |
| `dotnet format` | `src/Dotnet.Format/` | — |
| Template engine (`dotnet new`) | `src/TemplateEngine/` | — |
| API compat tooling | `src/Compatibility/` | ApiCompat/GenAPI/ApiDiff |
| .NET analyzers (CA####) | `src/Microsoft.CodeAnalysis.NetAnalyzers/` | AGENTS.md |
| SDK layout / installers | `src/Layout/` | `src/Layout/AGENTS.md` |
| Workload manifests | `src/Workloads/` | manifest *templates*, not built manifests |
| Shared source (multi-project) | `src/Common/` | linked into many projects, not an SDK |
| Tests | `test/` | `test/AGENTS.md`; harness = `Microsoft.NET.TestFramework.MSTest` |
| Test inputs | `test/TestAssets/` | not tests; TestAssets/AGENTS.md |
| Versions / dependency flow | `eng/Versions.props`, `eng/Version.Details.xml` | `Version.Details.props` is generated |
| Build orchestration | `eng/Build.props`, `eng/build.sh` | Arcade `ProjectToBuild` selection |
| CI | `.vsts-ci.yml`, `.vsts-pr.yml`, `eng/pipelines/` | Azure DevOps; GHA is automation only |

## CODE MAP

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `Program.Main` | entry | `src/Cli/dotnet/Program.cs` | managed CLI dispatch |
| `dotnet_execute` | entry | `src/Cli/dotnet-aot/NativeEntryPoint.cs` | NativeAOT CLI (equal weight) |
| `MSBuildLogger` | logger | `src/Cli/dotnet/Commands/MSBuild/MSBuildLogger.cs` | INodeLogger loaded by MSBuild directly |
| `Microsoft.NET.Sdk.props/.targets` | SDK entry | `src/Tasks/Microsoft.NET.Build.Tasks/targets/` | top-level build entry points |
| `Sdk.props/.targets` | SDK entry | `src/Tasks/Microsoft.NET.Build.Tasks/sdk/` | `<Sdk>` attribute path |
| `redist.csproj` | layout | `src/Layout/redist/redist.csproj` | composes final `dotnet` layout |

## CONVENTIONS

- **TFM: never hardcode** `net8.0`-style TFMs in a `.csproj`. Use `$(SdkTargetFramework)`
  (source/test projects), Arcade props or `net472` (multi-target), `$(CurrentTargetFramework)`
  (test assets).
- **Conditional compilation:** `#if NET` / `#if NETFRAMEWORK` — never `#if NETCOREAPP`.
- **Style (root .editorconfig):** `var` forbidden (explicit types); block-scoped `using`
  (not `using var`); index/range operators disabled; predefined types (`int` not `Int32`);
  MIT license header required (IDE0073); `this.` qualification avoided. Static fields use
  `s_`, private fields `_camelCase`.
  - **Exceptions:** `src/StaticWebAssetsSdk/.editorconfig` sets `root=true` and *requires*
    `var` + file-scoped namespaces. `src/Dotnet.Watch` permits block namespaces.
- **Project-level:** `LangVersion=Preview`, `Nullable=enable`, `TreatWarningsAsErrors=True`,
  `EnforceCodeStyleInBuild=true`, `ImplicitUsings=enable` with global usings
  (`System.Runtime.InteropServices`, `System.Text`, `System.Xml.Linq`) and
  `System.Threading.Tasks` **removed** (collides with `Microsoft.Build.Utilities.Task`).
- **Banned APIs:** no BannedApiAnalyzers — the root `.editorconfig` CA-rule cluster is the
  enforcement mechanism (security cluster CA3061/CA3075-77/CA535x etc. at warning).
  Shipping assemblies require `PublicAPI.txt`/`Unshipped.txt` (`require_api_files = true`).
- **Tests:** MSTest v4 via `MSTest.Sdk` + Microsoft.Testing.Platform (xUnit fully migrated).
  Parallelism `None` by default (opt-in per project). `SdkTest` base, `SdkTestContext.Current`
  for paths, assets in `test/TestAssets/`. See `test/AGENTS.md`.

## ANTI-PATTERNS (THIS PROJECT)

- **Never hand-edit generated files:** `.xlf` (regenerate `/t:UpdateXlf`), `eng/Version.Details.props`
  (edit `Version.Details.xml`), `.github/workflows/*.lock.yml`, generated man pages,
  anything `linguist-generated=true`.
- **Never edit `eng/common/**`** — vendored Arcade, overwritten by automation.
- **Never hardcode a TFM or a version** in project/target files; versions flow through
  `Directory.Packages.props` / `eng/Versions.props` / `eng/Version.Details.xml`.
- **No new `NoWarn` without a justifying comment;** existing suppressions have documented reasons.
- **Never commit `*.received.*`** Verify snapshots — promote received → verified on purpose.
- **Don't run `dotnet format` or reformat unrelated files** — match the file's existing style,
  minimal diffs.
- **Deprecated patterns to avoid:** `IParameterSet` (TemplateEngine migration), `RoslynCompilerType=Framework`,
  `DotNetCliToolReference`, EOL TFMs, `BinaryFormatter` (SYSLIB0011 = error).
- **Telemetry:** never use MSBuild Engine telemetry APIs from SDK components
  (`documentation/project-docs/external-component-telemetry.md`); preserve
  `DOTNET_CLI_TELEMETRY_SESSIONID` in CI.
- **`async void`** — one known instance (`TemplateEngine .../GlobalSettings.cs:169`); don't add more.

## COMMANDS

```bash
./build.sh                        # full SDK build (Debug); restores .dotnet bootstrap
./build.sh -c Release             # release build
./build.sh -test                  # full test suite (very slow — avoid for local work)
./restore.sh                      # restore only
./.dotnet/dotnet <args>           # invoke the repo bootstrap SDK
./.dotnet/dotnet test test/dotnet.Tests/dotnet.Tests.csproj --filter "FullyQualifiedName~X"
source eng/dogfood.sh             # env using the built SDK (artifacts/bin/redist/Debug/dotnet)
./build.sh -projects src/.../X.slnx   # build a sub-solution (e.g. cli.slnf)
./build.sh -help                  # full flag list (or eng/common/build.sh --help)
```

**CI:** primary validation = Azure DevOps (`dotnet-sdk-public-ci` on PRs; Helix test
execution via `test/UnitTests.proj`). GitHub Actions workflows are automation only —
they do not build or test.

## NOTES

- CLI has **three equal-weight process entry points** (managed, NativeAOT, MSBuild logger) —
  see `src/Cli/AGENTS.md`; the logger must not assume CLI bootstrap ran.
- `src/Workloads/Manifests/*` are manifest **templates** (`WorkloadManifest.json.in`), per-TFM.
- Source-build enabled: `./build.sh --sourceBuild` builds `source-build.slnf`; real
  source-build validation happens in the VMR (dotnet/dotnet).
- Sub-area AGENTS.md exist under: `src/Cli`, `src/Tasks`, `src/Resolvers`, `src/Layout`,
  `src/Containers`, `src/Dotnet.Watch`, `src/StaticWebAssetsSdk`,
  `src/Microsoft.CodeAnalysis.NetAnalyzers`, `src/TemplateEngine`, `src/Compatibility`,
  `src/WebSdk`, `src/RazorSdk`, `src/Dotnet.Format`, `test`, `test/TestAssets`,
  `eng/common`, `.github/skills`.
