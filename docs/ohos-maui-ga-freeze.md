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

- Container CI (GA slice + MAUI 11.0.10): run `45772391744` —
  `cross`, `build verify.dll`, `build JIT hap`, `build AOT hap` all success.
- Device round `45783576391` with the GA JIT hap (MAUI 11.0.10) on the
  OpenHarmony device: all steps ok, `failures=0`
  (`device-round-ga110-final/summary.txt`):
  verify, lock, install/start, first frame, Blazor ×2, slots, a11y,
  deeplink, tester-run probe, 5-minute soak.
- Clean-machine direct run (SDK 11.0.100 + workload 1.0.1, GA prebuilt
  `verify.dll` from container run `45772391744`, JIT/AOT prebuilts,
  `skip_device=1`): **CLEAN-MACHINE GA PASS**. Evidence
  (`/data/storage/el2/base/tmp/opencode/gate-direct-ga/logs`):

```
[17:00:13] install OK
[17:00:15] clean workload/pack verification OK
[17:00:15] 826 using prebuilt verify.dll from .../art-ga2
[17:00:52] 826 OK
[17:00:52] JIT publish OK
[17:00:53] AOT publish OK
[17:00:53] CLEAN-MACHINE GA PASS

826.log:
[verify] preprobe sliceFiles=149 nativeLibraryUses=0 assert=True
[suite] checks=826 total=829 floor=809 assert=True
```

  The self-hosted runner later wedged in job cleanup (the known
  process-exit issue) after the device round finished, so the same script
  was executed directly on the host with an isolated `CLEAN_ROOT`; the
  run used the exact workflow inputs (same SDK tarball and sha256, same
  1.0.1 bundle and sha256, same prebuilt run).

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
