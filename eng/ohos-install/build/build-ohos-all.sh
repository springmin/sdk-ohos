#!/usr/bin/env bash
# ============================================================================
# build-ohos-all.sh — Build the complete OpenHarmony .NET product set
# from source in one invocation, mirroring official CI build-leg logic.
#
#   runtime (cross, -os openharmony) ──packs/feed──▶ aspnetcore (App.Runtime) ──▶ sdk (redist)
#
# Official CI has no single pipeline chaining the three repos; they are wired
# by darc/feed version flow. This script reproduces that locally: each repo is
# built with its official build-leg parameters and the intermediate nupkgs /
# runtime tarball are handed over through a local NuGet directory + asset dir.
#
# CI-alignment notes (2026-09-04 audit, docs/plans round-14c):
#  - runtime subset clr+libs+host+packs == official runtime.yml AllSubsets_CoreCLR*
#    cross legs (linux-musl-arm64 etc.); -os openharmony + --cross carry the OpenHarmony sysroot.
#  - ILCompiler packs via clr.aot+packs + explicit NativeAOT.sfxproj == fork plan C.7
#    (DotNetBuildAllRuntimePacks=true would also trigger Mono cross-AOT).
#  - ReadyToRun: the OFFICIAL NuGet crossgen2 compiles the CoreLib and, since
#    2026-09-13, the whole framework (OHOS_FRAMEWORK_R2R=1) with an overlay into
#    the runtime pack + layout + runtime tarball (so the SDK redist's shared
#    framework is R2R too); device-side self-contained + PublishReadyToRun
#    publishes then only compile app assemblies (the SDK skips already-R2R
#    framework dlls). OpenHarmony-only (fork crossgen2_inbuild hangs; no PGO
#    data). Intentional deviation.
#  - aspnetcore: os-name=openharmony passes through (no whitelist); PublishReadyToRun=false
#    + NativeAotSupported=false are OpenHarmony kill switches; PublicBaseURL local server
#    stands in for ci.dot.net feeds. Version overrides replace darc pins.
#  - sdk: no -pack (SDK assemblies stay IL; official R2Rs them) and
#    IncludeAspNetCoreRuntime=false (ASP.NET Core ships in the separate
#    aspnetcore-ohos release) are intentional deviations — full-support =true
#    variant is in sdk docs/plans 12.4.
#  - Pre-package .codesign signing (sign-ohos-pre.py) is OpenHarmony-only (device loads
#    only signed ELF); moved from install-dotnet-ohos.sh sign_all().
#
# Usage:
#   sh build-ohos-all.sh [--arch arm64] [--rid openharmony-arm64] [--config Release]
#                        [--buildid 20260901.1] [--skip-runtime|--skip-aspnetcore|--skip-sdk]
#                        [--stage-only 1|3]        # run only one stage (1=runtime …)
#   sh build-ohos-all.sh --fetch-verified <url> <dest> [sha256]   # CI helper: verify+download, exit
#
# Verification (C6): the stock crossgen2, reference runtime pack and host
# runtime packs are sha256-verified before use. Digests come from explicit pins
# (versions.env, HOST_PACK_SHA256) or the same release (SHA256SUMS / <url>.sha256
# / GitHub release-asset digest). Unverifiable downloads are refused unless
# ALLOW_UNVERIFIED=1 (insecure).
#
# Required env:
#   OHOS_NDK_HOME     OpenHarmony NDK root (e.g. $HOME/hmos-tools/sdk/default/openharmony)
#   RUNTIME_REPO SDK_REPO ASCORE_REPO  (defaults: this sdk checkout plus its sibling
#                                      checkouts runtime-ohos / aspnetcore-ohos)
#   OPENSSL_DIR ICU_DIR                (cross-compiled OpenSSL + ICU for the target)
#
# Version pins (product versions, crossgen2, digests, TFM, asset port) live in
# ../versions.env; exported environment values win over its defaults.
#
# Version flow (keep the three repos on ONE version so feeds resolve):
#   LABEL=rc, PRE=1, OFFICIALBUILDID=<id>  →  11.0.0-rc.1.<yyMMdd>.<id>
#   sdk uses the SDK band (100 vs runtime 0) via its own build.
# ============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
# Version pins come from ../versions.env (sourced below); exported environment
# values still win over its defaults.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="$SCRIPT_DIR/../versions.env"
if [ ! -f "$VERSIONS_ENV" ]; then
  echo "ERROR: missing $VERSIONS_ENV (run this script from the sdk-ohos repository)" >&2
  exit 1
fi
# shellcheck source=../versions.env
. "$VERSIONS_ENV"

ARCH="${ARCH:-arm64}"
RID="openharmony-${ARCH}"
CONFIG="${CONFIG:-Release}"
LABEL="${LABEL:-rc}"
PRE="${PRE:-1}"
BUILDID="${BUILDID:-$DEFAULT_BUILDID}"
RIDGRAPH_SDKVER="${RIDGRAPH_SDKVER:-$RIDGRAPH_SDK_VERSION}"  # bootstrap SDK whose RID graph carries openharmony
# Defaults: this sdk checkout (SDK_REPO) and its sibling checkouts.
SDK_REPO="${SDK_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
_SIBLING_DIR="$(dirname "$SDK_REPO")"
RUNTIME_REPO="${RUNTIME_REPO:-$_SIBLING_DIR/runtime-ohos}"
ASCORE_REPO="${ASCORE_REPO:-$_SIBLING_DIR/aspnetcore-ohos}"
unset _SIBLING_DIR
# Runtime work dir (feed/assets/log/selfsign/stock tools). Defaults to a
# .work dir under this build/ folder (git-ignored) so a fresh clone can run.
WORK="${WORK:-$(dirname "$SCRIPT_DIR")/.work}"
FEED="$WORK/feed"              # local NuGet directory feed
# Pre-seeded host linux-x64 packs. Everything inside becomes build input, so the
# default lives next to the other build scratch (and must be 0700); the CI
# workflow points HOSTFEED at its workspace and writes a sha256 manifest into it.
HOSTFEED="${HOSTFEED:-$WORK/hostfeed}"
ASSETS="$WORK/assets"          # runtime tarball assets for aspnetcore
LOG="$WORK/build.log"
OHOS_NDK_HOME="${OHOS_NDK_HOME:-}"
OPENSSL_DIR="${OPENSSL_DIR:-/tmp/openssl-ohos/install}"
ICU_DIR="${ICU_DIR:-/tmp/icu-ohos-install}"
# Official crossgen2 used to produce the ReadyToRun CoreLib image. Our fork-built
# crossgen2_inbuild (self-contained, embedded host) hangs at startup on its own
# EventSource/AdvSimd path (see runtime docs/plans round-13); the OFFICIAL NuGet
# crossgen2 compiles the openharmony CoreLib R2R fine (18.9MB, PGO). Matches how the
# official CI's crossgen2 runs against the previously-published host runtime.
STOCK_CROSSGEN2_DIR="$WORK/stock-crossgen2/$STOCK_CROSSGEN2_VERSION"
# sha256 pins for the stock crossgen2 builds in use (see versions.env; the
# dnceng flat2 feed serves immutable package versions). The download is refused
# when the selected version has no pin — add one (or export STOCK_CROSSGEN2_SHA256)
# when the version changes.
STOCK_CROSSGEN2_SHA256="${STOCK_CROSSGEN2_SHA256:-$(stock_crossgen2_sha256 "$STOCK_CROSSGEN2_VERSION")}"
# Reference runtime pack: metadata + PGO mibc source (the ohos-arm64 R2R-PGO
# build pinned in versions.env). Downloaded on demand, sha256-pinned; a manually
# placed $SCRIPT_DIR/third-party/<asset> still takes precedence.
REFERENCE_RUNTIME_PACK_URL="${REFERENCE_RUNTIME_PACK_URL:-https://github.com/${GH_USER}/runtime-ohos/releases/download/v${REFERENCE_RUNTIME_PACK_VERSION}-ohos/${REFERENCE_RUNTIME_PACK_ASSET}}"
REFERENCE_RUNTIME_PACK=""
# Framework-wide R2R overlay (mac model): 1 = compile all PureIL framework
# assemblies at pack build and overlay them (device SCD+R2R becomes app-only).
OHOS_FRAMEWORK_R2R="${OHOS_FRAMEWORK_R2R:-1}"
# In-tree R2R A/B (Level A): 1 = the CoreCLR.sfxproj R2Rs the framework with the
# in-build crossgen2 (gated by the OpenHarmonyInTreeR2R property in the sfxproj)
# and the out-of-tree runtime framework overlay is skipped. The PGO mibc must be
# seeded before the packs build. Default 0 keeps the shipped overlay path.
OHOS_IN_TREE_R2R="${OHOS_IN_TREE_R2R:-0}"
IN_TREE_R2R_PACK_ARGS=""
if [ "$OHOS_IN_TREE_R2R" = "1" ]; then
  IN_TREE_R2R_PACK_ARGS="/p:OpenHarmonyInTreeR2R=true /p:EnableNgenOptimization=true /p:Crossgen2InBuildDir=$STOCK_CROSSGEN2_DIR/tools/"
fi
R2R_JOBS="${R2R_JOBS:-4}"

