#!/bin/sh
# Verify the provenance of the GA OpenHarmony host ILCompiler package.
#
# The current GA host package is a repack of the stock Microsoft.DotNet.ILCompiler
# 11.0.0 package with the OpenHarmony build-integration targets from
# runtime-ohos (src/coreclr/nativeaot/BuildIntegration). Fresh runtime builds
# produce the host pack directly (BuildHostTools=true), but either way the
# package may be unsigned: the release SHA pin is the trust anchor.
#
# This check is network-backed when the caller downloads the release asset; it
# is kept out of the offline ohos-install-tests suite and run by
# .github/workflows/ohos-aot-host-provenance.yml.
#
# Usage: sh eng/ohos-install/tests/test-aot-host-provenance.sh <host.nupkg>
#        AOT_HOST_NUPKG=<host.nupkg> sh ...
set -eu

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

W="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG="${1:-${AOT_HOST_NUPKG:-}}"
[ -n "$PKG" ] || die "usage: $0 <Microsoft.DotNet.ILCompiler.11.0.0.nupkg>"
[ -f "$PKG" ] || die "package not found: $PKG"

# Single source of truth for the asset SHA.
. "$W/eng/ohos-install/versions.env"

AOT_VERSION="${AOT_VERSION:-11.0.0}"
ASSET="Microsoft.DotNet.ILCompiler.$AOT_VERSION.nupkg"
WANT="$(aot_pack_sha256 "$ASSET")"
[ -n "$WANT" ] || die "no SHA pin for $ASSET in eng/ohos-install/versions.env"
GOT="$(sha256sum "$PKG" | awk '{print $1}')"
[ "$GOT" = "$WANT" ] || die "sha256 mismatch: got $GOT, want $WANT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/aot-host-provenance.XXXXXX")"
trap 'rm -rf "$TMP"' 0
unzip -q "$PKG" \
    'build/Microsoft.DotNet.ILCompiler.SingleEntry.targets' \
    'build/Microsoft.NETCore.Native.Unix.targets' \
    -d "$TMP" || die "package does not contain the expected BuildIntegration targets"

SINGLE="$TMP/build/Microsoft.DotNet.ILCompiler.SingleEntry.targets"
UNIX="$TMP/build/Microsoft.NETCore.Native.Unix.targets"

grep -q 'openharmony' "$SINGLE" || die "SingleEntry.targets has no openharmony mapping"
grep -q 'LinkerFlavor.*openharmony' "$UNIX" || die "Native.Unix.targets has no openharmony lld mapping"
grep -q 'CrossCompileAbi.*openharmony' "$UNIX" || die "Native.Unix.targets has no openharmony ABI mapping"
grep -q 'System.Net.Security.Native.*openharmony' "$UNIX" || die "Native.Unix.targets does not skip System.Net.Security.Native for openharmony"

if unzip -l "$PKG" | grep -q '\.signature\.p7s'; then
    echo "signature: present"
else
    echo "signature: absent (expected for the repack; the SHA pin is the trust anchor)"
fi

echo "AOT host provenance OK: sha256=$GOT"
