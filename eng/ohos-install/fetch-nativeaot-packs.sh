#!/bin/sh
# fetch-nativeaot-packs.sh — fetch the NativeAOT host/runtime packs for
# OpenHarmony into a local folder feed, verifying the sha256 pins from
# eng/ohos-install/versions.env.
#
# The packs are needed by `dotnet publish -r openharmony-arm64 -p:PublishAot=true`
# when nuget.org is unreachable (air-gapped machines / restricted networks).
#
# Besides the digest, the OpenHarmony runtime pack is checked for the dlopen
# OpenSSL shim (see verify_nativeaot_shim): the 2026-09-27 static-OpenSSL build
# shipped a pack whose static crypto archive has no shim, and every NativeAOT
# app that uses crypto then fails to link/dlopen (undefined EVP_*/X509_*). The
# rc.2 line is now re-cut from the structurally fixed source (`...-struct1`,
# see versions.env); the build guards the archive too (build-ohos-all.sh
# verify_aot_crypto_shim) and this release-side check stays as defense in depth.
#
# Usage:
#   sh eng/ohos-install/fetch-nativeaot-packs.sh [dest-dir]
#   sh eng/ohos-install/fetch-nativeaot-packs.sh --local <dir-with-nupkgs> [dest-dir]
#   AOT_PACKS_TAG=<tag> sh ...        # override the release tag
#   AOT_PACKS_PROXY=<prefix> sh ...   # mirror tried after the direct URL
#                                     # (default https://gh-proxy.com; set empty to disable)
#
# Exit codes: 0 ok, 1 usage/download/verification error.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/versions.env"

LOCAL_DIR=""
if [ "${1:-}" = "--local" ]; then
    LOCAL_DIR="${2:-}"
    [ -n "$LOCAL_DIR" ] || { echo "usage: $0 [--local <dir>] [dest-dir]" >&2; exit 1; }
    shift 2 || true
fi
DEST="${1:-$PWD/aot-packs}"

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
        echo "  see the rc.2 -struct1 note in versions.env" >&2
        return 1
    fi
    echo "  OpenSSL shim OK ($count/5 local_*(EVP|SSL|X509) symbols)"
    return 0
}

assets="
Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64.11.0.0-rc.2.26451.112-struct1.nupkg
runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.11.0.0-rc.2.26451.112.nupkg
"

mkdir -p "$DEST"

failed=0
for asset in $assets; do
    want="$(aot_pack_sha256 "$asset")"
    if [ -z "$want" ]; then
        echo "ERROR: no pinned sha256 for $asset (update versions.env)" >&2
        failed=1
        continue
    fi

    if [ -n "$LOCAL_DIR" ] && [ -f "$LOCAL_DIR/$asset" ]; then
        echo "copying  $asset"
        cp -f "$LOCAL_DIR/$asset" "$DEST/$asset"
    elif [ -f "$DEST/$asset" ]; then
        echo "reusing  $asset"
    else
        url="$AOT_PACKS_BASE_URL/$asset"
        echo "fetching $asset"
        ok=0
        for base in "$AOT_PACKS_BASE_URL" "$AOT_PACKS_PROXY/$AOT_PACKS_BASE_URL"; do
            [ -n "$base" ] || continue
            if curl -fsSL --proto '=https' --proto-redir '=https' \
                    --retry 3 --retry-delay 2 --connect-timeout 30 \
                    -o "$DEST/$asset.part" "$base/$asset"; then
                ok=1
                break
            fi
            rm -f "$DEST/$asset.part"
        done
        if [ "$ok" != "1" ]; then
            echo "ERROR: download failed: $url" >&2
            echo "  fallback: download the asset from the release page and re-run with --local <dir>" >&2
            failed=1
            continue
        fi
        mv -f "$DEST/$asset.part" "$DEST/$asset"
    fi

    got="$(sha256_of "$DEST/$asset")"
    if [ "$got" != "$want" ]; then
        echo "ERROR: sha256 mismatch for $asset" >&2
        echo "  expected $want" >&2
        echo "  actual   $got" >&2
        rm -f "$DEST/$asset"
        failed=1
    else
        echo "  sha256 OK"
        if ! verify_nativeaot_shim "$asset"; then
            rm -f "$DEST/$asset"
            failed=1
        fi
    fi
done

if [ "$failed" != "0" ]; then
    echo "one or more AOT packs could not be fetched/verified" >&2
    exit 1
fi

cat <<EOF

NativeAOT packs are in: $DEST
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
