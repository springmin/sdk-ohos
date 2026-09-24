#!/bin/sh
# fetch-nativeaot-packs.sh — fetch the NativeAOT host/runtime packs for
# OpenHarmony into a local folder feed, verifying the sha256 pins from
# eng/ohos-install/versions.env.
#
# The packs are needed by `dotnet publish -r openharmony-arm64 -p:PublishAot=true`
# when nuget.org is unreachable (air-gapped machines / restricted networks).
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

assets="
Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64.11.0.0-rc.1.26451.109.nupkg
runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.11.0.0-rc.1.26451.109.nupkg
microsoft.netcore.app.runtime.nativeaot.linux-musl-arm64.11.0.0-rc.1.26425.128.nupkg
runtime.linux-musl-arm64.microsoft.dotnet.ilcompiler.11.0.0-rc.1.26425.128.nupkg
runtime.win-x64.microsoft.dotnet.ilcompiler.11.0.0-rc.1.26425.128.nupkg
microsoft.netcore.app.runtime.nativeaot.linux-musl-arm64.11.0.0-rc.1.26451.109.nupkg
runtime.linux-musl-arm64.microsoft.dotnet.ilcompiler.11.0.0-rc.1.26451.109.nupkg
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
