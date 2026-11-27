# OpenHarmony .NET 11 + MAUI 11.0.10 GA freeze

Status: frozen after the M0–M4 validation described below.
This note records the exact kit, the MAUI GA slice branch, and the evidence
runs so the next servicing pass can reproduce the same combination.

## Frozen kit

| Component | Version / ref | Asset |
|---|---|---|
| .NET SDK | **11.0.100** | `v11.0.100-openharmony` → `dotnet-sdk-11.0.100-openharmony-arm64.tar.gz`, sha256 `a8fa784e950521895c2986252566ac78ca0f95934f6a4e51fad3ea0ccf000c56` |
| Platform workload | **1.0.1** | `workload-1.0.1` → `openharmony-workload-1.0.1.tar.gz`, sha256 `088b585d46e4d28fbfdcefe5372e2e44463dfedcb778b529702c786437813cd4` |
| MAUI | **11.0.10** | NuGet GA line (`Microsoft.Maui.Controls` 11.0.10 et al.) |
| MAUI OpenHarmony slice | `maui-ohos` branch **`slice/11.0.10`** @ `cc39b1ada5a` | imported from `feature/openharmony` @ `030486c5c27` onto tag `11.0.10` |
| MAUI verify harness | `ohos-workload` master >= `7e78d14` | `test/maui-platform-verify`; `MAUI_SLICE_DIR` support |
| Runtime used by CI-built haps | 11.0.0 | the linux-x64 SDK line has no 11.0.101 build, so container publishes stay on the 11.0.0 known reference |

The workload manifest 1.0.1 lists the BCL runtime packs at 11.0.1. The
container CI uses the stock linux-x64 SDK 11.0.100 (11.0.101 is not published
for linux-x64), whose known reference still requests 11.0.0; app publishes in
CI therefore stay on 11.0.0. The 11.0.101 servicing SDK is published for
openharmony-arm64 (`v11.0.101-ohos`) and is the vehicle for 11.0.1 apps on a
device/host SDK.

## M1 — MAUI slice rebased onto 11.0.10

`maui-ohos` `slice/11.0.10` (5 logical commits):

1. `openharmony: import the platform slice` — 152 files, 48,939 lines, the
   `src/Core/src/Platform/OpenHarmony` tree imported verbatim from
   `feature/openharmony` @ `030486c5c27`.
2. `openharmony: wire the platform slice into Microsoft.Maui.Core` —
   `Core.csproj` + `OpenHarmonyCoreSlice.props`, handler partials, PublicAPI.
3. `openharmony: extend Microsoft.Maui.Controls for the OpenHarmony TFM` —
   `Controls.Core.csproj`, Controls platform helpers, PublicAPI.
4. `openharmony: enable the net11.0-openharmony target and workload` —
   `Directory.Build.props`, `MultiTargeting.targets`, Essentials, workload manifest.
5. `openharmony: add slice tests and port notes` — unit tests + slice docs.

Verification: the slice directory is byte-identical to the fork's slice, and
the GA build of `verify.dll` against `slice/11.0.10` succeeded in container CI
(run `45772391744`, job `build verify.dll (container)`).

## M2 — workload and MAUI dependency bump

- `ohos-workload` master `7578354` moves every test app to MAUI **11.0.10**
  and the workload manifest to **1.0.1**.
- `workload-1.0.1` is published and self-contained: it carries
  `Microsoft.OpenHarmony.Sdk 1.0.1`, Ref/Runtime 1.0.0, and
  `Microsoft.NETCore.App.Runtime.openharmony-arm64 11.0.1` +
  `Microsoft.AspNetCore.App.Runtime.openharmony-arm64 11.0.1` in `feed/`.
- The clean-machine gate now installs that bundle (version, sha256 and
  manifest verified in `install.log`/`workload-list.log`).
- The container hap jobs install workload **1.0.0** because the linux-x64
  SDK 11.0.100 known reference requests the 11.0.0 BCL runtime pack; the
  1.0.1 bundle is installed and validated by the clean-machine gate. This is
  the documented limit of the current x64 container image, not a MAUI change.

## M3 — 826 re-baseline against MAUI 11.0.10

The 11.0 GA Controls contract removed the rc.2 internal
`DropCompletedEventArgs.DropResult` member. The harness now feature-detects it
(`maui-platform-verify` commit `7e78d14`): when absent, the platform cannot
report a drop operation, which is the same no-target outcome the
over-the-void check pins. No product change was needed.

Host suite against `slice/11.0.10` + `Microsoft.Maui.Controls/11.0.10`:

```
[verify] preprobe sliceFiles=149 nativeLibraryUses=0 assert=True
[suite] checks=826 total=829 floor=809 assert=True
```

The same harness against the rc.2 baseline still prints
`[suite] checks=826 total=829 floor=809 assert=True` (prebuilt
`45771810037`), so the re-baseline is behaviour-preserving for rc.2.

## M4 — clean-machine and device validation

- Container CI (GA slice + MAUI 11.0.10): run `45792329302` —
  `cross`, `build verify.dll`, `build JIT hap`, `build AOT hap` all success
  (the earlier `45772391744` produced the same four green jobs).
- Clean-machine gate `45788553893` (**completed/success**) with
  SDK 11.0.100 (`a8fa...`), workload bundle 1.0.1 (`088b...`),
  `prebuilt_run=45772391744` and `maui_source=slice/11.0.10`.
  This run used the cached AOT IL-gate log because that artifact predated
  the log-staging step.
- Clean-machine gate `45794120507` (**completed/success**) with
  `prebuilt_run=45792329302`: the fresh AOT artifact is used and its own
  `publish-aot.log` is consumed (`using the fresh AOT IL-gate log`,
  15,125 B, 2026-11-26 09:31 UTC, `EXIT=0`). The job installed the
  workload and reported:

