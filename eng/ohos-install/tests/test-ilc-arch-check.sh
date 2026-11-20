#!/bin/sh
# test-ilc-arch-check.sh - regression tests for build/check-elf-arch.py.
#
# The AOT build must not publish the target (aarch64) ilc under the host RID
# (linux-x64); a wrong pack only fails later when the build host executes it.
# These tests use synthetic 20-byte ELF headers so the suite stays offline and
# architecture-independent.
#
# Usage: sh eng/ohos-install/tests/test-ilc-arch-check.sh
set -eu

W="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$W/eng/ohos-install/build/check-elf-arch.py"
[ -f "$CHECK" ] || { echo "FAIL: missing $CHECK" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ilc-arch.XXXXXX")"
trap 'rm -rf "$TMP"' 0

# build_elf <path> <e_machine>: write a minimal little-endian ELF header.
build_elf() {
    python3 - "$1" "$2" <<'PY'
import struct
import sys

path, machine = sys.argv[1], int(sys.argv[2])
header = (
    b"\x7fELF\x02\x01\x01\x00"  # magic, 64-bit, little-endian, version
    + b"\x00" * 8              # e_ident padding (16 bytes total)
    + struct.pack("<H", 2)     # e_type = ET_EXEC
    + struct.pack("<H", machine)
    + b"\x00" * 44             # rest of the header is irrelevant to the check
)
with open(path, "wb") as f:
    f.write(header)
PY
}

build_elf "$TMP/x64" 62
build_elf "$TMP/arm64" 183
printf 'not an elf\n' > "$TMP/not-elf"

python3 - "$TMP/x64" "$TMP/ilc-x64.nupkg" <<'PY'
import sys
import zipfile

elf, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as zf:
    zf.write(elf, "tools/ilc")
PY

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. The host compiler is accepted.
python3 "$CHECK" "$TMP/x64" --expect x86-64 >/dev/null \
    || fail "x86-64 ELF rejected"
pass "x86-64 file accepted"

# 2. The device compiler is accepted.
python3 "$CHECK" "$TMP/arm64" --expect aarch64 >/dev/null \
    || fail "aarch64 ELF rejected"
pass "aarch64 file accepted"

# 3. A target-arch ilc under the host name is rejected.
if python3 "$CHECK" "$TMP/arm64" --expect x86-64 >/dev/null 2>&1; then
    fail "aarch64 ELF accepted as x86-64"
fi
pass "aarch64 file rejected as x86-64"

# 4. The nupkg entry is what matters, not the file name.
python3 "$CHECK" "$TMP/ilc-x64.nupkg" --entry tools/ilc --expect x86-64 >/dev/null \
    || fail "x86-64 nupkg entry rejected"
pass "nupkg tools/ilc accepted"

# 5. Missing entries and non-ELF inputs fail closed.
if python3 "$CHECK" "$TMP/ilc-x64.nupkg" --entry tools/missing --expect x86-64 >/dev/null 2>&1; then
    fail "missing nupkg entry accepted"
fi
pass "missing nupkg entry rejected"

if python3 "$CHECK" "$TMP/not-elf" --expect x86-64 >/dev/null 2>&1; then
    fail "non-ELF input accepted"
fi
pass "non-ELF input rejected"

echo "ilc arch check tests passed"
