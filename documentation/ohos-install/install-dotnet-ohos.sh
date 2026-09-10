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
#   1) binary-sign-tool from the OpenHarmony SDK / harmonybrew (if found)
#   2) the bundled selfsign.sh (C# AOT self-sign tool, see selfsign.sh)
#
# Since 2026-08-26 the SDK embeds all OpenHarmony fixes (W^X, ICU-invariant, NUMA
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
  sdk|sdk-ohos|v11.0.100-rc.1.26451.109-ohos|dotnet-sdk-11.0.100-rc.1.26451.109-openharmony-arm64.tar.gz
  runtime|runtime-ohos|v11.0.0-rc.1.26451.109-ohos|dotnet-runtime-11.0.0-rc.1.26451.109-openharmony-arm64.tar.gz
"
# aspnetcore runtime is embedded in the SDK since 2026-08-26; kept here for
# standalone runtime installs that also want ASP.NET Core.
ASPNETCORE_REPO="aspnetcore-ohos"
ASPNETCORE_TAG="v11.0.0-rc.1.26451.109-ohos"
ASPNETCORE_FILE="aspnetcore-runtime-11.0.0-rc.1.26451.109-openharmony-arm64.tar.gz"

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.dotnet}"

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- find tools
# Signing preference (since 2026-09-06): selfsign FIRST (deployed next to
# dotnet/dnx at $INSTALL_DIR/selfsign, or found on PATH); binary-sign-tool is
# the fallback when selfsign is unavailable.
SELFSIGN=""
SIGN_TOOL=""

find_selfsign() {
    # 1) selfsign deployed parallel to dotnet/dnx in the install root
    if [ -x "${INSTALL_DIR}/selfsign" ]; then
        printf '%s\n' "${INSTALL_DIR}/selfsign"; return 0
    fi
    # 2) selfsign on PATH
    if command -v selfsign >/dev/null 2>&1; then
        command -v selfsign; return 0
    fi
    return 1
}

