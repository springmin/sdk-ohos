#!/bin/sh
# Update the dev snapshot pins in versions.env after a dev full build.
#
# Usage:
#   sh eng/ohos-install/update-dev-snapshot.sh <release-tag> [<sdk-tarball>]
#
#   <release-tag>   dev snapshot release tag, e.g. v11.0.100-ohos-dev.20261114
#   <sdk-tarball>   optional local dotnet-sdk-*.tar.gz. Without it, the tag's
#                   SHA256SUMS is downloaded and the SDK tarball digest is read.
#
# Env: VERSIONS_ENV=<path>   versions.env to edit (default: repo file; tests only)
#
# The SDK tarball name is derived from versions.env (SDK_VERSION / RID), so the
# branch must already be on the line being snapshotted.
set -eu

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/../.." && pwd)"
# Single source of truth for SDK_VERSION / RID / GH_USER.
. "$W/eng/ohos-install/versions.env"

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: $0 <release-tag> [<sdk-tarball>]"
TAG="$1"
TAR="${2:-}"
VERSIONS_ENV="${VERSIONS_ENV:-$W/eng/ohos-install/versions.env}"
NAME="dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz"

if [ -n "$TAR" ]; then
    [ -f "$TAR" ] || die "SDK tarball not found: $TAR"
    SHA="$(sha256sum "$TAR" | awk '{print $1}')"
else
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/dev-snapshot.XXXXXX")"
    trap 'rm -rf "$TMP"' 0
    gh release download "$TAG" --repo "${GH_USER}/sdk-ohos" \
        --pattern SHA256SUMS --dir "$TMP" --clobber >/dev/null 2>&1 \
        || die "cannot download SHA256SUMS for $TAG"
    SHA="$(awk -v n="$NAME" '$2 == n {print $1; exit}' "$TMP/SHA256SUMS")"
    [ -n "$SHA" ] || die "no $NAME in $TAG/SHA256SUMS"
fi

[ "${#SHA}" = 64 ] || die "bad sha256: $SHA"

python3 - "$VERSIONS_ENV" "$TAG" "$SHA" <<'PY'
import re
import sys

path, tag, sha = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
subs = [
    (r'^: "\$\{SDK_RELEASE_TAG:=.*\}"', f': "${{SDK_RELEASE_TAG:={tag}}}"'),
    (r'^: "\$\{SDK_TARBALL_SHA256:=.*\}"', f': "${{SDK_TARBALL_SHA256:={sha}}}"'),
]
for pattern, replacement in subs:
    text, count = re.subn(pattern, replacement, text, count=1, flags=re.M)
    if count != 1:
        raise SystemExit(f"missing anchor: {pattern}")
with open(path, "w", encoding="utf-8") as stream:
    stream.write(text)
PY

echo "updated $VERSIONS_ENV"
echo "  SDK_RELEASE_TAG=$TAG"
echo "  SDK_TARBALL_SHA256=$SHA"
