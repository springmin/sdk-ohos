# OHOS CI stage caches (2026-09-28)

**Scope:** `.github/workflows/ohos-full-build.yml` used to run the whole
runtime -> aspnetcore -> sdk chain in one 50-60 minute serial job on every
dispatch. This change adds per-stage caches so that only the stages whose
inputs changed are rebuilt.

## 1. What is cached

| Cache | Key | Paths | Effect |
|---|---|---|---|
| runtime stage | `ohos-rt-<rid>-<buildid>-<in_tree_r2r>-<crossgen2>-<runtime SHA>-<eng/ohos-install hash>` | `.work/{feed,assets,rt-version.txt,selfsign,stock-crossgen2}`, `eng/ohos-install/build/third-party`, `runtime/.../Shipping`, `runtime/artifacts/bin/coreclr/**/StandardOptimizationData.mibc` | hit -> `--skip-runtime` (stage 1 skipped) |
| aspnetcore stage | `ohos-asp-<rid>-<buildid>-<runtime SHA>-<aspnetcore SHA>-<hash>` | same `$WORK` subset + `aspnetcore/.../Shipping` | hit -> `--skip-aspnetcore` (stage 3 skipped) |
| CI env | `ohos-ci-env-...` (unchanged key) | `~/.ohos-ci-env` | NDK/OpenSSL/ICU (~7 min) |

- `$WORK` = `sdk/eng/ohos-install/.work`. The SDK (stage 4) always rebuilds.
- The `eng/ohos-install/**` hash runs **before** any cache restore, so restored
  files can never feed back into the keys; restore and save steps share the
  exact same key expressions (`rt_key` / `asp_key` outputs).

## 2. Workflow wiring

- `Resolve stage SHAs + cache keys` (after checkouts) emits `rt_key` / `asp_key`.
- `Restore runtime stage cache` / `Restore aspnetcore stage cache`
  (`actions/cache/restore`).
- The build step appends `--skip-runtime` / `--skip-aspnetcore` for each hit and
  logs `stage caches: runtime=... aspnetcore=...; extra flags: ...`.
- `Save ...` steps (`actions/cache/save`, `continue-on-error`) run only after a
  green build, so incomplete stages are never cached.
- The NDK/OpenSSL/ICU cache now uses restore + save around the prepare step:
  previously a later build failure discarded the ~7 minute env build.

## 3. Expected timings

| Scenario | Before | After (warm caches) |
|---|---|---|
| sdk_ref / scripts change | 50-60 min | ~15-20 min (stages 2+4+5) |
| aspnetcore_ref change | 50-60 min | ~20-25 min (stages 3+4+5) |
| runtime_ref change | 50-60 min | ~50-60 min (full chain) |
| env cache miss | +7 min | saved even when the build later fails |

## 4. Operating notes

- Force a rebuild: change the ref, touch `eng/ohos-install/**`, or delete the
  cache entry (`gh api repos/<owner>/sdk-ohos/actions/caches`).
- A skipped stage still restores the repo `Shipping` dirs, so the artifact
  upload and the `upload_release` publish see the runtime/aspnetcore outputs.
- Edge case: runtime cache evicted + aspnetcore cache hit -> stage 1 rebuilds
  and the cached aspnetcore outputs are reused (same inputs by key); timing
  only, no correctness impact.
