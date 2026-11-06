#!/usr/bin/env bash
# Build only the OpenHarmony .NET SDK from its official ./build.sh entry point.
#
# This is intentionally separate from build-ohos-all.sh. The full-build script
# also builds runtime and aspnetcore; this script consumes the already-published
# runtime packs from the matching -openharmony release and exercises the official
# SDK build/layout path with the OpenHarmony toolchain supplied by the prereqs
# image (OHOS_NDK_HOME, OPENSSL_DIR, ICU_DIR).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_REPO="${SDK_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Product versions and the runtime package versions are owned by versions.env.
# Explicit environment values still win over the defaults.
# shellcheck source=../versions.env
. "$SCRIPT_DIR/../versions.env"

ARCH="${ARCH:-arm64}"
RID="${RID:-openharmony-arm64}"
CONFIG="${CONFIG:-Release}"
RT_VERSION="${RT_VERSION:-11.0.0-rc.3.26522.148}"
BUILDID="${BUILDID:-$DEFAULT_BUILDID}"
FEED="${FEED:-$SDK_REPO/artifacts/ohos-sdk-feed}"
WORK="${WORK:-$SDK_REPO/artifacts/ohos-sdk-work}"
RELEASE_BASE="${RELEASE_BASE:-https://github.com/springmin/runtime-ohos/releases/download/v${RT_VERSION}-openharmony}"
RELEASE_API="${RELEASE_API:-https://api.github.com/repos/springmin/runtime-ohos/releases/tags/v${RT_VERSION}-openharmony}"

OHOS_NDK_HOME="${OHOS_NDK_HOME:-}"
OPENSSL_DIR="${OPENSSL_DIR:-}"
ICU_DIR="${ICU_DIR:-}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

[ -n "$OHOS_NDK_HOME" ] || die "OHOS_NDK_HOME is not set"
[ -f "$OHOS_NDK_HOME/native/build/cmake/ohos.toolchain.cmake" ] || die "OHOS toolchain CMake file missing under $OHOS_NDK_HOME"
[ -f "$OPENSSL_DIR/lib/libcrypto.a" ] || die "OpenSSL static library missing under $OPENSSL_DIR"
[ -d "$ICU_DIR/lib" ] || die "ICU static libraries missing under $ICU_DIR"
[ -x "$SDK_REPO/.dotnet/dotnet" ] || die "SDK bootstrap missing at $SDK_REPO/.dotnet/dotnet"

mkdir -p "$FEED" "$WORK"

info "Downloading runtime package feed for $RT_VERSION"
curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
    "$RELEASE_API" -o "$WORK/runtime-release.json"
python3 - "$WORK/runtime-release.json" > "$WORK/runtime-assets.tsv" <<'PY'
import json
import sys

release = json.load(open(sys.argv[1], encoding="utf-8"))
for asset in release.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(".nupkg"):
        print(f"{name}\t{asset['browser_download_url']}")
PY
while IFS=$'\t' read -r name url; do
    [ -n "$name" ] || continue
    if [ ! -f "$FEED/$name" ]; then
        info "  $name"
        curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
            "$url" -o "$FEED/$name"
    fi
done < "$WORK/runtime-assets.tsv"

# Verify the downloaded packages against the release's checksum manifest when
# possible. Missing files are ignored because the manifest also covers tarballs.
if [ "${VERIFY_RELEASE_ASSETS:-1}" = "1" ]; then
    if curl -fsSL --retry 3 --connect-timeout 30 "$RELEASE_BASE/SHA256SUMS" \
        -o "$FEED/SHA256SUMS"; then
        (cd "$FEED" && sha256sum -c --ignore-missing SHA256SUMS)
    else
        info "WARN: release SHA256SUMS not available; continuing without package checksum verification"
    fi
fi

info "Building SDK only with the official build.sh entry point"
cd "$SDK_REPO"
rid_args=(/p:RidGraphOverridePortableJson="$SDK_REPO/eng/PortableRuntimeIdentifierGraph.openharmony.json")
if [ -f "$SDK_REPO/eng/RuntimeIdentifierGraph.openharmony.json" ]; then
    rid_args+=(/p:RidGraphOverrideRuntimeJson="$SDK_REPO/eng/RuntimeIdentifierGraph.openharmony.json")
fi
./build.sh -os openharmony -arch "$ARCH" -c "$CONFIG" \
    /p:MicrosoftNETCoreAppHostPackageVersion="$RT_VERSION" \
    /p:MicrosoftNETCoreAppRuntimePackageVersion="$RT_VERSION" \
    /p:MicrosoftNETCoreAppRefPackageVersion="$RT_VERSION" \
    /p:RestoreAdditionalProjectSources="$FEED" \
    "${rid_args[@]}" \
    /p:IncludeAspNetCoreRuntime=false \
    /p:SkipUsingCrossgen=true \
    /p:SkipBuildingInstallers=true \
    /p:AllowMissingPrunePackageData=true \
    /p:NativeAotSupported=false \
    /p:PreReleaseVersionLabel="${LABEL:-rc}" \
    /p:PreReleaseVersion="${PRE:-1}" \
    /p:OfficialBuildId="$BUILDID"

test -x "$SDK_REPO/artifacts/bin/redist/$CONFIG/dotnet/dotnet" ||
    die "official SDK build did not produce artifacts/bin/redist/$CONFIG/dotnet/dotnet"
info "SDK-only build completed: $SDK_REPO/artifacts/bin/redist/$CONFIG/dotnet"
