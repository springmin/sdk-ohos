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
#   binary-sign-tool ships inside the user's own OHOS SDK/harmonybrew install,
#   so this repo cannot anchor a digest for it. Set BINARY_SIGN_TOOL_SHA256=<hex>
#   to pin the exact file: it is verified before first use and a mismatch is
#   fatal. Without the pin the tool runs with a warning.
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
warn()  { printf 'WARN: %s\n' "$*" >&2; }

sha256_of() { # <file> -> hex on stdout
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | sed 's/.*[ =]//'
    else
        return 1
    fi
}

# ---------------------------------------------------------------- 0. sanity
[ -n "$TARBALL" ] || die "usage: sh $0 <dotnet-runtime-*.tar.gz> [install_dir]"
[ -r "$TARBALL" ] || die "tarball not readable: $TARBALL
  (on OHOS, files inside another app's sandbox — e.g. WeChat appdata — cannot
   be read; move the file to a readable location such as the Download folder first)"

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
        "${HOME}/.harmonybrew/Cellar/ohos-sdk/"*/bin/binary-sign-tool
    do
        if [ -x "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# Optional pin: verify the exact fallback tool before executing it. Without
# BINARY_SIGN_TOOL_SHA256 the tool is user-installed SDK content and is used
# with a warning (see the header).
verify_sign_tool() { # <path> -> 0 verified-or-unpinned, 1 refused
    VST_PATH="$1"
    [ -f "$VST_PATH" ] || { printf 'ERROR: binary-sign-tool not found: %s\n' "$VST_PATH" >&2; return 1; }
    [ -x "$VST_PATH" ] || { printf 'ERROR: binary-sign-tool is not executable: %s\n' "$VST_PATH" >&2; return 1; }
    if [ -n "${BINARY_SIGN_TOOL_SHA256:-}" ]; then
        VST_GOT="$(sha256_of "$VST_PATH")" || {
            printf 'ERROR: no sha256 tool (sha256sum/shasum/openssl) to verify binary-sign-tool\n' >&2
            return 1
        }
        VST_WANT="$(printf '%s' "$BINARY_SIGN_TOOL_SHA256" | tr 'A-F' 'a-f')"
        if [ "$VST_GOT" != "$VST_WANT" ]; then
            printf 'ERROR: binary-sign-tool sha256 mismatch: %s\n  expected: %s\n  actual:   %s\n' \
                "$VST_PATH" "$VST_WANT" "$VST_GOT" >&2
            return 1
        fi
        info "binary-sign-tool verified against BINARY_SIGN_TOOL_SHA256"
    else
        warn "binary-sign-tool is not pinned (set BINARY_SIGN_TOOL_SHA256 to verify it before use)"
    fi
    return 0
}

SIGN_TOOL="$(find_sign_tool)" || die "binary-sign-tool not found
  (install the OpenHarmony SDK or harmonybrew, or add it to PATH)"
verify_sign_tool "$SIGN_TOOL" || die "refusing to use an unverified binary-sign-tool: ${SIGN_TOOL}"

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
