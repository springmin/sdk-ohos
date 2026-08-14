# TemplateEngine Agent Instructions

Guidance for changes under `src/TemplateEngine` (the template engine behind
`dotnet new`, plus the template authoring/discovery tools).

## Where things live

| Project | Role |
|---------|------|
| `Microsoft.TemplateEngine.Abstractions` | Core interfaces (`ITemplate`, `IGenerator`, parameter & mount abstractions) that everything else implements. `PublicAPI.txt` is tracked. |
| `Microsoft.TemplateEngine.Core` / `Core.Contracts` | Text-processing engine: tokenization, operations, variable collections. Contracts is the interface half. |
| `Microsoft.TemplateEngine.Edge` | Host-side runtime: settings loading, mount points, template installers, `DefaultTemplateEngineHost`. |
| `Microsoft.TemplateEngine.IDE` | `Bootstrapper` for hosting the engine inside Visual Studio. |
| `Microsoft.TemplateEngine.Orchestrator.RunnableProjects` | `RunnableProjectGenerator` plus the `template.json` config model: macros, value forms, localization, and the JSON schema under `Schemas/`. |
| `Microsoft.TemplateEngine.Utils` | Shared helpers: globbing, in-memory file system, version specs, well-known search filters. |
| `Microsoft.TemplateSearch.Common` | Search-cache model consumed by `dotnet new search`. |
| `Shared/` | Small shared sources (`IsExternalInit`, `JExtensions`) linked into projects, not a package. |

**`Tools/` — authoring tools.** `Microsoft.TemplateEngine.Authoring.CLI` is the
`dotnet` global tool exposing the `localize` and `verify` commands;
`Microsoft.TemplateEngine.Authoring.Tasks` is the MSBuild `Localize` task for
template packages; `Authoring.TemplateVerifier` is the snapshot-testing framework;
`Authoring.TemplateApiVerifier` is an internal Edge-only host for tests;
`TemplateLocalizer.Core` backs `localize`; `TemplateSearch.TemplateDiscovery` is an
internal CLI that regenerates the `dotnet new search` cache.

## Conventions & gotchas

- **Async / `IParameterSetData` migration is in flight.** `IGenerator.CreateAsync`
  and `GetCreationEffectsAsync` now take `IParameterSetData`; `IParameterSet` is
  `[Obsolete]`, and the old `IGenerator` members are `[Obsolete]` with the
  replacement named in the attribute. Write new code against the async,
  `IParameterSetData` APIs; don't widen the obsolete surface.
- **`net472` multitargeting drives style.** TE projects build for `net472` and
  current .NET, so `IDE0005` (unnecessary using) is relaxed to *suggestion* in
  `.editorconfig` and many StyleCop rules are disabled. Don't "fix" them.
- **The `template.json` schema lives in the repo.** `Orchestrator.RunnableProjects/Schemas`
  holds the JSON schema used by validation and schema tests; authoring changes must
  keep it in sync.
- **`.xlf` files are generated**, never hand-edited: change the `.resx` and
  regenerate via `/t:UpdateXlf`.
- **Shipping packages.** `IsShippingPackage=true` and strong-naming
  (`StrongNameKeyId=MicrosoftAspNetCore`) apply under this tree; public API
  analyzers gate new surface via `PublicAPI.Shipped.txt` / `Unshipped.txt`.

## Tests

- Per-component unit/integration tests live in `test/TemplateEngine/`
  (`Microsoft.TemplateEngine.*.UnitTests`, `*.IntegrationTests`), with shared fakes
  in `Microsoft.TemplateEngine.Mocks` and `Microsoft.TemplateEngine.TestHelper`.
- `test/Microsoft.TemplateEngine.Cli.UnitTests` covers the `dotnet new` command
  layer, which lives in `src/Cli/Microsoft.TemplateEngine.Cli` (not under
  `src/TemplateEngine`).
- `test/dotnet-new.IntegrationTests` is end-to-end `dotnet new`, including
  Verify snapshot tests: promote `*.received.*` to `*.verified.*` on intentional
  output changes, never commit the received files.
- Tests are MSTest v4 (`MSTest.Sdk`) with `Verify.MSTest`; projects multi-target
  `$(NetCurrent);$(NetFrameworkCurrent)`.
- Build the focused filter `TemplateEngine.slnf`; run individual projects with the
  bootstrap SDK, e.g.
  `./.dotnet/dotnet test test/TemplateEngine/Microsoft.TemplateEngine.Core.UnitTests/Microsoft.TemplateEngine.Core.UnitTests.csproj --filter "FullyQualifiedName~SomeTest"`.
