# Test Assets Agent Instructions

Guidance for changes under `test/TestAssets/`. These are test INPUTS, not tests: tiny
sample projects, packages, and workloads that tests copy into scratch directories at
runtime via `TestAssetsManager`.

## Where things live

- **`TestProjects/`** — ~270 tiny `.csproj` fixtures named after the scenario they
  exercise (e.g. `AppWithLibrary`, `AppWithLaunchSettings`). This is the default lookup
  directory for `CopyTestAsset("Name")`.
- **`DesktopTestProjects/`** — .NET Framework (net4x) fixtures:
  `MultiTFMXunitProject`, `NETFrameworkReferenceNETStandard20`.
- **`NonRestoredTestProjects/`** — intentionally unrestorable projects (missing tools,
  broken dependencies) used by failure-path tests.
- **`ProjectConstruction/`** — templates (`SdkProject`, `NetFrameworkProject`,
  `NetFrameworkProjectVB`) used by in-memory `TestProject` construction tests.
- **`TestWorkloads/`** — fake workload manifests and packs (under `manifests/`,
  `packs/`) for workload resolution tests.
- **`TestPackages/`** — package-shaped assets (analyzers, libraries with direct and
  transitive dependencies) for restore and reference tests.
- **`TestReleases/`** — release-shaped inputs (`TestRelease`,
  `VulnerabilityTestRelease`) for versioning and vulnerability tests.
- **`InstallationScriptTests/`** — inputs for installation script tests
  (`InstallationScriptTests.json`).
- **`dotnet-format/`** — fixtures for `dotnet format` tests (`for_analyzer_formatter`,
  `for_code_formatter`, `for_workspace_finder`).
- **`WasmOverride/`** — MSBuild props/targets and a `NuGet.config` that override Wasm
  pack resolution for Wasm SDK tests.

## Conventions & gotchas

- **Asset projects opt OUT of repo build conventions.** `Directory.Build.props` here sets
  `ManagePackageVersionsCentrally=false` (no CPM), `NuGetAudit=false`,
  `CheckEolTargetFramework=false`, and excludes `**/*.tmp`; `Directory.Build.targets` is
  intentionally empty. Both exist only to block the repo-root props and targets so assets
  behave like end-user projects. Do not add repo-wide settings back here.
- **`CopyTestAsset("Name")` resolves to `TestAssets/TestProjects/<Name>`.** The lookup
  defaults to the `TestProjects/` subdirectory; pass `testAssetSubdirectory:` to target
  `DesktopTestProjects` or `NonRestoredTestProjects` (constants live in
  `Microsoft.NET.TestFramework/TestAssetSubdirectories.cs`).
- **Use `$(CurrentTargetFramework)`, never a hardcoded TFM.** At test runtime
  `TestAssetsManager` rewrites the `TargetFramework`/`CurrentTargetFramework` property in
  copied assets to `ToolsetInfo.CurrentTargetFramework`. Test assets may import the root
  `testAsset.props`, which sets `RepoRoot`, `RestorePackagesPath` (repo NuGet cache) and
  disables SourceLink.
- **Give each theory case a distinct `identifier:`.** Test copies land in a scratch
  directory keyed by calling method, identifier, and asset name; pass a unique identifier
  derived from theory parameters so parallel cases do not collide (see the `CopyTestAsset`
  doc comment in `TestAssetsManager.cs`).
- **Treat assets as shared, read-mostly fixtures.** An edit is picked up by every test
  that copies the asset, so only change an asset when its scenario behavior must change.
  Renames and deletions break all referencing tests; grep for `CopyTestAsset("OldName"` first.
- **Keep assets self-contained.** They must restore and build from a scratch copy using
  only the repo NuGet cache; never reference `bin`/`obj` outputs or built artifacts.

## Deploying to Helix

- `test/UnitTests.proj` ships the whole tree to Helix via
  `<AssetFiles Include="TestAssets\**\*.*" />`, so every asset is available under
  `SdkTestContext.Current.TestAssetsDirectory` with no per-asset registration.
- `TestAssets\**\*.Tests.csproj` and `TestAssets\**\*` are excluded from the test-project
  globs in `UnitTests.proj`, so an asset is never picked up as a test project.
- Non-asset helpers (root `testAsset.props`, `eng/Versions.props`, etc.) reach the test
  execution directory through `TestExecutionDirectoryFiles` in the same file.
