#!/bin/sh
# ============================================================================
# test-hostfeed-verification.sh — regression tests for the build-time hostfeed digest enforcement (H-C1).
# No network access: the download transport and the package sources are mocked.
#
# Usage: sh eng/ohos-install/tests/test-hostfeed-verification.sh
# ============================================================================

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
OHOS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
expect_rc() { # <rc> <want> <label> [<output>]
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (rc=$1 want $2) $4"; fi
}
expect_msg() { # <output> <needle> <label>
    case "$1" in *"$2"*) pass "$3" ;; *) fail "$3: $1" ;; esac
}

TMP="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

hostfeed_tests() {
    BUILD_SCRIPT="$OHOS_DIR/build/build-ohos-all.sh"
    HOSTFEED="$TMP/hostfeed"
    FEED="$TMP/feed"
    mkdir -p "$HOSTFEED"
    chmod 700 "$HOSTFEED"
    {
        printf "HOSTFEED='%s'\nFEED='%s'\n" "$HOSTFEED" "$FEED"
        for f in hostfeed_pin hostfeed_manifest_sha256 hostfeed_digest ingest_hostfeed; do
            sed -n "/^$f() {/,/^}/p" "$BUILD_SCRIPT"
        done
        printf 'info() { printf "==> %%s\\n" "$*"; }\n'
        printf 'die() { printf "ERROR: %%s\\n" "$*" >&2; exit 1; }\n'
    } > "$TMP/build-funcs.sh"
    # shellcheck disable=SC1091
    . "$TMP/build-funcs.sh"
    trap cleanup EXIT

    id=microsoft.netcore.app.runtime.linux-x64
    ver=11.0.0-rc.1.99999.9
    mkdir -p "$HOSTFEED/$id/$ver"
    printf 'fake package' > "$HOSTFEED/$id/$ver/$id.$ver.nupkg"

    out="$(ingest_hostfeed 2>&1)"; rc=$?
    expect_rc "$rc" 1 "an unpinned hostfeed entry is refused" "$out"
    expect_msg "$out" "no digest pinned" "the missing pin is named"

    printf '%064d  %s/%s/%s.%s.nupkg\n' 0 "$id" "$ver" "$id" "$ver" > "$HOSTFEED/manifest.sha256"
    out="$(ingest_hostfeed 2>&1)"; rc=$?
    expect_rc "$rc" 1 "a mismatching manifest digest is refused" "$out"
    expect_msg "$out" "sha256 mismatch" "the mismatch is named"

    good="$(sha256sum "$HOSTFEED/$id/$ver/$id.$ver.nupkg" | cut -d' ' -f1)"
    printf '%s  %s/%s/%s.%s.nupkg\n' "$good" "$id" "$ver" "$id" "$ver" > "$HOSTFEED/manifest.sha256"
    rm -rf "$FEED"
    out="$(ingest_hostfeed 2>&1)"; rc=$?
    expect_rc "$rc" 0 "a pinned hostfeed entry is accepted" "$out"
    [ -f "$FEED/$id.$ver.nupkg" ] && pass "the verified package is mirrored into the feed" || fail "the verified package is mirrored into the feed"

    mkdir -p "$HOSTFEED/evil.package/1.0.0"
    printf x > "$HOSTFEED/evil.package/1.0.0/evil.package.1.0.0.nupkg"
    out="$(ingest_hostfeed 2>&1)"; rc=$?
    expect_rc "$rc" 1 "an unexpected package id is refused" "$out"

    rm -rf "$HOSTFEED" "$FEED"
    mkdir -p "$HOSTFEED" "$TMP/outside"
    chmod 700 "$HOSTFEED"
    printf evil > "$TMP/outside/$id.$ver.nupkg"
    ln -s "$TMP/outside/$id.$ver.nupkg" "$HOSTFEED/link.nupkg"
    out="$(ingest_hostfeed 2>&1)"; rc=$?
    expect_rc "$rc" 0 "symlinked packages are not ingested" "$out"

    chmod 770 "$HOSTFEED"
    out="$(ingest_hostfeed 2>&1)"; rc=$?
    expect_rc "$rc" 1 "a group/world-writable hostfeed is refused" "$out"
    expect_msg "$out" "group/world writable" "the directory mode refusal is named"
}


echo "[build: hostfeed ingestion]"
hostfeed_tests

echo "test-hostfeed-verification: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
