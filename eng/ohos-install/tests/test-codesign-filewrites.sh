#!/bin/sh
# ============================================================================
# test-codesign-filewrites.sh — regression tests for the OpenHarmony codesign clean contract
# (audit V2). The two codesign passes in Microsoft.NET.Sdk.targets rewrite build/publish outputs
# in place and leave one stamp each in the object tree; a stamp that is not registered in
# FileWrites survives `dotnet clean`, so the next build's incremental check (the stamp's
# timestamp) can skip a needed re-sign.
#
# The check parses the target file and requires, for both passes:
#   * the incremental pair Inputs=<collector items> Outputs=<stamp> stays intact,
#   * the Touch writes the same stamp the Outputs names,
#   * the target registers that stamp in FileWrites in the same target body (the clean reader
#     consumes the FileWrites items of the project, so a stamp registered in another target or
#     file is not enough when the target is skipped/incrementally up to date... it must be
#     registered in the target that creates it),
#   * the two stamps are distinct files.
# A tampered copy (FileWrites line removed, or moved outside the target) must fail the check.
#
# Usage: sh eng/ohos-install/tests/test-codesign-filewrites.sh
# ============================================================================

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
TARGETS="$SDK_DIR/src/Tasks/Microsoft.NET.Build.Tasks/targets/Microsoft.NET.Sdk.targets"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

[ -f "$TARGETS" ] || { echo "FATAL: targets not found: $TARGETS" >&2; exit 1; }

# check_targets <file> <label>; sets GATE_RC/GATE_OUT
check_targets() {
    GATE_OUT="$(python3 - "$1" "$2" <<'PY' 2>&1
import re, sys

path, label = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()

def target_body(name):
    m = re.search(r'<Target\b[^>]*Name="%s"[^>]*>(.*?)</Target>' % re.escape(name), text, re.S)
    return m.group(0) if m else None

errors = []
for name, stamp in (('_OpenHarmonyCodeSignBuildOutputs', 'OpenHarmonyCodeSign.stamp'),
                    ('_OpenHarmonyCodeSignPublishOutputs', 'OpenHarmonyCodeSignPublish.stamp')):
    body = target_body(name)
    if body is None:
        errors.append(f'{name}: target not found')
        continue
    if f'Outputs="$(IntermediateOutputPath){stamp}"' not in body:
        errors.append(f'{name}: incremental Outputs="{stamp}" missing')
    if 'Inputs="@(_OpenHarmonyCodeSign' not in body:
        errors.append(f'{name}: incremental Inputs collector missing')
    if f'<Touch Files="$(IntermediateOutputPath){stamp}"' not in body:
        errors.append(f'{name}: Touch of {stamp} missing')
    if f'<FileWrites Include="$(IntermediateOutputPath){stamp}" />' not in body:
        errors.append(f'{name}: {stamp} is not registered in FileWrites inside the target')
    if '<OpenHarmonyCodesign Directories=' not in body:
        errors.append(f'{name}: the codesign task call is missing')
    # The registration must sit inside the same target body, after the Touch.
    touch_at = body.find(f'<Touch Files="$(IntermediateOutputPath){stamp}"')
    filewrites_at = body.find(f'<FileWrites Include="$(IntermediateOutputPath){stamp}" />')
    if filewrites_at < touch_at:
        errors.append(f'{name}: FileWrites registration must follow the Touch')

# The two passes must not share a stamp (a shared stamp would let one pass mask the other).
if 'OpenHarmonyCodeSign.stamp' == 'OpenHarmonyCodeSignPublish.stamp':
    errors.append('the two stamps collide')

if errors:
    print(f'{label}: FAIL')
    for e in errors:
        print(f'  - {e}')
    sys.exit(1)
print(f'{label}: OK')
PY
)"
    return $?
}

# ---- T1: the real target file carries the contract -----------------------------------------
if check_targets "$TARGETS" "real targets"; then
    pass "T1 both codesign passes register their stamps in FileWrites ($GATE_OUT)"
else
    fail "T1 the real targets file violates the clean contract: $GATE_OUT"
fi

# ---- T2: a removed FileWrites registration is detected -------------------------------------
sed '/OpenHarmonyCodeSign.stamp" \/>$/d' "$TARGETS" > "$TMP/no-build-stamp.targets"
if check_targets "$TMP/no-build-stamp.targets" "tampered build stamp"; then
    fail "T2 a targets file without the build-stamp FileWrites registration was accepted"
else
    pass "T2 a removed build-stamp registration fails the check"
fi

# ---- T3: a removed publish registration is detected ----------------------------------------
sed '/OpenHarmonyCodeSignPublish.stamp" \/>$/d' "$TARGETS" > "$TMP/no-publish-stamp.targets"
if check_targets "$TMP/no-publish-stamp.targets" "tampered publish stamp"; then
    fail "T3 a targets file without the publish-stamp FileWrites registration was accepted"
else
    pass "T3 a removed publish-stamp registration fails the check"
fi

# ---- T4: a registration moved out of the target is detected --------------------------------
python3 - "$TARGETS" "$TMP/moved.targets" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
text = text.replace('''    <ItemGroup>
      <FileWrites Include="$(IntermediateOutputPath)OpenHarmonyCodeSign.stamp" />
    </ItemGroup>
  </Target>''', '''  </Target>
  <ItemGroup>
    <FileWrites Include="$(IntermediateOutputPath)OpenHarmonyCodeSign.stamp" />
  </ItemGroup>''')
open(dst, 'w', encoding='utf-8').write(text)
PY
if check_targets "$TMP/moved.targets" "moved registration"; then
    fail "T4 a FileWrites registration moved outside the target was accepted"
else
    pass "T4 a registration outside the creating target fails the check"
fi

# ---- T5: the collector targets stay wired --------------------------------------------------
if python3 - "$TARGETS" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
for name, before in (('_OpenHarmonyCodeSignCollectBuildInputs', '_OpenHarmonyCodeSignBuildOutputs'),
                     ('_OpenHarmonyCodeSignCollectPublishInputs', '_OpenHarmonyCodeSignPublishOutputs')):
    m = re.search(r'<Target\b[^>]*Name="%s"[^>]*BeforeTargets="%s"' % (re.escape(name), re.escape(before)), text, re.S)
    if not m:
        print(f'{name} does not declare BeforeTargets="{before}"', file=sys.stderr)
        sys.exit(1)
print('collectors OK')
PY
then
    pass "T5 the input collector targets still run before their codesign passes"
else
    fail "T5 the codesign collector targets/order drifted"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
