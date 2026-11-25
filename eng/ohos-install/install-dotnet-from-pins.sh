#!/bin/sh
# ============================================================================
# install-dotnet-from-pins.sh — install the SDK/runtime pinned in versions.env
# using the shared dotnet-install.sh (vendored under eng/ohos-install/vendor).
#
# This is the thin-wrapper entry point for the versions.env flow. The full
# device installer (install-dotnet-ohos.sh) keeps the interactive artifact
# picker and the automatic workload-release resolution; both share the download,
# verification, extraction, signing and post-install steps.
#
# Usage:
#   sh eng/ohos-install/install-dotnet-from-pins.sh [sdk|runtime]
#
# Environment:
#   INSTALL_DIR          install root (default: $HOME/.dotnet)
#   SDK_TARBALL_URL      override the release URL (mirror or file://)
#   SDK_TARBALL_SHA256   pinned digest (required unless ALLOW_UNVERIFIED=1)
#   SIGN_MODE            auto (default) / none / tool
#   WORKLOAD_BUNDLE      optional workload bundle path or URL
#   INSTALL_WORKLOAD=0   skip the workload even when WORKLOAD_BUNDLE is set
#   ALLOW_UNVERIFIED=1   accept an unpinned tarball (insecure)
#   DOTNET_INSTALL_SH    use another dotnet-install.sh instead of the vendored copy
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# OHOS_VERSIONS_ENV points at another pin file (tests, alternate release lines).
VERSIONS_ENV="${OHOS_VERSIONS_ENV:-$SCRIPT_DIR/versions.env}"
# shellcheck source=versions.env
if [ ! -f "$VERSIONS_ENV" ]; then
    printf 'ERROR: missing %s (run this script from the sdk-ohos repository)\n' \
        "$VERSIONS_ENV" >&2
    exit 1
fi
. "$VERSIONS_ENV"

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ARG="${1:-sdk}"
case "$ARG" in
    sdk)
        VERSION="${SDK_VERSION}"
        SHA="${SDK_TARBALL_SHA256:-}"
        DEFAULT_FILE="dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz"
        DEFAULT_TAG="v${SDK_VERSION}-ohos"
        ;;
    runtime)
        VERSION="${RT_VERSION}"
        SHA="${RUNTIME_TARBALL_SHA256:-}"
        DEFAULT_FILE="dotnet-runtime-${RT_VERSION}-${RID}.tar.gz"
        DEFAULT_TAG="v${RT_VERSION}-ohos"
        ;;
    *)
        die "usage: sh $0 [sdk|runtime]"
        ;;
esac

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.dotnet}"
SIGN_MODE="${SIGN_MODE:-auto}"
URL="${SDK_TARBALL_URL:-https://github.com/${GH_USER}/${ARG}-ohos/releases/download/${DEFAULT_TAG}/${DEFAULT_FILE}}"

if [ -z "$SHA" ] && [ "${ALLOW_UNVERIFIED:-0}" != "1" ]; then
    die "no pinned SHA-256 for ${ARG} ${VERSION}; refusing an unverified install
  set ALLOW_UNVERIFIED=1 only for local experiments"
fi

SHARED="${DOTNET_INSTALL_SH:-$SCRIPT_DIR/vendor/dotnet-install-ohos.sh}"
[ -x "$SHARED" ] || [ -f "$SHARED" ] || die "shared installer not found: ${SHARED}"
[ -f "$SHARED" ] || die "shared installer is not a file: ${SHARED}"

info "installing ${ARG} ${VERSION} from ${URL}"
set -- --url "$URL" --version "$VERSION" --install-dir "$INSTALL_DIR" --sign "$SIGN_MODE"
if [ -n "$SHA" ]; then
    set -- "$@" --sha256 "$SHA"
fi
if [ "${ALLOW_UNVERIFIED:-0}" = "1" ]; then
    set -- "$@" --allow-unverified
fi
if [ -n "${WORKLOAD_BUNDLE:-}" ] && [ "${INSTALL_WORKLOAD:-1}" != "0" ]; then
    set -- "$@" --workload-bundle "$WORKLOAD_BUNDLE"
else
    info "workload not bundled in this invocation; run 'dotnet workload install openharmony' or use install-dotnet-ohos.sh for automatic resolution"
fi

sh "$SHARED" "$@" || die "shared installer failed"

# ------------------------------------------------------------------ post-install
# Same steps as install-dotnet-ohos.sh: C++ runtime for device-side NativeAOT,
# libhostpolicy at the install root, and DOTNET_ROOT/PATH/TMPDIR in the profiles.
# shellcheck source=postinstall.sh
. "$SCRIPT_DIR/postinstall.sh"

export INSTALL_DIR
deploy_cxx_runtime
deploy_hostpolicy
for pf in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
    setup_profile "$pf" "$INSTALL_DIR"
done

# ---------------------------------------------------------------------- verify
export DOTNET_ROOT="$INSTALL_DIR"
export PATH="$PATH:$INSTALL_DIR:$INSTALL_DIR/tools"
if [ -x "$INSTALL_DIR/dotnet" ]; then
    "$INSTALL_DIR/dotnet" --list-runtimes || die "dotnet did not start"
    [ "$ARG" = "runtime" ] || "$INSTALL_DIR/dotnet" --list-sdks 2>/dev/null || true
else
    die "dotnet binary not found after install (wrong tarball?)"
fi

info "DONE. .NET installed at ${INSTALL_DIR}"
