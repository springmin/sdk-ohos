#!/bin/sh
# ============================================================================
# test-fetch-aot-packs-resolution.sh — regression tests for the version-aware
# NativeAOT/Crossgen2 mirror resolution (kit #57 NU1100 hardening).
#
# Context: fetch-nativeaot-packs.sh used to hardcode the .112 asset names, so a
# product-line switch (.105) silently fetched the wrong packs; the .105 packs
# were only on runtime-ohos until 2026-10-15. The resolution now maps the line
# (AOT_PACKS_VERSION, default RT_VERSION) to its mirror release/assets/pins and
# fails closed on an unmapped line with the known lines listed.
#
# No network access: only versions.env resolvers and the script's pre-download
# fail-closed path (an unknown version exits before any transport runs) are
# exercised.
#
# Usage: sh eng/ohos-install/tests/test-fetch-aot-packs-resolution.sh
# ============================================================================

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
OHOS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FETCH="$OHOS_DIR/fetch-nativeaot-packs.sh"

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
is_sha256() { # <value>
    case "$1" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
        *) return 1 ;;
    esac
    [ "${#1}" = 64 ]
}

TMP="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Never inherit an override from the caller's environment (CI or a local run).
unset AOT_PACKS_VERSION AOT_PACKS_TAG

# ---- resolvers ---------------------------------------------------------------
# shellcheck disable=SC1091
. "$OHOS_DIR/versions.env"

[ "$AOT_PACKS_VERSION" = "$RT_VERSION" ] \
    && pass "AOT_PACKS_VERSION defaults to the current line ($RT_VERSION)" \
    || fail "AOT_PACKS_VERSION defaults to RT_VERSION (got '$AOT_PACKS_VERSION')"
[ "$AOT_PACKS_TAG" = "aot-packs-$RT_VERSION" ] \
    && pass "the default line ($RT_VERSION) resolves its mirror tag" \
    || fail "the default line resolves its mirror tag (got '$AOT_PACKS_TAG')"

# Every known line: tag + asset names + a 64-hex pin per asset; the tag maps
# back to exactly the line (so AOT_PACKS_TAG=<tag> resolves the same assets).
for line in $(aot_packs_known_lines); do
    tag="$(aot_packs_tag "$line")"
    assets="$(aot_packs_assets "$line")"
    ok=1
    [ -n "$tag" ] || ok=0
    [ "$(aot_packs_tag_version "$tag")" = "$line" ] || ok=0
    [ -n "$assets" ] || ok=0
    for a in $assets; do
        w="$(aot_pack_sha256 "$a")"
        is_sha256 "$w" || ok=0
    done
    [ "$ok" = 1 ] && pass "line $line: tag '$tag', $(printf '%s\n' "$assets" | grep -c .) asset(s), all pinned" \
                  || fail "line $line: tag '$tag' / assets '$assets' / pins incomplete"
done

# The .105 names are pinned exactly (the assets uploaded to the mirror).
have="$(aot_packs_assets 11.0.0-rc.2.26504.105 | sort | tr '\n' ' ')"
want="Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64.11.0.0-rc.2.26504.105.nupkg runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.11.0.0-rc.2.26504.105.nupkg "
[ "$have" = "$want" ] && pass "the .105 AOT set is the runtime pack + the ILCompiler" \
                      || fail "the .105 AOT set: '$have'"

# Crossgen2 mirrors (JIT R2R): .105 and .112 mapped + pinned; rc.1 unmapped.
for line in 11.0.0-rc.2.26504.105 11.0.0-rc.2.26451.112; do
    cg_tag="$(crossgen2_packs_tag "$line")"
    cg_asset="$(crossgen2_pack_asset "$line")"
    cg_sha="$(crossgen2_pack_sha256 "$cg_asset")"
    ok=1
    [ -n "$cg_tag" ] || ok=0
    case "$cg_asset" in
        "Microsoft.NETCore.App.Crossgen2.openharmony-arm64.$line.nupkg") ;;
        *) ok=0 ;;
    esac
    is_sha256 "$cg_sha" || ok=0
    [ "$ok" = 1 ] && pass "crossgen2 $line: tag '$cg_tag' + pin" \
                  || fail "crossgen2 $line: tag '$cg_tag' asset '$cg_asset' sha '$cg_sha'"
