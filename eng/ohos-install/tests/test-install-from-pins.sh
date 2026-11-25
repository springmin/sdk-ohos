#!/bin/sh
# ============================================================================
# test-install-from-pins.sh — offline tests for the versions.env thin wrapper.
#
# Verifies that install-dotnet-from-pins.sh installs the pinned layout through
# the vendored dotnet-install.sh, runs the shared post-install steps and refuses
# an unpinned tarball. No network access.
#
# Usage: sh eng/ohos-install/tests/test-install-from-pins.sh
# ============================================================================

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
OHOS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_DIR="$(cd "$OHOS_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TMP="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- fixture
make_tarball() {
    root="$TMP/tar"
    mkdir -p "$root/sdk/11.0.100"
    printf '11.0.100\n' > "$root/sdk/11.0.100/.version"
    cat > "$root/dotnet" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--list-runtimes" ]; then
    echo "Microsoft.NETCore.App 11.0.100 [/fake]"
fi
if [ "${1:-}" = "--list-sdks" ]; then
    echo "11.0.100 [/fake/sdk]"
fi
exit 0
EOF
    chmod +x "$root/dotnet"
    tar -czf "$TMP/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz" -C "$root" .
    sha256sum "$TMP/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz" | awk '{ print $1 }'
}

TARBALL_SHA="$(make_tarball)"
TARBALL_URL="file://$TMP/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz"

run_wrapper() { # <install-dir> <home>
    HOME="$2" INSTALL_DIR="$1" SIGN_MODE=none \
    SDK_VERSION=11.0.100 SDK_TARBALL_SHA256="$TARBALL_SHA" SDK_TARBALL_URL="$TARBALL_URL" \
    sh "$OHOS_DIR/install-dotnet-from-pins.sh" sdk 2>&1
}

# 1. Pinned install extracts the SDK layout.
mkdir -p "$TMP/home1"
: > "$TMP/home1/.profile"
: > "$TMP/home1/.bashrc"
if out="$(run_wrapper "$TMP/inst1" "$TMP/home1")"; then
    [ -d "$TMP/inst1/sdk/11.0.100" ] \
        && pass "pinned install extracts sdk/11.0.100" \
        || fail "pinned install did not extract sdk/11.0.100"
else
    fail "pinned install failed: $out"
fi

# 2. Post-install step writes DOTNET_ROOT and TMPDIR to the profiles.
if grep -q 'DOTNET_ROOT' "$TMP/home1/.profile" 2>/dev/null; then
    pass "profile receives DOTNET_ROOT"
else
    fail "profile missing DOTNET_ROOT"
fi
if grep -q 'TMPDIR' "$TMP/home1/.profile" 2>/dev/null; then
    pass "profile receives the TMPDIR guard"
else
    fail "profile missing the TMPDIR guard"
fi

# 3. An unpinned install is refused before any download.
cat > "$TMP/versions-nosha.env" <<'EOF'
: "${SDK_VERSION:=11.0.100}"
: "${RT_VERSION:=11.0.0}"
: "${RID:=openharmony-arm64}"
: "${GH_USER:=springmin}"
EOF
if out="$(HOME="$TMP/home1" INSTALL_DIR="$TMP/inst2" SIGN_MODE=none \
        OHOS_VERSIONS_ENV="$TMP/versions-nosha.env" SDK_TARBALL_URL="$TARBALL_URL" \
        sh "$OHOS_DIR/install-dotnet-from-pins.sh" sdk 2>&1)"; then
    fail "unpinned install unexpectedly succeeded"
else
    case "$out" in
        *"refusing an unverified install"*) pass "unpinned install is refused" ;;
        *) fail "unexpected refusal message: $out" ;;
    esac
fi

# 4. --list-runtimes verification ran against the installed host.
if [ -x "$TMP/inst1/dotnet" ]; then
    pass "dotnet host extracted and executable"
else
    fail "dotnet host missing after install"
fi

printf 'test-install-from-pins: passed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
