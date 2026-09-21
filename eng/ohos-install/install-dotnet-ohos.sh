#!/bin/sh
# ============================================================================
# install-dotnet-ohos.sh
# Install .NET (SDK or Runtime) on OpenHarmony from GitHub release artifacts
#
# Downloads from the ${GH_USER}/{sdk,runtime,aspnetcore}-ohos GitHub releases
# (version pins in versions.env; a local tar.gz or URL also works), extracts
# into $HOME/.dotnet, code-signs every ELF with a .codesign section, and
# persists DOTNET_ROOT/PATH.
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
# Verification (C2): every downloaded artifact (selfsign binary, SDK/runtime
# tarball, workload bundle) is sha256-verified before it is extracted or
# executed; downloads land in a mktemp file and only move into place after the
# digest matches. The expected digest comes from, in order:
#   1) an explicit env pin:
#        SELFSIGN_SHA256   selfsign-ohos-arm64
#        TARBALL_SHA256    the sdk/runtime tarball (also local-file installs)
#        WORKLOAD_SHA256   the workload bundle
#   2) a SHA256SUMS sibling asset in the same GitHub release
#   3) a <asset>.sha256 sibling asset in the same release
#   4) the GitHub release-asset digest (sha256) of that release
# When no digest resolves the artifact is refused. ALLOW_UNVERIFIED=1 bypasses
# that (insecure; offline/legacy installs only) and prints a warning.
# Local tarballs are verified against <file>.sha256 or TARBALL_SHA256 and are
# refused without one unless ALLOW_UNVERIFIED=1. A cached rolling workload
# bundle is re-verified before reuse and discarded when it cannot be.
# Release publishers should upload SHA256SUMS next to the artifacts (the
# ohos-full-build workflow does this for new releases).
#
# Idempotent: safe to re-run (re-extract, re-sign, profile entries deduped).
# ============================================================================

set -u

# ------------------------------------------------------------------ config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Version pins (release tags, asset names, GH account) live in versions.env.
# shellcheck source=versions.env
if [ ! -f "$SCRIPT_DIR/versions.env" ]; then
    printf 'ERROR: missing %s (run this script from the sdk-ohos repository)\n' \
        "$SCRIPT_DIR/versions.env" >&2
    exit 1
fi
. "$SCRIPT_DIR/versions.env"

# Release assets: <short-name>|<repo>|<release-tag>|<asset-file>. Short names
# "sdk"/"runtime" resolve through this table; asset names derive from the
# version pins in versions.env.
RELEASES="
  sdk|sdk-ohos|v${SDK_VERSION}-ohos|dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz
  runtime|runtime-ohos|v${RT_VERSION}-ohos|dotnet-runtime-${RT_VERSION}-${RID}.tar.gz
"
# aspnetcore runtime is embedded in the SDK since 2026-08-26; kept here for
# standalone runtime installs that also want ASP.NET Core.
ASPNETCORE_REPO="aspnetcore-ohos"
ASPNETCORE_TAG="v${RT_VERSION}-ohos"
ASPNETCORE_FILE="aspnetcore-runtime-${RT_VERSION}-${RID}.tar.gz"

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.dotnet}"
# Explicit opt-out from download verification (insecure; offline/legacy only).
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-0}"

# OpenHarmony platform workload (${TFM}-openharmony<api>). Ships as a bundle
# (ohos-workload-<version>.tar.gz: manifests/ + feed/ + install-ohos-workload.sh)
# next to the SDK tarball. INSTALL_WORKLOAD=0 disables the step; WORKLOAD_BUNDLE
# points at a local bundle (directory or tarball); WORKLOAD_RELEASE_TAG selects the
# release whose assets are searched for the bundle.

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
        "${HOME}/.harmonybrew/Cellar/ohos-sdk/"*/bin/binary-sign-tool
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

# ---------------------------------------------------------- verification (C2)
# sha256 + expected-digest helpers; see the Verification section in the header.
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

