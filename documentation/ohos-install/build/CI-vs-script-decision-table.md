# OHOS build — official CI vs local script: decision-point table

**Date:** 2026-09-05
**Script:** `build/build-ohos-all.sh` (this directory)
**Scope:** each build decision, what official CI chooses (upstream evidence) and
what the ohos script chooses, with the deviation class.

| # | Decision | Official CI (evidence) | OHOS script | Deviation |
|---|---|---|---|---|
| 1 | runtime subset | `clr+libs+host+packs` (eng/pipelines/runtime.yml AllSubsets_CoreCLR — host builds apphost/host packs) | `clr+libs+packs` (+host trips NETSDK1084 — independent ohos RID has no apphost in the prebuilt SDK; Host pack still produced via packs dependency chain) | intentional (RID independence) |
| 2 | ilc tool shape | NativeAOT (eng/toolAot.targets: UseNativeAotForComponents → PublishAot; same-OS builds) | CoreCLR split layout (OHOS excluded from NativeAotForComponents at eng/Subsets.props:59 + on-device hostpolicy resolution; split = only device-PASSED shape, rounds 9/16) | intentional (no same-OS host; device constraint) |
| 3 | ReadyToRun | inside CoreCLR.sfxproj packaging, PGO mibc, full framework | CoreLib only, via OFFICIAL NuGet crossgen2 (26427) + pack CoreLib swap; PGO when mibc exists | intentional (fork crossgen2_inbuild startup hang; CoreLib-only, no-PGO fallback) |
| 4 | NativeAOT pack | all-RID pack legs (VMR / DotNetBuildAllRuntimePacks) | `clr.aot+packs` + explicit NativeAOT.sfxproj (fork plan C.7) | intentional (DotNetBuildAllRuntimePacks also triggers Mono cross-AOT) |
| 5 | R2R image version | 27.1 unconditional (readytorun.h — 36ef/#132787) | 27.0 (revert 36ef — device SIGSEGV; upstream issue dotnet/runtime #133296) | **temporary** — pending upstream fix; must resolve before PR merge |
| 6 | aspnetcore | os-name any value passes; Release R2R default on (App.Runtime.sfxproj:16) | os-name=ohos + `PublishReadyToRun=false` + `NativeAotSupported=false` | intentional (no PGO/krb5 on ohos) |
| 7 | sdk | `-pack` (SkipUsingCrossgen false — SDK assemblies crossgen'd) + IncludeAspNetCoreRuntime default-include | no `-pack` (SDK stays IL) + `IncludeAspNetCoreRuntime=false` (ASP.NET Core ships in aspnetcore-ohos) | intentional (ohos SDK crossgen unverified; separate aspnetcore release) |
| 8 | signing | none (no OHOS concept) | `.codesign` on every ELF at build/pre-package time | ohos-specific (device executes only signed ELF) |
| 9 | version flow | darc / transport feeds | local NuGet folder feed + `rt-version.txt` override + localhost asset server | environment substitute (no darc; overrides mirror it) |
| 10 | bootstrap host | official uses same-arch hosts/containers (same-OS AOT tools) | x64 host cross + bootstrap host sync (bin corehost → bootstrap/<rid>/host) | environment (no ohos host) |

**Classes:** intentional = ohos-specific / reviewed; temporary = pending upstream
(item 5 — revert 36ef / R2R 27.0, tracked dotnet/runtime #133296); environment =
mechanically equivalent substitutes for CI infra the forks do not have.

**Remaining alignment gap:** only item 5 blocks PR merge (36ef fix must land
upstream first, else OHOS NativeAOT apps crash on 27.1). Items 1-4, 6-8 are
reviewed/intentional; 9-10 local-only.
