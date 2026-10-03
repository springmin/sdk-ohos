#!/bin/sh
# ============================================================================
# refresh-release-anchors.sh — print the release digests that eng/ohos-install/versions.env pins.
#
# Downloads the SHA256SUMS asset of the published -ohos releases and prints the
# SDK / runtime / selfsign candidate lines next to the current
# SDK_TARBALL_SHA256 / RUNTIME_TARBALL_SHA256 / SELFSIGN_SHA256 pins, so an
# anchor bump is a copy/paste. Read-only; nothing is modified.
#
# Usage: sh eng/ohos-install/refresh-release-anchors.sh [<sdk-tag> [<runtime-tag>]]
# Requires: gh (authenticated) and network access to the release assets.
# ============================================================================
set -e
SDK_REPO=springmin/sdk-ohos
RUNTIME_REPO=springmin/runtime-ohos
SDK_TAG="${1:-v11.0.100-rc.2.26451.109-ohos}"
RUNTIME_TAG="${2:-v11.0.0-rc.1.26451.109-ohos}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

T="$(mktemp -d "${TMPDIR:-/tmp}/ohos-anchors.XXXXXX")"
trap 'rm -rf "$T"' 0 1 2 3 15
mkdir -p "$T/sdk" "$T/runtime"

echo "== sdk release SHA256SUMS ($SDK_REPO@$SDK_TAG) =="
gh release download "$SDK_TAG" -R "$SDK_REPO" -p SHA256SUMS -D "$T/sdk" --clobber
grep -E "dotnet-sdk-|selfsign" "$T/sdk/SHA256SUMS"
echo
echo "== runtime release SHA256SUMS ($RUNTIME_REPO@$RUNTIME_TAG) =="
gh release download "$RUNTIME_TAG" -R "$RUNTIME_REPO" -p SHA256SUMS -D "$T/runtime" --clobber
grep -E "dotnet-runtime-" "$T/runtime/SHA256SUMS"
echo
echo "== current pins =="
grep -E "SDK_TARBALL_SHA256|RUNTIME_TARBALL_SHA256|SELFSIGN_SHA256" "$SELF_DIR/versions.env"
