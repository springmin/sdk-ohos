#!/bin/sh
# ============================================================================
# test-installer-verification.sh — regression tests for the installer's download-verification hardening (D-4).
# No network access: the download transport and the package sources are mocked.
#
# Usage: sh eng/ohos-install/tests/test-installer-verification.sh
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

installer_tests() {
    # Source only the function section of the installer (everything before main),
    # with SCRIPT_DIR pinned to the real directory so versions.env is found.
    sed -n '1,/^# -\{10,\} main$/p' "$OHOS_DIR/install-dotnet-ohos.sh" | sed '$d' \
        | sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR='$OHOS_DIR'|" > "$TMP/install-funcs.sh"
    # shellcheck disable=SC1091
    . "$TMP/install-funcs.sh"
    trap cleanup EXIT

    artifact="$TMP/artifact.bin"
    printf 'payload' > "$artifact"
    good="$(sha256_of "$artifact")"
    url="https://mirror.example/${SELFSIGN_ASSET}"

    out="$(resolve_choice sdk; printf '%s|%s|%s' "$RESOLVED_URL" "$RESOLVED_ANCHOR" "$SDK_TARBALL_SHA256")"
    case "$out" in
        *"$SDK_TARBALL_SHA256"*) pass "the pinned SDK release resolves with an anchored digest" ;;
        *) fail "the pinned SDK release resolves with an anchored digest: $out" ;;
    esac

    out="$(resolve_choice http://mirror.example/x.tar.gz 2>&1)"; rc=$?
    expect_rc "$rc" 1 "http:// is refused" "$out"
    expect_msg "$out" "insecure http://" "the http refusal is explained"

    out="$(download http://mirror.example/x 2>&1)"; rc=$?
    expect_rc "$rc" 1 "download() refuses plaintext http" "$out"

    download() { cp -f "$artifact" "$2"; }   # mock transport

    out="$(download_verified "$url" "$TMP/o1" "user asset" "" "" 2>&1)"; rc=$?
    expect_rc "$rc" 1 "a user URL without an anchor is refused" "$out"
    expect_msg "$out" "not a pinned release URL" "the same-origin rule is named"

    out="$(download_verified "$url" "$TMP/o2" "user asset" "$good" "" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "a user URL with an explicit pin verifies" "$out"

    out="$(download_verified "$url" "$TMP/o3" "user asset" "" "$good" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "an anchored digest verifies" "$out"

    out="$(download_verified "$url" "$TMP/o4" "user asset" "0000000000000000000000000000000000000000000000000000000000000000" "$good" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "an anchored digest overrides a mismatching caller pin" "$out"

    out="$(download_verified "$url" "$TMP/o5" "user asset" "" "0000000000000000000000000000000000000000000000000000000000000000" 2>&1)"; rc=$?
    expect_rc "$rc" 1 "a mismatching anchor is refused" "$out"

    out="$(resolve_expected_sha256 "$url" "$SELFSIGN_ASSET" 2>&1)"; rc=$?
    expect_rc "$rc" 1 "same-origin checksums cannot be resolved for non-pinned hosts" "$out"

    verify_selfsign_asset "$artifact" >/dev/null 2>&1; rc=$?
    expect_rc "$rc" 1 "a selfsign file that does not match the pin is rejected" ""
    SELFSIGN_SHA256="$good"
    export SELFSIGN_SHA256
    verify_selfsign_asset "$artifact" >/dev/null 2>&1; rc=$?
    expect_rc "$rc" 0 "a selfsign file matching the pin is accepted" ""
    SELFSIGN_SHA256=""
    export SELFSIGN_SHA256
    verify_selfsign_asset "$artifact" >/dev/null 2>&1; rc=$?
    expect_rc "$rc" 2 "without a pin the selfsign file is reported as unverifiable" ""
}


echo "[installer: download verification]"
installer_tests

echo "test-installer-verification: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
