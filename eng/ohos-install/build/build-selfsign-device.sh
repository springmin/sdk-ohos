#!/bin/sh
# Build the device-side selfsign on an OpenHarmony host (NativeAOT,
# openharmony-arm64) and self-test it (usage, sign-produces-block,
# sign-unsigned-runs). Extracted from the 2026-09-29 device run (see
# runtime-ohos docs/plans/2026-09-28-rc2-conflict-sharding-plan.md S8).
#
# Prerequisites:
#   - an OHOS .NET SDK with the LINUX-alias platform fix (runtime 417ab220532
#     or later: RuntimeInformation.IsOSPlatform(OSPlatform.Linux)=true) and the
#     rc.2 OpenHarmony workload installed;
#   - the AOT packs in $AOT_PACKS_DIR: Microsoft.DotNet.ILCompiler
#     (meta + impl), Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64
#     and Microsoft.NETCore.App.Runtime.openharmony-arm64 (the last comes from
#     the workload bundle; fetch-nativeaot-packs.sh fetches the release-mirrored
#     ones);
#   - the OHOS NDK and an OpenSSL 3 build for the device (defaults below).
#
# usage: build-selfsign-device.sh <dotnet-root> [output-dir]
# env:   AOT_PACKS_DIR (default: $HOME/.aot-packs)
#        OHOS_NDK_DIR  (default: first harmonybrew ohos-sdk native dir)
#        OHOS_OPENSSL_DIR (default: $HOME/.harmonybrew/opt/openssl@3/lib)
set -u
DR="${1:?usage: build-selfsign-device.sh <dotnet-root> [output-dir]}"
T="${2:-$(pwd)/selfsign-device-out}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # eng/ohos-install
AOT_PACKS_DIR="${AOT_PACKS_DIR:-$HOME/.aot-packs}"
OHOS_NDK_DIR="${OHOS_NDK_DIR:-$(ls -d "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/native 2>/dev/null | head -1)}"
OSSL="${OHOS_OPENSSL_DIR:-$HOME/.harmonybrew/opt/openssl@3/lib}"
[ -x "$DR/dotnet" ] || { echo "no dotnet at $DR" >&2; exit 2; }
[ -n "$OHOS_NDK_DIR" ] || { echo "OHOS_NDK_DIR not set and no harmonybrew ohos-sdk found" >&2; exit 2; }
[ -f "$AOT_PACKS_DIR/Microsoft.DotNet.ILCompiler.11.0.0-rc.2.26451.112.nupkg" ] || \
  echo "WARN: expected ILCompiler pack not found in $AOT_PACKS_DIR" >&2
SSLPKGS=""
[ -f "$OSSL/libssl.a" ] && [ -f "$OSSL/libcrypto.a" ] && SSLPKGS="$OSSL/libssl.a $OSSL/libcrypto.a"
[ -n "$SSLPKGS" ] || echo "WARN: no static libssl.a/libcrypto.a under $OSSL (link may fail on OpenSSL symbols)" >&2
# Minimal restore config (avoids enumerating the repo's full feed list).
CFG="$(mktemp "${TMPDIR:-/tmp}/selfsign-restore.XXXXXX")"
cat > "$CFG" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="aotpacks" value="$AOT_PACKS_DIR" />
    <add key="nuget" value="https://api.nuget.org/v3/index.json" />
    <add key="dotnet11" value="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/index.json" />
  </packageSources>
</configuration>
EOF
trap 'rm -f "$CFG"' EXIT

export DOTNET_ROOT="$DR"
export PATH="$DR:$DR/tools:$OHOS_NDK_DIR/llvm/bin:$PATH"
export TMPDIR="${TMPDIR:-$HOME/.tmp}"; mkdir -p "$TMPDIR"
# The NDK's lld resolves its own libxml2.so.16 via RUNPATH; a distro libxml2
# (e.g. harmonybrew 2.15.x) ahead of it in LD_LIBRARY_PATH lacks the symbols.
export LD_LIBRARY_PATH="$OHOS_NDK_DIR/llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mkdir -p "$T"; rm -rf "$T/out"
echo "== publishing selfsign (NativeAOT, openharmony-arm64) $(date) =="
( cd "$HERE" && "$DR/dotnet" publish selfsign.csproj \
    -c Release -r openharmony-arm64 -p:PublishAot=true -p:CompressSymbols=false \
    -p:RestoreConfigFile="$CFG" \
    -p:DisableTransitiveFrameworkReferenceDownloads=true \
    -p:CppCompiler="$OHOS_NDK_DIR/llvm/bin/aarch64-unknown-linux-ohos-clang" \
    -p:CppLinker="$OHOS_NDK_DIR/llvm/bin/aarch64-unknown-linux-ohos-clang++" \
    -p:CppCompilerAndLinker="$OHOS_NDK_DIR/llvm/bin/aarch64-unknown-linux-ohos-clang++" \
    -p:SysRoot="$OHOS_NDK_DIR/sysroot" \
    -p:CustomAfterMicrosoftCommonTargets="$HERE/build/selfsign-ohos-link.targets" \
    -p:OhosStaticOpenSslDir="$OSSL" \
    -o "$T/out" -v:m --nologo ) || { echo "publish failed" >&2; exit 1; }
rm -f "$CFG"
BIN="$T/out/selfsign"
ls -l "$BIN"
echo "-- sha256: $(sha256sum "$BIN" | cut -d' ' -f1)"
echo "-- codesign blocks (as linked): $(readelf -S "$BIN" 2>/dev/null | grep -c codesign)"
# The OHOS link may leave a .codesign section that the device rejects (EPERM);
# strip it so the artifact ships unsigned, as pack-sdk.sh does for the release
# asset - the installer bootstrap-signs an unsigned selfsign.
"$OHOS_NDK_DIR/llvm/bin/llvm-objcopy" --remove-section .codesign "$BIN" 2>/dev/null || true
echo "-- codesign blocks after strip: $(readelf -S "$BIN" 2>/dev/null | grep -c codesign)"
# Self-test through a bootstrap-signed copy (binary-sign-tool, the installer
# fallback): the unsigned artifact itself cannot exec on device.
cp -f "$BIN" "$T/exec-test"
if timeout 20 "$T/exec-test" >/dev/null 2>&1; then
  echo "WARN: unsigned copy executed (device is not enforcing signatures?)" >&2
else
  echo "-- unsigned exec refused as expected"
fi
SIGN_TOOL="$(command -v binary-sign-tool 2>/dev/null || true)"
[ -n "$SIGN_TOOL" ] || SIGN_TOOL="$(ls "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/bin/binary-sign-tool "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/toolchains/lib/binary-sign-tool 2>/dev/null | head -1)"
[ -n "$SIGN_TOOL" ] || { echo "binary-sign-tool not found (needed for the bootstrap self-test)" >&2; exit 1; }
"$SIGN_TOOL" sign -inFile "$T/exec-test" -outFile "$T/exec-test" -selfSign 1 >/dev/null 2>&1 || \
  { echo "bootstrap sign failed: $SIGN_TOOL" >&2; exit 1; }
OUT="$(timeout 20 "$T/exec-test" 2>&1)"; RC=$?
case "$OUT" in
  *"usage: selfsign"*) echo "-- bootstrap-signed copy runs: selfsign OK" ;;
  *) echo "signed copy did not run (rc=$RC): $OUT" >&2; exit 1 ;;
esac
