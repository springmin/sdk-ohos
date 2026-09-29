#!/usr/bin/env bash
# ============================================================================
# pack-sdk.sh — Stage 4 of build-ohos-all.sh: build the OpenHarmony SDK
# redist from the runtime+aspnetcore feed, patch the shipped MSBuild/Roslyn
# named pipes, verify the tarball architecture and pre-sign it.
#
# Split out of build-ohos-all.sh (which still owns stages 1-3 and remains the
# only external entry point) so an SDK-packaging-only edit does not flip the
# runtime/aspnetcore stage cache keys in .github/workflows/ohos-full-build.yml
# ("Resolve stage SHAs + cache keys"). build-ohos-all.sh passes the resolved
# stage parameters; direct invocation is for debugging only:
#
#   sh pack-sdk.sh --sdk-repo <dir> --work <dir> [--runtime-repo <dir>] \
#                  [--feed <dir>] [--log <file>] [--arch arm64] \
#                  [--rid openharmony-arm64] [--config Release] [--buildid <id>]
#
# The parameters mirror what build-ohos-all.sh parsed/resolved; version pins
# (RT_VERSION fallback, ASSET_PORT, ...) come from ../versions.env like in the
# monolith, with exported environment values winning over the defaults.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="$SCRIPT_DIR/../versions.env"
if [ ! -f "$VERSIONS_ENV" ]; then
  echo "ERROR: missing $VERSIONS_ENV (run this script from the sdk-ohos repository)" >&2
  exit 1
fi
# shellcheck source=../versions.env
. "$VERSIONS_ENV"

ARCH="${ARCH:-arm64}"
RID="${RID:-openharmony-${ARCH}}"
CONFIG="${CONFIG:-Release}"
LABEL="${LABEL:-rc}"
PRE="${PRE:-1}"
BUILDID="${BUILDID:-$DEFAULT_BUILDID}"
SDK_REPO="${SDK_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
RUNTIME_REPO="${RUNTIME_REPO:-}"
WORK="${WORK:-}"
FEED="${FEED:-}"
LOG="${LOG:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --sdk-repo=*)     SDK_REPO="${1#*=}"; shift ;;
    --runtime-repo=*) RUNTIME_REPO="${1#*=}"; shift ;;
    --work=*)         WORK="${1#*=}"; shift ;;
    --feed=*)         FEED="${1#*=}"; shift ;;
    --log=*)          LOG="${1#*=}"; shift ;;
    --arch=*)         ARCH="${1#*=}"; RID="openharmony-$ARCH"; shift ;;
    --rid=*)          RID="${1#*=}"; shift ;;
    --config=*)       CONFIG="${1#*=}"; shift ;;
    --buildid=*)      BUILDID="${1#*=}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# Defaults mirror build-ohos-all.sh: the sibling runtime checkout and the
# .work scratch next to build/; the feed/log paths hang off WORK.
RUNTIME_REPO="${RUNTIME_REPO:-$(dirname "$SDK_REPO")/runtime-ohos}"
WORK="${WORK:-$(dirname "$SCRIPT_DIR")/.work}"
FEED="${FEED:-$WORK/feed}"
LOG="${LOG:-$WORK/build.log}"
mkdir -p "$WORK"

