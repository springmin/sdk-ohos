# OHOS build — official CI vs local script: decision-point table

**Date:** 2026-09-05
**Script:** `build/build-ohos-all.sh` (this directory)
**Scope:** each build decision, what official CI chooses (upstream evidence) and
what the ohos script chooses, with the deviation class.

| # | Decision | Official CI (evidence) | OHOS script | Deviation |
|---|---|---|---|---|
| 1 | runtime subset | `clr+libs+host+packs` (eng/pipelines/runtime.yml AllSubsets_CoreCLR — host builds apphost/host packs) | `clr+libs+packs` (+host trips NETSDK1084 — independent ohos RID has no apphost in the prebuilt SDK; Host pack still produced via packs dependency chain) | intentional (RID independence) |
| 2 | ilc tool shape | NativeAOT (eng/toolAot.targets: UseNativeAotForComponents → PublishAot; same-OS builds) | CoreCLR split layout (OHOS excluded from NativeAotForComponents at eng/Subsets.props:59 + on-device hostpolicy resolution; split = only device-PASSED shape, rounds 9/16) | intentional (no same-OS host; device constraint) |
| 3 | ReadyToRun | inside CoreCLR.sfxproj packaging, PGO mibc, full framework | full framework + CoreLib: OFFICIAL NuGet crossgen2 (26427) over all layout assemblies (`crossgen-framework.py`), overlaid into the runtime pack, layout and runtime tarball (`overlay-pack.py` / `overlay-tarball.py`); PGO mibc seeded from `reference-runtime-pack.nupkg` (30 MB, `mibc=yes` in CI run 34748587486; 180/180 compiled) | intentional, policy choice — the out-of-tree overlay is the shipped path; **the in-build crossgen2 is probe-verified** (official-shape host tool compiled the OHOS CoreLib: run 34784718506; no hang). In-tree A/B (34789839170): OpenHarmonyInTreeR2R reaches the sfxproj R2R but the packaged assets stayed PureIL (runtime pack R2R=1/181), so the overlay remains the shipped path; the aspnetcore-tarball overlay gap was found and fixed (overlay-tarball.py now matches shared/Microsoft.AspNetCore.App). Device SCD+R2R publish now compiles the app only: 43 s vs >15 min stall (2026-09-13) |
| 4 | NativeAOT pack | all-RID pack legs (VMR / DotNetBuildAllRuntimePacks) | `clr.aot+packs` + explicit NativeAOT.sfxproj (fork plan C.7) | intentional (DotNetBuildAllRuntimePacks also triggers Mono cross-AOT) |
| 5 | R2R image version | 27.1 unconditional (readytorun.h — 36ef/#132787) | 27.1 retained (runtime `7b6677116de`; sdk crossgen2 default 26451.109, `01e940d295`). The earlier device SIGSEGV was the ILLink-stripped-methods issue (#133296 class), avoided by the untrimmed split layout (`PublishSingleFile=false`/`PublishTrimmed=false`), device-verified | **resolved for the fork** — upstream #133296 remains open for trimmed packs; no longer a merge blocker |
| 6 | aspnetcore | Release R2R default on (App.Runtime.sfxproj:16-20) | `os-name=openharmony` + `PublishReadyToRun=false` at build time; the pack/tarball are then R2R-overlaid by `build-ohos-all.sh` stage3 (`crossgen-framework.py` with the stock crossgen2 openharmony-arm64 + runtime-pack PGO mibc → `overlay-pack.py` / `overlay-tarball.py`) before the pre-sign step | intentional (upstream sfxproj R2R needs a bootstrap SDK whose R2R resolution + bundled versions carry openharmony; the overlay is the reproducible offline path. Local device check 2026-09-13: 132/132 compiled, publish 314/314 DLLs R2R, app starts) |
| 7 | sdk | `-pack` (SkipUsingCrossgen false — SDK assemblies crossgen'd) + IncludeAspNetCoreRuntime default-include | no `-pack` (SDK stays IL) + `IncludeAspNetCoreRuntime=false` (ASP.NET Core ships in aspnetcore-ohos) | intentional (ohos SDK crossgen unverified; separate aspnetcore release) |
| 8 | signing | none (no OHOS concept) | `.codesign` on every ELF at build/pre-package time | ohos-specific (device executes only signed ELF) |
| 9 | version flow | darc / transport feeds | local NuGet folder feed + `rt-version.txt` override + localhost asset server | environment substitute (no darc; overrides mirror it) |
| 10 | bootstrap host | official uses same-arch hosts/containers (same-OS AOT tools) | x64 host cross + bootstrap host sync (bin corehost → bootstrap/<rid>/host) | environment (no ohos host) |
| 11 | crossgen2 pack shape (SDK-side R2R) | single-file, trimmed (`crossgen2_publish.csproj` PublishTrimmed/AotOrSingleFile; bootstrap layout) | untrimmed CoreCLR **split layout** + runtime-pack framework overlay + `runtimepack` deps entry (`assemble-crossgen2-pack.py`; same treatment as ilc) — device `PublishReadyToRun` E2E passed 2026-09-12 | intentional (device constraint: ILLink strips interface-dispatched methods — dotnet/runtime #133296 class; no bootstrap SDK on device) |

**Classes:** intentional = ohos-specific / reviewed; temporary = pending upstream
(none currently — item 5 was resolved on the fork with the untrimmed split layout;
dotnet/runtime #133296 still tracks the ILLink strip issue for trimmed packs);
environment = mechanically equivalent substitutes for CI infra the forks do not have.

**Remaining alignment gap:** none blocking the fork's releases. Item 5 is
resolved on the fork (27.1 with the untrimmed split layout); the upstream ILLink
issue (#133296) still affects trimmed packs. Items 1-4, 6-8 are
reviewed/intentional; 9-10 local-only.
