#!/bin/sh
# ============================================================================
# postinstall.sh — post-install steps shared by the OpenHarmony installers.
#
# Sourced by install-dotnet-ohos.sh (full device installer) and by
# install-dotnet-from-pins.sh (thin wrapper around the shared dotnet-install.sh).
# Expects INSTALL_DIR to be set; uses info()/warn_echo() when available.
# ============================================================================

set -u

if ! command -v info >/dev/null 2>&1; then
    info() { printf '==> %s\n' "$*"; }
fi
if ! command -v warn_echo >/dev/null 2>&1; then
    warn_echo() { printf '%s\n' "$*" >&2; }
fi

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
    # Read the 4-byte ELF magic directly. The host `file` utility can hang on
    # OpenHarmony filesystems (and is not guaranteed to exist on device).
    ELF_MAGIC="$(printf '\177ELF')"
    find "$INSTALL_DIR" -type f 2>/dev/null | while IFS= read -r f; do
        [ "$(head -c 4 "$f" 2>/dev/null)" = "$ELF_MAGIC" ] || continue
        # Never re-sign the preferred signer itself: when selfsign is used it
        # lives in $INSTALL_DIR, and this loop would invoke it on its own file -
        # the in-place rewrite of a running executable fails (ETXTBSY), which
        # makes sign_all die on the shipped selfsign asset.
        if [ -n "$SELFSIGN" ] && [ "$f" = "$SELFSIGN" ]; then
            read -r s k d < "$CNTFILE"
            printf '%d %d %d\n' "$s" "$((k + 1))" "$d" > "$CNTFILE"
            continue
        fi
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
    root="${2:-$INSTALL_DIR}"
    [ -f "$pf" ] || return 0
    if grep -q 'export DOTNET_ROOT=' "$pf" 2>/dev/null; then
        grep -q 'export TMPDIR=' "$pf" 2>/dev/null || cat >> "$pf" <<EOF

# OpenHarmony sandbox: /tmp is read-only; the runtime reads TMPDIR via Path.GetTempPath().
export TMPDIR="\${TMPDIR:-\$HOME/.tmp}"
mkdir -p "\$TMPDIR" 2>/dev/null || true
EOF
        return 0
    fi
    cat >> "$pf" <<EOF

# .NET (OpenHarmony install)
export DOTNET_ROOT=$root
export PATH=\$PATH:\$DOTNET_ROOT:\$DOTNET_ROOT/tools
# OpenHarmony sandbox: /tmp is read-only; the runtime reads TMPDIR via Path.GetTempPath().
export TMPDIR="\${TMPDIR:-\$HOME/.tmp}"
mkdir -p "\$TMPDIR" 2>/dev/null || true
EOF
    info "env vars added to ${pf}"
}
