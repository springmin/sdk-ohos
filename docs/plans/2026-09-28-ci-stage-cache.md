# OHOS CI stage caches (2026-09-28)

**Scope:** `.github/workflows/ohos-full-build.yml` used to run the whole
runtime -> aspnetcore -> sdk chain in one 50-60 minute serial job on every
dispatch. This change adds per-stage caches so that only the stages whose
inputs changed are rebuilt. A same-day follow-up (`b94fd513a3` +
`83b5a2f8d8`) scoped the script hashes per stage and moved stage 4 out of the
monolith, so packaging-only edits no longer invalidate the runtime/aspnetcore
caches at all.

## 1. What is cached

| Cache | Key | Paths | Effect |
|---|---|---|---|
| runtime stage | `ohos-rt-<rid>-<buildid>-<in_tree_r2r>-<crossgen2>-<runtime SHA>-<scripts_rt>-<env key_suffix>` | `.work/{feed,assets,rt-version.txt,selfsign,stock-crossgen2}`, `eng/ohos-install/build/third-party`, `runtime/.../Shipping`, coreclr `StandardOptimizationData.mibc` | hit -> `--skip-runtime` (stage 1 skipped) |
| aspnetcore stage | `ohos-asp-<rid>-<buildid>-<in_tree_r2r>-<crossgen2>-<runtime SHA>-<aspnetcore SHA>-<scripts_asp>-<env key_suffix>` | same `$WORK` subset + `aspnetcore/.../Shipping` | hit -> `--skip-aspnetcore` (stage 3 skipped) |
| CI env | `ohos-ci-env-...` (unchanged) | `~/.ohos-ci-env` | NDK/OpenSSL/ICU (~7 min) |

- `scripts_rt` = hash of the **stage-1 inputs** (literal patterns): `versions.env`,
  `build/build-ohos-all.sh`, `build/ohos-ci-env.sh`, the stage-1+3 shared helpers
  (`crossgen-framework.py`, `overlay-pack.py`, `overlay-tarball.py`,
  `sign-ohos-pre.py`, **`ohos-sign-common.sh`**, `selfsign.cs[proj]`, the scoping
  `Directory.Build.props/targets`, `install-dotnet-{ohos,runtime}.sh`), the
  runtime-only pack helpers, and the sdk-checkout inputs those stages consume
  (`eng/PortableRuntimeIdentifierGraph.openharmony.json`,
  `src/Tasks/Microsoft.NET.Build.Tasks/ElfSigner.cs`, `global.json`).
  A fail-closed guard rejects any listed input that is missing (hashFiles drops
  unmatched patterns silently).
- `scripts_asp` = **superset** of `scripts_rt` (stage 3 consumes stage 1
  outputs; there is no aspnetcore-only helper today). The asp key also carries
  `in_tree_r2r`/`crossgen2_version` — previously a change to either rebuilt
  stage 1 while stage 3 stayed on a stale cache.
- `env key_suffix` = sha256 of the resolved ndk/openssl/icu/dotnet-install
  digests, appended by the restore/save steps. The digest step runs after the
  key step, so the suffix is the clean way to fold those inputs in.
- **Stage 4 is not in the rt/asp keys**: its logic lives in
  `build/pack-sdk.sh` (+ `build/msbuild-pipe-patch/**`,
  `build/patch-msbuild-pipe.py`, `build/check-sdk-arch.py`), covered only by
  the whole-tree `scripts` identity hash (logged, not keyed). An
  SDK-packaging-only edit therefore runs stage 4 (plus stages 2/5) only.
- `$WORK` = `sdk/eng/ohos-install/.work`. The hashes run **before** any cache
  restore, so restored files can never feed back into the keys; restore and
  save steps share the exact same key expressions (`rt_key` / `asp_key`
  outputs plus the digest suffix).

## 2. Workflow wiring

