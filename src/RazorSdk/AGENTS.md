# Razor SDK Agent Instructions

Guidance for changes under `src/RazorSdk` (the `Microsoft.NET.Sdk.Razor` build SDK that
compiles Razor views/components for ASP.NET Core projects). It layers on top of
`Microsoft.NET.Sdk` and `Microsoft.NET.Sdk.StaticWebAssets`.

## Where things live

| Path | Role |
|------|------|
| `Sdk/Sdk.props` + `Sdk/Sdk.targets` | The `<Sdk>` attribute entry points. Conditionally import `Microsoft.NET.Sdk` and `Microsoft.NET.Sdk.StaticWebAssets` (skipped when already imported, e.g. by `Microsoft.NET.Sdk.Web`), then import the versioned `Sdk.Razor.CurrentVersion.props/.targets`. |
| `Targets/` | The shipping `.props`/`.targets`. `Sdk.Razor.CurrentVersion.targets` is the main body; the `Microsoft.NET.Sdk.Razor.*.targets` split by concern (CodeGeneration, Compilation, Component, Configuration, DesignTime, GenerateAssemblyInfo, MvcApplicationPartsDiscovery, SourceGenerators, BeforeCommon). `Rules/*.xaml` are the VS project-system rules. |
| `Tasks/` | `Microsoft.NET.Sdk.Razor.Tasks.csproj` (namespace `Microsoft.AspNetCore.Razor.Tasks`): `SdkRazorGenerate`, `SdkRazorTagHelper`, `FindAssembliesWithReferencesTo`, `EncodeRazorInputItem`, and the `DotnetToolTask` base that spawns the compiler tool. |
| `Tool/` | `Microsoft.NET.Sdk.Razor.Tool.csproj`, the Razor compiler CLI (`AssemblyName=rzc`), a client/server design (`Client.cs`, `ServerCommand.cs`, `ConnectionHost.cs`) in the style of Roslyn's compiler server. |
| `Razor.slnf` | Solution filter over the Razor/Blazor/Wasm/StaticWebAssets project and test subset. |
| `update-test-baselines.sh/.ps1` | Baseline regeneration/validation scripts. |

## Conventions & gotchas

- **The compiler and language packages flow through dependency flow.** `eng/Version.Details.xml`
  carries `Microsoft.CodeAnalysis.Razor.Tooling.Internal`,
  `Microsoft.AspNetCore.Mvc.Razor.Extensions.Tooling.Internal`, and
  `Microsoft.NET.Sdk.Razor.SourceGenerators.Transport`; bump them via Darc/Maestro, never
  hand-edit the generated `eng/Version.Details.props`.
- **`Tasks` multi-targets** `$(SdkTargetFramework)` and `$(NetFrameworkToolCurrent)`, so new
  task code must stay `net472`-compatible (no .NET-only APIs), the same constraint as `src/Tasks`.
- **The SDK layers on the base SDKs.** `Sdk.props/.targets` import `Microsoft.NET.Sdk` and
  `Microsoft.NET.Sdk.StaticWebAssets` only when `UsingMicrosoftNETSdk` /
  `UsingMicrosoftNETSdkStaticWebAssets` are not already set (e.g. by `Microsoft.NET.Sdk.Web`).
  Don't assume the base imports are absent or present.
- **Tool paths derive from `RazorSdkDirectoryRoot`** (overridable to test a local build):
  `tasks\<tfm>\Microsoft.NET.Sdk.Razor.Tasks.dll`, `tools\rzc.dll`, `source-generators\*.dll`.
- **The local `.editorconfig` flips the root `var` rule**: `csharp_style_var_* = true` means
  `var` is preferred here. IDE0073 (file header) is an error, so every file needs the MIT
  license header.
- **`RazorLangVersion` defaults are inferred per-TFM** (11.0 for current, down through 2.1
  legacy); `RazorCompileToolset` is `Implicit`, `RazorSdk`, or `PrecompilationTool`.
- **Source-generator path:** analyzers under `source-generators\` are added to `@(Analyzer)`
  and Razor inputs are handed to the compiler as `AdditionalFiles` (via `EncodeRazorInputItem`
  to work around special characters).
- **Default items:** `**\*.cshtml` / `**\*.razor` are picked up from `@(Content)` into
  `@(RazorGenerate)` / `@(RazorComponent)` (see `EnableDefaultRazorGenerateItems` /
  `EnableDefaultRazorComponentItems`).

## Tests

- `test/Microsoft.NET.Sdk.Razor.Tests`: MSBuild integration tests (`BuildIntegrationTest`,
  `BuildIncrementalismTest`, `DesignTimeBuildIntegrationTest`, `PackIntegrationTest`,
  `PublishIntegrationTest`, `MvcBuildIntegrationTest*`, `BuildWithComponentsIntegrationTest`).
  They use the `AspNetSdkTest` base in `test/Microsoft.NET.TestFramework.MSTest`
  (`[TestCategory("AspNetCore")]`), pull assets from `test/TestAssets/TestProjects`
  (RazorSimpleMvc, RazorClassLibrary, RazorComponentApp, ...), and generate a binlog per test
  by default.
- `test/Microsoft.NET.Sdk.Razor.Tool.Tests`: unit tests for the `rzc` tool (`CommandRoundTripTest`,
  `ServerCommandTest`, `ServerLifecycleTest`, `TagHelperJsonSerializationTest`, loaders,
  metadata cache).
- Both projects are in `Razor.slnf`.
