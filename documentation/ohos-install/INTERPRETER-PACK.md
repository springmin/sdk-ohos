# CoreCLR interpreter pack (`ohos-interpreter-pack*`)

The interpreter pack overlays a **feature-enabled CoreCLR** (`FEATURE_INTERPRETER=1`)
plus `libclrinterpreter.so` onto an openharmony-arm64 runtime pack, so a signed HAP
can run with `DOTNET_InterpMode=3` (pure interpreter) on images that refuse JIT
executable pages. It is a development/test asset, not part of the normal install.

## Current asset

Release `device-test-kit` on `springmin/sdk-ohos`:

| asset | id | size | sha256 |
|---|---|---|---|
| `ohos-interpreter-pack-rc2.tar.gz` | `RA_kwDOT39XK84kHaxL` | 2,409,070 B | `34709a94…73a9bf9` |
| `ohos-interpreter-pack-rc2.tar.gz.sha256` | `RA_kwDOT39XK84kHaxW` | 99 B | — |
| `ohos-interpreter-pack-rc2-README.md` | `RA_kwDOT39XK84kHaxZ` | — | — |

Contents: `native/libcoreclr.so` (BuildID `bc5ff740…`, sha256 `fd79f2bf…`),
`native/libclrinterpreter.so` (BuildID `ba83106b…`, sha256 `75360e65…`), plus
`README.md`, `VERIFICATION.md`, `SHA256SUMS`, `build-info.json`.

The earlier `ohos-interpreter-pack.tar.gz` (rc.1 line) stays for reference; its
recorded startup crash on the rc.2 runtime pack was a host/image issue
(EnsureStackSize vs the 1 MB app-thread stack; RWX write-barrier page), corrected in
runtime-ohos `docs/plans/2026-10-02-ohos-interp-fix.md`.

## Rebuild / repack

1. Build the pair on the runtime checkout (rc.2 line) with
   `scripts/ohos-runtime-interp-fullbuild.sh` (env: `ICU_DIR`, `OPENSSL_DIR`,
   `DOTNET_INSTALL_DIR`, `NUGET_CONFIG`, `JOBS`). Evidence: the script prints
   `FEATURE_INTERPRETER`, sizes, sha256, `NEEDED` and the wide-string check.
2. Assemble the asset:

```
python3 eng/ohos-install/build/package-interp-pack.py \
    --coreclr <checkout>/artifacts/bin/coreclr/openharmony.arm64.Release/libcoreclr.so \
    --interpreter <checkout>/artifacts/bin/coreclr/openharmony.arm64.Release/libclrinterpreter.so \
    --repo <runtime-ohos checkout> --out <dir> --tag rc2 \
    --version 11.0.0-rc.2.26451.112 --extra-doc VERIFICATION.md
```

3. Upload with an explicit clobber (new names when the runtime line changes):

```
gh release upload device-test-kit ohos-interpreter-pack-<tag>.tar.gz \
    ohos-interpreter-pack-<tag>.tar.gz.sha256 ohos-interpreter-pack-<tag>-README.md \
    -R springmin/sdk-ohos --clobber
```

4. Verify by asset id (`gh release view … --json assets --jq …`) and re-download the
   tarball to check `sha256sum -c` against its `.sha256` asset.

## Host requirements

The host must create the managed app thread with a stack above CoreCLR's 1.5 MB PAL
floor and, for `interp=3`, set `DOTNET_UseGCWriteBarrierCopy=0` (the HAP domain
refuses the RWX commit the default arm64 write-barrier copy needs). The
RC2-INTERP-FIX `libopenharmonyhost.so` (`scripts/build-host.sh` in ohos-workload,
commit `c9916cd`) does both; without it the pack crashes exactly like stock.

## Staging into a HAP

Use the workload switch (`OpenHarmony.Hap.targets`):

```
-p:OpenHarmonyRuntimeMode=interp -p:OpenHarmonyInterpreterPack=<extracted pack>
```

which replaces `libcoreclr.so`, adds `libclrinterpreter.so` and writes
`libs/<abi>/runtime-mode.txt=interp` before the codesign pass.
