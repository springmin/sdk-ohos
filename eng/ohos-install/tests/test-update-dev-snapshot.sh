#!/bin/sh
# Offline contract test for update-dev-snapshot.sh (local tarball path).
set -eu

W="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/update-dev-snapshot.XXXXXX")"
trap 'rm -rf "$TMP"' 0

cp "$W/eng/ohos-install/versions.env" "$TMP/versions.env"
printf 'dev-snapshot-contract' > "$TMP/sdk.tar.gz"
sha="$(sha256sum "$TMP/sdk.tar.gz" | awk '{print $1}')"

VERSIONS_ENV="$TMP/versions.env" \
    sh "$W/eng/ohos-install/update-dev-snapshot.sh" \
    v11.0.100-ohos-dev.20990101 "$TMP/sdk.tar.gz" > "$TMP/out.log"

grep -q '^: "${SDK_RELEASE_TAG:=v11.0.100-ohos-dev.20990101}"$' "$TMP/versions.env" \
    || { echo "FAIL: SDK_RELEASE_TAG not updated" >&2; cat "$TMP/out.log" >&2; exit 1; }
grep -q "^: \"\${SDK_TARBALL_SHA256:=$sha}\"$" "$TMP/versions.env" \
    || { echo "FAIL: SDK_TARBALL_SHA256 not updated" >&2; cat "$TMP/out.log" >&2; exit 1; }

# The anchors must stay single: a duplicate would silently shadow the new pin.
[ "$(grep -c 'SDK_RELEASE_TAG:=' "$TMP/versions.env")" = 1 ] || { echo "FAIL: duplicate SDK_RELEASE_TAG" >&2; exit 1; }
[ "$(grep -c 'SDK_TARBALL_SHA256:=' "$TMP/versions.env")" = 1 ] || { echo "FAIL: duplicate SDK_TARBALL_SHA256" >&2; exit 1; }

echo "update-dev-snapshot: OK (tag + sha updated)"
