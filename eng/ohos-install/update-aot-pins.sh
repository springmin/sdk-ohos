#!/bin/sh
# Update the suffixed AOT mirror pins in versions.env from a release SHA256SUMS.
#
# Usage:
#   sh eng/ohos-install/update-aot-pins.sh [<release-tag>]
#
#   <release-tag>  dev AOT mirror tag (default: AOT_PACKS_TAG, e.g.
#                  aot-packs-11.0.0-rtm)
#
# Env:
#   VERSIONS_ENV=<path>       versions.env to edit (default: repo file; tests only)
#   AOT_SHA256SUMS=<path>     local SHA256SUMS instead of downloading (tests/offline)
#
# The pins for the selected AOT line are refreshed. Assets shared with the
# base line (ILLink.Tasks) are only accepted when the digest is unchanged, so
# this script cannot silently break the GA 11.0.0 pin.
set -eu

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/../.." && pwd)"
. "$W/eng/ohos-install/versions.env"

TAG="${1:-${AOT_PACKS_TAG:-}}"
[ -n "$TAG" ] || die "no release tag (set AOT_PACKS_TAG or pass one)"
VERSIONS_ENV="${VERSIONS_ENV:-$W/eng/ohos-install/versions.env}"

if [ -n "${AOT_SHA256SUMS:-}" ]; then
    SUMS="$AOT_SHA256SUMS"
else
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/aot-pins.XXXXXX")"
    trap 'rm -rf "$TMP"' 0
    gh release download "$TAG" --repo "${GH_USER}/sdk-ohos" \
        --pattern SHA256SUMS --dir "$TMP" --clobber >/dev/null 2>&1 \
        || die "cannot download SHA256SUMS for $TAG"
    SUMS="$TMP/SHA256SUMS"
fi
[ -f "$SUMS" ] || die "SHA256SUMS not found: $SUMS"

ASSETS="$(aot_packs_assets "$AOT_PACKS_VERSION")"
[ -n "$ASSETS" ] || die "no mirrored assets for AOT_PACKS_VERSION=$AOT_PACKS_VERSION"
BASE_ASSETS="$(aot_packs_assets "$WORKLOAD_RUNTIME_VERSION")"

UPDATES=""
for asset in $ASSETS; do
    sha="$(awk -v n="$asset" '$2 == n {print $1; exit}' "$SUMS")"
    [ -n "$sha" ] || die "missing $asset in $SUMS"
    [ "${#sha}" = 64 ] || die "bad sha256 for $asset: $sha"
    UPDATES="$UPDATES$asset $sha
"
done

python3 - "$VERSIONS_ENV" "$BASE_ASSETS" "$UPDATES" <<'PY'
import re
import sys

path, base_assets, updates = sys.argv[1:4]
base = set(base_assets.split())
text = open(path, encoding="utf-8").read()
changed = []
for line in updates.splitlines():
    if not line.strip():
        continue
    asset, sha = line.split()
    match = re.search(r'^\s*"' + re.escape(asset) + r'"\)\s+printf \'%s\' "([0-9a-f]{64})" ;;$',
                      text, re.M)
    if not match:
        raise SystemExit(f"missing pin line for {asset}")
    old = match.group(1)
    if asset in base and old != sha:
        raise SystemExit(
            f"{asset} is shared with the base line ({old} != {sha}); "
            "update both lines deliberately")
    pattern = re.compile(r'^(\s*"' + re.escape(asset) +
                         r'"\)\s+printf \'%s\' ")[0-9a-f]{64}(" ;;)$', re.M)
    text, count = pattern.subn(lambda m: m.group(1) + sha + m.group(2), text, count=1)
    if count != 1:
        raise SystemExit(f"could not update {asset}")
    if old != sha:
        changed.append((asset, old, sha))
with open(path, "w", encoding="utf-8") as stream:
    stream.write(text)
for asset, old, sha in changed:
    print(f"  {asset}: {old[:12]}... -> {sha[:12]}...")
PY

echo "updated $VERSIONS_ENV from $TAG ($AOT_PACKS_VERSION)"
