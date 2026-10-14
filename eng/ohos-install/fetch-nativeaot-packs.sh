#!/bin/sh
# fetch-nativeaot-packs.sh — fetch the NativeAOT host/runtime packs for
# OpenHarmony into a local folder feed, verifying the sha256 pins from
# eng/ohos-install/versions.env.
#
# The packs are needed by `dotnet publish -r openharmony-arm64 -p:PublishAot=true`
# when nuget.org is unreachable (air-gapped machines / restricted networks).
#
# The build line is resolved from AOT_PACKS_VERSION (default: RT_VERSION from
# versions.env), so when the product moves to a new line the matching mirror
# release is selected automatically. An unmapped line fails closed and lists
# the known lines instead of silently asking for another line's assets — the
# kit #57 NU1100 incident: the .105 packs were only on runtime-ohos and the
# script still requested the .112 names.
#
# Besides the digest, the OpenHarmony runtime pack is checked for the dlopen
# OpenSSL shim (see verify_nativeaot_shim): the 2026-09-27 static-OpenSSL build
# shipped a pack whose static crypto archive has no shim, and every NativeAOT
# app that uses crypto then fails to link/dlopen (undefined EVP_*/X509_*). The
# rc.2 .112 line was re-cut from the structurally fixed source (`...-struct1`,
# see versions.env); the .105 line is a fresh build of that source. The build
# guards the archive too (build-ohos-all.sh verify_aot_crypto_shim) and this
# release-side check stays as defense in depth.
#
# Usage:
#   sh eng/ohos-install/fetch-nativeaot-packs.sh [--crossgen2] [dest-dir]
#   sh eng/ohos-install/fetch-nativeaot-packs.sh --local <dir-with-nupkgs> [--crossgen2] [dest-dir]
#   AOT_PACKS_VERSION=<version> sh ...  # select the build line explicitly
#   AOT_PACKS_TAG=<tag> sh ...          # override the release tag (when the tag
#                                       # names a known mirror line, that line's
#                                       # assets and pins win; rc.1 fallback:
#                                       # AOT_PACKS_TAG=aot-packs-11.0.0-rc.1)
#   AOT_PACKS_PROXY=<prefix> sh ...     # mirror tried after the direct URL
#                                       # (default https://gh-proxy.com; set empty to disable)
#   --crossgen2                         # also fetch the Crossgen2 pack of the
#                                       # same line (JIT ReadyToRun for app
#                                       # publishes; PublishAot does not need it);
#                                       # fails closed when the line has no mirror
#
# Exit codes: 0 ok, 1 usage/download/verification error.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/versions.env"

LOCAL_DIR=""
WANT_CROSSGEN2=0
DEST=""
usage() {
    cat <<'EOF'
usage: fetch-nativeaot-packs.sh [--crossgen2] [--local <dir-with-nupkgs>] [dest-dir]

Fetches the NativeAOT packs of the resolved build line (AOT_PACKS_VERSION,
default: RT_VERSION) from the sdk-ohos mirror release, verifying the sha256
pins in eng/ohos-install/versions.env. --crossgen2 also fetches the Crossgen2
pack of the same line (JIT ReadyToRun; not needed for PublishAot).
Env overrides: AOT_PACKS_VERSION, AOT_PACKS_TAG, AOT_PACKS_PROXY,
AOT_PACKS_BASE_URL, CROSSGEN2_BASE_URL.
exit: 0 ok, 1 usage/download/verification error.
EOF
}
while [ $# -gt 0 ]; do
    case "$1" in
        --local)
            shift
            [ $# -ge 1 ] || { usage >&2; exit 1; }
            LOCAL_DIR="$1"
            ;;
        --crossgen2) WANT_CROSSGEN2=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown argument: $1 (try --help)" >&2; exit 1 ;;
        *)
            [ -z "$DEST" ] || { echo "unexpected extra argument: $1" >&2; exit 1; }
            DEST="$1"
            ;;
    esac
    shift
done
DEST="${DEST:-$PWD/aot-packs}"

# Resolve the line, the mirror tag and the asset set. AOT_PACKS_VERSION picks
# the line; an AOT_PACKS_TAG that names a known mirror line overrides it (this
# keeps the documented `AOT_PACKS_TAG=aot-packs-11.0.0-rc.1` fallback working
# with the rc.1 assets). A custom (unknown) tag keeps the version's assets.
: "${AOT_PACKS_VERSION:=${RT_VERSION:-}}"
if [ -n "${AOT_PACKS_TAG:-}" ]; then
    _tag_line="$(aot_packs_tag_version "$AOT_PACKS_TAG")"
    [ -n "$_tag_line" ] && AOT_PACKS_VERSION="$_tag_line"