info() { printf '\n==> %s\n' "$*" | tee -a "$LOG"; }
die()  { printf 'ERROR: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

# ---- pre-package signing (helpers shared with build-ohos-all.sh stages 1+3) --
# ensure_selfsign/sign_all live in ohos-sign-common.sh so the signing
# implementation exists once; stage 4 signs the SDK tarball below.
# shellcheck source=ohos-sign-common.sh
. "$SCRIPT_DIR/ohos-sign-common.sh"

# ---- stage-4 helpers (moved from build-ohos-all.sh) -------------------------
# openharmony has no NativeAOT toolchain, so PublishDotnetAot is gated off and the
# build does not produce libdotnet-aot. The redist layout under artifacts/bin/redist
# is reused between builds and is never cleaned, so a stale copy (for example an
# x86-64 library from a host-RID build or a dotnet-aot test run on the build machine)
# would be copied into the SDK tarball and `dotnet` would try to dlopen it on every
# startup. Prune it before the build and verify the packaged archive afterwards.
SDK_ARCH_CHECK="$SCRIPT_DIR/check-sdk-arch.py"
prune_stale_sdk_aot_libs() {
  local redist="$SDK_REPO/artifacts/bin/redist/$CONFIG"
  [ -d "$redist" ] || return 0
  python3 "$SDK_ARCH_CHECK" prune "$redist" \
    || die "failed to prune stale dotnet-aot libraries from $redist"
}

verify_sdk_tarball_arch() {
  local tarball="$1"
  python3 "$SDK_ARCH_CHECK" verify "$tarball" \
    || die "SDK tarball $tarball contains a foreign-architecture dotnet-aot library"
}

# MSBuild named pipes are hardcoded to /tmp on Unix; OpenHarmony denies AF_UNIX
# bind() there (EACCES) so task hosts / the MSBuild server / worker nodes crash
# (exit 134) and the parent fails with MSB4216 after 30 s x 5 retries. The Roslyn
# compiler server has the same bug (csc/vbc fall back to in-process compilation
# after a ~20 s connect timeout). This tool flips the one IL instruction that
# builds each pipe path to Path.GetTempPath() (TMPDIR-aware); verified on device:
# Blazor WASM build 5:06 failure -> 15.4 s success, shared-compile build 30 s -> 11 s.
ensure_msbuild_pipe_patcher() {
  local dir="$WORK/msbuild-pipe-patch"
  local src="$SCRIPT_DIR/msbuild-pipe-patch"
  # Rebuild when the tool's sources changed (e.g. Roslyn targets were added); a
  # stale cached patcher would silently skip the new files.
  if [ ! -f "$dir/msbuild-pipe-patch.dll" ] \
     || [ "$src/Program.cs" -nt "$dir/msbuild-pipe-patch.dll" ] \
     || [ "$src/msbuild-pipe-patch.csproj" -nt "$dir/msbuild-pipe-patch.dll" ]; then
    info "building msbuild-pipe-patch (Mono.Cecil)..."
    local dotnet_bin="${DOTNET:-$RUNTIME_REPO/.dotnet/dotnet}"
    "$dotnet_bin" publish "$src/msbuild-pipe-patch.csproj" \
      -c Release -o "$dir" --nologo \
      -p:ImportDirectoryBuildProps=false -p:ImportDirectoryBuildTargets=false \
      2>&1 | tail -1 || die "msbuild-pipe-patch build failed"
    [ -f "$dir/msbuild-pipe-patch.dll" ] || die "msbuild-pipe-patch publish produced no dll"
  fi
  MSBUILD_PIPE_PATCHER="$dir/msbuild-pipe-patch.dll"
  MSBUILD_PIPE_PATCHER_DOTNET="${DOTNET:-$RUNTIME_REPO/.dotnet/dotnet}"
}

# ---- 4. sdk build (moved from build-ohos-all.sh stage4) ---------------------
info "Stage 4: sdk redist build (consumes runtime+aspnetcore feed)"
[ -f "$WORK/rt-version.txt" ] && RT_VERSION=$(cat "$WORK/rt-version.txt")
RT_VERSION="${RT_VERSION:-$VERSION_BAND-$LABEL.$PRE.$BUILDID}"
cd "$SDK_REPO"
rtver="$RT_VERSION"
# A stale dotnet-aot library in the reused redist layout would be archived into
# the SDK tarball even though this build does not produce one (see the helper).
prune_stale_sdk_aot_libs
# override ONLY Host/Runtime package versions (Ref/ILLink/Crossgen2 keep the
# darc-flowed official versions — see Directory.Build.props =='' guards)
./build.sh -os openharmony -arch "$ARCH" -c "$CONFIG" \
  /p:MicrosoftNETCoreAppHostPackageVersion="$rtver" \
  /p:MicrosoftNETCoreAppRuntimePackageVersion="$rtver" \
  /p:MicrosoftAspNetCoreAppRuntimePackageVersion="$rtver" \
  /p:RestoreAdditionalProjectSources="$FEED" \
  /p:PublicBaseURL=http://localhost:$ASSET_PORT/ \
  /p:RidGraphOverridePortableJson="$PWD/eng/PortableRuntimeIdentifierGraph.openharmony.json" \
  /p:IncludeAspNetCoreRuntime=false \
  /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" /p:OfficialBuildId="$BUILDID" \
  2>&1 | tee -a "$LOG" || die "sdk build failed"
info "sdk redist produced under $SDK_REPO/artifacts/bin/redist/$CONFIG/dotnet"
# Patch the shipped MSBuild + Roslyn compiler-server named pipes before
# signing: every pipe-bearing DLL (layout + tarball, excluding ref assemblies)
# must resolve pipes via TMPDIR because OpenHarmony denies AF_UNIX bind() in
# /tmp. Otherwise task hosts fail with MSB4216 and csc/vbc silently fall back
# to in-process compilation after a ~20 s compiler-server connect timeout.
ensure_msbuild_pipe_patcher
info "patching MSBuild/Roslyn named-pipe paths in the SDK layout + tarball"
python3 "$SCRIPT_DIR/patch-msbuild-pipe.py" \
  --sdk-root "$SDK_REPO" --config "$CONFIG" --rid "$RID" \
  --dotnet "$MSBUILD_PIPE_PATCHER_DOTNET" --patcher "$MSBUILD_PIPE_PATCHER" \
  || die "MSBuild named-pipe patch failed"
# pre-sign the SDK tarball (every ELF in the redist: dotnet host + all so)
sdk_tb=$(find "$SDK_REPO/artifacts" -maxdepth 5 -name "dotnet-sdk-*-$RID.tar.gz" | head -1)
[ -n "$sdk_tb" ] && verify_sdk_tarball_arch "$sdk_tb"
[ -n "$sdk_tb" ] && sign_all "$sdk_tb"

# ---- 5. selfsign release assets (prebuilt signing tools) --------------------
# The sdk release ships the prebuilt signing tools the installer consumes:
# selfsign-linux-x64 (host pre-signing) and selfsign-ohos-arm64 (device;
# SELFSIGN_ASSET in versions.env). The linux-x64 binary comes from
# ensure_selfsign. The openharmony-arm64 one is a NativeAOT cross publish
# against the feed's OpenHarmony packs: the host x64 ilc compiles, the OHOS
# NDK clang links, and eng/ohos-install/Directory.Build.targets adds the RID
# to the bootstrap SDK's known-pack lists. The asset name carries no version,
# so SELFSIGN_SHA256 in versions.env must be re-anchored to the produced
# binary after every release that rebuilds it.
stage_selfsign_release_assets() {
  local ship="$SDK_REPO/artifacts/packages/$CONFIG/Shipping"
  mkdir -p "$ship"
  ensure_selfsign
  cp -f "$SELFSIGN_BIN" "$ship/selfsign-linux-x64" || die "selfsign-linux-x64 staging failed"
  info "staged selfsign-linux-x64"
  local proj="$SDK_REPO/eng/ohos-install/selfsign.csproj"
  if [ ! -f "$proj" ]; then
    echo "WARN: no selfsign project; skipping selfsign-ohos-arm64" | tee -a "$LOG"
    return 0
  fi
  local out="$WORK/selfsign-ohos-out"
  local dotnet_bin="${DOTNET:-$RUNTIME_REPO/.dotnet/dotnet}"
  [ -x "$dotnet_bin" ] || dotnet_bin="$(command -v dotnet)"
  local llvm="${OHOS_NDK_HOME:-}/native/llvm/bin"
  local sysroot="${OHOS_NDK_HOME:-}/native/sysroot"
  local -a extra=()
  if [ -x "$llvm/aarch64-unknown-linux-ohos-clang" ]; then
    extra+=("-p:CppCompiler=$llvm/aarch64-unknown-linux-ohos-clang")
  fi
  if [ -x "$llvm/aarch64-unknown-linux-ohos-clang++" ]; then
    extra+=("-p:CppLinker=$llvm/aarch64-unknown-linux-ohos-clang++")
  fi
  if [ -d "$sysroot" ]; then
    extra+=("-p:SysRoot=$sysroot")
  fi
  # The OpenHarmony NativeAOT pack's crypto shim leaves the OpenSSL symbols for
  # the app link to resolve (the runtime links OpenSSL statically on OHOS), so
  # pass the CI's cross-built static libssl/libcrypto via the extension targets.
  local ssl_dir="${OPENSSL_DIR:-/tmp/openssl-ohos/install}"
  if [ -f "$ssl_dir/lib/libcrypto.a" ] && [ -f "$ssl_dir/lib/libssl.a" ]; then
    extra+=("-p:CustomAfterMicrosoftCommonTargets=$SCRIPT_DIR/selfsign-ohos-link.targets")
    extra+=("-p:OhosStaticOpenSslDir=$ssl_dir/lib")
  else
    echo "WARN: static OpenSSL not found under $ssl_dir/lib; the selfsign link may fail on OpenSSL symbols" | tee -a "$LOG"
  fi
  rm -rf "$out"
  info "publishing selfsign for openharmony-arm64 (NativeAOT cross, feed packs)"
  # The SDK derives RuntimeIdentifierGraphPath as
  # <dir of BundledRuntimeIdentifierGraphFile>/PortableRuntimeIdentifierGraph.json
  # (Microsoft.NET.Sdk.targets), so point it at a directory holding the fork's
  # portable graph under that standard name (the repo only carries the
  # .openharmony.json variant).
  local graphdir="$WORK/selfsign-ridgraph"
  mkdir -p "$graphdir"
  cp -f "$SDK_REPO/eng/PortableRuntimeIdentifierGraph.openharmony.json" \
        "$graphdir/PortableRuntimeIdentifierGraph.json" || die "selfsign RID graph staging failed"
  local graph="$graphdir/PortableRuntimeIdentifierGraph.json"
  # The fork ships the OpenHarmony-target ilc under the linux-x64 host pack name
  # (its tools/ilc is aarch64), which cannot execute on the CI host. Publish
  # against a filtered view of the feed without that package so restore takes
  # the official linux-x64 host ilc from the dnceng dotnet11 feed (already a
  # source in the repo NuGet.config); our patched microsoft.dotnet.ilcompiler
  # meta-package and the OpenHarmony target packs still come from the feed.
  local ffeed="$WORK/selfsign-feed"
  rm -rf "$ffeed"
  mkdir -p "$ffeed"
  find "$FEED" -maxdepth 1 -name "*.nupkg" \
    ! -name "runtime.linux-x64.Microsoft.DotNet.ILCompiler*" \
    -exec cp -l -f {} "$ffeed/" \; 2>/dev/null \
  || find "$FEED" -maxdepth 1 -name "*.nupkg" \
    ! -name "runtime.linux-x64.Microsoft.DotNet.ILCompiler*" \
    -exec cp -f {} "$ffeed/" \;
  local publog="$WORK/selfsign-ohos-publish.log"
  if ! (cd "$SDK_REPO/eng/ohos-install" && "$dotnet_bin" publish selfsign.csproj \
      -c "$CONFIG" -r openharmony-arm64 -p:PublishAot=true -p:CompressSymbols=false \
      -p:RuntimeFrameworkVersion="$RT_VERSION" \
      "-p:BundledRuntimeIdentifierGraphFile=$graph" \
      "/p:RestoreAdditionalProjectSources=$ffeed" \
      -o "$out" ${extra[@]+"${extra[@]}"}) > "$publog" 2>&1; then
    echo "WARN: selfsign-ohos-arm64 publish failed; last 80 log lines:" | tee -a "$LOG"
    tail -80 "$publog" | tee -a "$LOG"
    cat "$publog" >> "$LOG"
    return 0
  fi
  cat "$publog" >> "$LOG"
  if [ ! -f "$out/selfsign" ]; then
    echo "WARN: selfsign-ohos-arm64 publish produced no binary" | tee -a "$LOG"
    return 0
  fi
  cp -f "$out/selfsign" "$ship/selfsign-ohos-arm64" || die "selfsign-ohos-arm64 staging failed"
  info "staged selfsign-ohos-arm64 ($(stat -c%s "$ship/selfsign-ohos-arm64") bytes, sha256 $(sha256sum "$ship/selfsign-ohos-arm64" | cut -d' ' -f1))"
}
stage_selfsign_release_assets
