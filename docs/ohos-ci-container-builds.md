# Container-based CI for the OpenHarmony stack

Status of the GitHub Actions work that moves OpenHarmony build products off the
device and into a reproducible container.

## What runs where

| Job (workflow) | Host | Produces | Status |
|---|---|---|---|
| `cross` – `runtime-ohos/.github/workflows/ohos-cross-build.yml` | prereqs image (`azurelinux-4.0-net12.0-cross-openharmony-6.0-amd64`) | `libcoreclr.so`, `createdump`, `libclrinterpreter.so`, `singlefilehost` | ✅ run `44715082951` (11.0 line, stress log) |
| `verify826` – same workflow | same image | `bin/Debug/net11.0/verify.dll` (2,285,056 B) | ✅ run `45129518810` |
| `jit-hap` – same workflow | same image | `hello-maui-app-unsigned.hap` (133 MB) | ✅ run `45352330461` |
| `ohos-clean-machine.yml` | self-hosted OHOS runner | GA gate (826 / JIT / AOT / device) | ✅ `45001307175`, device round `44483866572` |

`ohos-clean-machine.yml` takes `runtime_libcoreclr=<path>` and installs that
runtime right after the SDK install, re-signing it with the deployed `selfsign`.

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
   MSBuild SDK resolver.
6. **`ArcadeSdkDir` needs the trailing slash** (`.../tools/`), otherwise
   `MSB4019 BeforeCommonTargets.targets not found`.
7. **maui-ohos**: the OpenHarmony slice lives on `feature/openharmony`, not
   `main`; check out that ref or `verify.csproj` fails with
   "maui-ohos slice directory does not exist".
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

## Still open

- **AOT in the container**: needs the `aot-packs-11.0.0-rtm` feed installed in
  the image and `publish-aot.sh` (with `AOT_WORKDIR`/`DOTNET`) instead of a plain
  `dotnet publish`. The gate keeps using `prebuilt_aot` until this lands.
- **Crash dumps** are unavailable on the port (`createdump` only dumps its
  parent, `ptrace` returns EPERM, `DOTNET_DbgEnableMiniDump` writes nothing), so
  `runtime-ohos#2` stays blocked on dump support.

## Helper assets

| Asset | Purpose |
|---|---|
| `sdk-ohos@arcade-mirror-11.0.0-beta.26527.113` | Arcade SDK nupkg for offline restore |
| `sdk-ohos@ohos-pack-tools-26.0.0.38` | DevEco `lib/` (arm64) — kept for reference, not used by CI |
| `sdk-ohos@aot-packs-11.0.0-rtm` | NativeAOT feed |
| cache key `ohos-sdk-public-6.0-v1` | Public OHOS SDK (2.37 GB) for packaging |