fi
AOT_PACKS_TAG="${AOT_PACKS_TAG:-$(aot_packs_tag "$AOT_PACKS_VERSION")}"
assets="$(aot_packs_assets "$AOT_PACKS_VERSION")"

if [ -z "$AOT_PACKS_TAG" ] || [ -z "$assets" ]; then
    echo "ERROR: no NativeAOT mirror release for version '${AOT_PACKS_VERSION:-<unset>}'" >&2
    echo "  known mirrored lines:" >&2
    aot_packs_known_lines | sed 's/^/    /' >&2
    echo "  add the line to aot_packs_tag()/aot_packs_assets()/aot_pack_sha256() in" >&2
    echo "  eng/ohos-install/versions.env and publish its mirror release (or fetch the" >&2
    echo "  nupkgs from the runtime-ohos release page and re-run with --local <dir>)." >&2
    echo "  A custom mirror with the same asset names can be selected with" >&2
    echo "  AOT_PACKS_TAG=<tag> AOT_PACKS_VERSION=${AOT_PACKS_VERSION:-<version>} ..." >&2
    exit 1
fi

# Direct github.com release downloads are flaky on some networks (TLS resets,
# truncated bodies); retry through the gh-proxy mirror as a fallback. The
# sha256 pin below rejects any truncated or substituted body.
: "${AOT_PACKS_PROXY:=https://gh-proxy.com}"
: "${AOT_PACKS_BASE_URL:=https://github.com/${AOT_PACKS_REPO}/releases/download/${AOT_PACKS_TAG}}"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo "ERROR: no sha256sum/shasum available" >&2
        return 1
    fi
}

# fetch_asset <asset> <want-sha> <base-url> <line-label>:
# 0 = present/verified, 1 = missing or refused. The caller adds the fail-closed
# guidance; this function keeps the transport + digest logic in one place.
fetch_asset() {
    _asset="$1"; _want="$2"; _base="$3"; _label="$4"
    if [ -n "$LOCAL_DIR" ] && [ -f "$LOCAL_DIR/$_asset" ]; then
        echo "copying  $_asset"
        cp -f "$LOCAL_DIR/$_asset" "$DEST/$_asset" || return 1
    elif [ -f "$DEST/$_asset" ]; then
        echo "reusing  $_asset"
    else
        url="$_base/$_asset"
        echo "fetching $_asset"
        ok=0
        for base in "$_base" "$AOT_PACKS_PROXY/$_base"; do
            [ -n "$base" ] || continue
            if curl -fsSL --proto '=https' --proto-redir '=https' \
                    --retry 3 --retry-delay 2 --connect-timeout 30 \
                    -o "$DEST/$_asset.part" "$base/$_asset"; then
                ok=1
                break
            fi
            rm -f "$DEST/$_asset.part"
        done
        if [ "$ok" != "1" ]; then
            echo "ERROR: download failed: $url" >&2
            echo "  the mirror release '$_label' may not carry $_asset yet;" >&2
            echo "  fallback: download the asset from the release page (or the fork" >&2
            echo "  release) and re-run with --local <dir>" >&2
            return 1
        fi
        mv -f "$DEST/$_asset.part" "$DEST/$_asset" || return 1
    fi

    got="$(sha256_of "$DEST/$_asset")"
    if [ "$got" != "$_want" ]; then
        echo "ERROR: sha256 mismatch for $_asset" >&2
        echo "  expected $_want" >&2
        echo "  actual   $got" >&2
        rm -f "$DEST/$_asset"
        return 1
    fi
    echo "  sha256 OK"
    if ! verify_nativeaot_shim "$_asset"; then
        rm -f "$DEST/$_asset"
        return 1
    fi
    return 0
}

