#!/bin/sh
# ============================================================================
# install-dotnet-ohos.sh
# Install .NET (SDK or Runtime) on OpenHarmony from GitHub release artifacts
#
# Downloads from the springmin/{sdk,runtime,aspnetcore}-ohos GitHub releases
# (or accepts a local tar.gz), extracts into $HOME/.dotnet, code-signs every
# ELF with a .codesign section, and persists DOTNET_ROOT/PATH.
#
# OpenHarmony only executes ELF binaries carrying a .codesign section
# (unsigned -> EACCES). The runtime/SDK tarballs are NOT pre-signed, so this
# script signs them with, in order of preference:
#   1) binary-sign-tool from the OHOS SDK / harmonybrew (if found)
#   2) the bundled selfsign.sh (C# AOT self-sign tool, see selfsign.sh)
#
# Since 2026-08-26 the SDK embeds all OHOS fixes (W^X, ICU-invariant, NUMA
# probe skip, TMPDIR shared memory, auto-codesign of build outputs), and the
# SDK tarball includes the ASP.NET Core runtime. Installing the SDK alone is
# sufficient for both building and running (including ASP.NET Core apps).
#
# Usage:
#   sh install-dotnet-ohos.sh                    # interactive: pick artifact
#   sh install-dotnet-ohos.sh sdk                # install latest SDK
#   sh install-dotnet-ohos.sh runtime            # install latest Runtime
#   sh install-dotnet-ohos.sh <local.tar.gz>     # install from local file
#   sh install-dotnet-ohos.sh <url>              # install from URL
#
# Options:
#   INSTALL_DIR=<dir>  override install dir (default $HOME/.dotnet)
#
# Idempotent: safe to re-run (re-extract, re-sign, profile entries deduped).
# ============================================================================

set -u

# ------------------------------------------------------------------ config
GH_USER="springmin"
RELEASES="
  sdk|sdk-ohos|v11.0.100-rc.1.26451.1-ohos|dotnet-sdk-11.0.100-rc.1.26451.1-ohos-arm64.tar.gz
  runtime|runtime-ohos|v11.0.0-rc.1.26451.1-ohos|dotnet-runtime-11.0.0-rc.1.26451.1-ohos-arm64.tar.gz
"
# aspnetcore runtime is embedded in the SDK since 2026-08-26; kept here for
# standalone runtime installs that also want ASP.NET Core.
ASPNETCORE_REPO="aspnetcore-ohos"
ASPNETCORE_TAG="v11.0.0-rc.1.26451.1-ohos"
ASPNETCORE_FILE="aspnetcore-runtime-11.0.0-rc.1.26451.1-ohos-arm64.tar.gz"

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.dotnet}"

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- find tools
find_sign_tool() {
    if command -v binary-sign-tool >/dev/null 2>&1; then
        command -v binary-sign-tool; return 0
    fi
    for p in \
        "${HOME}/.harmonybrew/bin/binary-sign-tool" \
        "${HOME}/.harmonybrew/Cellar/ohos-sdk/"*/toolchains/lib/binary-sign-tool \
        "${HOME}/.harmonybrew/Cellar/ohos-sdk/"*/bin/binary-sign-tool \
        "/storage/Users/currentUser/.harmonybrew/bin/binary-sign-tool"
    do
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

sign_elf() { # f -> signs one ELF in place
    f="$1"
    if [ -n "$SIGN_TOOL" ]; then
        "$SIGN_TOOL" sign -inFile "$f" -outFile "$f" -selfSign 1 >/dev/null 2>&1
    else
        selfsign "$f" >/dev/null 2>&1
    fi
}

# ------------------------------------------------------------- download
download() { # url -> file
    url="$1"; out="$2"
    info "downloading ${url}"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL -o "$out" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$out" "$url" || return 1
    else
        die "need curl or wget to download"
    fi
    [ -s "$out" ] || die "download produced empty file: ${out}"
}

# ------------------------------------------------------- resolve artifact
RESOLVED_FILE=""
resolve_choice() { # "sdk"|"runtime"|local path|url
    arg="$1"
    case "$arg" in
        sdk)
            repo="sdk-ohos"; tag="v11.0.100-rc.1.26451.1-ohos"; file="dotnet-sdk-11.0.100-rc.1.26451.1-ohos-arm64.tar.gz"
            RESOLVED_FILE="$file"
            RESOLVED_URL="https://github.com/${GH_USER}/${repo}/releases/download/${tag}/${file}"
            ;;
        runtime)
            repo="runtime-ohos"; tag="v11.0.0-rc.1.26451.1-ohos"; file="dotnet-runtime-11.0.0-rc.1.26451.1-ohos-arm64.tar.gz"
            RESOLVED_FILE="$file"
            RESOLVED_URL="https://github.com/${GH_USER}/${repo}/releases/download/${tag}/${file}"
            ;;
        http://*|https://*)
            RESOLVED_FILE="$(basename "$arg")"
            RESOLVED_URL="$arg"
            ;;
        *)
            [ -r "$arg" ] || die "tarball not readable: ${arg}
  (on OHOS, files inside another app's sandbox — e.g. WeChat appdata — cannot
   be read; move the file to /storage/Users/currentUser/Download first)"
            RESOLVED_FILE="$arg"
            RESOLVED_URL=""
            ;;
    esac
}

