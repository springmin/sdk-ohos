# dotnet format Agent Instructions

Guidance for changes under `src/Dotnet.Format` (the `dotnet format` code
formatter, a Roslyn-based sibling of `dotnet watch`).

## Where things live

| Path | Role |
|---------|------|
| `dotnet-format` | The tool project (`Microsoft.CodeAnalysis.Tools`). `Program.cs` parses `RootFormatCommand` via System.CommandLine. |
| `Workspaces/` | Workspace loading. `MSBuildWorkspaceLoader` opens solutions/projects through `Microsoft.CodeAnalysis.MSBuild`; `FolderWorkspace` handles `--folder` mode with its own C#/VB project loaders. |
| `Formatters/` | The `ICodeFormatter` pipeline composed in `CodeFormatter.cs`: whitespace, final newline, EOL, charset, organize imports, then code-style and third-party analyzers. |
| `Analyzers/` | Roslyn analyzer loading/running and code-fix application (`AnalyzerRunner`, `AnalyzerFormatter`, `SolutionCodeFixApplier`). |
| `Commands/` | `RootFormatCommand` plus the `whitespace`, `style`, and `analyzers` subcommands. |
| `Utilities/` | `.editorconfig` discovery and parsing (`EditorConfigFinder`, `EditorConfigOptions`), file matching, `DotNetHelper`, `ProcessRunner`. |
| `Resources.resx` + `xlf/` | Localized strings; a strong-typed `Resources` class is generated from the resx. |

## Conventions & gotchas

- **Shipped inside the SDK layout.** `redist.csproj` builds this project and
  `GenerateLayout.targets` places it at `DotnetTools/dotnet-format/`; the CLI's
  `FormatForwardingApp` runs `dotnet format` by forwarding args to that dll. The same
  project is `PackAsTool=true`, so it also packs as the `dotnet-format` global tool.
- **Two workspace modes, both must work.** Solution/project mode uses a real
  `MSBuildWorkspace` (full MSBuild evaluation, honors `--binarylog`); `--folder` mode uses
  `FolderWorkspace` and skips MSBuild entirely. Changes to workspace loading must cover both.
- **`MSBuildWorkspaceLoader.Guard` serializes MSBuild loads.** A static `SemaphoreSlim`
  prevents concurrent MSBuild invocations; tests depend on it. Don't remove it.
- **Formatters run in fixed order.** `s_codeFormatters` in `CodeFormatter.cs` defines the
  pipeline. Add new formatters there, not ad hoc.
- **Style/analyzer fixes use Roslyn code fixes.** `AnalyzerFormatter` applies fixers filtered
  by `--severity`/`--diagnostics`; the `Microsoft.CodeAnalysis.*.Features` packages are
  loaded dynamically, not referenced statically.
- **Project-file quirks.** `CopyLocalLockFileAssemblies=true` copies NuGet assemblies to the
  output; `AutoGenerateBindingRedirects=false` avoids arcade issue 9305; `ServerGarbageCollection=true`.
- **Localization.** Add strings to `Resources.resx` and regenerate `xlf/` with `/t:UpdateXlf`;
  never hand-edit the `.xlf` files.

## Tests

- `test/dotnet-format.UnitTests`. **Disabled in CI** (removed in `test/UnitTests.proj`,
  tracked by https://github.com/dotnet/sdk/issues/54249). Run locally via the `dotnet-format.slnf`
  filter. Has `InternalsVisibleTo` access into the tool.
- `test/dotnet-format.IntegrationTests`. CI runs these **only on Linux x64**, one Helix work
  item per test class via `PartitionByClass`. Each class (`SdkFormatTests`,
  `MsBuildFormatTests`, `ProjectSystemFormatTests`) shallow-clones an external repo at a pinned
  SHA, strips the `sdk` section from its `global.json`, restores, then runs
  `dotnet format --verify-no-changes`. Exit code 0 means clean, 2 means format differences
  found (expected for foreign repos); anything else fails. These are heavy (30-minute process
  timeout) — keep them lean.
