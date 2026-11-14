#!/bin/sh
# Offline contract test for the clean-machine GA script.
#
# The full gate needs an OpenHarmony host and network; this test only runs the
# --dry-run plan and pins the published asset SHAs, the isolated install path,
# and the 826/JIT/AOT phases. It keeps the self-hosted workflow's script from
# rotting without adding network access to ohos-install-tests.
set -eu

W="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/clean-machine-plan.XXXXXX")"
trap 'rm -rf "$TMP"' 0

# shellcheck source=../versions.env
. "$W/eng/ohos-install/versions.env"
SDK_SHA="$SDK_TARBALL_SHA256"
BUNDLE_SHA="$WORKLOAD_BUNDLE_SHA256"

OUT="$TMP/plan.txt"
CLEAN_ROOT="$TMP/root" \
OHOS_WORKLOAD_DIR="$TMP/ohos-workload" \
SKIP_DEVICE=1 \
sh "$W/eng/ohos-install/tests/clean-machine-ga.sh" --dry-run > "$OUT"

check() {
    grep -q "$1" "$OUT" || { echo "FAIL: missing '$1' in the clean-machine plan" >&2; cat "$OUT" >&2; exit 1; }
}

check 'DRY-RUN clean-machine GA plan'
check 'install-dotnet-ohos.sh'
check "$SDK_SHA"
check "$BUNDLE_SHA"
check "${SDK_RELEASE_TAG}/dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz"
check "workload-${WORKLOAD_BUNDLE_VERSION}/openharmony-workload-${WORKLOAD_BUNDLE_VERSION}.tar.gz"
check '826:'
check 'JIT:'
check 'AOT:'
check 'fetch-nativeaot-packs.sh'
check 'publish-aot.sh'

echo "clean-machine GA plan OK ($SDK_VERSION / workload $WORKLOAD_BUNDLE_VERSION)"