done
[ -z "$(crossgen2_packs_tag 11.0.0-rc.1.26451.109)" ] \
    && pass "the rc.1 line has no crossgen2 mirror (empty => fail closed)" \
    || fail "the rc.1 crossgen2 mapping must stay empty"

# An unmapped line resolves to nothing (the script then fails closed).
[ -z "$(aot_packs_tag 11.0.0-rc.9.1.1)" ] && [ -z "$(aot_packs_assets 11.0.0-rc.9.1.1)" ] \
    && pass "an unknown line maps to no tag/assets" \
    || fail "an unknown line must not map to a tag/assets"

# ---- host ilc selection ------------------------------------------------------
# A mirror may carry host ilcs for more than one RID (openharmony-arm64 for the
# device, linux-x64 for the desktop build host). --list exercises the same
# selection logic without downloading. Use the current line so the test works
# on both the dev and servicing branches.
list_ohos="$(AOT_PACKS_VERSION="$RT_VERSION" HOST_RID=openharmony-arm64 sh "$FETCH" --list 2>&1)"; rc=$?
expect_rc "$rc" 0 "host-aware --list (openharmony-arm64) exits 0" "$list_ohos"
expect_msg "$list_ohos" "fetch runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler." \
    "the OpenHarmony host ilc is selected on the device"

list_linux="$(AOT_PACKS_VERSION="$RT_VERSION" HOST_RID=linux-x64 sh "$FETCH" --list 2>&1)"; rc=$?
expect_rc "$rc" 0 "host-aware --list (linux-x64) exits 0" "$list_linux"
case "$list_linux" in
    *"fetch runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler."*)
        fail "the OpenHarmony host ilc must be skipped on linux-x64" ;;
    *) pass "the OpenHarmony host ilc is skipped on linux-x64" ;;
esac
case "$(aot_packs_assets "$RT_VERSION")" in
    *runtime.linux-x64.Microsoft.DotNet.ILCompiler.*)
        expect_msg "$list_linux" "fetch runtime.linux-x64.Microsoft.DotNet.ILCompiler." \
            "the linux-x64 host ilc is selected on linux-x64" ;;
    *) pass "this line has no linux-x64 host ilc (nothing to select)" ;;
esac

list_win="$(AOT_PACKS_VERSION="$RT_VERSION" HOST_RID=win-x64 sh "$FETCH" --list 2>&1)"; rc=$?
expect_rc "$rc" 0 "host-aware --list (win-x64) exits 0" "$list_win"
case "$list_win" in
    *"fetch runtime."*".Microsoft.DotNet.ILCompiler."*)
        fail "no mirrored host ilc matches win-x64; none must be selected" ;;
    *) pass "no mirrored host ilc matches win-x64" ;;
esac
expect_msg "$list_win" "fetch Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64." \
    "the target runtime pack is selected on every host"
expect_msg "$list_win" "fetch Microsoft.DotNet.ILCompiler." \
    "the build integration pack is selected on every host"

# ---- the script's fail-closed path -------------------------------------------
out="$(AOT_PACKS_VERSION=11.0.0-rc.9.1.1 sh "$FETCH" "$TMP/out-unknown" 2>&1)"; rc=$?
expect_rc "$rc" 1 "an unmapped line fails closed before any download" "$out"
expect_msg "$out" "no NativeAOT mirror release for version '11.0.0-rc.9.1.1'" \
    "the failing line is named"
expect_msg "$out" "11.0.0-rc.2.26504.105" "the known lines are listed"
expect_msg "$out" "aot_packs_tag()/aot_packs_assets()" "the fix location is pointed at"
[ ! -e "$TMP/out-unknown" ] && pass "the fail-closed path writes nothing" \
    || fail "the fail-closed path writes nothing"

# An unknown tag with a known line keeps that line's assets (custom mirror).
out="$(AOT_PACKS_VERSION=11.0.0-rc.2.26504.105 AOT_PACKS_TAG=custom-tag sh "$FETCH" --help 2>&1)"; rc=$?
expect_rc "$rc" 0 "--help exits 0" "$out"
expect_msg "$out" "AOT_PACKS_TAG" "--help documents the tag override"

# ---- verdict ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