RUN_RUNTIME=1; RUN_ASCORE=1; RUN_SDK=1
STAGE_ONLY=""
FETCH_MODE=0; FETCH_URL=""; FETCH_DEST=""; FETCH_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch=*)   ARCH="${1#*=}"; RID="openharmony-$ARCH"; shift ;;
    --rid=*)    RID="${1#*=}"; shift ;;
    --config=*) CONFIG="${1#*=}"; shift ;;
    --buildid=*) BUILDID="${1#*=}"; shift ;;
    --skip-runtime) RUN_RUNTIME=0; shift ;;
    --skip-aspnetcore) RUN_ASCORE=0; shift ;;
    --skip-sdk) RUN_SDK=0; shift ;;
    --stage-only=*) STAGE_ONLY="${1#*=}"; shift ;;
    --fetch-verified)
      # single verified download used by CI: <url> <dest> [sha256]; exit after.
      FETCH_MODE=1; shift
      if [ $# -gt 0 ]; then FETCH_URL="$1"; shift; fi
      if [ $# -gt 0 ]; then FETCH_DEST="$1"; shift; fi
      if [ $# -gt 0 ]; then FETCH_SHA="$1"; shift; fi
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

info() { printf '\n==> %s\n' "$*" | tee -a "$LOG"; }
die()  { printf 'ERROR: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

mkdir -p "$FEED" "$ASSETS" "$WORK"
: > "$LOG"

# ---- 0. environment checks --------------------------------------------------
stage0() {
  info "Stage 0: environment"
  [ -n "$OHOS_NDK_HOME" ] || die "OHOS_NDK_HOME not set"
  for d in "$RUNTIME_REPO" "$SDK_REPO" "$ASCORE_REPO"; do
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || die "repo missing: $d"  # .git file = git worktree
    git -C "$d" status --porcelain | grep -q . && { echo "warn: dirty tree in $d" | tee -a "$LOG"; }
  done
  [ -f "$OPENSSL_DIR/lib/libcrypto.a" ] || die "OpenSSL missing at $OPENSSL_DIR (cross-compiled for $RID)"
  [ -d "$ICU_DIR/lib" ] || die "ICU missing at $ICU_DIR"
  # confirm clean checkout of the latest upstream on each repo
  info "Repos ready: runtime=$(git -C "$RUNTIME_REPO" log --oneline -1 | cut -c1-40)"
}

# ---- download verification (C6) ---------------------------------------------
# Every download goes through fetch_verified(): the digest is either pinned by
# the caller or resolved from the same release (<url>.sha256, SHA256SUMS, or the
# GitHub release-asset digest). Downloads with no resolvable digest are refused
# unless ALLOW_UNVERIFIED=1 is set explicitly (insecure).
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-0}"

github_asset_sha256() { # <owner> <repo> <tag> <asset> -> hex
  local body line v
  body="$(curl -fsSL --retry 2 --connect-timeout 20 --max-time 60 \
      "https://api.github.com/repos/$1/$2/releases/tags/$3" 2>/dev/null)" || return 1
  # The API returns minified JSON: split the asset array on "},{" before
  # matching the asset by name, then pull its sha256 digest (empty when the
  # asset predates GitHub's digest field).
  line="$(printf '%s' "$body" | tr -d ' \n' | sed 's/},{/}\n{/g' \
      | grep -F "\"name\":\"$4\"" | head -n 1 || true)"
  [ -n "$line" ] || return 1
  v="$(printf '%s' "$line" | sed -n 's/.*"digest":"sha256:\([0-9a-f]\{64\}\).*/\1/p')"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

resolve_url_sha256() { # <url> <asset-name> -> hex or empty
  local url="$1" name="$2" dir tmp v rest owner repo tag
  dir="${url%/*}"
  tmp="$(mktemp)" || return 1
  if curl -fsSL --retry 1 --connect-timeout 20 --max-time 60 -o "$tmp" "${url}.sha256" 2>/dev/null; then
    v="$(grep -oE '[0-9a-fA-F]{64}' "$tmp" | head -1 || true)"
    rm -f "$tmp"
    if [ -n "$v" ]; then printf '%s' "$v" | tr 'A-F' 'a-f'; return 0; fi
  else
    rm -f "$tmp"
  fi
  tmp="$(mktemp)" || return 1
  if curl -fsSL --retry 1 --connect-timeout 20 --max-time 60 -o "$tmp" "$dir/SHA256SUMS" 2>/dev/null; then
    v="$(awk -v a="$name" '$NF == a || $NF == "*" a { print $1; exit }' "$tmp")"
    v="$(printf '%s' "$v" | grep -oE '^[0-9a-fA-F]{64}$' || true)"
    rm -f "$tmp"
    if [ -n "$v" ]; then printf '%s' "$v" | tr 'A-F' 'a-f'; return 0; fi
  else
    rm -f "$tmp"
  fi
  case "$url" in
    https://github.com/*/releases/download/*)
      rest="${url#https://github.com/}"
      owner="${rest%%/*}"; rest="${rest#*/}"
      repo="${rest%%/*}"; rest="${rest#*/}"
      rest="${rest#releases/download/}"; tag="${rest%%/*}"
      github_asset_sha256 "$owner" "$repo" "$tag" "$name" && return 0
      ;;
  esac
  return 1
}

# sha256 for immutable package versions on the dnceng flat2 feeds (Azure
# Artifacts rejects re-uploads, so the digest is stable). Measured from the
# feed on 2026-09-21; HOST_PACK_SHA256 env overrides, and a pin must be added
# here (or via the env override) when a new version is selected.
dnceng_pkg_sha256() { # <package-id> <version> -> hex or empty
  case "$1/$2" in
    microsoft.netcore.app.runtime.linux-x64/11.0.0-rc.1.26420.103)
      printf '%s' "9ad5bb3b9b72646c952b583a4a8c6097967aadd3697045e4433e864301285d66" ;;
    *) printf '%s' "" ;;
  esac
}

verify_pinned_nupkg() { # <file> <expected-hex> <what> -> 0 verified
  [ -n "$2" ] || { info "no sha256 pinned for $3"; return 1; }
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || { info "sha256 mismatch for $3: got $got want $2"; return 1; }
  return 0
}

# ---- pre-seeded host packages ($HOSTFEED) -----------------------------------
# $HOSTFEED is writable by other local jobs/users on shared machines, so every
# package taken from it must match an anchored digest before it is copied into
# the local feed or the NuGet global-packages folder (H-C1):
#   HOSTFEED_<ID>_<VER>_SHA256   env pin (dots/dashes -> '_', upper-cased)
#   $HOSTFEED/manifest.sha256    "sha256  <name|relative-path>" lines
# Unknown packages and unpinned files are refused; only the pinned linux-x64
# host runtime packs/crossgen2 packs may be pre-seeded.
hostfeed_pin() { # <id> <ver> -> hex or empty
  local var="HOSTFEED_$(printf '%s' "$1" | tr 'a-z.-' 'A-Z__')_$(printf '%s' "$2" | tr 'a-z.-' 'A-Z__')_SHA256"
  eval "printf '%s' \"\${$var:-}\""
}

hostfeed_manifest_sha256() { # <nupkg> -> hex or empty
  local manifest="$HOSTFEED/manifest.sha256" name rel line sha path
  [ -f "$manifest" ] || return 0
  name="$(basename "$1")"
  rel="${1#"$HOSTFEED"/}"
  while IFS= read -r line; do
    sha="$(printf '%s' "$line" | awk '{print $1}')"
    printf '%s' "$sha" | grep -qE '^[0-9a-fA-F]{64}$' || continue
    path="$(printf '%s' "$line" | awk '{print $NF}')"
    [ "$path" = "$rel" ] || [ "$path" = "$name" ] || [ "$path" = "./$name" ] || continue
    printf '%s' "$sha" | tr 'A-F' 'a-f'
    return 0
  done < "$manifest"
  return 0
}

hostfeed_digest() { # <id> <ver> <nupkg> -> hex or empty
  local pin
  pin="$(hostfeed_pin "$1" "$2")"
  [ -n "$pin" ] || pin="$(hostfeed_manifest_sha256 "$3")"
  printf '%s' "$pin" | tr 'A-F' 'a-f'
}

ingest_hostfeed() {
  [ -d "$HOSTFEED" ] || return 0
  if [ -n "$(find "$HOSTFEED" -maxdepth 0 -perm /022 2>/dev/null)" ]; then
    die "hostfeed $HOSTFEED is group/world writable; chmod 700 it or set HOSTFEED to a private directory"
  fi

  mkdir -p "$FEED"
  local nupkg id ver want got found=0
  while IFS= read -r nupkg; do
    [ -n "$nupkg" ] || continue
    id="$(basename "$(dirname "$(dirname "$nupkg")")")"
    ver="$(basename "$(dirname "$nupkg")")"
    case "$id" in
      microsoft.netcore.app.runtime.linux-x64|microsoft.netcore.app.crossgen2.linux-x64) ;;
      *) die "unexpected package in $HOSTFEED: $nupkg
  only pinned linux-x64 host runtime/crossgen2 packs may be pre-seeded" ;;
    esac

    want="$(hostfeed_digest "$id" "$ver" "$nupkg")"
    if [ -z "$want" ]; then
      die "no digest pinned for hostfeed entry $nupkg
  add HOSTFEED_$(printf '%s_%s' "$id" "$ver" | tr 'a-z.-' 'A-Z__')_SHA256 or a line in $HOSTFEED/manifest.sha256"
    fi

    got="$(sha256sum "$nupkg" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || die "sha256 mismatch for hostfeed entry $nupkg (want $want got $got)"
    cp -f "$nupkg" "$FEED/" || die "could not copy $nupkg into $FEED"
    found=$((found + 1))
    info "hostfeed: verified $(basename "$nupkg")"
  done <<EOF
$(find "$HOSTFEED" -type f -name '*.nupkg' | sort)
EOF
  info "hostfeed: $found verified package(s) mirrored into $FEED"
}

# fetch <url> <dest> <sha256|-> <what>; verifies the digest before moving into place.
fetch_verified() {
  local url="$1" dest="$2" sha="${3:-}" what="$4"
  local tmp="$dest.download.$$"
  local got
  mkdir -p "$(dirname "$dest")"
  if [ -z "$sha" ] || [ "$sha" = "-" ]; then
    sha="$(resolve_url_sha256 "$url" "$(basename "${url%%\?*}")" || true)"
  fi
  if [ -z "$sha" ]; then
    if [ "${ALLOW_UNVERIFIED:-0}" = "1" ]; then
      info "WARNING: ALLOW_UNVERIFIED=1 - $what is NOT checksum-verified (insecure)"
    else
      info "refusing unverified download for $what (no sha256; publish SHA256SUMS next to the artifact or set ALLOW_UNVERIFIED=1)"
      return 1
    fi
  fi
  info "downloading $what ..."
  if ! curl -sL --fail --retry 3 -o "$tmp" "$url"; then
    rm -f "$tmp"; info "download failed: $what"; return 1
  fi
  if [ -n "$sha" ]; then
    got=$(sha256sum "$tmp" | cut -d' ' -f1)
    if [ "$got" != "$sha" ]; then
      rm -f "$tmp"; info "sha256 mismatch for $what: got ${got} want ${sha}"; return 1
    fi
    info "sha256 OK: $what"
  fi
  mv -f "$tmp" "$dest"
}

# --fetch-verified <url> <dest> [sha256]: single verified download for CI
# (used by .github/workflows/ohos-full-build.yml). Set ALLOW_UNVERIFIED=1 to
# bypass, which is insecure. Exits 0 on success, 1 on download/verify failure.
if [ "$FETCH_MODE" = "1" ]; then
  [ -n "$FETCH_URL" ] && [ -n "$FETCH_DEST" ] \
    || { echo "usage: build-ohos-all.sh --fetch-verified <url> <dest> [sha256]" >&2; exit 2; }
  LOG=/dev/stdout   # progress/banners go to the step log
  fetch_verified "$FETCH_URL" "$FETCH_DEST" "${FETCH_SHA:--}" "fetch $(basename "${FETCH_URL%%\?*}")" || exit 1
  exit 0
fi

