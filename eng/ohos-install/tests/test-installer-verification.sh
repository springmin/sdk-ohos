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

    # ---------------------------------------------------------- binary-sign-tool
    tool="$TMP/binary-sign-tool"
    printf '#!/bin/sh\nexit 0\n' > "$tool"
    chmod -x "$tool"
    out="$(verify_binary_sign_tool "$tool" 2>&1)"; rc=$?
    expect_rc "$rc" 1 "a non-executable binary-sign-tool is refused" "$out"
    expect_msg "$out" "not executable" "the executable check is named"

    chmod +x "$tool"
    out="$(BINARY_SIGN_TOOL_SHA256="" verify_binary_sign_tool "$tool" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "an unpinned binary-sign-tool is accepted with a warning" "$out"
    expect_msg "$out" "not pinned" "the missing pin is reported"

    tool_good="$(sha256_of "$tool")"
    out="$(BINARY_SIGN_TOOL_SHA256="$tool_good" verify_binary_sign_tool "$tool" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "a pin matching the tool verifies" "$out"
    expect_msg "$out" "verified against BINARY_SIGN_TOOL_SHA256" "the pin verification is reported"

    out="$(BINARY_SIGN_TOOL_SHA256="$(printf '%s' "$tool_good" | tr 'a-f' 'A-F')" verify_binary_sign_tool "$tool" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "an upper-case pin is normalized" "$out"

    out="$(BINARY_SIGN_TOOL_SHA256="0000000000000000000000000000000000000000000000000000000000000000" verify_binary_sign_tool "$tool" 2>&1)"; rc=$?
    expect_rc "$rc" 1 "a mismatching binary-sign-tool pin is refused" "$out"
    expect_msg "$out" "sha256 mismatch" "the mismatch is named"

    # A non-executable harmonybrew candidate must not be picked up by the finder.
    fake_home="$TMP/home"
    mkdir -p "$fake_home/.harmonybrew/bin"
    printf '#!/bin/sh\nexit 0\n' > "$fake_home/.harmonybrew/bin/binary-sign-tool"
    chmod -x "$fake_home/.harmonybrew/bin/binary-sign-tool"
    found="$(HOME="$fake_home" PATH="$TMP/empty-path:/usr/bin:/bin" find_binary_sign_tool 2>/dev/null)" || found=""
    [ -z "$found" ] && pass "a non-executable harmonybrew candidate is not selected" \
        || fail "a non-executable harmonybrew candidate is not selected: $found"

    chmod +x "$fake_home/.harmonybrew/bin/binary-sign-tool"
    found="$(HOME="$fake_home" PATH="$TMP/empty-path:/usr/bin:/bin" find_binary_sign_tool 2>/dev/null)" || found=""
    [ "$found" = "$fake_home/.harmonybrew/bin/binary-sign-tool" ] \
        && pass "an executable harmonybrew candidate is selected" \
        || fail "an executable harmonybrew candidate is selected: $found"

    # ------------------------------------------------- workload bundle anchor
    wl_asset="openharmony-workload-${WORKLOAD_BUNDLE_VERSION}.tar.gz"
    wl_url="https://github.com/${GH_USER}/sdk-ohos/releases/download/workload-latest/${wl_asset}"

    wl_anchor="$(workload_anchor_sha256 "$wl_asset")"
    if [ "$wl_anchor" = "$WORKLOAD_BUNDLE_SHA256" ] && printf '%s' "$wl_anchor" | grep -qE '^[0-9a-f]{64}$'; then
        pass "the versioned workload bundle name resolves to the pinned 64-hex anchor"
    else
        fail "the versioned workload bundle name resolves to the pinned 64-hex anchor: $wl_anchor"
    fi
    [ "$(workload_anchor_sha256 openharmony-workload-latest.tar.gz)" = "$WORKLOAD_BUNDLE_SHA256" ] \
        && pass "the rolling workload bundle name resolves to the pinned anchor" \
        || fail "the rolling workload bundle name resolves to the pinned anchor: $(workload_anchor_sha256 openharmony-workload-latest.tar.gz)"
    [ -z "$(workload_anchor_sha256 openharmony-workload-0.0.0-other.tar.gz)" ] \
        && pass "an unpinned workload bundle name resolves to no anchor" \
        || fail "an unpinned workload bundle name resolves to no anchor: $(workload_anchor_sha256 openharmony-workload-0.0.0-other.tar.gz)"

    WORKLOAD_BUNDLE_SHA256="$good"
    export WORKLOAD_BUNDLE_SHA256
    out="$(download_workload_bundle "$wl_url" "$TMP/wl1" "$wl_asset" "workload bundle" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "a workload bundle matching the anchor verifies" "$out"

    WORKLOAD_BUNDLE_SHA256="$(printf '%s' "$good" | tr 'a-f' 'A-F')"
    export WORKLOAD_BUNDLE_SHA256
    out="$(download_workload_bundle "$wl_url" "$TMP/wl2" "$wl_asset" "workload bundle" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "an upper-case workload anchor is normalized" "$out"

    # Same-release evidence that WOULD accept the file: the anchor must still win.
    resolve_expected_sha256() { printf '%s' "$good"; }
    WORKLOAD_BUNDLE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    export WORKLOAD_BUNDLE_SHA256
    out="$(download_workload_bundle "$wl_url" "$TMP/wl3" "$wl_asset" "workload bundle" 2>&1)"; rc=$?
    expect_rc "$rc" 1 "an anchored mismatch is not rescued by same-release evidence" "$out"
    expect_msg "$out" "sha256 mismatch" "the workload anchor mismatch is named"
    expect_msg "$out" "mismatch for workload bundle (WORKLOAD_BUNDLE_SHA256 anchor)" "the mismatch names the anchor as the pin source"
    [ ! -f "$TMP/wl3" ] \
        && pass "a refused workload bundle is not moved into place" \
        || fail "a refused workload bundle is not moved into place"

    # No anchor for the asset name -> the pre-existing same-release semantics apply.
    WORKLOAD_BUNDLE_SHA256=""
    export WORKLOAD_BUNDLE_SHA256
    out="$(download_workload_bundle "$wl_url" "$TMP/wl4" "openharmony-workload-1.0.0-preview.25.tar.gz" "workload bundle" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "a bundle without an anchor falls back to same-release evidence" "$out"
    expect_msg "$out" "using the release's own checksum evidence" "the same-release fallback is warned about"

    resolve_expected_sha256() { return 1; }
    out="$(download_workload_bundle "$wl_url" "$TMP/wl5" "openharmony-workload-1.0.0-preview.25.tar.gz" "workload bundle" 2>&1)"; rc=$?
    expect_rc "$rc" 1 "without anchor and same-release evidence the download is refused" "$out"
    expect_msg "$out" "no sha256 available" "the missing-evidence refusal is explained"

    # Documented escape hatch: WORKLOAD_SHA256 replaces the anchor (with a warning).
    resolve_expected_sha256() { printf '%s' "$good"; }
    WORKLOAD_BUNDLE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    WORKLOAD_SHA256="$good"
    export WORKLOAD_BUNDLE_SHA256 WORKLOAD_SHA256
    out="$(download_workload_bundle "$wl_url" "$TMP/wl6" "$wl_asset" "workload bundle" 2>&1)"; rc=$?
    expect_rc "$rc" 0 "WORKLOAD_SHA256 overrides the bundle anchor" "$out"
    expect_msg "$out" "WORKLOAD_SHA256 overrides WORKLOAD_BUNDLE_SHA256" "the override is reported as a warning"
    WORKLOAD_SHA256=""
    export WORKLOAD_SHA256

    # install_workload(): a local copy of the pinned bundle is anchored before the
    # network is consulted; curl is stubbed out so no request can leave.
    wl_install="$TMP/wl-install"
    mkdir -p "$wl_install/workload"
    printf '#!/bin/sh\nexit 0\n' > "$wl_install/dotnet"
    chmod +x "$wl_install/dotnet"
    cp -f "$artifact" "$wl_install/workload/$wl_asset"

    WORKLOAD_BUNDLE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    export WORKLOAD_BUNDLE_SHA256
    out="$(curl() { return 1; }; ALLOW_MISSING_WORKLOAD=0; INSTALL_DIR="$wl_install"; export ALLOW_MISSING_WORKLOAD INSTALL_DIR; install_workload 2>&1)"; rc=$?
    expect_rc "$rc" 1 "a local bundle mismatching the anchor is refused before any download" "$out"
    expect_msg "$out" "sha256 mismatch" "the local bundle anchor mismatch is named"

    WORKLOAD_BUNDLE_SHA256="$good"
    export WORKLOAD_BUNDLE_SHA256
    out="$(curl() { return 1; }; ALLOW_MISSING_WORKLOAD=0; INSTALL_DIR="$wl_install"; export ALLOW_MISSING_WORKLOAD INSTALL_DIR; install_workload 2>&1)"; rc=$?
    expect_msg "$out" "could not extract" "a local bundle matching the anchor passes verification"
    [ "$rc" -ne 0 ] || fail "the stubbed extraction failure must not report success"
}


echo "[installer: download verification]"
installer_tests

echo "test-installer-verification: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