# verify_nativeaot_shim <asset>: the OpenHarmony NativeAOT runtime pack must
# carry the dlopen OpenSSL shim (opensslshim.c.o defines the `*_ptr` globals
# and the local_* wrappers the rest of the archive calls). The 2026-09-27
# static-OpenSSL full build (LinkStaticOpenSsl=true) dropped it, and NativeAOT
# apps that use crypto then fail at link/dlopen time (undefined EVP_*/X509_*).
# The sha256 pin covers integrity, not content, so check the content too. Skips
# (with a warning) when unzip/nm are unavailable.
verify_nativeaot_shim() {
    case "$1" in
        Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64.*) ;;
        *) return 0 ;;
    esac

    if ! command -v unzip >/dev/null 2>&1; then
        echo "  WARN: unzip not found; skipping the OpenSSL shim content check" >&2
        return 0
    fi
    nm_tool=""
    for candidate in llvm-nm nm; do
        if command -v "$candidate" >/dev/null 2>&1; then
            nm_tool="$candidate"
            break
        fi
    done
    if [ -z "$nm_tool" ]; then
        echo "  WARN: neither llvm-nm nor nm found; skipping the OpenSSL shim content check" >&2
        return 0
    fi

    tmpdir="$(mktemp -d 2>/dev/null || true)"
    if [ -z "$tmpdir" ]; then
        echo "  WARN: mktemp -d failed; skipping the OpenSSL shim content check" >&2
        return 0
    fi
    lib="$tmpdir/libSystem.Security.Cryptography.Native.OpenSsl.a"
    if ! unzip -p "$DEST/$1" \
            'runtimes/openharmony-arm64/native/libSystem.Security.Cryptography.Native.OpenSsl.a' \
            > "$lib" 2>/dev/null || [ ! -s "$lib" ]; then
        rm -rf "$tmpdir"
        echo "ERROR: cannot read libSystem.Security.Cryptography.Native.OpenSsl.a from $1" >&2
        return 1
    fi
    count="$("$nm_tool" --defined-only "$lib" 2>/dev/null | grep -cE 'local_(EVP|SSL|X509)' || true)"
    rm -rf "$tmpdir"
    if [ "${count:-0}" -lt 5 ]; then
        echo "ERROR: $1 has no OpenSSL dlopen shim ($count/5 local_*(EVP|SSL|X509) symbols)" >&2
        echo "  this pack fails to link/dlopen for crypto-using NativeAOT apps;" >&2
        echo "  see the rc.2 structural note in versions.env" >&2
        return 1
    fi
    echo "  OpenSSL shim OK ($count/5 local_*(EVP|SSL|X509) symbols)"
    return 0
}

mkdir -p "$DEST"

failed=0
for asset in $assets; do
    want="$(aot_pack_sha256 "$asset")"
    if [ -z "$want" ]; then
        echo "ERROR: no pinned sha256 for $asset (update aot_pack_sha256 in versions.env)" >&2
        failed=1
        continue
    fi
    fetch_asset "$asset" "$want" "$AOT_PACKS_BASE_URL" "$AOT_PACKS_TAG" || failed=1
done

if [ "$WANT_CROSSGEN2" = 1 ]; then
    cg_tag="$(crossgen2_packs_tag "$AOT_PACKS_VERSION")"
    cg_asset="$(crossgen2_pack_asset "$AOT_PACKS_VERSION")"
    cg_want="$(crossgen2_pack_sha256 "$cg_asset")"
    if [ -z "$cg_tag" ] || [ -z "$cg_asset" ] || [ -z "$cg_want" ]; then
        echo "ERROR: no Crossgen2 mirror for line '${AOT_PACKS_VERSION:-<unset>}'" >&2
        echo "  publish the pack (see crossgen2_packs_tag() in versions.env) or drop" >&2
        echo "  --crossgen2; PublishAot does not need it." >&2
        failed=1
    else
        : "${CROSSGEN2_BASE_URL:=https://github.com/${AOT_PACKS_REPO}/releases/download/${cg_tag}}"
        fetch_asset "$cg_asset" "$cg_want" "$CROSSGEN2_BASE_URL" "$cg_tag" || failed=1
    fi
fi

if [ "$failed" != "0" ]; then
    echo "one or more packs could not be fetched/verified" >&2
    exit 1
fi

cat <<EOF

NativeAOT packs for ${AOT_PACKS_VERSION} are in: $DEST
Add the folder as a NuGet source, for example a NuGet.config next to the project:

  <configuration>
    <packageSources>
      <clear />
      <add key="aot-packs" value="$DEST" />
      <add key="ohos-workload" value="<path to ohos-workload/.feed>" />
    </packageSources>
  </configuration>

or pass it per command: dotnet restore --source "$DEST"
EOF