verify_sha256() { # <file> <expected-hex> <what>
    VF_FILE="$1"; VF_WANT="$2"; VF_WHAT="$3"
    if [ -z "$VF_WANT" ]; then
        printf 'ERROR: no sha256 to verify %s against\n' "$VF_WHAT" >&2
        return 1
    fi
    VF_GOT="$(sha256_of "$VF_FILE")" || {
        printf 'ERROR: no sha256 tool (sha256sum/shasum/openssl) to verify %s\n' "$VF_WHAT" >&2
        return 1
    }
    VF_WANT="$(printf '%s' "$VF_WANT" | tr 'A-F' 'a-f')"
    if [ "$VF_GOT" != "$VF_WANT" ]; then
        printf 'ERROR: sha256 mismatch for %s\n  expected: %s\n  actual:   %s\n' \
            "$VF_WHAT" "$VF_WANT" "$VF_GOT" >&2
        return 1
    fi
    info "sha256 OK: ${VF_WHAT}"
    return 0
}

fetch_text() { # <url> -> stdout; nonzero when unreachable
    FETCH_TMP="$(mktemp "${TMPDIR:-/tmp}/dotnet-sha.XXXXXX")" || return 1
    if download "$1" "$FETCH_TMP" >/dev/null 2>&1; then
        cat "$FETCH_TMP"; rm -f "$FETCH_TMP"; return 0
    fi
    rm -f "$FETCH_TMP"; return 1
}

resolve_expected_sha256() { # <url> <asset-name> -> hex or empty
    RE_URL="$1"; RE_NAME="$2"
    # 1) SHA256SUMS sibling in the same release
    if RE_TXT="$(fetch_text "${RE_URL%/*}/SHA256SUMS")"; then
        RE_SHA="$(printf '%s\n' "$RE_TXT" | awk -v a="$RE_NAME" '$NF == a || $NF == "*" a { print $1; exit }')"
        RE_SHA="$(printf '%s' "$RE_SHA" | grep -oE '^[0-9a-fA-F]{64}$' || true)"
        if [ -n "$RE_SHA" ]; then printf '%s' "$RE_SHA" | tr 'A-F' 'a-f'; return 0; fi
    fi
    # 2) <url>.sha256 sibling
    if RE_TXT="$(fetch_text "${RE_URL}.sha256")"; then
        RE_SHA="$(printf '%s\n' "$RE_TXT" | grep -oE '[0-9a-fA-F]{64}' | head -1 || true)"
        if [ -n "$RE_SHA" ]; then printf '%s' "$RE_SHA" | tr 'A-F' 'a-f'; return 0; fi
    fi
    # 3) GitHub API release-asset digest (same-release trust, like SHA256SUMS)
    case "$RE_URL" in
        https://github.com/*/releases/download/*)
            RE_REST="${RE_URL#https://github.com/}"
            RE_OWNER="${RE_REST%%/*}"; RE_REST="${RE_REST#*/}"
            RE_REPO="${RE_REST%%/*}"; RE_REST="${RE_REST#*/}"
            RE_REST="${RE_REST#releases/download/}"; RE_TAG="${RE_REST%%/*}"
            RE_TXT="$(fetch_text "https://api.github.com/repos/${RE_OWNER}/${RE_REPO}/releases/tags/${RE_TAG}")" || return 1
            printf '%s\n' "$RE_TXT" | awk -v want="$RE_NAME" '
                /"name": / { hit = (index($0, "\"name\": \"" want "\"") > 0) ? 1 : 0; next }
                hit && /"digest": "sha256:/ { s = $0; sub(/.*"digest": "sha256:/, "", s); sub(/".*/, "", s); print s; exit }'
            return 0
            ;;
    esac
    return 1
}

download_verified() { # <url> <out> <what> [expected-sha256]
    DV_URL="$1"; DV_OUT="$2"; DV_WHAT="$3"; DV_SHA="${4:-}"
    DV_TMP="$(mktemp "${TMPDIR:-/tmp}/dotnet-dl.XXXXXX")" || {
        printf 'ERROR: mktemp failed for %s\n' "$DV_WHAT" >&2; return 1
    }
    if ! download "$DV_URL" "$DV_TMP"; then
        rm -f "$DV_TMP"
        printf 'ERROR: download failed: %s\n' "$DV_URL" >&2
        return 1
    fi
    if [ -z "$DV_SHA" ]; then
        DV_SHA="$(resolve_expected_sha256 "$DV_URL" "$(basename "$DV_URL")")" || DV_SHA=""
    fi
    if [ -z "$DV_SHA" ]; then
        if [ "$ALLOW_UNVERIFIED" = "1" ]; then
            warn_echo "WARN: ALLOW_UNVERIFIED=1 — accepting unverified ${DV_WHAT}"
        else
            rm -f "$DV_TMP"
            printf 'ERROR: no sha256 available for %s\n  refusing unverified download: %s\n  Set the matching *_SHA256 pin (see script header) or ALLOW_UNVERIFIED=1 (insecure).\n' \
                "$DV_WHAT" "$DV_URL" >&2
            return 1
        fi
    else
        verify_sha256 "$DV_TMP" "$DV_SHA" "$DV_WHAT" || { rm -f "$DV_TMP"; return 1; }
    fi
    mv -f "$DV_TMP" "$DV_OUT" || { rm -f "$DV_TMP"; return 1; }
    return 0
}