# --------------------------------------------------------------- install
install_tarball() {
    tb="$1"
    info "extracting $(basename "$tb") -> ${INSTALL_DIR}"
    mkdir -p "$INSTALL_DIR" || die "cannot create ${INSTALL_DIR}"
    tar zxf "$tb" -C "$INSTALL_DIR" || die "tar extraction failed: ${tb}"
}

sign_all() {
    info "signing ELF binaries (.codesign) ..."
    CNTFILE="${TMPDIR:-/tmp}/dotnet-sign-cnt.$$"
    printf '0 0 0\n' > "$CNTFILE"
    find "$INSTALL_DIR" -type f 2>/dev/null | while IFS= read -r f; do
        file "$f" 2>/dev/null | grep -q "ELF" || continue
        read -r s k d < "$CNTFILE"
        if readelf -S "$f" 2>/dev/null | grep -q ".codesign"; then
            printf '%d %d %d\n' "$s" "$((k + 1))" "$d" > "$CNTFILE"; continue
        fi
        if sign_elf "$f" >/dev/null 2>&1; then
            printf '%d %d %d\n' "$((s + 1))" "$k" "$d" > "$CNTFILE"
        else
            printf 'WARN: signing failed: %s\n' "$f" >&2
            printf '%d %d %d\n' "$s" "$k" "$((d + 1))" > "$CNTFILE"
        fi
    done
    read -r SIGNED SKIPPED FAILED < "$CNTFILE"
    rm -f "$CNTFILE"
    info "signing done: signed=${SIGNED} already_signed=${SKIPPED} failed=${FAILED}"
    [ "$FAILED" -eq 0 ] || die "some binaries could not be signed"
}

setup_profile() {
    pf="$1"
    [ -f "$pf" ] || return 0
    grep -q 'export DOTNET_ROOT=' "$pf" 2>/dev/null && return 0
    cat >> "$pf" <<EOF

# .NET (OHOS install)
export DOTNET_ROOT=\$HOME/.dotnet
export PATH=\$PATH:\$DOTNET_ROOT:\$DOTNET_ROOT/tools
EOF
    info "env vars added to ${pf}"
}

# ------------------------------------------------------------------- main
# prerequisite tools
for tool in tar file readelf; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# sign tool: prefer binary-sign-tool, fall back to selfsign (C# AOT)
SIGN_TOOL="$(find_sign_tool || true)"
if [ -n "$SIGN_TOOL" ]; then
    info "using sign tool: ${SIGN_TOOL}"
elif command -v selfsign >/dev/null 2>&1; then
    info "using selfsign (built-in C# AOT signer)"
    SIGN_TOOL=""
else
    die "no signing tool available: install the OHOS SDK/harmonybrew (binary-sign-tool) or place selfsign on PATH (see selfsign.cs in this directory)"
fi

# resolve artifact (default: sdk)
ARG="${1:-sdk}"
case "$ARG" in
    sdk|runtime|http://*|https://*)
        resolve_choice "$ARG"
        ;;
    *)
        resolve_choice "$ARG"
        ;;
esac

TARBALL=""
if [ -n "${RESOLVED_URL:-}" ]; then
    TMP="${TMPDIR:-/tmp}/dotnet-ohos-$$"
    mkdir -p "$TMP"
    TARBALL="$TMP/$RESOLVED_FILE"
    download "$RESOLVED_URL" "$TARBALL" || die "download failed: ${RESOLVED_URL}"
else
    TARBALL="$RESOLVED_FILE"
fi

install_tarball "$TARBALL"
sign_all
setup_profile "${HOME}/.bashrc"
setup_profile "${HOME}/.zshrc"
setup_profile "${HOME}/.profile"

# ----------------------------------------------------------------- verify
info "verifying ..."
export DOTNET_ROOT="$INSTALL_DIR"
export PATH="$PATH:$INSTALL_DIR:$INSTALL_DIR/tools"
if [ -x "$INSTALL_DIR/dotnet" ]; then
    "$INSTALL_DIR/dotnet" --list-runtimes || die "dotnet did not start"
    case "$ARG" in
        runtime) ;;
        *) "$INSTALL_DIR/dotnet" --list-sdks 2>/dev/null || true ;;
    esac
else
    die "dotnet binary not found after install (wrong tarball?)"
fi

info "DONE. .NET installed at ${INSTALL_DIR}"
info "  runtimes: dotnet --list-runtimes"
info "  sdks:     dotnet --list-sdks"
info "  env:      DOTNET_ROOT + PATH persisted in ~/.bashrc ~/.zshrc ~/.profile"
info "  NOTE: SDK installs include ASP.NET Core runtime (embedded since 2026-08-26)"