- `Resolve stage SHAs + cache keys` (after checkouts) emits `rt_key` / `asp_key`,
  `scripts_rt` / `scripts_asp` / `scripts`.
- `Resolve CI-env checksums` emits `key_suffix`; restore/save append it.
- `Restore runtime stage cache` / `Restore aspnetcore stage cache`
  (`actions/cache/restore`).
- The build step appends `--skip-runtime` / `--skip-aspnetcore` for each hit and
  logs `stage caches: runtime=... aspnetcore=...; extra flags: ...`.
- `Save ...` steps (`actions/cache/save`, `continue-on-error`) run only after a
  green build, so incomplete stages are never cached.
- `build-ohos-all.sh` stays the only external entry point; its `stage4()`
  delegates to `bash build/pack-sdk.sh --sdk-repo=... --work=...` etc., and
  `build/ohos-sign-common.sh` holds `ensure_selfsign` / `sign_all` (sourced by
  both scripts, single implementation).

## 3. Expected timings (stage-scoped keys)

| Scenario | Before | After |
|---|---|---|
| packaging-only edit (`pack-sdk.sh`, patcher, arch guard, tests) | 50-60 min | **~10-25 min** (stages 2+4+5; rt/asp hit) |
| stages-1..3 script edit (`build-ohos-all.sh`, shared helpers, RID graph, ElfSigner, global.json) | 50-60 min | 50-60 min (both cold) |
| toolchain digest input change (ndk/openssl/icu/dotnet-install) | 50-60 min | 50-60 min (`key_suffix` flips; correct — stale outputs must not be reused) |
| runtime_ref change | 50-60 min | 50-60 min (full chain) |
| sdk_ref-only change touching no listed input | 50-60 min | ~10-25 min |
| env cache miss | +7 min | saved even when the build later fails |

## 4. Operating notes

- Force a rebuild: change the ref, touch a listed input, or delete the cache
  entry (`gh api repos/<owner>/sdk-ohos/actions/caches`).
- A skipped stage still restores the repo `Shipping` dirs, so the artifact
  upload and the `upload_release` publish see the runtime/aspnetcore outputs.
- Edge case: runtime cache evicted + aspnetcore cache hit -> stage 1 rebuilds
  and the cached aspnetcore outputs are reused (same inputs by key); timing
  only, no correctness impact.
- Maintenance: a new stage-1/3 helper goes into `scripts_rt` **and** the guard
  list; a new stage-4-only helper stays out of both (the `scripts` glob covers
  it); a new aspnetcore-only helper goes into `scripts_asp` only.

## 5. Verification (2026-09-28)

| Run | Refs | Stage caches | Duration |
|---|---|---|---|
| 36351296885 | branch refs (cold, first cache implementation) | - | 58m06s |
| 36354820829 | branch refs, runtime advanced in between | runtime=false aspnetcore=false (key includes the runtime SHA: correct miss) | 32m26s |
| 36356790450 | pinned SHAs equal to run1 (runtime `b935cb97b77`, aspnetcore `07ed2fe38d`, sdk `82dc57c64c`) | **runtime=true aspnetcore=true** (`--skip-runtime --skip-aspnetcore`) | **10m02s** |
| 36373081395 | item-5 branch, first run with the **stage-scoped** keys | runtime=false aspnetcore=false (new key format, cold by design) | ~60 min |
| 36377101149 | same refs as 36373081395 | **runtime=true aspnetcore=true** (`--skip-runtime --skip-aspnetcore`) | **12m09s** |
| 36391100465 | **stage-4 split** (`83b5a2f8d8`) + digest `key_suffix`, cold by design | see run | see run |

The run3/run5 build-step logs show
`stage caches: runtime=true aspnetcore=true; extra flags: --skip-runtime --skip-aspnetcore`.
The 36373081395/36377101149 pair proves the stage-scoped keys are deterministic
across runs (same `scripts_rt=scripts_asp` hash on both) and that a warm run
costs ~13 minutes.
