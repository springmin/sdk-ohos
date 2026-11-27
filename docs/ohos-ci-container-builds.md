# Container-based CI for the OpenHarmony stack

Status of the GitHub Actions work that keeps OpenHarmony build products off the
device and reproducible. Updated after the .NET 11 + MAUI 11.0.10 GA freeze
(2026-11-27).

## What runs where

| Job (workflow) | Host | Produces | Status |
|---|---|---|---|
| `cross` – `runtime-ohos/.github/workflows/ohos-cross-build.yml` | prereqs image (`azurelinux-4.0-net12.0-cross-openharmony-6.0-amd64`) | `libcoreclr.so`, `createdump`, `libclrinterpreter.so`, `singlefilehost` | ✅ `45792329302` |
| `verify826` – same workflow | same image | `bin/Debug/net11.0/verify.dll` (2,285,056 B) | ✅ `45792329302` (MAUI 11.0.10) |
| `jit-hap` – same workflow | same image | `hello-maui-app-unsigned.hap` (133 MB) | ✅ `45792329302` |
| `aot-hap` – same workflow | same image | AOT hap (22 MB) + `publish-aot.log` inside the artifact | ✅ `45792329302` |
| `maui-core` – `runtime-ohos/.github/workflows/maui-core-build.yml` | same image | `artifacts/bin/Core/.../Microsoft.Maui.dll` (1,092,096 B) and `.../Controls.Core/.../Microsoft.Maui.Controls.dll` (2,329,600 B) for `net11.0-openharmony20.0` | ✅ `46004135066` |
| `csc-repro` – `runtime-ohos/.github/workflows/csc-repro.yml` | same image | glibc reproducer for `runtime-ohos#2`, dump capture | ✅ `46002170870`: 9/9 rebuilds `rc=0`, no dumps |
| `ohos-clean-machine.yml` | self-hosted OHOS runner | GA gate (826 / JIT / AOT) | ✅ `45794120507` (fresh AOT log) |
| `ohos-device-round.yml` | self-hosted OHOS runner | device round (11 steps) | ✅ `45790115314` (`failures=0`) |

## Container defaults after the freeze

- `ohos-cross-build.yml` defaults: `maui_ref=slice/11.0.10`, `maui_pin=ga`.
  `feature/openharmony` + `rc2` remain available as historical inputs.
- `verify826` restores the frozen `Microsoft.Maui.*` 11.0.10 packages from the
  `sdk-ohos@maui-11.0.10` mirror (`maui-11.0.10-nupkgs.tar.gz`) instead of
  nuget.org.
- `jit-hap` / `aot-hap` put the same mirror and the 1.0.0 workload feed into
  `offline-feed`, which their generated `NuGet.config` registers as a source.
- `ohos-clean-machine.yml` defaults `maui_source` to the stable
  `/storage/Users/currentUser/springsources/maui-ohos-ga` worktree (branch
  `slice/11.0.10`). Scheduled runs resolve `prebuilt_run` to the newest
  successful `ohos-cross-build.yml` run and use the assembled `prebuilt-*`
  directories.

## Pitfalls hit while building the container jobs

1. **Image tag** carries the NDK version: `...-cross-openharmony-6.0-amd64`
   (missing `6.0` → docker pull failure).
2. **`-os openharmony`** must be passed to `build.sh`, otherwise it configures a
   linux build (`Unsupported OS harmonyos` otherwise).
3. **OpenSSL/ICU are not on the default search path**: point
   `OPENSSL_ROOT_DIR` at `/opt/ohos-assets/openssl` and stage ICU/OpenSSL headers
   and `.a` files into `$OHOS_NDK_HOME/native/sysroot` (the cross toolchain
   restricts `find_*` to the sysroot).
4. **Static-graph restore crashes** in the container; use
   `/p:RestoreUseStaticGraphEvaluation=false` **plus** an explicit `-restore`
   step, otherwise `cdac-build-tool` has no `project.assets.json`.
5. **Arcade 11.0.0-beta is not on the public dnceng feed.** Mirror the nupkg as a
   release asset (`sdk-ohos@arcade-mirror-11.0.0-beta.26527.113`) and add it as a
   `NuGet.config` `packageSources` entry — `RestoreSources` is ignored by the
   MSBuild SDK resolver. The `maui-core` job also overrides the maui-ohos
   `global.json` Arcade pin (`26514.118` → `26527.113`) to use that mirror.
