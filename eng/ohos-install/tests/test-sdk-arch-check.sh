#!/bin/sh
# ============================================================================
# test-sdk-arch-check.sh — regression tests for the SDK architecture guard (P1-2).
#
# The openharmony SDK build reuses artifacts/bin/redist/<config>/ between builds
# and never cleans it, so a stale (typically x86-64) libdotnet-aot.<ext> can be
# packaged into the SDK tarball; the CLI muxer then tries to dlopen it on every
# `dotnet` invocation and prints a load error. check-sdk-arch.py prunes the layout
# before the build and verifies the tarball before signing; this suite covers both
# modes and the build-script wiring.
#
# No network access: the ELF fixtures are synthetic 64-byte headers and the
# tarballs are built with python3's tarfile.
#
# Usage: sh eng/ohos-install/tests/test-sdk-arch-check.sh
# ============================================================================

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
OHOS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
CHECK="$OHOS_DIR/build/check-sdk-arch.py"

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

# make_elf <path> <machine-hex> : minimal ELF64 header (only e_machine is read)
make_elf() {
    python3 - "$1" "$2" <<'PY'
import struct, sys
path, machine = sys.argv[1], int(sys.argv[2], 16)
hdr = bytearray(64)
hdr[0:4] = b"\x7fELF"
hdr[4] = 2  # ELFCLASS64
hdr[5] = 1  # ELFDATA2LSB
hdr[6] = 1  # EV_CURRENT
struct.pack_into("<H", hdr, 18, machine)
with open(path, "wb") as f:
    f.write(bytes(hdr))
PY
}

# make_tar <tarball> <member> <machine-hex|text> [<member> <machine-hex|text> ...]
make_tar() {
    tarball="$1"
    shift
    python3 - "$tarball" "$@" <<'PY'
import io, struct, sys, tarfile
tarball = sys.argv[1]
specs = sys.argv[2:]
with tarfile.open(tarball, "w:gz") as tar:
    it = iter(specs)
    for name, kind in zip(it, it):
        if kind == "text":
            data = b"not an ELF\n"
        else:
            data = bytearray(64)
            data[0:4] = b"\x7fELF"
            data[4:7] = b"\x02\x01\x01"
            struct.pack_into("<H", data, 18, int(kind, 16))
            data = bytes(data)
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(data))
PY
}

# ---- fixtures ---------------------------------------------------------------
good_tar="$TMP/good.tar.gz"
bad_tar="$TMP/bad.tar.gz"
arm_tar="$TMP/arm.tar.gz"
nonelf_tar="$TMP/nonelf.tar.gz"
make_tar "$good_tar" \
    "dotnet" b7 \
    "sdk/v/MSBuild" b7 \
    "sdk/v/trustedroots.Tests" 3e \
    "sdk/v/runtimes/linux-x64/native/libCoverageInstrumentationMethod.so" 3e
make_tar "$bad_tar" "dotnet" b7 "sdk/v/libdotnet-aot.so" 3e
make_tar "$arm_tar" "dotnet" b7 "sdk/v/libdotnet-aot.so" b7
make_tar "$nonelf_tar" "dotnet" b7 "sdk/v/libdotnet-aot.so" text

layout="$TMP/layout/sdk/11.0.100-rc.1.26451.109"
mkdir -p "$layout"
make_elf "$layout/libdotnet-aot.so" 3e
make_elf "$layout/libdotnet-aot.dylib" 3e
make_elf "$layout/libdotnet-aot.so.bak" 3e
printf 'managed\n' > "$layout/System.Private.CoreLib.dll"

# ---- check-sdk-arch.py prune ------------------------------------------------
out="$(python3 "$CHECK" prune "$TMP/layout" 2>&1)"; rc=$?
expect_rc "$rc" 0 "prune succeeds on a contaminated layout" "$out"
[ ! -e "$layout/libdotnet-aot.so" ] && pass "the x86-64 libdotnet-aot.so is removed" \
    || fail "the x86-64 libdotnet-aot.so is removed"
[ ! -e "$layout/libdotnet-aot.dylib" ] && pass "the libdotnet-aot.dylib is removed" \
    || fail "the libdotnet-aot.dylib is removed"
[ -e "$layout/libdotnet-aot.so.bak" ] && pass "only exact dotnet-aot library names are removed" \
    || fail "only exact dotnet-aot library names are removed"