find_binary_sign_tool() {
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

has_codesign() { readelf -S "$1" 2>/dev/null | grep -q ".codesign"; }

sign_elf() { # f -> signs one ELF in place (selfsign preferred, then binary-sign-tool)
    f="$1"
    if [ -n "$SELFSIGN" ]; then
        # --force re-signs even when a .codesign section already exists:
        # shipped signatures may come from older tooling and are rejected by
        # the device (EPERM), so every ELF is rewritten with the current
        # device-verified algorithm.
        "$SELFSIGN" "$f" --force >/dev/null 2>&1
    else
        "$SIGN_TOOL" sign -inFile "$f" -outFile "$f" -selfSign 1 >/dev/null 2>&1
    fi
}

# ------------------------------------------------------------- download
download() { # url -> file
    url="$1"; out="$2"
    info "downloading ${url}"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 --retry-delay 2 --connect-timeout 30 -o "$out" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=30 -O "$out" "$url" || return 1
    else
        printf 'ERROR: need curl or wget to download\n' >&2; return 1
    fi
    [ -s "$out" ] || { printf 'ERROR: download produced empty file: %s\n' "$out" >&2; return 1; }
}

# ------------------------------------------------------- resolve artifact
RESOLVED_FILE=""
resolve_choice() { # "sdk"|"runtime"|local path|url
    arg="$1"
    case "$arg" in
        sdk)
            repo="sdk-ohos"; tag="v11.0.100-rc.1.26451.109-ohos"; file="dotnet-sdk-11.0.100-rc.1.26451.109-openharmony-arm64.tar.gz"
            RESOLVED_FILE="$file"
            RESOLVED_URL="https://github.com/${GH_USER}/${repo}/releases/download/${tag}/${file}"
            ;;
        runtime)
            repo="runtime-ohos"; tag="v11.0.0-rc.1.26451.109-ohos"; file="dotnet-runtime-11.0.0-rc.1.26451.109-openharmony-arm64.tar.gz"
            RESOLVED_FILE="$file"
            RESOLVED_URL="https://github.com/${GH_USER}/${repo}/releases/download/${tag}/${file}"
            ;;
        http://*|https://*)
            RESOLVED_FILE="$(basename "$arg")"
            RESOLVED_URL="$arg"
            ;;
        *)
            [ -r "$arg" ] || die "tarball not readable: ${arg}
  (on OpenHarmony, files inside another app's sandbox — e.g. WeChat appdata — cannot
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

# ------------------------------------------------------------------ selfsign
# Deploy the device-side selfsign (NativeAOT single-file, C# AOT) next to
# dotnet/dnx in the install root so it is the preferred signer:
#   - $INSTALL_DIR is on PATH (setup_profile) -> `selfsign` resolves directly
#   - sign_all() picks it up automatically (it is an ELF under $INSTALL_DIR)
# Falls back gracefully: offline installs or missing release assets simply
# leave selfsign absent and binary-sign-tool is used instead.
# The selfsign asset lives in the sdk-ohos release, same tag as the SDK.
SDK_TAG="$(printf '%s\n' "$RELEASES" | sed -n 's/^ *sdk|sdk-ohos|\([^|]*\)|.*/\1/p' | head -n 1)"
SELFSIGN_URL="https://github.com/springmin/sdk-ohos/releases/download/${SDK_TAG}/selfsign-ohos-arm64"
deploy_selfsign() {
    [ -x "${INSTALL_DIR}/selfsign" ] && { info "selfsign already at ${INSTALL_DIR}/selfsign"; return 0; }
    TMP="${TMPDIR:-/tmp}/selfsign-ohos-$$"
    if ! download "$SELFSIGN_URL" "$TMP" 2>/dev/null; then
        rm -f "$TMP"
        warn_echo "  WARN: selfsign download failed (offline?); will use binary-sign-tool if present"
        return 1
    fi
    if ! file "$TMP" 2>/dev/null | grep -q "ELF"; then
        rm -f "$TMP"
        warn_echo "  WARN: downloaded selfsign is not an ELF (release asset missing?); using binary-sign-tool if present"
        return 1
    fi
    mv -f "$TMP" "${INSTALL_DIR}/selfsign" || { rm -f "$TMP"; return 1; }
    chmod +x "${INSTALL_DIR}/selfsign"
    info "deployed selfsign -> ${INSTALL_DIR}/selfsign (preferred signer, parallel to dotnet/dnx)"
    # The just-deployed selfsign must itself carry .codesign before it can exec
    # (unsigned ELF -> EACCES). Prefer a pre-signed release asset; otherwise
    # bootstrap it with binary-sign-tool. If neither holds, remove it so
    # sign_all() does not try to sign the whole tree with an un-runnable
    # selfsign (that would fail every file and abort the install).
    if ! has_codesign "${INSTALL_DIR}/selfsign"; then
        if [ -n "$SIGN_TOOL" ]; then
            "$SIGN_TOOL" sign -inFile "${INSTALL_DIR}/selfsign" -outFile "${INSTALL_DIR}/selfsign" -selfSign 1 >/dev/null 2>&1 \
                && info "  bootstrapped .codesign on selfsign via binary-sign-tool" \
                || warn_echo "  WARN: could not bootstrap selfsign signature with binary-sign-tool"
        fi
        if ! has_codesign "${INSTALL_DIR}/selfsign"; then
            warn_echo "  WARN: deployed selfsign is unsigned and cannot be bootstrapped; removing it and falling back to binary-sign-tool"
            rm -f "${INSTALL_DIR}/selfsign"
        fi
    fi
}

# ------------------------------------------------------------------ cxx runtime
# The NativeAOT toolchain (ilc) links GNU libstdc++.so.6 + libgcc_s.so.1 which the
# device (HarmonyOS) does not ship (it only has LLVM libc++). The ILCompiler pack
# carries both under its tools/ dir; deploy them to a location the dynamic loader
# finds (system /lib when writable, else $INSTALL_DIR/lib + LD_LIBRARY_PATH).
deploy_cxx_runtime() {
    # find libstdc++/libgcc shipped anywhere in the install (ILCompiler pack tools/)
    STDCPP=""
    LIBGCC=""
    while IFS= read -r f; do
        case "$f" in
            *libstdc++.so.6) STDCPP="$f" ;;
            *libgcc_s.so.1)  LIBGCC="$f" ;;
        esac
    done <<EOF