6. **`ArcadeSdkDir` needs the trailing slash** (`.../tools/`), otherwise
   `MSB4019 BeforeCommonTargets.targets not found`.
7. **maui-ohos refs**: the GA slice is `slice/11.0.10` (frozen, default now);
   `feature/openharmony` is the historical fork tip. Checking out the wrong ref
   fails with "maui-ohos slice directory does not exist" or builds the old
   table.
8. **`dotnet nuget locals` exits non-zero** in this image; derive the global
   packages folder from `$NUGET_PACKAGES` / `$HOME/.nuget/packages` instead.
9. **HAP packaging needs `ohos_packing_tool`**, which the public SDK no longer
   ships — only `app_packing_tool.jar`. Shim it:
   `ohos_packing_tool` / `hap-sign-tool` → `java -jar <tool>.jar "$@"`, placed in
   both `toolchains/` and `toolchains/lib/`, with a JDK from
   `actions/setup-java@v4` (the azurelinux image has no java package).
10. **Signing inside the container has no material**: pass
    `-p:OpenHarmonyHapSigning=false` and let the device side sign
    (`selfsign` / `sign-for-device.sh`).
11. **Workload 1.0.1 needs a newer SDK than linux-x64 has.** The 1.0.1 manifest
    lists the BCL runtime packs at 11.0.1; the stock linux-x64 SDK 11.0.100
    requests 11.0.0 (and SDK 11.0.101 is not published for linux-x64). The
    container hap jobs therefore install workload **1.0.0**; the clean-machine
    gate installs **1.0.1** (the `v11.0.101-ohos` arm64 SDK is the 11.0.1 app
    vehicle). `-p:RuntimeFrameworkVersion=11.0.1` is not a fix: it also retargets
    the OpenHarmony runtime pack (which is 1.0.0).
12. **The 60 MB AOT artifact is unreliable over the GitHub API on the runner.**
    The container publishes `aot-prebuilt.tar.gz` (hap + publish libs + log) to
    `ci-prebuilts`; the gate downloads it through `ghfast.top`. The per-run
    artifact zip is only a bounded fallback.
13. **Scheduled runs need a prebuilt source.** They used to fall back to local
    `/data/.../prebuilt-*` directories; now they resolve the newest successful
    cross-build run (`prebuilt_run=latest` is also accepted for a manual test)
    and set `PREBUILT_*_DIR` to the assembled workspace paths.

## AOT in the container (done)

`aot-hap` builds the AOT hap inside the same image. What it took:

1. fetch the `-rtm` pack assets (`Microsoft.DotNet.ILCompiler.11.0.0-rtm`,
   `Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64.11.0.0-rtm`,
   `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.11.0.0-rtm`,
   `Microsoft.NET.ILLink.Tasks.11.0.0-rtm.*`) into `$AOT_WORKDIR/feed`;
2. register that folder **and** the mirrored Arcade nupkg as `packageSources`
   (the SDK resolver ignores `RestoreSources`);
3. `publish-aot.sh` pins `--source "$BASE/feed"`, which hides nuget.org — patch
   the script in the job to add the offline feed and nuget.org;
4. analyzers must be off (`CA5394` in the maui-ohos slice is fatal otherwise)
   and signing is skipped (`-p:OpenHarmonyHapSigning=false`);
5. link with the image wrappers, not the host binutils:
   `CppCompilerAndLinker=/opt/ohos-toolchain/bin/aarch64-linux-ohos-cc` and
   `ObjCopyName=/opt/ohos-toolchain/bin/aarch64-linux-ohos-objcopy`
   (otherwise `crtn.o` is missing and `objcopy` cannot parse the arm64 `.so`);
6. stage `publish-aot.log` inside the uploaded bin tree (the absolute
   `${{ runner.temp }}` path is not part of the artifact) and publish
   `aot-prebuilt.tar.gz` to `ci-prebuilts`.

Result: `EXIT=0`, IL2026/IL3050/IL3051 = 0, hap ≈ 22 MB. The gate consumes the
fresh `publish-aot.log` (`using the fresh AOT IL-gate log`, run `45794120507`).

## Whole-repo MAUI build

`maui-core-build.yml` builds the maui-ohos repository itself, not only the slice
sources through the verify harness:

- ref default `slice/11.0.10`;
- workload 1.0.0 + the `Microsoft.Maui.*` 11.0.10 mirror;
- `IncludeOpenHarmonyTargetFrameworks=true`, version `20.0`, all non-OHOS
  platform TFMs disabled;
- builds `src/Core/src/Core.csproj` and `src/Controls/src/Core/Controls.Core.csproj`
  for `net11.0-openharmony20.0`;
- verifies the Arcade outputs (`artifacts/bin/...`), not the old `src/.../bin`.

Run `46004135066`: `Microsoft.Maui.dll` 1,092,096 B,
`Microsoft.Maui.Controls.dll` 2,329,600 B.

## csc SIGSEGV (`runtime-ohos#2`)

`csc-repro.yml` rebuilds the 1.27 MB `maui-platform-verify` project on a glibc
x64 GitHub-hosted container, 3 iterations × 3 variants (baseline,
`DOTNET_TieredCompilation=0`, 1 GB `DOTNET_GCHeapHardLimit`) with mini-dump
capture enabled. Result `46002170870`: **9/9 `rc=0`, no dumps**. The crash is
therefore OpenHarmony-runtime-specific; the next step is dump support on the
port (or a glibc self-hosted reproducer with the same runtime).

## Still open

- **`cross` can be flaky** (`ld.lld: cannot open .../libruntimeinfo.a`, a ninja
  parallel-build race). It was green in `45792329302`; the `-j4` shim stays.
- **Crash dumps on the port** are still unavailable (`createdump` only dumps its
  parent, `ptrace` EPERM, `DOTNET_DbgEnableMiniDump` writes nothing). The glibc
  matrix was clean, so the remaining work is a dump-capable OpenHarmony runtime
  or a glibc self-hosted runner with the same runtime build.
- **Runner cleanup wedge**: a job can finish all steps and stay `busy` in
  cleanup. `queue-watchdog.sh` now re-registers an offline runner and a runner
  busy longer than `MAX_BUSY` (3.5 h); the device job's 90-minute timeout keeps
  that recovery window short.

## Helper assets

| Asset | Purpose |
|---|---|
| `sdk-ohos@arcade-mirror-11.0.0-beta.26527.113` | Arcade SDK nupkg for offline restore |
| `sdk-ohos@maui-11.0.10` | frozen MAUI 11.0.10 nupkgs (verify826 + hap jobs) |
| `sdk-ohos@ohos-pack-tools-26.0.0.38` | DevEco `lib/` (arm64) — kept for reference, not used by CI |
| `sdk-ohos@aot-packs-11.0.0-rtm` | NativeAOT feed |
| `runtime-ohos@ci-prebuilts` | rolling `jit-hap.hap`, `aot-hap.hap`, `aot-prebuilt.tar.gz` |
| `sdk-ohos@v11.0.100-openharmony` | SDK 11.0.100 (`a8fa...`) |
| `sdk-ohos@workload-1.0.1` | workload bundle 1.0.1 (`088b...`) |
| cache key `ohos-sdk-public-6.0-v1` | Public OHOS SDK (2.37 GB) for packaging |

## 2026-11-27: real 826 build and the OpenSSL parallel-crypto bug

- `prebuilt_826` now defaults to **false**. The real 826 build passes with the
  warm NuGet cache (direct gate `gate-real-826`, workflow `46027834425`,
  `[suite] checks=826`, `CLEAN-MACHINE GA PASS`). The prebuilt path stays as a
  fallback.
- The old "csc SIGSEGV" was a misattribution: the device faultlogger shows
  `SIGTRAP` + jemalloc `may double free` in
  `libSystem.Security.Cryptography.Native.OpenSsl.so` (OpenSSL 3.3.1).
- Minimal repro: parallel `SHA256`/`SHA512` or parallel `RSA`/`X509Chain`
  crashes; sequential/single calls pass. A cold `dotnet restore` reproduces it
  in MSBuild; the warm cache passes.
- SDK 11.0.101 / runtime 11.0.1 still crashes (not a servicing fix).
- Workaround: `-p:RestoreDisableParallel=true` (verified on a fresh cache:
  3.36 s, no dump); the gate's `run_826` restore sets it.
- Proper fix: serialize the shim's OpenSSL calls or use a threads-safe OpenSSL,
  then rebuild the SDK runtime pack; validate with the parallel probe and a
  cold restore.
