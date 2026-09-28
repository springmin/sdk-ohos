# ============================================================================
# ohos-sign-common.sh — pre-package ELF signing helpers (sourced fragment).
#
# Shared by build-ohos-all.sh (stages 1+3 sign the runtime/aspnetcore packs)
# and pack-sdk.sh (stage 4 signs the SDK shipping tarball), so the signing
# implementation exists exactly once. Sourced with `set -euo pipefail` active;
# no side effects at source time. The caller must define info()/die() and
# provide SCRIPT_DIR (the build/ directory holding sign-ohos-pre.py), WORK,
# SDK_REPO and RUNTIME_REPO (DOTNET is an optional override).
# ============================================================================

# sign every ELF inside a .nupkg (OpenHarmony .codesign) — idempotent (skips signed)
ensure_selfsign() {
  local selfsign="$WORK/selfsign"
  if [ ! -x "$selfsign" ]; then
    info "building selfsign (sdk eng/ohos-install)..."
    local dotnet_bin="${DOTNET:-$RUNTIME_REPO/.dotnet/dotnet}"
    (cd "$SDK_REPO/eng/ohos-install" && \
      "$dotnet_bin" publish selfsign.csproj -c Release -r linux-x64 -p:PublishAot=true \
        -o "$WORK/selfsign-out") 2>&1 | tail -1 || die "selfsign build failed"
    cp -f "$WORK/selfsign-out/selfsign" "$selfsign" && chmod +x "$selfsign"
  fi
  SELFSIGN_BIN="$selfsign"
}

# sign every ELF in the given nupkg/tar.gz/dir (device needs .codesign on all
# loaded ELF). Moved from install-dotnet-ohos.sh sign_all() to pre-package time.
sign_all() {
  ensure_selfsign
  python3 "$SCRIPT_DIR/sign-ohos-pre.py" "$SELFSIGN_BIN" "$@" || die "signing failed"
}