# Resolve the reference runtime pack (on-demand download, sha256-pinned).
resolve_reference_runtime_pack() {
  [ -n "$REFERENCE_RUNTIME_PACK" ] && return 0
  if [ -f "$SCRIPT_DIR/reference-runtime-pack.nupkg" ]; then
    REFERENCE_RUNTIME_PACK="$SCRIPT_DIR/reference-runtime-pack.nupkg"
    return 0
  fi
  local dest="$SCRIPT_DIR/third-party/$REFERENCE_RUNTIME_PACK_ASSET"
  if [ ! -s "$dest" ] || [ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$REFERENCE_RUNTIME_PACK_SHA256" ]; then
    fetch_verified "$REFERENCE_RUNTIME_PACK_URL" "$dest" "$REFERENCE_RUNTIME_PACK_SHA256" "reference runtime pack (R2R-PGO)" || return 1
  fi
  REFERENCE_RUNTIME_PACK="$dest"
  return 0
}

ensure_stock_crossgen2() {
  # resolution order: repo-bundled -> NuGet cache -> dnceng public feed
  # (this is an internal-dev build: NOT on nuget.org, which returns 404);
  # downloads are sha256-pinned
  local nupkg=""
  local bundled="$SCRIPT_DIR/third-party/microsoft.netcore.app.crossgen2.linux-x64.$STOCK_CROSSGEN2_VERSION.nupkg"
  [ -f "$bundled" ] && nupkg="$bundled"
  if [ -z "$nupkg" ]; then
    local cache="$HOME/.nuget/packages/microsoft.netcore.app.crossgen2.linux-x64/$STOCK_CROSSGEN2_VERSION"
    [ -d "$cache" ] && nupkg=$(ls "$cache"/*.nupkg 2>/dev/null | grep -v symbols | head -1)
  fi
  if [ -z "$nupkg" ]; then
    [ -n "$STOCK_CROSSGEN2_SHA256" ] \
      || die "no sha256 pinned for stock crossgen2 $STOCK_CROSSGEN2_VERSION; set STOCK_CROSSGEN2_SHA256 or bundle the nupkg under $SCRIPT_DIR/third-party/"
    nupkg="$HOME/.nuget/packages/microsoft.netcore.app.crossgen2.linux-x64/$STOCK_CROSSGEN2_VERSION/microsoft.netcore.app.crossgen2.linux-x64.$STOCK_CROSSGEN2_VERSION.nupkg"
    fetch_verified \
      "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet12/nuget/v3/flat2/microsoft.netcore.app.crossgen2.linux-x64/$STOCK_CROSSGEN2_VERSION/microsoft.netcore.app.crossgen2.linux-x64.$STOCK_CROSSGEN2_VERSION.nupkg" \
      "$nupkg" "$STOCK_CROSSGEN2_SHA256" "official crossgen2 $STOCK_CROSSGEN2_VERSION (dnceng dotnet12 feed)" \
      || die "download official crossgen2 failed (place the nupkg at $SCRIPT_DIR/third-party/ to go offline)"
  fi
  # An existing extracted directory is not trusted: verify the source package
  # against the pin, re-extract it and use the freshly extracted tool (the cache
  # is replaced when it differs). Fail-closed when no pin is available.
  verify_pinned_nupkg "$nupkg" "$STOCK_CROSSGEN2_SHA256" "stock crossgen2 $STOCK_CROSSGEN2_VERSION" \
    || die "refusing unverified stock crossgen2 nupkg $nupkg (add the digest to versions.env stock_crossgen2_sha256())"
  local fresh="$STOCK_CROSSGEN2_DIR.fresh.$$"
  rm -rf "$fresh"
  mkdir -p "$fresh"
  python3 -c "import zipfile; zipfile.ZipFile('$nupkg').extractall('$fresh')" || { rm -rf "$fresh"; die "extract crossgen2 failed"; }
  chmod +x "$fresh/tools/crossgen2" 2>/dev/null
  if [ -x "$STOCK_CROSSGEN2_DIR/tools/crossgen2" ] && cmp -s "$fresh/tools/crossgen2" "$STOCK_CROSSGEN2_DIR/tools/crossgen2"; then
    rm -rf "$fresh"
    info "stock crossgen2 ready (sha256 verified): $STOCK_CROSSGEN2_DIR/tools/crossgen2 ($STOCK_CROSSGEN2_VERSION)"
    return 0
  fi
  rm -rf "$STOCK_CROSSGEN2_DIR"
  mv "$fresh" "$STOCK_CROSSGEN2_DIR"
  info "stock crossgen2: $STOCK_CROSSGEN2_DIR/tools/crossgen2 ($STOCK_CROSSGEN2_VERSION)"
}


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

# singlefilehost links against libruntimeinfo.a; its ninja target is not
# ordered first on a clean build (link fails with "cannot open libruntimeinfo.a").
ensure_runtimeinfo() {
  local nio="$RUNTIME_REPO/artifacts/obj/coreclr/openharmony.$ARCH.$CONFIG/debug/runtimeinfo/libruntimeinfo.a"
  if [ ! -s "$nio" ]; then
    info "pre-building libruntimeinfo.a (clean-build link order)..."
    (cd "$RUNTIME_REPO/artifacts/obj/coreclr/openharmony.$ARCH.$CONFIG" \
      && ninja debug/runtimeinfo/libruntimeinfo.a) >>"$LOG" 2>&1 || die "libruntimeinfo.a build failed"
  fi
}

# On a clean build the shims (NetFx facade assemblies: System.dll, mscorlib,
# netstandard, ...) are filtered out of libs.sfx by the unix-vs-managed TFM
# mismatch and sfx-finish fails ("...were missing"). Compile all shims (their
# referenced libs are already built at that point) and copy the facades into
# the shared-framework layout, then retry the libs build once.
compile_shims_into_layout() {
  local rsp="$RUNTIME_REPO/.dotnet/sdk/$RIDGRAPH_SDKVER/RuntimeIdentifierGraph.json"
  local layout="$RUNTIME_REPO/artifacts/bin/microsoft.netcore.app.runtime.$RID/$CONFIG/runtimes/$RID/lib/$TFM"
  mkdir -p "$layout"
  info "compiling shims (facade assemblies) and copying into the layout..."
  for P in $(find "$RUNTIME_REPO/src/libraries/shims" -name "*.csproj" -path "*/src/*" | sort); do
    (cd "$RUNTIME_REPO" && ./.dotnet/dotnet build "$P" -c "$CONFIG" \
      -p:TargetOS=openharmony -p:TargetArchitecture="$ARCH" -p:PortableOS=openharmony -p:UseBootstrapLayout=true \
      "-p:RuntimeIdentifierGraphPath=$rsp" -p:IncludeSymbols=false \
      -p:PreReleaseVersionLabel="$LABEL" -p:PreReleaseVersion="$PRE" -p:OfficialBuildId="$BUILDID" \
      -v:q -nologo) >>"$LOG" 2>&1 || { echo "shim build failed: $P" | tee -a "$LOG"; return 1; }
  done
  for D in "$RUNTIME_REPO"/artifacts/bin/*/Release/${TFM}-unix; do
    [ -d "$D" ] || continue
    for F in "$D"/*.dll; do
      [ -f "$F" ] || continue
      case "$(basename "$F")" in System.Private.*|System.Runtime.dll) continue ;; esac
      cp -f "$F" "$layout/" 2>/dev/null || true
    done
  done
  info "shims compiled and facades copied into $layout"
}

# runtime clr+libs+packs build with clean-build fixes: pre-build
# libruntimeinfo.a, and on an sfx-finish "facades missing" failure compile the
# shims and retry once. Normal (incremental) runs never take the retry path.
# seed the bootstrap ref pack from the bootstrap SDK's Ref pack (clean builds:
# the local targeting-pack Error fires before anything has produced a local
# ref; the SDK's ref is a version-neutral stand-in — local packs overwrite it)
seed_bootstrap_ref() {
  local sdkref=""
  local packs="$RUNTIME_REPO/.dotnet/packs/Microsoft.NETCore.App.Ref"
  local p
  for p in "$packs/$REFERENCE_RUNTIME_PACK_VERSION" "$packs/$BOOTSTRAP_SDK_VERSION" "$packs/$RIDGRAPH_SDKVER" $(ls -d "$packs"/*/ 2>/dev/null); do
    [ -d "$p/ref" ] && [ -f "$p/data/FrameworkList.xml" ] && { sdkref="$p"; break; }
  done
  [ -n "$sdkref" ] || die "no SDK Ref pack to seed bootstrap (looked under $packs)"
  local bdir="$RUNTIME_REPO/artifacts/bootstrap/openharmony-$ARCH/microsoft.netcore.app/ref"
  mkdir -p "$bdir"
  cp -rf "$sdkref"/. "$bdir/"
  [ -f "$bdir/data/FrameworkList.xml" ] || die "bootstrap ref seed missing FrameworkList.xml"
  info "seeded bootstrap ref pack from SDK Ref ($(basename "$sdkref"))"
}

build_clr_libs_packs() {
  # --- in-tree R2R preparation (A/B, OHOS_IN_TREE_R2R=1) ---------------------
  # Seed the PGO mibc at $(CoreCLRArtifactsPath)StandardOptimizationData.mibc
  # BEFORE the packs build (eng/codeOptimization.targets reads it there when
  # PublishReadyToRun+EnableNgenOptimization are set), and stage the stock
  # linux-x64 crossgen2 for the CoreCLR.sfxproj's overridden
  # ResolveReadyToRunCompilers (Crossgen2InBuildDir is overridden globally to
  # point at it).
  if [ "$OHOS_IN_TREE_R2R" = "1" ]; then
    local clrbin_early="$RUNTIME_REPO/artifacts/bin/coreclr/openharmony.$ARCH.$CONFIG"
    mkdir -p "$clrbin_early"
    if [ ! -s "$clrbin_early/StandardOptimizationData.mibc" ] && resolve_reference_runtime_pack; then
      (python3 -c "
import zipfile
z = zipfile.ZipFile('$REFERENCE_RUNTIME_PACK')
open('$clrbin_early/StandardOptimizationData.mibc','wb').write(z.read('tools/StandardOptimizationData.mibc'))
" && info "in-tree R2R: PGO mibc seeded before the packs build") || info "in-tree R2R: mibc seed failed - continuing without PGO"
    fi
    # The in-pass crossgen2_inbuild is published for the OHOS bootstrap layout
    # (aarch64 apphost) under UseBootstrapLayout, so it cannot run on the x64
    # build host (Exec format error, run 34787921027). Use the stock linux-x64
    # crossgen2 for the in-tree pipeline and point the sfxproj's overridden
    # ResolveReadyToRunCompilers at it via the Crossgen2InBuildDir global
    # property. The in-build tool itself is probe-verified separately
    # (sdk-ohos run 34784718506).
    ensure_stock_crossgen2
    info "in-tree R2R: sfxproj crossgen2 -> $STOCK_CROSSGEN2_DIR/tools/crossgen2"
  fi
  # Mirror the verified host linux-x64 packs into the local NuGet feed (flat)
  # so the in-build tool restore (RestoreAdditionalProjectSources=$FEED) and
  # SDK runtime-pack download can resolve them regardless of version source.
  # Every package is digest-checked against $HOSTFEED/manifest.sha256 or a
  # HOSTFEED_*_SHA256 pin before it becomes build input.
  ingest_hostfeed
  # The in-build tools resolve the host runtime pack at ProductVersion
  # ($VERSION_BAND base, no suffix) per targetingpacks KnownRuntimePack;
  # re-version the seeded reference pack to $VERSION_BAND in both the folder
  # feed and the flat feed (docs/plans problem-4 pattern: repackage to the
  # requested version).
  if [ -f "$HOSTFEED/microsoft.netcore.app.runtime.linux-x64/$REFERENCE_RUNTIME_PACK_VERSION/microsoft.netcore.app.runtime.linux-x64.$REFERENCE_RUNTIME_PACK_VERSION.nupkg" ]; then
    for dest in "$HOSTFEED" "$FEED"; do
      mkdir -p "$dest/microsoft.netcore.app.runtime.linux-x64/$VERSION_BAND"
      python3 -c "
import zipfile, io
src = '$HOSTFEED/microsoft.netcore.app.runtime.linux-x64/$REFERENCE_RUNTIME_PACK_VERSION/microsoft.netcore.app.runtime.linux-x64.$REFERENCE_RUNTIME_PACK_VERSION.nupkg'
out = '$dest/microsoft.netcore.app.runtime.linux-x64/$VERSION_BAND/microsoft.netcore.app.runtime.linux-x64.$VERSION_BAND.nupkg'
zin = zipfile.ZipFile(src)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zout:
    for n in zin.namelist():
        d = zin.read(n)
        if n.endswith('.nuspec') or n.endswith('.nupkg.metadata'):
            d = d.decode().replace('$REFERENCE_RUNTIME_PACK_VERSION', '$VERSION_BAND').encode()
        zout.writestr(n, d)
" && info "re-versioned host pack to $VERSION_BAND in $dest"
    done
  fi
  # Seed every verified hostfeed version into the NuGet global cache too (the
  # SDK runtime-pack check looks at ~/.nuget for the resolved version). The
  # nupkg was digest-verified above; the content hash is computed from the same
  # verified bytes.
  if [ -d "$HOSTFEED" ]; then
    for nupkg in $(find "$HOSTFEED" -type f -name "*.nupkg"); do
      id=$(basename "$(dirname "$(dirname "$nupkg")")")
      ver=$(basename "$(dirname "$nupkg")")
      dir="$HOME/.nuget/packages/$id/$ver"
      if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        cp "$nupkg" "$dir/$(basename "$nupkg")"
        python3 -c "
import hashlib,base64,json,zipfile,glob
p='$dir/' + '$(basename "$nupkg")'
h=base64.b64encode(hashlib.sha512(open(p,'rb').read()).digest()).decode()
open('$dir/' + '$(basename "$nupkg")' + '.sha512','w').write(h)
open('$dir/.nupkg.metadata','w').write(json.dumps({'version':2,'contentHash':h,'source':'local'}))
zipfile.ZipFile(p).extractall('$dir')
for n in glob.glob('$dir/*.nuspec'):
    import shutil; shutil.copy(n, '$dir/$id.nuspec'); break
" && info "seeded $id $ver into ~/.nuget"
      fi
    done
  fi
  # SDK's FrameworkReference resolution (in-build self-contained host tools)
  # reads NuGet.config sources, not RestoreAdditionalProjectSources. The
  # repository file must stay untouched (a build may not modify tracked files),
  # so the repo config is merged with the local folder feeds into a private
  # config under $WORK and restore is pointed at it with RestoreConfigFile.
  NUGET_CONFIG="$WORK/NuGet.config"
  python3 - "$RUNTIME_REPO/NuGet.config" "$NUGET_CONFIG" "$FEED" "$HOSTFEED" <<'PYEOF'
import os, sys
src, out, feed, hostfeed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
marker = '  </packageSources>'
assert marker in s, "packageSources close not found"
adds = []
if feed not in s:
    adds.append('    <add key="local-feed" value="' + feed + '" />\n')
if os.path.isdir(hostfeed) and hostfeed not in s:
    adds.append('    <add key="local-hostfeed" value="' + hostfeed + '" />\n')
if adds:
    s = s.replace(marker, ''.join(adds) + marker, 1)
open(out, 'w').write(s)
print("wrote " + out + " (repo NuGet.config untouched)")
PYEOF
  chmod 600 "$NUGET_CONFIG" 2>/dev/null || true
  RESTORE_SOURCES="$(grep -oE 'value="[^"]*"' "$NUGET_CONFIG" | sed 's/value="//; s/"//' | grep -E '^https?://|^/' | tr '\n' ';')"
  info "restore sources set (private NuGet.config: $NUGET_CONFIG)"
  # A clean build hits several self-healing failures (all ordering, not our
  # code): singlefilehost links before libruntimeinfo.a is built, sfx-finish
  # runs before the shims (facades) are compiled, and restore needs the
  # bootstrap ref pack before any local ref exists. Handle each once and
  # retry; normal incremental runs never take these paths.
  local attempt=0
  local fixed=""
  local alog="$WORK/build-attempt.log"    # per-attempt output for self-heal detection
  while :; do
    if ./build.sh -os openharmony -arch "$ARCH" --cross -c "$CONFIG" -lc "$CONFIG" -rc "$CONFIG" \
        -subset clr+libs+packs \
        /p:UseBootstrapLayout=true /p:BuildHostTools=true /p:ApiCompatValidateAssemblies=false \
        /p:RuntimeIdentifierGraphPath="$rsp" /p:IncludeSymbols=false \
        "/p:RestoreConfigFile=$NUGET_CONFIG" \
        $IN_TREE_R2R_PACK_ARGS \
        /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" /p:OfficialBuildId="$BUILDID" \
        "/p:RestoreAdditionalProjectSources=$FEED" \
        -cmakeargs "-DCMAKE_SYSTEM_NAME=OHOS -DHAVE_CLOCK_MONOTONIC_COARSE_EXITCODE=0 -DHAVE_CLOCK_REALTIME_EXITCODE=0 -DHAVE_CLOCK_THREAD_CPUTIME_EXITCODE=0 -DHAVE_MMAP_DEV_ZERO_EXITCODE=0 -DHAVE_PROCFS_CTL_EXITCODE=1 -DHAVE_PROCFS_STAT_EXITCODE=0 -DHAVE_PROCFS_STATM_EXITCODE=0 -DHAVE_SCHED_GETCPU_EXITCODE=0 -DHAVE_SCHED_GET_PRIORITY_EXITCODE=0 -DHAVE_WORKING_CLOCK_GETTIME_EXITCODE=0 -DHAVE_WORKING_GETTIMEOFDAY_EXITCODE=0 -DONE_SHARED_MAPPING_PER_FILEREGION_PER_PROCESS_EXITCODE=1 -DREALPATH_SUPPORTS_NONEXISTENT_FILES_EXITCODE=1 -DHAVE_SHM_OPEN_THAT_WORKS_WELL_ENOUGH_WITH_MMAP_EXITCODE=0 -DHAVE_BROKEN_FIFO_KEVENT_EXITCODE=1 -DHAVE_BROKEN_FIFO_SELECT_EXITCODE=1 -DOPENSSL_ROOT_DIR=$OPENSSL_DIR -DOPENSSL_INCLUDE_DIR=$OPENSSL_DIR/include \
          -DOPENSSL_CRYPTO_LIBRARY=$OPENSSL_DIR/lib/libcrypto.a -DOPENSSL_SSL_LIBRARY=$OPENSSL_DIR/lib/libssl.a \
          -DCMAKE_ICU_DIR=$ICU_DIR" \
        > "$alog" 2>&1; then
      cat "$alog" >> "$LOG"
      return 0
    fi
    cat "$alog" >> "$LOG"
    if grep -qE "shared framework must be built before the local targeting" "$alog"; then
      if [ "$attempt" -ge 4 ]; then die "bootstrap ref Error persists after 4 seeds — check ordering"; fi
      info "clean build missing bootstrap ref pack — seeding and retrying (attempt $((attempt+1)))"
      seed_bootstrap_ref
      fixed="bootstrap-ref"
      attempt=$((attempt+1))
      continue
    fi
    if grep -qE "cannot open .*libruntimeinfo\.a|libhostpolicy.*No such|libruntimeinfo\.a: No such" "$alog"; then
      if [ "$attempt" -ge 4 ]; then die "libruntimeinfo.a missing persists after retries"; fi
      info "clean build missing libruntimeinfo.a — building and retrying (attempt $((attempt+1)))"
      ensure_runtimeinfo
      fixed="runtimeinfo"
      attempt=$((attempt+1))
      continue
    fi
    if grep -qE "sfx-finish\.proj.*were missing" "$alog"; then
      if [ "$attempt" -ge 4 ]; then die "sfx-finish facade gap persists after retries"; fi
      info "sfx-finish missing facades on clean build — compiling shims and retrying (attempt $((attempt+1)))"
      compile_shims_into_layout || die "shim compile/copy failed"
      fixed="shims"
      attempt=$((attempt+1))
      continue
    fi
    echo "--- NETSDK1112 diag ---" | tee -a "$LOG"
    echo "--- manual Bcl.Numerics netstandard2.1 diag ---" | tee -a "$LOG"
    if grep -q "Bcl.Numerics" "$alog" 2>/dev/null; then
      (cd "$RUNTIME_REPO" && ./.dotnet/dotnet build src/libraries/Microsoft.Bcl.Numerics/src/Microsoft.Bcl.Numerics.csproj -f netstandard2.1         -p:TargetOS=openharmony -p:TargetArchitecture=arm64 -p:UseBootstrapLayout=true -v:diag 2>&1 |         grep -iE "References=|/r:|netstandard.dll|System.Runtime.dll|ResolveFrameworkReferences|CS0518|netstandard.library" | head -12) 2>/dev/null | tee -a "$LOG" || true
    fi
    echo "--- CS0518 csc context ---" | tee -a "$LOG"
    grep -B2 -A2 "ExceptionPolyfills" "$alog" 2>/dev/null | grep -iE "csc|/r:|netstandard|CoreLib|Reference" | head -6 | tee -a "$LOG" || true
    echo "--- NETSDK1112 error lines ---" | tee -a "$LOG"
    grep -E "NETSDK1112|error NETSDK1112" "$alog" 2>/dev/null | head -3 | tee -a "$LOG" || true
    echo "--- NuGet download attempts (linux-x64 runtime pack version) ---" | tee -a "$LOG"
    grep -oE "(GET|Restoring|Downloading).*linux-x64[^ ]*|runtime\.linux-x64[^ ]*2645[0-9]+[^ ]*|2645[0-9]+\.[0-9]+" "$alog" 2>/dev/null | sort -u | head -8 | tee -a "$LOG" || true
    find "$RUNTIME_REPO/artifacts/obj" -maxdepth 2 -type d -name "*ILCompiler_inbuild*" 2>/dev/null | tee -a "$LOG" || true
    local dg=$(find "$RUNTIME_REPO/artifacts/obj" -path "*ILCompiler_inbuild*" -name "*.dgspec.json" 2>/dev/null | head -1)
    [ -n "$dg" ] && python3 -c "
import json,sys
d = json.load(open('$dg'))
proj = d.get('project',{})
print('frameworks:', list(proj.get('frameworks',{}).keys()))
for tfm, fr in proj.get('frameworks',{}).items():
    print(tfm, 'runtimeIdentifierGraphPath:', fr.get('runtimeIdentifierGraphPath'))
    print(tfm, 'frameworks:', json.dumps(fr.get('frameworkReferences',{}))[:200])
" 2>&1 | tee -a "$LOG"
    echo "--- nuget linux-x64 cache ---" | tee -a "$LOG"
    ls "$HOME/.nuget/packages/microsoft.netcore.app.runtime.linux-x64/" 2>/dev/null | tee -a "$LOG" || true
    ls "$HOME/.nuget/packages/microsoft.netcore.app.runtime.linux-x64/$BOOTSTRAP_RUNTIME_VERSION/" 2>/dev/null | head -6 | tee -a "$LOG"
    echo "--- last attempt log tail ---" | tee -a "$LOG"
    tail -40 "$alog" | tee -a "$LOG"
    echo "--- configure platform lines ---" | tee -a "$LOG"
    grep -iE "CMAKE_SYSTEM_NAME|The C compiler|CMAKE_CROSSCOMPILING|Targeting|System is|CMAKE_TOOLCHAIN_FILE|CMAKE_SYSTEM_PROCESSOR" "$alog" 2>/dev/null | head -12 | tee -a "$LOG"
    die "runtime build (clr+libs+packs) failed (see log tail above)"
  done
}

# expected digest for a host runtime pack (dnceng pins or the GitHub release
# digest of the 'host-runtime-packs' release); empty when unavailable.
host_pack_expected_sha256() { # <id> <ver> <url> -> hex or empty
  case "$3" in
    *pkgs.dev.azure.com*) printf '%s' "${HOST_PACK_SHA256:-$(dnceng_pkg_sha256 "$1" "$2")}" ;;
    https://github.com/*) github_asset_sha256 "$GH_USER" sdk-ohos host-runtime-packs "$1.$2.nupkg" || true ;;
    *) printf '%s' "" ;;
  esac
}

# A directory in ~/.nuget is not evidence of integrity: the cached nupkg must
# match the expected digest before it is used (H-C1).
verify_host_pack_cache() { # <id> <ver> <expected-hex> -> 0 when the cache is usable
  local dir="$HOME/.nuget/packages/$1/$2"
  local nupkg=""
  nupkg="$(ls "$dir"/*.nupkg 2>/dev/null | grep -v symbols | head -1)"
  if [ -z "$nupkg" ]; then
    return 1
  fi
  if [ -z "$3" ]; then
    info "no anchored digest to verify cached $1 $2 against"
    return 1
  fi
  local got
  got="$(sha256sum "$nupkg" | cut -d' ' -f1)"
  if [ "$got" != "$3" ]; then
    info "cached $1 $2 sha256 mismatch (got $got want $3)"
    return 1
  fi
  ls "$dir"/*.nuspec >/dev/null 2>&1 || return 1
  return 0
}

# pre-seed a host-RID runtime pack into ~/.nuget (clean hosts cannot restore
# the host pack for the in-build toolchain from the feed in some cmake/nuget
# combos — NETSDK1112). ILCompiler_inbuild is SelfContained at the SDK runtime
# version (nuget.org), so try that first, then dnceng dotnet12 candidates.
# Downloads are sha256-verified (fetch_verified); dnceng versions use the
# dnceng_pkg_sha256 pins, GitHub-hosted ones resolve the release digest. A
# pre-existing cache is re-verified against the same digest before it is used.
ensure_nuget_runtime_pack() {
  local rid="$1"
  local id="microsoft.netcore.app.runtime.$rid"
  local ver
  for ver in "$2" "$3" "$4"; do
    [ -n "$ver" ] || continue
    local dir="$HOME/.nuget/packages/$id/$ver"
    local url=""
    # GitHub-hosted copy first (CI cannot reliably reach dnceng/nuget.org for
    # these; see sdk-ohos release 'host-runtime-packs'), then the origin feeds.
    if [ "$ver" = "$HOST_PACK_DNCENG_DOTNET11_VERSION" ]; then
      url="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/flat2/$id/$ver/$id.$ver.nupkg"
    elif is_github_host_pack_version "$ver"; then
      url="https://github.com/${GH_USER}/sdk-ohos/releases/download/host-runtime-packs/$id.$ver.nupkg"
    else
      url="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet12/nuget/v3/flat2/$id/$ver/$id.$ver.nupkg"
    fi
    local sha
    sha="$(host_pack_expected_sha256 "$id" "$ver" "$url")"
    if [ -z "$sha" ]; then
      # pinned GitHub release only; resolve_url_sha256 refuses other hosts
      sha="$(resolve_url_sha256 "$url" "$id.$ver.nupkg" || true)"
    fi
    if [ -d "$dir" ]; then
      if verify_host_pack_cache "$id" "$ver" "$sha"; then
        return 0
      fi
      info "cached $id $ver is not usable; re-downloading"
      rm -rf "$dir"
    fi
    info "pre-seeding $id $ver..."
    local tmp="$(mktemp -d)"
    if fetch_verified "$url" "$tmp/p.nupkg" "$sha" "host runtime pack $id $ver"; then
      mkdir -p "$dir"
      cp "$tmp/p.nupkg" "$dir/$id.$ver.nupkg"
      python3 -c "import hashlib,base64,json; h=base64.b64encode(hashlib.sha512(open('$tmp/p.nupkg','rb').read()).digest()).decode(); open('$dir/$id.$ver.nupkg.sha512','w').write(h); open('$dir/.nupkg.metadata','w').write(json.dumps({'version':2,'contentHash':h,'source':'local'}))"
      (cd "$dir" && python3 -c "import zipfile; zipfile.ZipFile('$tmp/p.nupkg').extractall('.')")
      cp "$dir"/*.nuspec "$dir/$id.nuspec" 2>/dev/null
      rm -rf "$tmp"
      if ls "$dir"/*.nuspec >/dev/null 2>&1; then info "pre-seeded $id $ver"; return 0; fi
    else
      rm -rf "$tmp"
      info "  (not found or unverified: $id $ver)"
    fi
  done
  return 1
}

# ---- 1. runtime cross build -------------------------------------------------
RUNTIME_RID_DIR=""       # e.g. artifacts/bin/coreclr/openharmony.arm64.Release
stage1() {
  info "Stage 1: runtime cross build (-os openharmony -arch $ARCH --cross)"
  export MSBUILDDISABLENODEREUSE=1
  cd "$RUNTIME_REPO"
  # Bootstrap SDK RID graph must carry the openharmony entries (independent RID).
  # Inject the repo's eng graphs (complete 802-RID files) into every installed
  # SDK whose graph lacks openharmony — the runtime build actually uses the
  # global.json SDK version, which may differ from RIDGRAPH_SDKVER. Covers
  # fresh clones / CI (no pre-seeded .dotnet).
  local eng_rsp="$SDK_REPO/eng/RuntimeIdentifierGraph.openharmony.json"
  local eng_prsp="$SDK_REPO/eng/PortableRuntimeIdentifierGraph.openharmony.json"
  local gjv=""
  if [ -f "$RUNTIME_REPO/global.json" ]; then
    gjv=$(python3 -c "import json;print(json.load(open('$RUNTIME_REPO/global.json'))['sdk']['version'])" 2>/dev/null || true)
  fi
  for v in $RIDGRAPH_SDKVER $gjv; do
    [ -n "$v" ] || continue
    local sdkdir="$RUNTIME_REPO/.dotnet/sdk/$v"
    [ -d "$sdkdir" ] || continue
    local rsp="$sdkdir/RuntimeIdentifierGraph.json"
    if [ -f "$rsp" ] && ! python3 -c "import json,sys; sys.exit(0 if 'openharmony-arm64' in json.load(open('$rsp'))['runtimes'] else 1)" 2>/dev/null; then
      [ -f "$eng_rsp" ] || die "no eng graph at $eng_rsp"
      cp -f "$eng_rsp" "$rsp"
      [ -f "$eng_prsp" ] && cp -f "$eng_prsp" "$sdkdir/PortableRuntimeIdentifierGraph.json"
      info "injected eng/ openharmony RID graphs into bootstrap SDK $v"
    fi
  done
  local rsp="$RUNTIME_REPO/.dotnet/sdk/$RIDGRAPH_SDKVER/RuntimeIdentifierGraph.json"
  [ -f "$rsp" ] || die "RID graph not found at $rsp (bootstrap SDK lacks openharmony) — inject eng/ graphs first"
  # crossgen2_inbuild publish (self-contained) resolves AppHostSourcePath to
  # artifacts/bootstrap/openharmony-arm64/host/apphost when UseBootstrapLayout=true;
  # if the bootstrap layout is stale/missing the publish dies MSB3030. Build
  # the corehost (host subset) when needed, then sync apphost/singlefilehost
  # into the bootstrap host dir. Clean hosts (CI) have no corehost output
  # until the host subset runs.
  local chbin="$RUNTIME_REPO/artifacts/bin/openharmony-$ARCH.$CONFIG/corehost"
  local bhdir="$RUNTIME_REPO/artifacts/bootstrap/openharmony-$ARCH/host"
  # In-build tools (crossgen2/ILCompiler/R2R) restore the HOST (linux-x64)
  # runtime pack during clr+libs+packs; clean restores miss it (NETSDK1112).
  # ILCompiler_inbuild is SelfContained at the SDK runtime version; seed the
  # SDK version plus dnceng candidates (branch product version, darc baseline).
  ensure_nuget_runtime_pack "linux-x64" \
    "$BOOTSTRAP_RUNTIME_VERSION" \
    "${HOST_PACK_BRANCH_VERSION%.*}.$(echo "$BUILDID" | cut -d. -f2)" \
    "$HOST_PACK_BRANCH_VERSION" || true
  if [ ! -f "$chbin/apphost" ]; then
    info "corehost apphost missing — building host subset"
    (cd "$RUNTIME_REPO" && ./build.sh -os openharmony -arch "$ARCH" --cross -c "$CONFIG" \
      -subset host \
      /p:UseBootstrapLayout=true /p:IncludeSymbols=false \
      /p:RuntimeIdentifierGraphPath="$rsp" \
      /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" /p:OfficialBuildId="$BUILDID" \
      -cmakeargs "-DCMAKE_SYSTEM_NAME=OHOS -DHAVE_CLOCK_MONOTONIC_COARSE_EXITCODE=0 -DHAVE_CLOCK_REALTIME_EXITCODE=0 -DHAVE_CLOCK_THREAD_CPUTIME_EXITCODE=0 -DHAVE_MMAP_DEV_ZERO_EXITCODE=0 -DHAVE_PROCFS_CTL_EXITCODE=1 -DHAVE_PROCFS_STAT_EXITCODE=0 -DHAVE_PROCFS_STATM_EXITCODE=0 -DHAVE_SCHED_GETCPU_EXITCODE=0 -DHAVE_SCHED_GET_PRIORITY_EXITCODE=0 -DHAVE_WORKING_CLOCK_GETTIME_EXITCODE=0 -DHAVE_WORKING_GETTIMEOFDAY_EXITCODE=0 -DONE_SHARED_MAPPING_PER_FILEREGION_PER_PROCESS_EXITCODE=1 -DREALPATH_SUPPORTS_NONEXISTENT_FILES_EXITCODE=1 -DHAVE_SHM_OPEN_THAT_WORKS_WELL_ENOUGH_WITH_MMAP_EXITCODE=0 -DHAVE_BROKEN_FIFO_KEVENT_EXITCODE=1 -DHAVE_BROKEN_FIFO_SELECT_EXITCODE=1") \
      >> "$LOG" 2>&1 || true
    # The host subset may fail later at nupkg packaging (host pack is produced
    # by the packs subset); what we need is the native corehost output.
    [ -f "$chbin/apphost" ] || { echo "--- host subset log tail ---" | tee -a "$LOG"; tail -30 "$LOG" | tee -a "$LOG"; die "host subset produced no corehost apphost"; }
  fi
  if [ -f "$chbin/apphost" ]; then
    mkdir -p "$bhdir"
    cp -f "$chbin/apphost" "$bhdir/apphost" 2>/dev/null || true
    [ -f "$chbin/singlefilehost" ] && cp -f "$chbin/singlefilehost" "$bhdir/singlefilehost" 2>/dev/null || true
    info "corehost apphost synced to bootstrap host dir"
  fi
  # openharmony RID is independent (no linux-musl fallback) so the prebuilt SDK has no
  # openharmony apphost entry; libs/host do not publish apphosts, so host builds disable
  # the SDK apphost resolution (split build, see notes in stage comments).
  # clr+libs+packs — NOT +host: the independent openharmony RID has no apphost entry
  # in the prebuilt SDK (RID independence 2026-09-03 removed the linux-musl
  # fallback), so an explicit host subset trips NETSDK1084
  # ("no application host available for the specified RuntimeIdentifier").
  # The Host pack is still produced via the packs dependency chain (host.pkg).
  build_clr_libs_packs
  # Derive the product version from the packs clr+libs just produced, before
  # clr.aot: ILCompiler_inbuild restores the HOST (linux-x64) runtime pack at
  # this version, which must already be in ~/.nuget on clean hosts.
  local ship="$RUNTIME_REPO/artifacts/packages/$CONFIG/Shipping"
  RT_VERSION=$(ls "$ship"/Microsoft.NETCore.App.Ref.$VERSION_BAND-rc.*.nupkg 2>/dev/null | grep -v symbols | sed "s/.*Ref\.//; s/\.nupkg//" | sort -V | tail -1 || true)
  if [ -z "$RT_VERSION" ]; then
    RT_VERSION=$(ls "$ship"/Microsoft.NETCore.App.Runtime.$RID.$VERSION_BAND-rc.*.nupkg 2>/dev/null | sed "s/.*Runtime\.$RID\.//; s/\.nupkg//" | sort -V | tail -1 || true)
  fi
  [ -n "$RT_VERSION" ] || RT_VERSION="$VERSION_BAND-$LABEL.$PRE.$BUILDID"
  echo "$RT_VERSION" > "$WORK/rt-version.txt"
  info "runtime product version: $RT_VERSION"
  # Hardening (2026-09-13): a non-default buildid derives a fresh RT_VERSION for
  # which no host linux-x64 pack is published anywhere (a 26463.1 build died
  # with a 404 at the pre-seed below). Re-version an available seeded pack to
  # RT_VERSION (same repackage approach as the 11.0.0 alias above), so clean
  # hosts always have the pack the in-build tools restore.
  HOSTPACK_ID=microsoft.netcore.app.runtime.linux-x64
  HOSTPACK_DIR="$HOME/.nuget/packages/$HOSTPACK_ID/$RT_VERSION"
  if ! ls "$HOSTPACK_DIR"/*.nuspec >/dev/null 2>&1; then
    # Only a digest-verified pack may be re-versioned: the ~/.nuget cache is
    # writable by anything running as this user (H-C1).
    HOSTPACK_SRC=""
    HOSTPACK_SRCVER=""
    for cand in "$HOME/.nuget/packages/$HOSTPACK_ID"/*; do
      [ -d "$cand" ] || continue
      f=$(ls "$cand"/*.nupkg 2>/dev/null | head -1)
      [ -n "$f" ] || continue
      cver=$(basename "$f" | sed "s/^$HOSTPACK_ID\.//; s/\.nupkg$//")
      csha="${HOST_PACK_SHA256:-$(dnceng_pkg_sha256 "$HOSTPACK_ID" "$cver")}"
      [ -n "$csha" ] || csha="$(github_asset_sha256 "$GH_USER" sdk-ohos host-runtime-packs "$HOSTPACK_ID.$cver.nupkg" || true)"
      if verify_pinned_nupkg "$f" "$csha" "host pack source $cver"; then
        HOSTPACK_SRC="$f"
        HOSTPACK_SRCVER="$cver"
        break
      fi
      info "skipping unverified host pack candidate $f"
    done
    if [ -n "$HOSTPACK_SRC" ]; then
      info "re-versioning host pack $HOSTPACK_SRCVER -> $RT_VERSION (no published pack for this buildid)"
      mkdir -p "$HOSTPACK_DIR"
      [ -d "$HOSTFEED" ] && mkdir -p "$HOSTFEED/$HOSTPACK_ID/$RT_VERSION"
      python3 -c "
import zipfile
src, out, old, new = '$HOSTPACK_SRC', '$HOSTPACK_DIR/$HOSTPACK_ID.$RT_VERSION.nupkg', '$HOSTPACK_SRCVER', '$RT_VERSION'
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zout:
    for n in zin.namelist():
        d = zin.read(n)
        if n.endswith('.nuspec') or n.endswith('.nupkg.metadata'):
            d = d.decode().replace(old, new).encode()
        zout.writestr(n, d)
"
      if [ -d "$HOSTFEED" ]; then
        cp "$HOSTPACK_DIR/$HOSTPACK_ID.$RT_VERSION.nupkg" "$HOSTFEED/$HOSTPACK_ID/$RT_VERSION/"
        # The re-versioned pack is a derived artifact, but a later build treats
        # $HOSTFEED as untrusted input: pin its digest in the manifest.
        sha256sum "$HOSTFEED/$HOSTPACK_ID/$RT_VERSION/$HOSTPACK_ID.$RT_VERSION.nupkg" \
          | sed "s|$HOSTFEED/||" >> "$HOSTFEED/manifest.sha256"
      fi
      python3 -c "
import hashlib,base64,json,zipfile,glob,shutil
dirp='$HOSTPACK_DIR'; n='$HOSTPACK_ID.$RT_VERSION.nupkg'; p=dirp+'/'+n
h=base64.b64encode(hashlib.sha512(open(p,'rb').read()).digest()).decode()
open(p+'.sha512','w').write(h)
open(dirp+'/.nupkg.metadata','w').write(json.dumps({'version':2,'contentHash':h,'source':'local'}))
zipfile.ZipFile(p).extractall(dirp)
for x in glob.glob(dirp+'/*.nuspec'): shutil.copy(x, dirp+'/$HOSTPACK_ID.nuspec'); break
"
      info "re-versioned host pack -> $RT_VERSION"
    fi
  fi
  ensure_nuget_runtime_pack "linux-x64" "$RT_VERSION" "" ""

  # AOT tooling packs via clr.aot+packs + explicit NativeAOT.sfxproj — the
  # fork's authoritative C.7 shape (DotNetBuildAllRuntimePacks=true would also
  # trigger Mono cross-AOT which misfires for openharmony).
  ./build.sh -os openharmony -arch "$ARCH" --cross -c "$CONFIG" -lc "$CONFIG" -rc "$CONFIG" \
    /p:UseBootstrapLayout=true /p:ApiCompatValidateAssemblies=false \
    -subset clr.aot+packs \
    /p:RuntimeIdentifierGraphPath="$rsp" /p:IncludeSymbols=false \
    /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" /p:OfficialBuildId="$BUILDID" \
    2>&1 | tee -a "$LOG" || die "runtime build (clr.aot+packs / ILCompiler) failed"
  info "runtime product version: $RT_VERSION"

  # clr.aot+packs emits the ilc as a CoreCLR SINGLE-FILE (toolAot.targets
  # PublishSingleFile when UseNativeAotForComponents is false) — that shape
  # fails device startup (rounds 14-15). Re-publish ILCompiler_publish with
  # PublishSingleFile=false (round-9/16 split layout — device-PASSED) and
  # reassemble the pack from that output.
  local ilcp="$RUNTIME_REPO/src/coreclr/tools/aot/ILCompiler/ILCompiler_publish.csproj"
  local ilcd="$RUNTIME_REPO/artifacts/bin/coreclr/openharmony.$ARCH.$CONFIG/ilc-published"
  info "re-publishing ilc as CoreCLR split layout (PublishSingleFile=false)..."
  # PublishTrimmed=false: ILLink strips interface-dispatched methods such as
  # CustomAttributeTypeProvider.GetPrimitiveType from ILCompiler.TypeSystem.dll
  # when trimming the split publish (device TypeLoadException, dotnet/runtime
  # #133296 verification round). ilc is a build tool, not a shipping artifact —
  # trimming buys nothing here and breaks the split layout.
  ./.dotnet/dotnet build "$ilcp" -c "$CONFIG" -r "$RID" -t:Publish \
    -p:TargetOS=openharmony -p:TargetArchitecture="$ARCH" -p:PortableOS=openharmony \
    -p:UseBootstrap=true -p:PublishSingleFile=false -p:PublishTrimmed=false \
    "/p:RuntimeIdentifierGraphPath=$rsp" -p:IncludeSymbols=false -v:q -nologo \
    2>&1 | tee -a "$LOG" || die "ilc split publish failed"
  pkill -9 -f "MSBuild.*nodem" 2>/dev/null || true; sleep 2
  # device loads the native .so next to the apphost; add NDK libc++_shared
  local ndk_libcxx="$OHOS_NDK_HOME/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so"
  [ -f "$ilcd/libc++_shared.so" ] || cp -f "$ndk_libcxx" "$ilcd/libc++_shared.so"
  local ilcpk="$ship/runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.$RT_VERSION.nupkg"
  local ilc_ref=$(ls "$ship"/runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.*.nupkg 2>/dev/null | grep -v "$RT_VERSION" | head -1)
  [ -n "$ilc_ref" ] || ilc_ref="$ilcpk"  # same-pack metadata is safe (atomic write)
  # Framework overlay source: the split publish runs with UseBootstrapLayout so
  # it does not copy Microsoft.NETCore.App files next to the ilc apphost; the
  # device has no bootstrap SDK, so the pack must carry the framework itself.
  # The runtime pack nupkg from clr+libs+packs (same build) provides it.
  # The deps runtimepack entry version must be the framework the ilc was built
  # against (bootstrap SDK runtime, BOOTSTRAP_RUNTIME_VERSION, round-17 device-verified), NOT the
  # runtime pack file version - hostpolicy resolves libcoreclr.so from it and a
  # mismatch fails with "Could not resolve CoreCLR path" on device.
  local rtpack_nupkg=$(ls "$ship"/Microsoft.NETCore.App.Runtime.$RID.$RT_VERSION.nupkg 2>/dev/null | head -1)
  python3 "$SCRIPT_DIR/assemble-ilc-pack.py" "$ilcd" "$ilc_ref" "$ilcpk" "$rtpack_nupkg" "$BOOTSTRAP_RUNTIME_VERSION" --tfm "$TFM" \
    || die "assemble ilc split pack failed"

  # --- crossgen2 pack: untrimmed split re-publish (device R2R) ---
  # The in-build crossgen2 pack is a TRIMMED SINGLE-FILE publish; ILLink strips
  # interface-dispatched methods such as CustomAttributeTypeProvider.GetPrimitiveType
  # from ILCompiler.TypeSystem.dll (device TypeLoadException, dotnet/runtime #133296 -
  # the same class of bug the ilc split publish above fixes). Re-publish
  # crossgen2_publish with PublishSingleFile=false + PublishTrimmed=false and
  # reassemble the pack (framework overlay + runtimepack deps entry). The tool
  # tarball is refreshed from the same layout so both released artifacts agree.
  local cg2p="$RUNTIME_REPO/src/coreclr/tools/aot/crossgen2/crossgen2_publish.csproj"
  local cg2d="$RUNTIME_REPO/artifacts/bin/coreclr/openharmony.$ARCH.$CONFIG/crossgen2-published"
  info "re-publishing crossgen2 as CoreCLR split layout (PublishSingleFile=false, PublishTrimmed=false)..."
  ./.dotnet/dotnet build "$cg2p" -c "$CONFIG" -r "$RID" -t:Publish \
    -p:TargetOS=openharmony -p:TargetArchitecture="$ARCH" -p:PortableOS=openharmony \
    -p:UseBootstrap=true -p:PublishSingleFile=false -p:PublishTrimmed=false \
    "/p:RuntimeIdentifierGraphPath=$rsp" -p:IncludeSymbols=false -v:q -nologo \
    2>&1 | tee -a "$LOG" || die "crossgen2 split publish failed"
  pkill -9 -f "MSBuild.*nodem" 2>/dev/null || true; sleep 2
  [ -f "$cg2d/libc++_shared.so" ] || cp -f "$ndk_libcxx" "$cg2d/libc++_shared.so"
  local cg2pk="$ship/Microsoft.NETCore.App.Crossgen2.$RID.$RT_VERSION.nupkg"
  local cg2_ref=$(ls "$ship"/Microsoft.NETCore.App.Crossgen2.$RID.*.nupkg 2>/dev/null | grep -v "$RT_VERSION" | head -1)
  [ -n "$cg2_ref" ] || cg2_ref="$cg2pk"  # same-pack metadata is safe (atomic write)
  python3 "$SCRIPT_DIR/assemble-crossgen2-pack.py" "$cg2d" "$cg2_ref" "$cg2pk" "$rtpack_nupkg" "$BOOTSTRAP_RUNTIME_VERSION" --tfm "$TFM" \
    || die "assemble crossgen2 split pack failed"
  tar czf "$ship/dotnet-crossgen2-$RT_VERSION-$RID.tar.gz" -C "$cg2d" --exclude='*.pdb' . \
    || die "crossgen2 tool tarball refresh failed"
  ./build.sh -os openharmony -arch "$ARCH" --cross -c "$CONFIG" -lc "$CONFIG" -rc "$CONFIG" \
    /p:UseBootstrapLayout=true \
    -projects "$RUNTIME_REPO/src/installer/pkg/sfx/Microsoft.NETCore.App/Microsoft.NETCore.App.Runtime.NativeAOT.sfxproj" \
    /p:RuntimeIdentifierGraphPath="$rsp" /p:IncludeSymbols=false \
    /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" /p:OfficialBuildId="$BUILDID" \
    2>&1 | tee -a "$LOG" || die "runtime build (NativeAOT pack) failed"
  pkill -9 -f "MSBuild.*nodem" 2>/dev/null || true
  sleep 2

  # build.sh returns while msbuild node processes may still finish queued
  # work (they can clobber the layout / emit an empty pack afterwards). Wait for
  # them to go idle, then kill any stragglers before touching the layout.
  for _ in $(seq 1 10); do
    pgrep -f "MSBuild.*nodem" >/dev/null 2>&1 || break
    sleep 3
  done
  pkill -9 -f "MSBuild.*nodem" 2>/dev/null || true
  sleep 2
  # --- ReadyToRun CoreLib with the OFFICIAL crossgen2 (CI-aligned) ---
  # fork crossgen2_inbuild hangs at startup (round-13); the official NuGet
  # crossgen2 compiles the openharmony CoreLib R2R (PGO when the mibc exists).
  ensure_stock_crossgen2
  local clrbin="$RUNTIME_REPO/artifacts/bin/coreclr/openharmony.$ARCH.$CONFIG"
  # Read the CoreLib IL from the compiler obj dir: the bin IL/ copy is clobbered
  # (0-byte) by later build steps, which made crossgen2 die on an empty file.
  local corelib_il="$RUNTIME_REPO/artifacts/obj/coreclr/System.Private.CoreLib/openharmony.$ARCH.$CONFIG/System.Private.CoreLib.dll"
  [ -s "$corelib_il" ] || die "CoreLib IL missing: $corelib_il"
  info "producing ReadyToRun CoreLib (official crossgen2, PGO if mibc present)..."
  # PGO data: the reference runtime pack (downloaded on demand) carries
  # tools/StandardOptimizationData.mibc (profiles for the reference-pack
  # assemblies; verified applicable: PGO crossgen of System.Text.Json emits a
  # PGO image). Seed it when the clean build did not produce its own.
  if [ ! -s "$clrbin/StandardOptimizationData.mibc" ] && resolve_reference_runtime_pack; then
    (python3 -c "
import zipfile
z = zipfile.ZipFile('$REFERENCE_RUNTIME_PACK')
open('$clrbin/StandardOptimizationData.mibc','wb').write(z.read('tools/StandardOptimizationData.mibc'))
" && info "PGO mibc seeded from the reference runtime pack") || info "PGO mibc seed failed - continuing without PGO"
  fi
  local mibc="$clrbin/StandardOptimizationData.mibc"
  local pgo_args=()
  [ -s "$mibc" ] && pgo_args=(-m:"$mibc" --embed-pgo-data) || info "no PGO mibc (clean build) — R2R without PGO"
  (cd "$STOCK_CROSSGEN2_DIR/tools" && DOTNET_ROOT="$RUNTIME_REPO/.dotnet" ./crossgen2 \
      -o:"$clrbin/System.Private.CoreLib.dll" -r:"$corelib_il" \
      --targetarch:arm64 --obj-format:pe --targetos:linux \
      "${pgo_args[@]}" -O \
      "$corelib_il") 2>&1 | tee -a "$LOG" || die "R2R CoreLib (official crossgen2) failed"
  # the runtime pack lives in the native/ dir of the layout; sync the R2R image
  local rtpk="$ship/Microsoft.NETCore.App.Runtime.$RID.$RT_VERSION.nupkg"
  local rtl="$RUNTIME_REPO/artifacts/bin/microsoft.netcore.app.runtime.$RID/$CONFIG"
  cp -f "$clrbin/System.Private.CoreLib.dll" "$rtl/runtimes/$RID/native/System.Private.CoreLib.dll" 2>/dev/null || true
  # the sfxproj pack step can emit an EMPTY zip (0 files) on a clean openharmony
  # build; reassemble from the layout + reference metadata only when the pack is
  # missing, zero-length, or an empty/corrupt zip. A valid pack is kept as-is
  # (the CoreLib swap below still runs on it).
  if [ ! -s "$rtpk" ] || ! python3 -c "import zipfile,sys; sys.exit(0 if len(zipfile.ZipFile('$rtpk').namelist()) else 1)" 2>/dev/null; then
    info "Runtime pack empty/corrupt — reassembling from layout"
    resolve_reference_runtime_pack || die "reference runtime pack unavailable (needed to reassemble the runtime pack)"
    local refpk="$REFERENCE_RUNTIME_PACK"
    python3 "$SCRIPT_DIR/pack-runtime.py" "$rtl" "$refpk" "$rtpk" || die "manual runtime pack failed"
  fi
  # swap the PureIL CoreLib in the pack for the R2R image (native/ location).
  # The layout can still be settling (msbuild pack leftovers); retry on failure.
  sleep 3
  local rep_ok=""
  for attempt in 1 2 3; do
    if python3 "$SCRIPT_DIR/replace-pack-corelib.py" \
        "$rtpk" "$clrbin/System.Private.CoreLib.dll" "$rtpk" 2>/dev/null; then
      rep_ok=1; break
    fi
    echo "replace attempt $attempt failed — layout settling, retrying" | tee -a "$LOG"
    sleep 5
  done
  [ -n "$rep_ok" ] || die "replace pack CoreLib failed after retries"
  info "runtime pack CoreLib swapped to R2R ($(stat -c%s "$rtpk") bytes)"
  # --- framework-wide ReadyToRun overlay (mac model, 2026-09-13) -------------
  # The SDK skips already-R2R framework assemblies when a self-contained app
  # publishes with PublishReadyToRun, so overlaying the whole framework here
  # turns device publishes into app-only compiles (previously ~180 assemblies,
  # hours on device). Same stock crossgen2 as the CoreLib step; per-assembly
  # failures (facades/no-IL) are tolerated and stay PureIL.
  # --- diagnostic: in-build crossgen2 (host) on the OHOS CoreLib ------------
  # Round 12/13 saw the official-shape tool hang at startup while the
  # framework-dependent workarounds were in place; the TargetRid fix (host
  # tools resolve the NuGet host pack, the local pack override is target-only)
  # superseded those workarounds, so publish the official shape here for the
  # build host and run a bounded probe. This records whether the in-tree
  # sfxproj PublishReadyToRun path is viable (the round 12/13 hang was never
  # re-tested after the fix).
  # Diagnostic only: the script runs with 'set -euo pipefail', and a failed
  # probe must never fail the build. Everything below runs with 'set +e'
  # (restored at the end of the block), including the initial artifact lookup.
  set +e
  local cg2inb=""
  local cg2_probe_rid=""
  case "$(uname -m)" in
    x86_64|amd64) cg2_probe_rid="linux-x64" ;;
    aarch64|arm64) cg2_probe_rid="linux-arm64" ;;
  esac
  cg2inb=$(ls "$RUNTIME_REPO/artifacts/bin"/*/crossgen2/crossgen2 2>/dev/null | head -1)
  if [ -z "$cg2inb" ] && [ -n "$cg2_probe_rid" ]; then
    local cg2pub_log="$WORK/inbuild-crossgen2-publish.log"
    local cg2out="$WORK/inbuild-crossgen2"
    info "crossgen2 probe: publishing in-build crossgen2 (official shape, $cg2_probe_rid)"
    # Mirror the ilc/crossgen2 split-publish recipe (proven in CI): build from
    # the repo root with the build's target properties, but for the build HOST
    # RID and with the official tool shape untouched. PublishDir is pinned to a
    # work path because the project's default ($(RuntimeBinDir)$(BuildArchitecture)/crossgen2)
    # resolves to an empty BuildArchitecture in a direct invocation, which made
    # the artifact undiscoverable. The 'hostver' variant additionally pins the
    # host runtime pack version the build re-versions into the local feeds.
    for cg2_variant in base hostver; do
      local cg2_extra=""
      if [ "$cg2_variant" = "hostver" ]; then cg2_extra="/p:RuntimeFrameworkVersion=$VERSION_BAND"; fi
      rm -rf "$cg2out"
      : > "$cg2pub_log"
      ( cd "$RUNTIME_REPO" && \
        timeout 900 ./.dotnet/dotnet build src/coreclr/tools/aot/crossgen2/crossgen2_inbuild.csproj \
          -c "$CONFIG" -r "$cg2_probe_rid" -t:Publish \
          -p:TargetOS=openharmony -p:TargetArchitecture="$ARCH" -p:PortableOS=openharmony \
          -p:UseBootstrap=true -p:CrossBuild=true \
          "/p:PublishDir=$cg2out/" \
          /p:OfficialBuildId="$BUILDID" /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" \
          $cg2_extra \
          "/p:RuntimeIdentifierGraphPath=$rsp" -p:IncludeSymbols=false -v:q -nologo \
          ) >> "$cg2pub_log" 2>&1
      cg2inb="$cg2out/crossgen2"
      if [ ! -f "$cg2inb" ]; then
        cg2inb=$(ls "$RUNTIME_REPO/artifacts/bin"/*/crossgen2/crossgen2 2>/dev/null | head -1)
      fi
      if [ -n "$cg2inb" ]; then break; fi
      local cg2_err=""
      cg2_err=$(grep -aE ": error|error [A-Z]{2,}[0-9]{4}|Build FAILED|MSB[0-9]{4}|NETSDK[0-9]{4}|NU[0-9]{4}" "$cg2pub_log" 2>/dev/null | head -1)
      info "crossgen2 probe: publish variant '$cg2_variant' failed: ${cg2_err:-no recognizable error; tail follows}"
      tail -12 "$cg2pub_log" 2>/dev/null
    done
    # In-build tool publishes can leave MSBuild nodes that clobber later
    # outputs; mirror the ilc re-publish cleanup.
    pkill -9 -f "MSBuild.*nodem" 2>/dev/null
    sleep 2
  fi
  if [ -n "$cg2inb" ]; then
    local probe_out="$WORK/inbuild-crossgen2-probe.dll"
    rm -f "$probe_out"
    if DOTNET_ROOT="$RUNTIME_REPO/.dotnet" timeout 180 "$cg2inb" -o:"$probe_out" -r:"$corelib_il" \
        --targetarch:arm64 --obj-format:pe --targetos:linux -O "$corelib_il" > "$WORK/inbuild-crossgen2-probe.log" 2>&1; then
      info "crossgen2 probe: in-build tool OK (image $(stat -c%s "$probe_out" 2>/dev/null || echo 0) B, tool $(stat -c%s "$cg2inb" 2>/dev/null || echo 0) B)"
    else
      local probe_rc=$?
      info "crossgen2 probe: in-build tool FAILED (rc=$probe_rc; 124=timeout) - log $WORK/inbuild-crossgen2-probe.log"
    fi
  elif [ -f "$WORK/inbuild-crossgen2-publish.log" ]; then
    info "crossgen2 probe: in-build tool publish failed - log $WORK/inbuild-crossgen2-publish.log"
  else
    info "crossgen2 probe: in-build crossgen2 binary not found"
  fi
  set -e
  if [ "$OHOS_FRAMEWORK_R2R" = "1" ] && [ "$OHOS_IN_TREE_R2R" != "1" ]; then
    local libdir="$rtl/runtimes/$RID/lib/$TFM"
    local r2rout="$WORK/framework-r2r"
    local r2rrefs="$WORK/framework-r2r-refs"
    [ -d "$libdir" ] || die "framework R2R: layout lib dir missing: $libdir"
    rm -rf "$r2rout" "$r2rrefs"
    mkdir -p "$r2rout" "$r2rrefs"
    # The sfxproj layout keeps System.Private.CoreLib out of lib/$TFM (the
    # pack assembly step adds it); crossgen2 needs it as the core reference, so
    # add the IL image from the compiler obj dir to the ref set.
    cp -f "$libdir"/*.dll "$r2rrefs/" 2>/dev/null || true
    cp -f "$corelib_il" "$r2rrefs/System.Private.CoreLib.dll" || die "framework R2R: CoreLib ref missing"
    info "framework R2R: compiling $(find "$libdir" -maxdepth 1 -name '*.dll' | wc -l) assemblies (stock crossgen2, jobs=$R2R_JOBS)..."
    local r2r_mibc=()
    [ -s "$mibc" ] && r2r_mibc=(--mibc "$mibc") || info "framework R2R: no PGO mibc - compiling without PGO"
    DOTNET_ROOT="$RUNTIME_REPO/.dotnet" python3 "$SCRIPT_DIR/crossgen-framework.py" \
      --crossgen2 "$STOCK_CROSSGEN2_DIR/tools/crossgen2" \
      --libdir "$libdir" --refdir "$r2rrefs" --outdir "$r2rout" --jobs "$R2R_JOBS" \
      "${r2r_mibc[@]}" \
      2>&1 | tee -a "$LOG" || die "framework R2R crossgen failed"
    # the CoreLib R2R image (swapped into the pack above) also belongs to the
    # overlay set so the tarball/SDK shared framework gets it too
    cp -f "$clrbin/System.Private.CoreLib.dll" "$r2rout/" || die "framework R2R: CoreLib R2R image missing"
    python3 "$SCRIPT_DIR/overlay-pack.py" "$rtpk" "$r2rout" || die "framework R2R pack overlay failed"
    cp -f "$r2rout"/*.dll "$libdir/" 2>/dev/null || true
    # the runtime tarball is created by the runtime build before this point; the
    # SDK redist consumes it, so overlaying it makes the SDK shared framework
    # R2R as well (FD apps no longer JIT the runtime framework).
    local rttb
    rttb=$(ls "$ship"/dotnet-runtime-*"$RT_VERSION"*.tar.gz 2>/dev/null | head -1) || true
    if [ -n "$rttb" ]; then
      python3 "$SCRIPT_DIR/overlay-tarball.py" "$rttb" "$r2rout" || die "framework R2R tarball overlay failed"
      info "framework R2R: overlaid runtime tarball $(basename "$rttb")"
    else
      info "framework R2R: runtime tarball for $RT_VERSION not found yet (skipped)"
    fi
    info "framework R2R: overlaid pack ($(stat -c%s "$rtpk") bytes) + layout"
  elif [ "$OHOS_IN_TREE_R2R" = "1" ]; then
    info "in-tree R2R: out-of-tree runtime framework overlay skipped (handled by the build)"
  fi
  # refresh the local feed copy
  cp -f "$ship/Microsoft.NETCore.App.Runtime.$RID.$RT_VERSION.nupkg" "$FEED/" 2>/dev/null
  # --- pre-sign every openharmony ELF (runtime/nativeaot/host/ilc packs + tarballs) ---
  # device loads these from NuGet/app publish, so they must carry .codesign now.
  info "pre-signing runtime packs (ELF -> .codesign)..."
  # shellcheck disable=SC2045
  for pk in "$ship"/*"$RID"*"$RT_VERSION"*.nupkg; do
    [ -f "$pk" ] && sign_all "$pk"
  done
  for tb in "$ship"/dotnet-runtime-*"$RID"*.tar.gz "$ship"/dotnet-crossgen2-*"$RID"*.tar.gz; do
    [ -f "$tb" ] && sign_all "$tb"
  done
  # collect packs into the local feed (post-sign: feed is the downstream restore source)
  find "$ship" -maxdepth 1 -name "*.nupkg" -exec cp -f {} "$FEED/" \;
  find "$ship" -maxdepth 1 -name "*.tar.gz" -exec cp -f {} "$ASSETS/" \;
  info "runtime packs: $(ls "$FEED" | wc -l) nupkg, $(ls "$ASSETS" | wc -l) tarball"
}

# ---- 2. aspnetcore asset layout --------------------------------------------
ASPCORE_TRANSPORT=""
stage2() {
  info "Stage 2: aspnetcore asset server layout"
  # aspnetcore-runtime.proj downloads  <PublicBaseURL>/Runtime/<transport>/dotnet-runtime-<v>-<rid>.tar.gz
  # transport version = the runtime version we override aspnetcore to use
  [ -f "$WORK/rt-version.txt" ] && RT_VERSION=$(cat "$WORK/rt-version.txt")
  RT_VERSION="${RT_VERSION:-$VERSION_BAND-$LABEL.$PRE.$BUILDID}"
  ASPCORE_TRANSPORT="$RT_VERSION"
  mkdir -p "$ASSETS/Runtime/$ASPCORE_TRANSPORT"
  # pick the tarball matching the current build version (assets dir also holds
  # stale dev/older tarballs from previous builds)
  local rt_archive=$(ls "$ASSETS"/dotnet-runtime-*"$RID".tar.gz 2>/dev/null | grep "\.$RT_VERSION\." | head -1)
  [ -n "$rt_archive" ] || rt_archive=$(ls "$ASSETS"/dotnet-runtime-*"$RID".tar.gz 2>/dev/null | tail -1)
  [ -n "$rt_archive" ] || die "no runtime tarball for $RID in $ASSETS (runtime build missing it?)"
  cp -f "$rt_archive" "$ASSETS/Runtime/$ASPCORE_TRANSPORT/$(basename "$rt_archive")"
  # The SDK redist RestoreLayout downloads the shared-framework tarball from
  # Runtime/<Microsoft.NETCore.Platforms blob version>/dotnet-runtime-<RuntimePkgVer>-<rid>.tar.gz.
  # The Platforms version darc-flows independently of our buildid, so mirror the
  # tarball under that folder too (filename already carries our build version).
  local plat_ver=$(python3 -c "
import re, sys
s = open('$SDK_REPO/eng/Version.Details.xml').read()
m = re.search(r'Name=\"Microsoft.NETCore.Platforms\" Version=\"([^\"]+)\"', s)
print(m.group(1) if m else '')
")
  if [ -n "$plat_ver" ] && [ "$plat_ver" != "$ASPCORE_TRANSPORT" ]; then
    mkdir -p "$ASSETS/Runtime/$plat_ver"
    cp -f "$rt_archive" "$ASSETS/Runtime/$plat_ver/$(basename "$rt_archive")"
    info "asset mirrored: Runtime/$plat_ver/$(basename "$rt_archive") (SDK Platforms blob version)"
  fi
  # start the asset http server the aspnetcore/sdk builds download from
  # (PublicBaseURL=http://localhost:$ASSET_PORT/) unless one is already listening
  if ! curl -sf --max-time 2 "http://localhost:$ASSET_PORT/" >/dev/null 2>&1; then
    (cd "$ASSETS" && nohup python3 -m http.server "$ASSET_PORT" >"$WORK/http-server.log" 2>&1 &)
    sleep 1
    curl -sf --max-time 2 "http://localhost:$ASSET_PORT/" >/dev/null 2>&1 \
      || die "asset http server failed to start on :$ASSET_PORT"
    info "asset http server started on :$ASSET_PORT (root $ASSETS)"
  fi
  info "asset: $ASSETS/Runtime/$ASPCORE_TRANSPORT/$(basename "$rt_archive")"
}

# ---- 3. aspnetcore build ----------------------------------------------------
stage3() {
  info "Stage 3: aspnetcore runtime build (App.Runtime + shared framework)"
  [ -f "$WORK/rt-version.txt" ] && RT_VERSION=$(cat "$WORK/rt-version.txt")
  RT_VERSION="${RT_VERSION:-$VERSION_BAND-$LABEL.$PRE.$BUILDID}"
  cd "$ASCORE_REPO"
  local eng_pgraph="$SDK_REPO/eng/PortableRuntimeIdentifierGraph.openharmony.json"
  [ -f "$eng_pgraph" ] || die "no eng portable graph at $eng_pgraph"
  for sd in "$ASCORE_REPO"/.dotnet/sdk/*/; do
    local ridgraph="$sd/PortableRuntimeIdentifierGraph.json"
    if [ ! -f "$ridgraph" ] || ! python3 -c "import json,sys; sys.exit(0 if 'openharmony-arm64' in json.load(open('$ridgraph'))['runtimes'] else 1)" 2>/dev/null; then
      mkdir -p "$(dirname "$ridgraph")"
      cp -f "$eng_pgraph" "$ridgraph"
      info "injected eng/ portable RID graph into aspnetcore SDK $(basename "$sd")"
    fi
  done
  # NETSDK1083 (openharmony-arm64 not recognized) — the aspnetcore bootstrap SDK's
  # RuntimeIdentifierGraph.json also needs the openharmony entries. Inject into every
  # installed SDK (the build uses global.json's, which may not be RIDGRAPH_SDKVER).
  for sd in "$ASCORE_REPO"/.dotnet/sdk/*/; do
    local arsp="$sd/RuntimeIdentifierGraph.json"
    [ -f "$arsp" ] || continue
    if ! python3 -c "import json,sys; sys.exit(0 if 'openharmony-arm64' in json.load(open('$arsp'))['runtimes'] else 1)" 2>/dev/null; then
      [ -f "$SDK_REPO/eng/RuntimeIdentifierGraph.openharmony.json" ] || die "no eng RID graph for aspnetcore inject"
      cp -f "$SDK_REPO/eng/RuntimeIdentifierGraph.openharmony.json" "$arsp"
      info "injected eng/ RID graph into aspnetcore SDK $(basename "$sd")"
    fi
  done
  # aspnetcore's darc-flowed runtime version points at a feed that has no
  # openharmony packs — override the runtime-driven versions to the locally
  # built one so restore hits our feed.
  local rtver="$RT_VERSION"
  # Pre-existing warning noise from the cross-compiled aspnetcore build, not
  # introduced by the OpenHarmony port; upstream sources are deliberately left
  # untouched, so suppress it for this invocation only:
  #   nullable:           CS8602 CS8603 CS8604 CS8618 CS8625 CS8714 CS8764
  #   obsolete/bootstrap: CS0618, CS9103 (RefSafetyRules version mismatch of the
  #                       local ref assemblies vs the bootstrap compiler)
  #   docs/async:         CS1574, CS1998
  #   analyzers:          CA1305 CA1416 CA2000 CA2007 IDE0005 IDE0060 IDE0073 IDE0055 RS0016 RS0041
  #   source-gen:         SYSLIB0057 SYSLIB1002 SYSLIB1005 SYSLIB1006 SYSLIB1025
  #   NuGet:              NU1507 NU1603 NU5128
  #   aspnetcore:         ASPNETCORE_DIRECTTLS_001
  # Removal: drop these codes (or this list) once the cross-compiled aspnetcore
  # build is warning-clean for openharmony-*.
  ./eng/build.sh --os-name "$(echo "$RID" | cut -d- -f1)" --arch "$ARCH" -c "$CONFIG" \
    --no-build-nodejs \
    --projects "$(pwd)/src/Framework/App.Runtime/src/aspnetcore-runtime.proj" \
    -p:PublicBaseURL="http://localhost:$ASSET_PORT/" \
    -p:PublishReadyToRun=false -p:NativeAotSupported=false \
    -p:RestoreAdditionalProjectSources="$FEED" \
    -p:RuntimeIdentifierGraphPath="$ridgraph" \
    -p:MicrosoftNETCoreAppRefPackageVersion="$rtver" \
    -p:MicrosoftInternalRuntimeAspNetCoreTransportPackageVersion="$rtver" \
    -p:SkipValidatePackage=true \
    -p:NoWarn=CS9103%3BCS8714%3BNU1507%3BCA2007%3BIDE0005%3BRS0041%3BNU5128%3BNU1603%3BCS8618%3BCS8764%3BSYSLIB0057%3BCA1416%3BIDE0060%3BCS1574%3BCA2000%3BCA1305%3BCS0618%3BCS1998%3BIDE0073%3BIDE0055%3BRS0016%3BSYSLIB1025%3BASPNETCORE_DIRECTTLS_001%3BSYSLIB1006%3BSYSLIB1002%3BSYSLIB1005%3BCS8604%3BCS8603%3BCS8602%3BCS8625%3BCS8618 \
    /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" /p:OfficialBuildId="$BUILDID" \
    2>&1 | tee -a "$LOG" || die "aspnetcore build failed"
  local aship="$ASCORE_REPO/artifacts/packages/$CONFIG/Shipping"
  # --- aspnetcore ReadyToRun overlay (mac model, 2026-09-13) -----------------
  # Same stock crossgen2 + PGO mibc as the runtime framework overlay: the
  # AspNetCore shared framework is pure IL in the pack, so every ASP.NET app
  # would JIT it on device. Compile/overlay here, before the pre-sign step, so
  # the R2R images are signed together with the rest of the pack and tarball.
  if [ "$OHOS_FRAMEWORK_R2R" = "1" ]; then
    local asppk asptb asplib aspout asprefs
    asppk=$(ls "$aship"/Microsoft.AspNetCore.App.Runtime*"$RID"*"$RT_VERSION"*.nupkg 2>/dev/null | grep -v symbols | head -1 || true)
    asptb=$(ls "$aship"/aspnetcore-runtime-*"$RID"*.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "$asppk" ]; then
      asplib="$WORK/aspnet-r2r-lib"
      aspout="$WORK/aspnet-r2r"
      asprefs="$WORK/aspnet-r2r-refs"
      rm -rf "$asplib" "$aspout" "$asprefs"
      mkdir -p "$asplib" "$aspout" "$asprefs"
      python3 - "$asppk" "$asplib" "$RID" <<'PY' || die "aspnetcore R2R: pack extraction failed"
import os, sys, zipfile
nupkg, outdir, rid = sys.argv[1], sys.argv[2], sys.argv[3]
prefix = "runtimes/%s/lib/net" % rid
count = 0
with zipfile.ZipFile(nupkg) as z:
    for name in z.namelist():
        if name.startswith(prefix) and name.endswith(".dll"):
            with z.open(name) as src, open(os.path.join(outdir, os.path.basename(name)), "wb") as dst:
                dst.write(src.read())
            count += 1
print("aspnetcore R2R: extracted %d assemblies" % count)
PY
      cp -f "$asplib"/*.dll "$asprefs/" 2>/dev/null || true
      cp -f "$RUNTIME_REPO/artifacts/bin/microsoft.netcore.app.runtime.$RID/$CONFIG/runtimes/$RID/lib/$TFM"/*.dll "$asprefs/" 2>/dev/null || true
      cp -f "$RUNTIME_REPO/artifacts/obj/coreclr/System.Private.CoreLib/openharmony.$ARCH.$CONFIG/System.Private.CoreLib.dll" "$asprefs/System.Private.CoreLib.dll" || die "aspnetcore R2R: CoreLib ref missing"
      local as_mibc=()
      local as_mibc_file="$RUNTIME_REPO/artifacts/bin/coreclr/openharmony.$ARCH.$CONFIG/StandardOptimizationData.mibc"
      [ -s "$as_mibc_file" ] && as_mibc=(--mibc "$as_mibc_file") || info "aspnetcore R2R: no PGO mibc - compiling without PGO"
      info "aspnetcore R2R: compiling $(find "$asplib" -maxdepth 1 -name '*.dll' | wc -l) assemblies (stock crossgen2, jobs=$R2R_JOBS)..."
      DOTNET_ROOT="$RUNTIME_REPO/.dotnet" python3 "$SCRIPT_DIR/crossgen-framework.py" \
        --crossgen2 "$STOCK_CROSSGEN2_DIR/tools/crossgen2" \
        --libdir "$asplib" --refdir "$asprefs" --outdir "$aspout" --jobs "$R2R_JOBS" \
        "${as_mibc[@]}" \
        2>&1 | tee -a "$LOG" || die "aspnetcore R2R crossgen failed"
      python3 "$SCRIPT_DIR/overlay-pack.py" "$asppk" "$aspout" || die "aspnetcore R2R pack overlay failed"
      if [ -n "$asptb" ]; then
        python3 "$SCRIPT_DIR/overlay-tarball.py" "$asptb" "$aspout" || die "aspnetcore R2R tarball overlay failed"
      fi
      info "aspnetcore R2R: overlaid pack ($(stat -c%s "$asppk") bytes)${asptb:+, tarball $(stat -c%s "$asptb") bytes}"
    else
      info "aspnetcore R2R: no App.Runtime pack found - skipped"
    fi
  fi
  # pre-sign aspnetcore App.Runtime ELF (shared framework loaded on device)
  for pk in "$aship"/Microsoft.AspNetCore.App.Runtime*"$RID"*"$RT_VERSION"*.nupkg; do
    [ -f "$pk" ] && sign_all "$pk"
  done
  for tb in "$aship"/aspnetcore-runtime-*"$RID"*.tar.gz; do
    [ -f "$tb" ] && sign_all "$tb"
  done
  find "$aship" -maxdepth 1 -name "*.nupkg" -exec cp -f {} "$FEED/" \;
  info "aspnetcore packs staged into feed (signed)"
}

# ---- 4. sdk build -----------------------------------------------------------
stage4() {
  info "Stage 4: sdk redist build (consumes runtime+aspnetcore feed)"
  [ -f "$WORK/rt-version.txt" ] && RT_VERSION=$(cat "$WORK/rt-version.txt")
  RT_VERSION="${RT_VERSION:-$VERSION_BAND-$LABEL.$PRE.$BUILDID}"
  cd "$SDK_REPO"
  local rtver="$RT_VERSION"
  # override ONLY Host/Runtime package versions (Ref/ILLink/Crossgen2 keep the
  # darc-flowed official versions — see Directory.Build.props =='' guards)
  ./build.sh -os openharmony -arch "$ARCH" -c "$CONFIG" \
    /p:MicrosoftNETCoreAppHostPackageVersion="$rtver" \
    /p:MicrosoftNETCoreAppRuntimePackageVersion="$rtver" \
    /p:MicrosoftAspNetCoreAppRuntimePackageVersion="$rtver" \
    /p:RestoreAdditionalProjectSources="$FEED" \
    /p:PublicBaseURL=http://localhost:$ASSET_PORT/ \
    /p:RidGraphOverrideRuntimeJson="$PWD/eng/RuntimeIdentifierGraph.openharmony.json" \
    /p:RidGraphOverridePortableJson="$PWD/eng/PortableRuntimeIdentifierGraph.openharmony.json" \
    /p:IncludeAspNetCoreRuntime=false \
    /p:PreReleaseVersionLabel="$LABEL" /p:PreReleaseVersion="$PRE" /p:OfficialBuildId="$BUILDID" \
    2>&1 | tee -a "$LOG" || die "sdk build failed"
  info "sdk redist produced under $SDK_REPO/artifacts/bin/redist/$CONFIG/dotnet"
  # pre-sign the SDK tarball (every ELF in the redist: dotnet host + all so)
  local sdk_tb
  sdk_tb=$(find "$SDK_REPO/artifacts" -maxdepth 5 -name "dotnet-sdk-*-$RID.tar.gz" | head -1)
  [ -n "$sdk_tb" ] && sign_all "$sdk_tb"
}

# ---- 5. collect + self-check ------------------------------------------------
stage5() {
  info "Stage 5: collect outputs"
  local out="$WORK/output"
  mkdir -p "$out"
  cp -f "$FEED"/*.nupkg "$out/" 2>/dev/null || true
  cp -f "$ASSETS"/*.tar.gz "$out/" 2>/dev/null || true
  # sdk tarball
  find "$SDK_REPO/artifacts" -maxdepth 5 -name "dotnet-sdk-*-$RID.tar.gz" -exec cp -f {} "$out/" \; 2>/dev/null || true
  # aspnetcore tarball
  find "$ASCORE_REPO/artifacts/packages/$CONFIG/Shipping" -maxdepth 1 -name "aspnetcore-runtime-*$RID.tar.gz" -exec cp -f {} "$out/" \; 2>/dev/null || true
  # OpenHarmony platform workload bundle (produced by the ohos-workload repo:
  # scripts/pack-workload-bundle.sh, asset openharmony-workload-<version>.tar.gz).
  # release (install-dotnet-ohos.sh -> install_workload) or from a local path.
  local wb="${OHOS_WORKLOAD_BUNDLE:-}"
  if [ -z "$wb" ]; then
    wb="$(ls -t "$HOME"/springsources/ohos-workload/dist/openharmony-workload-*.tar.gz 2>/dev/null | head -1 || true)"
    [ -n "$wb" ] || wb="$(ls -t "$HOME"/springsources/ohos-workload/dist/ohos-workload-*.tar.gz 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$wb" ] && [ -f "$wb" ]; then
    cp -f "$wb" "$out/"
    info "workload bundle: $(basename "$wb")"
  else
    info "workload bundle not found (set OHOS_WORKLOAD_BUNDLE=... to include it in the outputs)"
  fi
  info "Outputs: $(ls "$out" | wc -l) files in $out"
  echo "--- artifacts ---" | tee -a "$LOG"
  ls -la "$out" | tee -a "$LOG"
}

# ---- run --------------------------------------------------------------------
stage0
if [ -z "$STAGE_ONLY" ] || [ "$STAGE_ONLY" = 1 ]; then [ "$RUN_RUNTIME" = 1 ] && stage1; fi
if [ -z "$STAGE_ONLY" ] || [ "$STAGE_ONLY" = 2 ]; then stage2; fi
if [ -z "$STAGE_ONLY" ] || [ "$STAGE_ONLY" = 3 ]; then [ "$RUN_ASCORE" = 1 ] && stage3; fi
if [ -z "$STAGE_ONLY" ] || [ "$STAGE_ONLY" = 4 ]; then [ "$RUN_SDK" = 1 ] && stage4; fi
if [ -z "$STAGE_ONLY" ]; then stage5; fi
info "done (log: $LOG)"
