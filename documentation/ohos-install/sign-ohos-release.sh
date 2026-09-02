#!/bin/sh
# ============================================================================
# sign-ohos-release.sh
# Host-side (x64) pre-signer for OHOS release tarballs.
#
# HarmonyOS only executes ELF binaries carrying a .codesign section. The
# signing algorithm (ElfSelfSigner) is pure ELF byte manipulation — no device
# dependency, fully deterministic, byte-identical to the on-device flow. This
# script lets CI / release builds pre-sign artifacts on the cross-compilation
# host so the device installer can skip signing.
#
# Usage:
#   sh sign-ohos-release.sh <dir-or-tarball> [<dir-or-tarball> ...]
#
#   - a directory: signs every ELF under it in place
#   - a .tar.gz:    extracts to a temp dir, signs every ELF, repacks in place
#
# Prerequisites:
#   SELFSIGN=<path>   path to the host selfsign binary (default: ./selfsign,
#                     or $PWD/selfsign). Build it with:
#                     dotnet publish selfsign.csproj -c Release -r linux-x64
#                     -p:PublishAot=true
#
# Idempotent: already-signed ELFs are skipped (readelf .codesign check).
# ============================================================================

set -u

SELFSIGN="${SELFSIGN:-$(dirname "$0")/selfsign}"
if [ ! -x "$SELFSIGN" ]; then
    echo "ERROR: selfsign not found at '$SELFSIGN'. Build it first:" >&2
    echo "  dotnet publish selfsign.csproj -c Release -r linux-x64 -p:PublishAot=true" >&2
    exit 1
fi

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in tar file readelf; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

sign_dir() {
    d="$1"
    total=0; skipped=0
    while IFS= read -r f; do
        file "$f" 2>/dev/null | grep -q "ELF" || continue
        if readelf -S "$f" 2>/dev/null | grep -q ".codesign"; then
            skipped=$((skipped + 1)); continue
        fi
        "$SELFSIGN" "$f" >/dev/null 2>&1 || { echo "WARN: sign failed: $f" >&2; }
        total=$((total + 1))
    done <<EOF
$(find "$d" -type f 2>/dev/null)
EOF
    info "signed ${total} ELF (${skipped} already signed) in $d"
}

sign_tarball() {
    tb="$1"
    tmp="${TMPDIR:-/tmp}/ohos-sign-$$"
    mkdir -p "$tmp"
    tar zxf "$tb" -C "$tmp" || die "extract failed: $tb"
    sign_dir "$tmp"
    tar czf "$tb" -C "$tmp" . || die "repack failed: $tb"
    rm -rf "$tmp"
    info "signed tarball: $tb"
}

[ $# -ge 1 ] || die "usage: $0 <dir-or-tarball> [...]"

for arg in "$@"; do
    if [ -d "$arg" ]; then
        sign_dir "$arg"
    elif [ -f "$arg" ] && echo "$arg" | grep -q '\.tar\.gz$'; then
        sign_tarball "$arg"
    else
        die "not a directory or .tar.gz: $arg"
    fi
done

info "DONE."
