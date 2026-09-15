#!/bin/sh
# ============================================================================
# install-dotnet-runtime.sh
# Install .NET Runtime on OpenHarmony from an official tar.gz binary
#
# Logic follows Microsoft's manual install guide:
#   https://learn.microsoft.com/zh-cn/dotnet/core/install/linux-scripted-manual#manual-install
#   - DOTNET_FILE=...; export DOTNET_ROOT=$HOME/.dotnet
#   - mkdir -p "$DOTNET_ROOT" && tar zxf "$DOTNET_FILE" -C "$DOTNET_ROOT"
#   - export PATH=$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools
#   - persist DOTNET_ROOT + PATH in shell profiles
#
# OpenHarmony-specific requirement (missing in the official docs):
#   OHOS only executes ELF binaries that carry a .codesign section.
#   Unsigned binaries fail execve() with EACCES "Permission denied".
#   We sign every ELF file with the OHOS SDK binary-sign-tool (-selfSign 1),
#   the same tool harmonybrew uses to make its binaries executable.
#
# Usage:
#   sh install-dotnet-runtime.sh <dotnet-runtime-*.tar.gz> [install_dir]
#
#   install_dir defaults to $HOME/.dotnet
#   Idempotent: safe to re-run (re-extract, re-sign, profile entries deduped).
#
# Prerequisites:
#   - tarball must be readable by this shell (NOT inside another app's
#     private sandbox, e.g. WeChat appdata — move it to Download first)
#   - binary-sign-tool from OpenHarmony SDK / harmonybrew (auto-detected)
# ============================================================================

set -u

TARBALL="${1:-}"
INSTALL_DIR="${2:-${HOME}/.dotnet}"

info()  { printf '==> %s\n' "$*"; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. sanity
[ -n "$TARBALL" ] || die "usage: sh $0 <dotnet-runtime-*.tar.gz> [install_dir]"
[ -r "$TARBALL" ] || die "tarball not readable: $TARBALL
  (on OHOS, files inside another app's sandbox — e.g. WeChat appdata — cannot
   be read; move the file to /storage/Users/currentUser/Download first)"

# required tools (tar/file/readelf come with the OHOS SDK or coreutils)
for tool in tar file readelf; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# ------------------------------------------------------- 1. locate sign tool
find_sign_tool() {
    # 1) in PATH
    if command -v binary-sign-tool >/dev/null 2>&1; then
        command -v binary-sign-tool
        return 0
    fi
    # 2) common harmonybrew / OHOS SDK locations
    for p in \
        "${HOME}/.harmonybrew/bin/binary-sign-tool" \
        "${HOME}/.harmonybrew/Cellar/ohos-sdk/"*/toolchains/lib/binary-sign-tool \
        "${HOME}/.harmonybrew/Cellar/ohos-sdk/"*/bin/binary-sign-tool \
        "/storage/Users/currentUser/.harmonybrew/bin/binary-sign-tool"
    do
        if [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

SIGN_TOOL="$(find_sign_tool)" || die "binary-sign-tool not found
  (install the OpenHarmony SDK or harmonybrew, or add it to PATH)"

info "using sign tool: ${SIGN_TOOL}"

# ------------------------------------------------------ 2. extract tarball
info "extracting ${TARBALL} -> ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR" || die "cannot create ${INSTALL_DIR}"
tar zxf "$TARBALL" -C "$INSTALL_DIR" || die "tar extraction failed"

# ------------------------------------------------------- 3. sign ELF files
# NOTE: counters live in a temp file because the `find | while` pipeline runs
# in a subshell on POSIX sh (parent would never see increments).
info "signing ELF binaries (.codesign) ..."
CNTFILE="${TMPDIR:-/tmp}/dotnet-sign-cnt.$$"
printf '0 0 0\n' > "$CNTFILE"

find "$INSTALL_DIR" -type f 2>/dev/null | while IFS= read -r f; do
    # only ELF files need signing (skip .dll, .json, .txt, scripts, ...)
    if ! file "$f" 2>/dev/null | grep -q "ELF"; then
        continue
    fi
    read -r signed skipped failed < "$CNTFILE"
    # idempotent: skip if .codesign section already present
    if readelf -S "$f" 2>/dev/null | grep -q ".codesign"; then
        printf '%d %d %d\n' "$signed" "$((skipped + 1))" "$failed" > "$CNTFILE"
        continue
    fi
    if "$SIGN_TOOL" sign -inFile "$f" -outFile "$f" -selfSign 1 >/dev/null 2>&1; then
        printf '%d %d %d\n' "$((signed + 1))" "$skipped" "$failed" > "$CNTFILE"
    else
        printf 'WARN: signing failed: %s\n' "$f" >&2
        printf '%d %d %d\n' "$signed" "$skipped" "$((failed + 1))" > "$CNTFILE"
    fi
done

read -r SIGNED SKIPPED FAILED < "$CNTFILE"
rm -f "$CNTFILE"
info "signing done: signed=${SIGNED} already_signed=${SKIPPED} failed=${FAILED}"
[ "$FAILED" -eq 0 ] || die "some binaries could not be signed"

# ------------------------------------------- 4. persist env vars (deduped)
setup_profile() {
    pf="$1"
    [ -f "$pf" ] || return 0
    if grep -q 'export DOTNET_ROOT=' "$pf" 2>/dev/null; then
        info "env vars already present in ${pf}"
        return 0
    fi
    cat >> "$pf" <<EOF

# .NET Runtime (manual install)
export DOTNET_ROOT=\$HOME/.dotnet
export PATH=\$PATH:\$DOTNET_ROOT:\$DOTNET_ROOT/tools
EOF
    info "env vars added to ${pf}"
}

setup_profile "${HOME}/.bashrc"
setup_profile "${HOME}/.zshrc"
setup_profile "${HOME}/.profile"

# ----------------------------------------------------- 5. verify install
info "verifying ..."
export DOTNET_ROOT="$INSTALL_DIR"
export PATH="$PATH:$INSTALL_DIR:$INSTALL_DIR/tools"
"$INSTALL_DIR/dotnet" --list-runtimes || die "dotnet did not start"

info "DONE. .NET Runtime installed at ${INSTALL_DIR}"
info "  runtimes:  dotnet --list-runtimes"
info "  env vars:  DOTNET_ROOT + PATH persisted in ~/.bashrc ~/.zshrc ~/.profile"
info "  NOTE: this is the runtime only — install the SDK for 'dotnet build'"
