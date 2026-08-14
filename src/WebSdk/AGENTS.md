# Web SDK Agent Instructions

Guidance for changes under `src/WebSdk` (the ASP.NET Core web SDKs that layer on the base `Microsoft.NET.Sdk` from `src/Tasks`).

## Where things live

`src/WebSdk` holds four sub-SDKs, each laid out as `Sdk/` (the `<Sdk>` attribute entry points), `Targets/` (shipping `.props`/`.targets`), and `Tasks/` (the MSBuild task assembly project, which is also the package project):

| Sub-SDK | Package | Role |
|---------|---------|------|
| `Web/` | `Microsoft.NET.Sdk.Web` | Meta SDK. `Sdk/Sdk.props` dispatches on `TargetPlatformIdentifier`: `browser` delegates to the Blazor WebAssembly SDK, otherwise `Sdk.Server.props` imports base `Microsoft.NET.Sdk` + Razor + ProjectSystem + Publish. Adds the implicit `Microsoft.AspNetCore.App` `FrameworkReference`, ASP.NET Core analyzers, and web implicit usings. |
| `ProjectSystem/` | `Microsoft.NET.Sdk.Web.ProjectSystem` | VS project-system integration: `OutputType=Exe`, `DebugType=full`, `ServerGarbageCollection=true`, VS TypeScript props, default-item handling for `launchSettings.json`/`PublishProfiles`, and AOT `EventSourceSupport` defaulted before the common targets. |
| `Publish/` | `Microsoft.NET.Sdk.Publish` | Profile-driven publish: MSDeploy, ZipDeploy, OneDeploy, Kudu, FileSystem, Container/Docker targets, `PublishProfiles/*.pubxml`, and transform tasks (Xdt, AppSettings, WebConfig, WebJobs, EF SQL scripts). |
| `Worker/` | `Microsoft.NET.Sdk.Worker` | Thin wrapper: imports base `Microsoft.NET.Sdk`, sets `OutputType=Exe`, default content globs for `*.json`/`*.config`. |

Root files: `Package.props` (shared packaging props), `CopyPackageLayout.targets`, `WebSdk.slnf` (focused build: the four `Tasks/` projects plus `test/Microsoft.NET.Sdk.Publish.Tasks.Tests`), and `README.md` (profile-based publish usage). The projects build as part of `sdk.slnx`; use `./build.sh -projects src/WebSdk/WebSdk.slnf` for a focused build.

## Conventions & gotchas

- No `.editorconfig` here: root repo style applies (explicit types, block-scoped `using`s, no `var`).
- Task assemblies multi-target `$(SdkTargetFramework);net472` (Worker uses `$(NetFrameworkToolCurrent)`), so task code must stay .NET Framework-compatible, like `src/Tasks`.
- File naming is `Microsoft.NET.Sdk.*` throughout; there is no `WebSDK-` prefix convention for targets or tasks.
- Each `Sdk/Sdk.props` sets a `UsingMicrosoftNETSdk*` flag (e.g. `UsingMicrosoftNETSdkWeb`) then imports its `Targets/` files; `Web/Sdk/Sdk.props` branches on `$([MSBuild]::GetTargetPlatformIdentifier($(TargetFramework)))`.
- Import order matters: `Sdk.Server.targets` imports base `Microsoft.NET.Sdk` targets first, then sets `AddRazorSupportForMvc=true`, imports Razor/ProjectSystem/Publish targets, and finally adds `RuntimeHostConfigurationOption` defaults.
- Publish tasks carry their own `Properties/Resources.resx` + `.xlf`, separate from the NETSDK `Strings.resx` in `src/Tasks`; never hand-edit `.xlf`, regenerate via `/t:UpdateXlf`.
- `Package.props` + `CopyPackageLayout.targets` pack `Sdk/` and `Targets/` as `AdditionalContent` into `Sdks/<PackageId>/` under `PackageLayoutOutputPath`.

## Tests

- `test/Microsoft.NET.Sdk.Web.Tests/`: `PublishTests.cs` (`PublishTests : SdkTest`, MSTest.Sdk) covers web publish behavior (trimming defaults, runtimeconfig). References the `Microsoft.NET.Sdk.Web.Tasks` project.
- `test/Microsoft.NET.Sdk.Publish.Tasks.Tests/`: unit tests for the publish tasks (AppSettingsTransform, WebConfigTransform, EnvironmentHelper, WebJobsCommandGenerator, WebConfigTelemetry, EndToEnd).
- `AspNetSdkTest` (in `test/Microsoft.NET.TestFramework.MSTest/AspNetSdkTest.cs`, `[TestCategory("AspNetCore")]`, extends `SdkTest`) provides `CreateAspNetSdkTestAsset` and `DefaultTfm` from the `AspNetTestTfm` assembly metadata; Razor, Blazor WebAssembly, and Static Web Assets integration tests derive from it.
- Web test assets live in `test/TestAssets/TestProjects/` (`WebApp`, `TestWebAppSimple`).
- No conditional-test scope exists for `src/WebSdk` in `test/ConditionalTests.props`; run tests directly with `./.dotnet/dotnet test`.