$(find "$INSTALL_DIR" -name 'libstdc++.so.6' -o -name 'libgcc_s.so.1' 2>/dev/null)
EOF
    [ -n "$STDCPP" ] || { info "no libstdc++/libgcc found in install (ILCompiler pack not present)"; return 0; }

    info "deploying C++ runtime for device-side NativeAOT (ilc)"
    if [ -w /lib ]; then
        cp -f "$STDCPP" /lib/libstdc++.so.6 && cp -f "$LIBGCC" /lib/libgcc_s.so.1 \
            && info "  installed libstdc++.so.6 + libgcc_s.so.1 -> /lib" \
            || warn_echo "  WARN: could not write /lib; falling back to \$INSTALL_DIR/lib"
    fi
    if [ ! -f /lib/libstdc++.so.6 ]; then
        mkdir -p "$INSTALL_DIR/lib"
        cp -f "$STDCPP" "$INSTALL_DIR/lib/libstdc++.so.6"
        cp -f "$LIBGCC" "$INSTALL_DIR/lib/libgcc_s.so.1"
         info "  installed to \$INSTALL_DIR/lib (add to LD_LIBRARY_PATH if ilc still can't load)"
    fi
}
warn_echo() { printf '%s\n' "$*" >&2; }

# ------------------------------------------------------------------ hostpolicy
# CoreCLR-based tools without a runtimeconfig (e.g. the single-file ilc) resolve
# as self-contained and look for libhostpolicy.so at the DOTNET_ROOT root; the
# shared-framework layout keeps it under shared/Microsoft.NETCore.App/<ver>/,
# which the root lookup misses (device FAIL exit 131, round-15). Mirror the
# Linux SDK behavior by making it reachable from the install root.
deploy_hostpolicy() {
    HP=""
    while IFS= read -r f; do
        case "$f" in
            *shared/Microsoft.NETCore.App/*/libhostpolicy.so) HP="$f"; break ;;
        esac
    done <<EOF
$(find "$INSTALL_DIR" -name 'libhostpolicy.so' 2>/dev/null)
EOF
    [ -n "$HP" ] || { info "no libhostpolicy.so found (runtime/SDK shared framework absent)"; return 0; }
    if [ ! -f "$INSTALL_DIR/libhostpolicy.so" ]; then
        cp -f "$HP" "$INSTALL_DIR/libhostpolicy.so" \
            && info "deployed libhostpolicy.so -> $INSTALL_DIR/ (DOTNET_ROOT hostpolicy resolution)" \
            || warn_echo "  WARN: could not deploy libhostpolicy.so"
    else
        info "libhostpolicy.so already at $INSTALL_DIR/"
    fi
}

sign_all() {
    info "signing ELF binaries (.codesign) ..."
    CNTFILE="${TMPDIR:-/tmp}/dotnet-sign-cnt.$$"
    printf '0 0 0\n' > "$CNTFILE"
    find "$INSTALL_DIR" -type f 2>/dev/null | while IFS= read -r f; do
        file "$f" 2>/dev/null | grep -q "ELF" || continue
        read -r s k d < "$CNTFILE"
        # Re-sign unconditionally: shipped signatures may be from older
        # tooling and rejected by the device (EPERM). selfsign --force
        # rewrites them with the current algorithm.
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

# .NET (OpenHarmony install)
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
deploy_cxx_runtime
deploy_hostpolicy

# NativeAOT tools (selfsign) link GNU libstdc++/libgcc which, when /lib is not
# writable, live in $INSTALL_DIR/lib (see deploy_cxx_runtime). Make them
# findable for the signing pass below.
if [ -d "${INSTALL_DIR}/lib" ]; then
    export LD_LIBRARY_PATH="${INSTALL_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

# sign tools: selfsign preferred, binary-sign-tool fallback.
# Probe binary-sign-tool first so deploy_selfsign can bootstrap with it;
# SELFSIGN is resolved after deployment (deployed copy wins over PATH).
SIGN_TOOL="$(find_binary_sign_tool || true)"
if [ -n "$SIGN_TOOL" ]; then
    info "found binary-sign-tool: ${SIGN_TOOL} (fallback signer)"
fi
deploy_selfsign
SELFSIGN="$(find_selfsign || true)"
if [ -n "$SELFSIGN" ]; then
    info "using selfsign: ${SELFSIGN} (preferred signer)"
elif [ -n "$SIGN_TOOL" ]; then
    info "using binary-sign-tool: ${SIGN_TOOL}"
else
    die "no signing tool available: selfsign download failed and binary-sign-tool not found. Install harmonybrew/OHOS SDK or place selfsign on PATH (see selfsign.cs in this directory)"
fi

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