```
[verify] preprobe sliceFiles=149 nativeLibraryUses=0 assert=True
[suite] checks=826 total=829 floor=809 assert=True
Successfully installed workload(s) openharmony.
```

- Device round: run `45790115314` (**completed/success**) with the GA JIT hap
  (MAUI 11.0.10) on the OpenHarmony device. The round reported
  `完成：11 步，failures=0`:

```
verify: ok — tree=bdd2f98c...
install_start: ok — runtime_mode=jit(hap)
first_frame: ok — canvas presented + frames/first.jpeg
blazor: ok — default boot=yes rendered=yes click=ok(Current count: 1)
blazor: ok — nocsp boot=yes rendered=yes click=ok(Current count: 1)
slots: ok — create=2 destroy=1 ...
a11y: ok — status=<unavailable> node_count=72
tester_run_probe: ok — v=14
soak: ok — minutes=5 pid_lost=0 fault_new=0
```

The same gate script was also executed directly on the host with an isolated
`CLEAN_ROOT` (same SDK tarball/sha256, same 1.0.1 bundle/sha256, same prebuilt
run) and printed `CLEAN-MACHINE GA PASS`; the logs are kept in
`gate-direct-ga/logs`. This was a fallback after the runner wedged in job
cleanup, not a different configuration.

## M5 — freeze

The frozen matrix at the top is the release kit. CI pins the MAUI ref and
package line through the `ohos-cross-build.yml` inputs (`maui_ref`,
`maui_pin`); the clean-machine gate pins the SDK tarball, workload bundle
(version + sha256), the MAUI source (`maui_source`) and the prebuilt run.

## Reproduce

```sh
# 1. MAUI slice branch
git -C maui-ohos checkout slice/11.0.10   # cc39b1ada5a

# 2. GA harness (host)
MAUI_SLICE_DIR=<maui-ohos>/src/Core/src/Platform/OpenHarmony \
OHOS_WORKLOAD_ROOT=<ohos-workload> \
  dotnet <verify826-artifact>/bin/Debug/net11.0/verify.dll

# 3. Clean-machine gate
gh workflow run ohos-clean-machine.yml -R springmin/sdk-ohos \
  -f prebuilt_run=<container-run> \
  -f maui_source=<slice/11.0.10 checkout> \
  -f workload_source=<ohos-workload> \
  -f skip_device=true
```

## Post-freeze hardening (2026-11-27)

P0 — the frozen line is now the default:

- Clean-machine gate: `maui_source` defaults to the stable
  `/storage/Users/currentUser/springsources/maui-ohos-ga` worktree
  (`slice/11.0.10`); scheduled runs resolve `prebuilt_run` to the newest
  successful `ohos-cross-build` run and use the assembled `prebuilt-*` dirs.
  `prebuilt_run=latest` is accepted for testing that path.
- Container CI: defaults are `maui_ref=slice/11.0.10`, `maui_pin=ga`;
  `feature/openharmony`/`rc2` remain historical inputs.
- `Microsoft.Maui.*` 11.0.10 is mirrored as `sdk-ohos@maui-11.0.10`
  (`maui-11.0.10-nupkgs.tar.gz`, sha256
  `e820f6a4719ae5efc33b23393363ca4bca3f485bdb11b4d6ef89aa105b65d216`) and
  used by `verify826` and the hap jobs.
- The container publishes `ci-prebuilts/aot-prebuilt.tar.gz` (hap + publish
  libs + `publish-aot.log`); the gate downloads it through `ghfast.top`
  instead of the slow 60 MB per-run artifact.

P1 — `runtime-ohos#2` (csc SIGSEGV) narrowed:

- New `csc-repro.yml` rebuilds the 1.27 MB harness on a glibc x64
  GitHub-hosted container, 3 iterations × 3 variants (baseline,
  `DOTNET_TieredCompilation=0`, 1 GB heap) with dump capture.
- Run `46002170870`: **9/9 `rc=0`, no dumps**. The crash is
  OpenHarmony-runtime-specific; the remaining work is dump support on the port
  (or a glibc self-hosted runner with the same runtime).

P2 — runner liveness:

- `queue-watchdog.sh` now re-registers an **offline** runner after
  `OFFLINE_STRIKES` (default 2) checks and a runner busy longer than
  `MAX_BUSY` (3.5 h), in addition to the stale-queue recovery. It stops the
  supervisor through `.supervisor.lock/pid`, kills surviving listeners, and
  starts a fresh `supervise.sh`.
- Dry-run tested: busy state logs `ok busy`, simulated offline logs
  `runner stayed offline; re-registering` without touching the live runner.

P3 — whole-repo MAUI compile:

- `maui-core-build.yml` builds the maui-ohos repository itself for
  `net11.0-openharmony20.0` (Core + Controls), with workload 1.0.0, the MAUI
  11.0.10 mirror, and the Arcade mirror.
- Run `46004135066`: success —
  `Microsoft.Maui.dll` 1,092,096 B and `Microsoft.Maui.Controls.dll`
  2,329,600 B under `artifacts/bin/.../net11.0-openharmony20.0/`.

P4 — docs and release:

- `docs/ohos-ci-container-builds.md` updated with the 1.0.1/11.0.101 split,
  the AOT tarball/log staging, the scheduled-prebuilt resolution, the MAUI
  mirror, the maui-core and csc-repro jobs, and the watchdog.
- Kit release `kit-11.0.100-maui-11.0.10` carries the machine-readable
  manifest and checksums for this matrix.
