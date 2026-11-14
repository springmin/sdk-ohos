#!/bin/sh
# Offline contract test for update-aot-pins.sh (local SHA256SUMS path).
set -eu

W="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/update-aot-pins.XXXXXX")"
trap 'rm -rf "$TMP"' 0

# shellcheck source=../versions.env
. "$W/eng/ohos-install/versions.env"
ASSETS="$(aot_packs_assets "$AOT_PACKS_VERSION")"
[ -n "$ASSETS" ] || { echo "FAIL: no assets for $AOT_PACKS_VERSION" >&2; exit 1; }

cp "$W/eng/ohos-install/versions.env" "$TMP/versions.env"

python3 - "$TMP/SHA256SUMS" $ASSETS <<'PY'
import sys

path, assets = sys.argv[1], sys.argv[2:]
with open(path, "w", encoding="utf-8") as stream:
    for index, asset in enumerate(assets, 1):
        if "ILLink" in asset:
            # Keep the current -rtm ILLink digest.
            sha = "9df0c53dbda5feb4f8df06fe0a8fe66fa5c3db7d021e6b3fa5c079d601630e0e"
        else:
            sha = f"{index:064x}"
        stream.write(f"{sha}  {asset}\n")
PY

VERSIONS_ENV="$TMP/versions.env" AOT_SHA256SUMS="$TMP/SHA256SUMS" \
    sh "$W/eng/ohos-install/update-aot-pins.sh" aot-packs-11.0.0-rtm > "$TMP/out.log"

python3 - "$TMP/versions.env" "$TMP/SHA256SUMS" $ASSETS <<'PY'
import re
import sys

path, sums = sys.argv[1], sys.argv[2]
assets = sys.argv[3:]
text = open(path, encoding="utf-8").read()
for asset in assets:
    want = next(line.split()[0] for line in open(sums, encoding="utf-8")
                if line.split()[1] == asset)
    match = re.search(r'^\s*"' + re.escape(asset) + r'"\)\s+printf \'%s\' "([0-9a-f]{64})" ;;$',
                      text, re.M)
    assert match, f"missing pin for {asset}"
    assert match.group(1) == want, f"{asset}: {match.group(1)} != {want}"
print("all pins updated")
PY

# A changed shared asset digest must fail instead of breaking the base line.
# The current -rtm line uses a distinct ILLink name, so force the base line to
# the same version to exercise the shared-pin guard.
cp "$W/eng/ohos-install/versions.env" "$TMP/versions2.env"
sed 's/9df0c53dbda5feb4f8df06fe0a8fe66fa5c3db7d021e6b3fa5c079d601630e0e/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
    "$TMP/SHA256SUMS" > "$TMP/SHA256SUMS.bad"
if VERSIONS_ENV="$TMP/versions2.env" WORKLOAD_RUNTIME_VERSION=11.0.0-rtm \
    AOT_SHA256SUMS="$TMP/SHA256SUMS.bad" \
    sh "$W/eng/ohos-install/update-aot-pins.sh" aot-packs-11.0.0-rtm > "$TMP/bad.log" 2>&1; then
    echo "FAIL: shared ILLink pin change was accepted" >&2
    cat "$TMP/bad.log" >&2
    exit 1
fi
grep -q 'shared with the base line' "$TMP/bad.log" || { echo "FAIL: missing shared-pin error" >&2; exit 1; }

echo "update-aot-pins: OK (pins refreshed; shared ILLink change refused)"