[ -e "$layout/System.Private.CoreLib.dll" ] && pass "unrelated layout files are untouched" \
    || fail "unrelated layout files are untouched"

out="$(python3 "$CHECK" prune "$TMP/layout" 2>&1)"; rc=$?
expect_rc "$rc" 0 "prune is idempotent" "$out"
expect_msg "$out" "0 stale" "a second prune removes nothing"

# ---- check-sdk-arch.py verify -----------------------------------------------
out="$(python3 "$CHECK" verify "$good_tar" 2>&1)"; rc=$?
expect_rc "$rc" 0 "a tarball without dotnet-aot passes" "$out"
expect_msg "$out" "no dotnet-aot" "the clean tarball is confirmed"

out="$(python3 "$CHECK" verify "$bad_tar" 2>&1)"; rc=$?
expect_rc "$rc" 1 "an x86-64 libdotnet-aot.so fails verification" "$out"
expect_msg "$out" "x86-64" "the offending architecture is named"

out="$(python3 "$CHECK" verify "$arm_tar" 2>&1)"; rc=$?
expect_rc "$rc" 0 "an aarch64 libdotnet-aot.so is accepted (loadable on target)" "$out"

out="$(python3 "$CHECK" verify "$nonelf_tar" 2>&1)"; rc=$?
expect_rc "$rc" 1 "a non-ELF libdotnet-aot.so fails verification" "$out"
expect_msg "$out" "not an ELF" "the non-ELF member is named"

out="$(python3 "$CHECK" verify "$good_tar" --list-foreign 2>&1)"; rc=$?
expect_rc "$rc" 0 "--list-foreign stays informational" "$out"
expect_msg "$out" "trustedroots.Tests" "--list-foreign reports other non-target ELFs"
case "$out" in
    *"runtimes/linux-x64"*) fail "--list-foreign skips packaged runtimes/ payloads" ;;
    *) pass "--list-foreign skips packaged runtimes/ payloads" ;;
esac

# ---- build-script wiring ----------------------------------------------------
# Stage 4 (and with it the dotnet-aot prune/verify helpers) was split out of
# build-ohos-all.sh into build/pack-sdk.sh; read them from their owner script.
BUILD_SCRIPT="$OHOS_DIR/build/pack-sdk.sh"
SDK_REPO="$TMP/sdkrepo"
CONFIG=Release
mkdir -p "$SDK_REPO/artifacts/bin/redist/Release/sdk/1.0"
make_elf "$SDK_REPO/artifacts/bin/redist/Release/sdk/1.0/libdotnet-aot.so" 3e
{
    printf "SDK_REPO='%s'\nCONFIG='%s'\nSCRIPT_DIR='%s'\n" "$SDK_REPO" "$CONFIG" "$OHOS_DIR/build"
    sed -n '/^SDK_ARCH_CHECK=/p' "$BUILD_SCRIPT"
    sed -n '/^prune_stale_sdk_aot_libs() {/,/^}/p' "$BUILD_SCRIPT"
    sed -n '/^verify_sdk_tarball_arch() {/,/^}/p' "$BUILD_SCRIPT"
    printf 'die() { printf "ERROR: %%s\\n" "$*" >&2; exit 1; }\n'
} > "$TMP/build-funcs.sh"
# shellcheck disable=SC1091
. "$TMP/build-funcs.sh"
trap cleanup EXIT

out="$(prune_stale_sdk_aot_libs 2>&1)"; rc=$?
expect_rc "$rc" 0 "the build-script prune helper succeeds" "$out"
[ ! -e "$SDK_REPO/artifacts/bin/redist/Release/sdk/1.0/libdotnet-aot.so" ] \
    && pass "the build-script prune helper clears the stale redist layout library" \
    || fail "the build-script prune helper clears the stale redist layout library"

out="$(verify_sdk_tarball_arch "$bad_tar" 2>&1)"; rc=$?
expect_rc "$rc" 1 "the build-script verify helper rejects a foreign dotnet-aot library" "$out"
out="$(verify_sdk_tarball_arch "$good_tar" 2>&1)"; rc=$?
expect_rc "$rc" 0 "the build-script verify helper accepts a clean tarball" "$out"

# ---- verdict ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