verify_local_file() { # <file> <pin> <what-prefix> -> 0 verified/opted-out, 1 unavailable
    LF_FILE="$1"; LF_PIN="${2:-}"; LF_WHAT="$3"
    if [ -z "$LF_PIN" ] && [ -f "${LF_FILE}.sha256" ]; then
        LF_PIN="$(grep -oE '[0-9a-fA-F]{64}' "${LF_FILE}.sha256" | head -1 || true)"
    fi
    if [ -z "$LF_PIN" ]; then
        if [ "$ALLOW_UNVERIFIED" = "1" ]; then
            warn_echo "WARN: ALLOW_UNVERIFIED=1 — accepting unverified ${LF_WHAT}"
            return 0
        fi
        printf 'ERROR: no sha256 for %s\n  add %s.sha256, or set the matching *_SHA256 pin, or ALLOW_UNVERIFIED=1 (insecure)\n' \
            "$LF_WHAT" "$LF_FILE" >&2
        return 1
    fi
    verify_sha256 "$LF_FILE" "$LF_PIN" "$LF_WHAT"
}

# ------------------------------------------------------- resolve artifact
RESOLVED_FILE=""
resolve_choice() { # "sdk"|"runtime"|local path|url
    arg="$1"
    case "$arg" in
        sdk)
            repo="sdk-ohos"; tag="v${SDK_VERSION}-ohos"; file="dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz"
            RESOLVED_FILE="$file"
            RESOLVED_URL="https://github.com/${GH_USER}/${repo}/releases/download/${tag}/${file}"
            ;;
        runtime)
            repo="runtime-ohos"; tag="v${RT_VERSION}-ohos"; file="dotnet-runtime-${RT_VERSION}-${RID}.tar.gz"
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
   be read; move the file to a readable location such as the Download folder first)"
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
SELFSIGN_URL="https://github.com/${GH_USER}/sdk-ohos/releases/download/${SDK_TAG}/${SELFSIGN_ASSET}"
deploy_selfsign() {
    [ -x "${INSTALL_DIR}/selfsign" ] && { info "selfsign already at ${INSTALL_DIR}/selfsign"; return 0; }
    SELFSIGN_TMP="$(mktemp "${TMPDIR:-/tmp}/selfsign-ohos.XXXXXX")" || {
        warn_echo "  WARN: mktemp failed; cannot download selfsign"
        return 1
    }
    if ! download_verified "$SELFSIGN_URL" "$SELFSIGN_TMP" "selfsign (${SELFSIGN_ASSET})" "${SELFSIGN_SHA256:-}"; then
        rm -f "$SELFSIGN_TMP"
        warn_echo "  WARN: selfsign download/verification failed (offline or no sha256?); will use binary-sign-tool if present"
        return 1
    fi
    if ! file "$SELFSIGN_TMP" 2>/dev/null | grep -q "ELF"; then
        rm -f "$SELFSIGN_TMP"
        warn_echo "  WARN: downloaded selfsign is not an ELF (release asset missing?); using binary-sign-tool if present"
        return 1
    fi
    mv -f "$SELFSIGN_TMP" "${INSTALL_DIR}/selfsign" || { rm -f "$SELFSIGN_TMP"; return 1; }
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

# -------------------------------------------------------------- workload
# Installs the OpenHarmony platform workload so that ${TFM}-openharmony<api>
# projects build without DOTNETSDK_WORKLOAD_* environment variables.
install_workload() {
    [ "${INSTALL_WORKLOAD:-1}" = "1" ] || { info "workload install skipped (INSTALL_WORKLOAD=0)"; return 0; }
    [ -x "${INSTALL_DIR}/dotnet" ] || { info "no dotnet in ${INSTALL_DIR}; skipping the workload"; return 0; }

    bundle="${WORKLOAD_BUNDLE:-}"
    tmp=""
    tb=""
    asset=""
    rel_tag=""
    if [ -z "$bundle" ]; then
        # a bundle installed next to the SDK (or shipped with it); a local bundle
        # is only used after verification via <file>.sha256 / WORKLOAD_SHA256
        for pat in openharmony-workload ohos-workload; do
            [ -n "$tb" ] && break
            tb="$(ls "${INSTALL_DIR}"/workload/"$pat"-*.tar.gz 2>/dev/null | tail -1 || true)"
            if [ -z "$tb" ]; then
                tb="$(ls "${SCRIPT_DIR}"/"$pat"-*.tar.gz 2>/dev/null | tail -1 || true)"
            fi
            if [ -n "$tb" ]; then
                if [ -f "${tb}.sha256" ] || [ -n "${WORKLOAD_SHA256:-}" ] || [ "$ALLOW_UNVERIFIED" = "1" ]; then
                    verify_local_file "$tb" "${WORKLOAD_SHA256:-}" "workload bundle $(basename "$tb")" || tb=""
                else
                    info "ignoring local workload bundle without checksum: $tb"
                    tb=""
                fi
            fi
        done
        if [ -z "$tb" ]; then
            # Rolling release with a stable asset name: no GitHub API needed (works without
            # gh and avoids anonymous rate limits). Cached for 7 days and re-verified
            # against its published digest before reuse.
            latest_url="https://github.com/${GH_USER}/sdk-ohos/releases/download/workload-latest/openharmony-workload-latest.tar.gz"
            latest_tb="${INSTALL_DIR}/workload/openharmony-workload-latest.tar.gz"
            if [ -f "$latest_tb" ]; then
                latest_sha="${WORKLOAD_SHA256:-}"
                if [ -z "$latest_sha" ]; then latest_sha="$(resolve_expected_sha256 "$latest_url" "openharmony-workload-latest.tar.gz")" || latest_sha=""; fi
                if [ -z "$latest_sha" ] || ! verify_sha256 "$latest_tb" "$latest_sha" "cached workload bundle"; then
                    info "dropping cached workload bundle (no verifiable checksum)"
                    rm -f "$latest_tb"
                fi
            fi
            if [ ! -f "$latest_tb" ] || [ -n "$(find "$latest_tb" -mtime +7 2>/dev/null)" ]; then
                mkdir -p "${INSTALL_DIR}/workload"
                if curl -fsIL --connect-timeout 20 "$latest_url" >/dev/null 2>&1; then
                    download_verified "$latest_url" "$latest_tb" "workload bundle (workload-latest)" "${WORKLOAD_SHA256:-}" \
                        || rm -f "$latest_tb"
                fi
            fi
            [ -f "$latest_tb" ] && tb="$latest_tb"
        fi
        if [ -z "$tb" ]; then
            # Look for a published bundle: an explicit workload release first, then the
            # newest workload-* release (the workload has its own version line), then the
            # release the SDK came from. A versioned workload release is a plain GitHub
            # release hosting openharmony-workload-<version>.tar.gz.
            wtags=""
            [ -n "${WORKLOAD_RELEASE_TAG:-}" ] && wtags="$WORKLOAD_RELEASE_TAG"
            if [ -z "$wtags" ]; then
                wtags="$(curl -fsSL "https://api.github.com/repos/${GH_USER}/sdk-ohos/releases?per_page=50" 2>/dev/null \
                         | grep -o '"tag_name": *"workload-[^"]*"' | head -1 \
                         | sed -E 's/.*"(workload-[^"]*)".*/\1/' || true)"
            fi
            sdk_tag="$(printf '%s' "${RESOLVED_URL:-}" | sed -nE 's|.*/releases/download/([^/]+)/.*|\1|p')"
            sdk_tag="${sdk_tag:-v${SDK_VERSION}-ohos}"
            wtags="$wtags $sdk_tag"
            for tag in $wtags; do
                [ -n "$asset" ] && break
                assets="$(curl -fsSL "https://api.github.com/repos/${GH_USER}/sdk-ohos/releases/tags/${tag}" 2>/dev/null || true)"
                for pat in openharmony-workload ohos-workload; do
                    [ -n "$asset" ] && break
                    asset="$(printf '%s' "$assets" | grep -o '"name": *"'"$pat"'-[^"]*\.tar\.gz"' | head -1 \
                             | sed -E 's/.*"('"$pat"'-[^"]*\.tar\.gz)".*/\1/')"
                    [ -n "$asset" ] && rel_tag="$tag"
                done
            done
            if [ -n "$asset" ]; then
                mkdir -p "${INSTALL_DIR}/workload"
                tb="${INSTALL_DIR}/workload/${asset}"
                wurl="https://github.com/${GH_USER}/sdk-ohos/releases/download/${rel_tag}/${asset}"
                if [ -f "$tb" ]; then
                    wsha="${WORKLOAD_SHA256:-}"
                    if [ -z "$wsha" ]; then wsha="$(resolve_expected_sha256 "$wurl" "$asset")" || wsha=""; fi
                    if [ -z "$wsha" ] || ! verify_sha256 "$tb" "$wsha" "cached workload bundle $asset"; then
                        info "dropping cached workload bundle $asset (no verifiable checksum)"
                        rm -f "$tb"
                    fi
                fi
                if [ ! -f "$tb" ]; then
                    download_verified "$wurl" "$tb" "workload bundle $asset" "${WORKLOAD_SHA256:-}" || tb=""
                fi
            fi
        fi
        if [ -n "$tb" ]; then
            tmp="$(mktemp -d)"
            tar zxf "$tb" -C "$tmp" || { info "WARNING: could not extract $tb"; rm -rf "$tmp"; return 0; }
            bundle="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
        fi
    fi

    if [ -z "$bundle" ]; then
        info "no workload bundle found (set WORKLOAD_BUNDLE=<dir|tar.gz> to install the OpenHarmony workload)"
        return 0
    fi
    if [ -f "$bundle" ]; then
        verify_local_file "$bundle" "${WORKLOAD_SHA256:-}" "workload bundle $(basename "$bundle")" \
            || { info "WARNING: refusing unverified workload bundle $bundle"; return 0; }
        tmp="$(mktemp -d)"
        tar zxf "$bundle" -C "$tmp" || { info "WARNING: could not extract $bundle"; rm -rf "$tmp"; return 0; }
        bundle="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
    fi

    info "installing the OpenHarmony platform workload from ${bundle}"
    dry=""
    [ "${WORKLOAD_DRY_RUN:-0}" = "1" ] && dry="--dry-run"
    if sh "${bundle}/install-ohos-workload.sh" $dry --dotnet "${INSTALL_DIR}/dotnet" "$bundle"; then
        info "workload installed (dotnet workload list)"
    else
        info "WARNING: OpenHarmony workload installation failed (continuing without it)"
    fi
    [ -n "$tmp" ] && rm -rf "$tmp"
    return 0
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
export DOTNET_ROOT=\$HOME/.dotnet
export PATH=\$PATH:\$DOTNET_ROOT:\$DOTNET_ROOT/tools
# OpenHarmony sandbox: /tmp is read-only; the runtime reads TMPDIR via Path.GetTempPath().
export TMPDIR="\${TMPDIR:-\$HOME/.tmp}"
mkdir -p "\$TMPDIR" 2>/dev/null || true
EOF
    info "env vars added to ${pf}"
}

# ------------------------------------------------------------------- main
# prerequisite tools
for tool in tar file readelf mktemp; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# resolve artifact (default: sdk)
ARG="${1:-sdk}"
case "$ARG" in
    workload)
        install_workload
        exit $?
        ;;

    sdk|runtime|http://*|https://*)
        resolve_choice "$ARG"
        ;;
    *)
        resolve_choice "$ARG"
        ;;
esac

TARBALL=""
if [ -n "${RESOLVED_URL:-}" ]; then
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-ohos.XXXXXX")" || die "mktemp -d failed"
    TARBALL="$TMP/$RESOLVED_FILE"
    download_verified "$RESOLVED_URL" "$TARBALL" "tarball $RESOLVED_FILE" "${TARBALL_SHA256:-}" \
        || die "download failed or unverified: ${RESOLVED_URL}
  (set TARBALL_SHA256=<sha256>, or ALLOW_UNVERIFIED=1 to accept unverified — insecure)"
else
    TARBALL="$RESOLVED_FILE"
    verify_local_file "$TARBALL" "${TARBALL_SHA256:-}" "local tarball $(basename "$TARBALL")" \
        || die "refusing unverified local tarball: ${TARBALL}"
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

# ----------------------------------------------------------------- workload
install_workload

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
