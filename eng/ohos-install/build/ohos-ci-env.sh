#!/usr/bin/env bash
# ============================================================================
# ohos-ci-env.sh — Prepare the OHOS cross-build environment from scratch.
#
# Builds everything build-ohos-all.sh needs that is NOT obtained by the
# repo builds themselves:
#   NDK      OpenHarmony Public SDK native/ (llvm + sysroot, ohos clang)
#   OpenSSL  cross-compiled static libs for aarch64-ohos
#   ICU      cross-compiled static libs for aarch64-ohos
# Versions and the NDK URL come from ../versions.env (env overrides win).
#
# Output layout (default PREFIX=~/.ohos-ci-env; override with --prefix):
#   $PREFIX/ohos-sdk       -> OHOS_NDK_HOME (SDK root, contains native/)
#   $PREFIX/openssl/install-> OPENSSL_DIR (lib/libcrypto.a + headers)
#   $PREFIX/icu/install    -> ICU_DIR (lib/ + include/)
#
# Prints the three env vars to stdout (eval "$(ohos-ci-env.sh ...)") or
# sources them when run as `source ohos-ci-env.sh ...`.
#
# Usage:
#   ohos-ci-env.sh [--prefix DIR] [--arch aarch64] [--config Debug]
#                  [--ndk-url URL] [--keep-sdk-tar]
#                  [--ndk-sha256 HEX] [--openssl-sha256 HEX] [--icu-sha256 HEX]
#                  [--print-digest ndk|openssl|icu] [--allow-unverified]
#   Env overrides: OPENSSL_VERSION ICU_VERSION NDK_URL (mirrors --ndk-url)
#                  NDK_SHA256 OPENSSL_SHA256 ICU_SHA256 (pins)
#
# Supply-chain verification (C7): every downloaded artifact (NDK tarball,
# OpenSSL source, ICU source) is checked against a published checksum before it
# is extracted. Resolution order for the expected digest:
#   1) explicit pin: --<artifact>-sha256 / NDK_SHA256 / OPENSSL_SHA256 / ICU_SHA256
#   2) sibling <url>.sha256            (first 64-hex token; OpenSSL publishes this)
#   3) sibling <dir>/SHA256SUMS        ("<hex>  <asset>" lines)
#   4) sibling <url>.sha512 / <dir>/SHASUM512.txt (128-hex; ICU publishes this)
#   5) GitHub API release-asset digest (sha256) for github.com release downloads
# When no digest resolves, the artifact is refused (exit 3) unless
# --allow-unverified is passed. --allow-unverified is insecure, must stay
# explicit, and applies to an overridden --ndk-url as well. --print-digest
# prints just the resolved hex digest (no trailing newline) so CI can include
# the exact artifact digests in its cache key.
#
# Reference for the OpenSSL/ICU incantations (device-verified):
#   runtime docs/plans/2026-08-13-ohos-cross-compile.md (problems 8-15)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/../versions.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/../versions.env (run this script from the sdk-ohos repository)" >&2
  exit 1
fi
# shellcheck source=../versions.env
. "$SCRIPT_DIR/../versions.env"

ARCH=aarch64
CONFIG=Debug
PREFIX="${PREFIX:-$HOME/.ohos-ci-env}"
KEEP_SDK_TAR=0
ALLOW_UNVERIFIED=0
PRINT_DIGEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --config) CONFIG="$2"; shift 2;;
    --ndk-url) NDK_URL="$2"; shift 2;;
    --ndk-sha256) NDK_SHA256="$2"; shift 2;;
    --openssl-sha256) OPENSSL_SHA256="$2"; shift 2;;
    --icu-sha256) ICU_SHA256="$2"; shift 2;;
    --print-digest) PRINT_DIGEST="$2"; shift 2;;
    --allow-unverified) ALLOW_UNVERIFIED=1; shift;;
    --keep-sdk-tar) KEEP_SDK_TAR=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

log() { printf '\033[1;34m[env]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# checksum verification helpers (C7: verify before extract)
# ---------------------------------------------------------------------------
sha256_file() { sha256sum "$1" | cut -d' ' -f1; }
sha512_file() { sha512sum "$1" | cut -d' ' -f1; }

verify_digest() { # <file> <spec> <what>; spec: sha256:<hex>|sha512:<hex>|<64hex>|<128hex>
  local file="$1" spec="$2" what="$3" algo="" hex="" got=""
  case "$spec" in
    sha256:*) algo=sha256; hex="${spec#sha256:}" ;;
    sha512:*) algo=sha512; hex="${spec#sha512:}" ;;
    *)
      if [ "${#spec}" -eq 64 ]; then algo=sha256; hex="$spec"
      elif [ "${#spec}" -eq 128 ]; then algo=sha512; hex="$spec"
      else echo "ERROR: malformed checksum for $what: $spec" >&2; return 1
      fi ;;
  esac
  hex="$(printf '%s' "$hex" | tr 'A-F' 'a-f')"
  if [ "$algo" = sha512 ]; then got="$(sha512_file "$file")"; else got="$(sha256_file "$file")"; fi
  if [ "$got" != "$hex" ]; then
    echo "ERROR: $algo mismatch for $what" >&2
    echo "  expected: $hex" >&2
    echo "  actual:   $got" >&2
    return 1
  fi
  log "checksum OK ($algo): $what"
}

fetch_url_text() { # <url> -> stdout (no logging); nonzero when unreachable
  local url="$1" tmp
  tmp="$(mktemp)" || return 1
  if curl -fsSL --retry 2 --connect-timeout 20 --max-time 120 -o "$tmp" "$url" >/dev/null 2>&1; then
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

github_asset_digest() { # <owner> <repo> <tag> <asset> -> sha256:<hex>
  local owner="$1" repo="$2" tag="$3" asset="$4" body
  body="$(fetch_url_text "https://api.github.com/repos/$owner/$repo/releases/tags/$tag")" || return 1
  printf '%s\n' "$body" | awk -v want="$asset" '
    /"name": / { hit = (index($0, "\"name\": \"" want "\"") > 0) ? 1 : 0; next }
    hit && /"digest": "sha256:/ {
      s = $0; sub(/.*"digest": "sha256:/, "", s); sub(/".*/, "", s); print "sha256:" s; exit
    }'
}

resolve_digest() { # <url> <asset-name> [pin] -> digest spec or empty
  local url="$1" name="$2" pin="${3:-}" dir txt v rest owner repo tag
  if [ -n "$pin" ]; then printf '%s' "$pin"; return 0; fi
  dir="${url%/*}"
  # <url>.sha256
  if txt="$(fetch_url_text "$url.sha256")"; then
    v="$(printf '%s\n' "$txt" | grep -oE '[0-9a-fA-F]{64}' | head -1 || true)"
    if [ -n "$v" ]; then printf 'sha256:%s' "$(printf '%s' "$v" | tr 'A-F' 'a-f')"; return 0; fi
  fi
  # <dir>/SHA256SUMS
  if txt="$(fetch_url_text "$dir/SHA256SUMS")"; then
    v="$(printf '%s\n' "$txt" | awk -v a="$name" '$NF == a || $NF == "*" a { print $1; exit }')"
    v="$(printf '%s' "$v" | grep -oE '^[0-9a-fA-F]{64}$' || true)"
    if [ -n "$v" ]; then printf 'sha256:%s' "$(printf '%s' "$v" | tr 'A-F' 'a-f')"; return 0; fi
  fi
  # <url>.sha512 / <dir>/SHASUM512.txt
  if txt="$(fetch_url_text "$url.sha512")"; then
    v="$(printf '%s\n' "$txt" | grep -oE '[0-9a-fA-F]{128}' | head -1 || true)"
    if [ -n "$v" ]; then printf 'sha512:%s' "$(printf '%s' "$v" | tr 'A-F' 'a-f')"; return 0; fi
  fi
  if txt="$(fetch_url_text "$dir/SHASUM512.txt")"; then
    v="$(printf '%s\n' "$txt" | awk -v a="$name" '$NF == a || $NF == "*" a { print $1; exit }')"
    v="$(printf '%s' "$v" | grep -oE '^[0-9a-fA-F]{128}$' || true)"
    if [ -n "$v" ]; then printf 'sha512:%s' "$(printf '%s' "$v" | tr 'A-F' 'a-f')"; return 0; fi
  fi
  # GitHub API release-asset digest
  case "$url" in
    https://github.com/*/releases/download/*)
      rest="${url#https://github.com/}"; owner="${rest%%/*}"
      rest="${rest#*/}"; repo="${rest%%/*}"
      rest="${rest#*/releases/download/}"; tag="${rest%%/*}"
      github_asset_digest "$owner" "$repo" "$tag" "$name" && return 0
      ;;
  esac
  return 1
}

require_digest() { # <digest> <what> <pin-var>; exits 3 when unverifiable and not opted out
  local digest="$1" what="$2" var="$3"
  [ -n "$digest" ] && return 0
  if [ "$ALLOW_UNVERIFIED" = 1 ]; then
    log "WARNING: --allow-unverified: $what has no checksum and will NOT be verified (insecure)"
    return 0
  fi
  echo "ERROR: no checksum available for $what" >&2
  echo "  Pin one (export $var=<sha256> or pass the matching --*-sha256 flag)," >&2
  echo "  or pass --allow-unverified to download without verification (insecure)." >&2
  exit 3
}

download_verified() { # <url> <dest> <what> <digest|"">; downloads to .part, verifies, moves
  local url="$1" dest="$2" what="$3" digest="${4:-}"
  if [ -z "$digest" ] && [ "$ALLOW_UNVERIFIED" != 1 ]; then
    echo "ERROR: refusing unverified download: $what (no checksum resolved)" >&2
    return 1
  fi
  log "Downloading $what..."
  curl -fL --retry 3 -o "$dest.part" "$url" || { rm -f "$dest.part"; echo "ERROR: download failed: $url" >&2; return 1; }
  if [ -n "$digest" ]; then
    verify_digest "$dest.part" "$digest" "$what" || { rm -f "$dest.part"; return 1; }
  else
    log "WARNING: $what NOT verified (--allow-unverified)"
  fi
  mv -f "$dest.part" "$dest"
}

# --print-digest: resolve one artifact's digest for CI cache keys (hex only).
if [ -n "$PRINT_DIGEST" ]; then
  pd_url=""; pd_name=""; pd_pin=""
  case "$PRINT_DIGEST" in
    ndk)
      pd_url="$NDK_URL"; pd_name="$(basename "${NDK_URL%%\?*}")"; pd_pin="${NDK_SHA256:-}" ;;
    openssl)
      pd_url="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
      pd_name="openssl-$OPENSSL_VERSION.tar.gz"; pd_pin="${OPENSSL_SHA256:-}" ;;
    icu)
      pd_uscore="${ICU_VERSION/./_}"; pd_tagver="${ICU_VERSION/./-}"
      pd_url="https://github.com/unicode-org/icu/releases/download/release-$pd_tagver/icu4c-$pd_uscore-src.tgz"
      pd_name="icu4c-$pd_uscore-src.tgz"; pd_pin="${ICU_SHA256:-}" ;;
    *) echo "ERROR: --print-digest expects ndk|openssl|icu (got: $PRINT_DIGEST)" >&2; exit 2 ;;
  esac
  pd_digest="$(resolve_digest "$pd_url" "$pd_name" "$pd_pin" || true)"
  if [ -z "$pd_digest" ]; then
    if [ "$ALLOW_UNVERIFIED" = 1 ]; then
      log "WARNING: no checksum for $PRINT_DIGEST (--allow-unverified); printing empty digest"
      exit 0
    fi
    echo "ERROR: no checksum available for $PRINT_DIGEST ($pd_url)" >&2
    echo "  Pin --$PRINT_DIGEST-sha256, or pass --allow-unverified (insecure)." >&2
    exit 3
  fi
  printf '%s' "${pd_digest#*:}"
  exit 0
fi

mkdir -p "$PREFIX"

# ---------------------------------------------------------------------------
# NDK — OpenHarmony Public SDK (linux). Layout: the SDK tarball extracts to
# <root>/linux/native-linux-x64-<ver>-Release.zip (+ ets/js/previewer/toolchains
# zips); unzip the native zip -> native/ (llvm + sysroot) = OHOS_NDK_HOME.
# OpenHarmony's llvm ships a generic `clang`, not ${trip}-clang wrappers, so
# create the wrappers the runtime build + OpenSSL expect (HarmonyOS NDK has
# them natively).
# ---------------------------------------------------------------------------
install_ndk() {
  [ -x "$PREFIX/ohos-sdk/native/llvm/bin/${ARCH}-unknown-linux-ohos-clang" ] && { log "NDK present"; return; }
  local sdk_tar="$PREFIX/ohos-sdk-windows_linux-public.tar.gz"
  if [ ! -f "$sdk_tar" ]; then
    local ndk_name ndk_digest
    ndk_name="$(basename "${NDK_URL%%\?*}")"
    ndk_digest="$(resolve_digest "$NDK_URL" "$ndk_name" "${NDK_SHA256:-}" || true)"
    # An overridden --ndk-url must resolve to a published checksum too; without
    # one this is refused unless --allow-unverified was passed explicitly.
    require_digest "$ndk_digest" "OpenHarmony Public SDK ($NDK_URL)" "NDK_SHA256"
    download_verified "$NDK_URL" "$sdk_tar" "OpenHarmony Public SDK ($ndk_name)" "$ndk_digest" \
      || { echo "ERROR: SDK download failed or checksum mismatch" >&2; exit 3; }
  fi
  log "Extracting NDK from SDK tarball..."
  local tmp="$(mktemp -d)"
  tar xzf "$sdk_tar" -C "$tmp" || { echo "ERROR: SDK tarball extract failed" >&2; rm -rf "$tmp"; exit 3; }
  local native_zip="$(find "$tmp" -name "native-linux-x64-*.zip" | head -1)"
  [ -n "$native_zip" ] || { echo "ERROR: native-linux-x64 zip not found" >&2; rm -rf "$tmp"; exit 3; }
  unzip -q "$native_zip" -d "$PREFIX/ndk-tmp"
  mkdir -p "$PREFIX/ohos-sdk"
mv "$PREFIX/ndk-tmp/native" "$PREFIX/ohos-sdk/native"
  rm -rf "$PREFIX/ndk-tmp" "$tmp"
  [ "$KEEP_SDK_TAR" = 0 ] && rm -f "$sdk_tar"
  [ -d "$PREFIX/ohos-sdk/native/llvm" ] || { echo "ERROR: NDK llvm missing after extract" >&2; exit 3; }
  ensure_ndk_wrappers
  log "NDK ready: $PREFIX/ohos-sdk/native"
}

# ${trip}-{clang,clang++,gcc,g++,ar,ranlib,nm,as} wrappers -> llvm tools
ensure_ndk_wrappers() {
  local llvm="$PREFIX/ohos-sdk/native/llvm/bin" trip="${ARCH}-unknown-linux-ohos"
  [ -x "$llvm/$trip-clang" ] && return
  log "Creating ${trip}-* compiler wrappers (generic clang NDK)..."
  ln -sf clang        "$llvm/$trip-clang"
  ln -sf clang++      "$llvm/$trip-clang++"
  ln -sf clang        "$llvm/$trip-gcc"
  ln -sf clang++      "$llvm/$trip-g++"
  ln -sf llvm-ar      "$llvm/$trip-ar"
  ln -sf llvm-ranlib  "$llvm/$trip-ranlib"
  ln -sf llvm-nm      "$llvm/$trip-nm"
  ln -sf llvm-as      "$llvm/$trip-as"
  [ -x "$llvm/$trip-clang" ] || { echo "ERROR: wrapper creation failed" >&2; exit 3; }
}

# ---------------------------------------------------------------------------
# OpenSSL — cross static. OpenSSL's makefile appends -gcc/-ar etc to the
# triplet, but OHOS only ships clang wrappers, so create symlinks first
# (08-13 doc problems 13/14).
# ---------------------------------------------------------------------------
install_openssl() {
  [ -f "$PREFIX/openssl/install/lib/libcrypto.a" ] && { log "OpenSSL present"; return; }
  local ver="$OPENSSL_VERSION" work="$PREFIX/openssl"
  mkdir -p "$work/src" "$work/install"
  local src="$work/src/openssl-$ver"
  if [ ! -f "$src/Configure" ]; then
    local ossl_url="https://github.com/openssl/openssl/releases/download/openssl-$ver/openssl-$ver.tar.gz"
    local ossl_digest
    ossl_digest="$(resolve_digest "$ossl_url" "openssl-$ver.tar.gz" "${OPENSSL_SHA256:-}" || true)"
    require_digest "$ossl_digest" "OpenSSL $ver source" "OPENSSL_SHA256"
    download_verified "$ossl_url" "$work/openssl.tar.gz" "OpenSSL $ver source" "$ossl_digest" \
      || { echo "ERROR: OpenSSL download failed or checksum mismatch" >&2; exit 4; }
    tar xzf "$work/openssl.tar.gz" -C "$work/src"
  fi
  local ndk="$PREFIX/ohos-sdk/native"
  local llvm="$ndk/llvm/bin"
  local wrap="$work/wrap"
  mkdir -p "$wrap"
  local trip="${ARCH}-unknown-linux-ohos"
  ln -sf "$llvm/$trip-clang"  "$wrap/$trip-gcc"
  ln -sf "$llvm/$trip-clang++" "$wrap/$trip-g++"
  ln -sf "$llvm/llvm-ar"      "$wrap/$trip-ar"
  ln -sf "$llvm/llvm-ranlib"  "$wrap/$trip-ranlib"
  ln -sf "$llvm/llvm-nm"      "$wrap/$trip-nm"
  export PATH="$wrap:$PATH"
  ( cd "$src"
    perl Configure "linux-${ARCH/-/}" no-shared no-tests \
      --prefix="$work/install" --cross-compile-prefix="$trip-" -static
    make -j"$(nproc)" >/dev/null
    make install_sw >/dev/null )
  unset PATH
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  [ -f "$work/install/lib/libcrypto.a" ] || { echo "ERROR: OpenSSL build failed" >&2; exit 4; }
  log "OpenSSL ready: $work/install"
}

# ---------------------------------------------------------------------------
# ICU — two-step: host build first (icupkg etc needed by the target build),
# then the ohos cross build with --with-cross-build pointing at it.
# ---------------------------------------------------------------------------
install_icu() {
  [ -d "$PREFIX/icu/install/lib" ] && { log "ICU present"; return; }
  local ver="$ICU_VERSION" icu_dir="$PREFIX/icu"
  mkdir -p "$icu_dir"
  # ICU_VERSION 75.1 -> source archive icu4c-75_1-src.tgz
  local uscore="${ver/./_}"
  local tagver="${ver/./-}"
  local src_archive="$icu_dir/icu4c-${uscore}-src.tgz"
  if [ ! -f "$src_archive" ]; then
    local icu_url="https://github.com/unicode-org/icu/releases/download/release-${tagver}/icu4c-${uscore}-src.tgz"
    local icu_digest
    icu_digest="$(resolve_digest "$icu_url" "icu4c-${uscore}-src.tgz" "${ICU_SHA256:-}" || true)"
    require_digest "$icu_digest" "ICU $ver source" "ICU_SHA256"
    download_verified "$icu_url" "$src_archive" "ICU $ver source" "$icu_digest" \
      || { echo "ERROR: ICU download failed or checksum mismatch" >&2; exit 5; }
  fi
  local root="$icu_dir/icu-src"
  [ -d "$root" ] || { mkdir -p "$root"; tar xzf "$src_archive" -C "$root" --strip-components=1; }
  local src="$root/source"

  # --- host build ---
  if [ ! -x "$icu_dir/host-install/bin/icu-config" ] && [ ! -f "$icu_dir/host-build/icudefs.mk" ]; then
    log "ICU host build..."
    mkdir -p "$icu_dir/host-build"
    ( cd "$icu_dir/host-build"
      "$src/configure" --prefix="$icu_dir/host-install" --disable-shared --enable-static \
        --disable-tests --disable-samples --disable-layoutex --disable-icuio >/dev/null
      make -j"$(nproc)" >/dev/null
      make install >/dev/null )
  fi

  # --- target cross build ---
  if [ ! -d "$icu_dir/install/lib" ]; then
    local ndk="$PREFIX/ohos-sdk/native/llvm/bin" trip="${ARCH}-unknown-linux-ohos"
    log "ICU target cross build (${trip})..."
    mkdir -p "$icu_dir/target-build" "$icu_dir/install"
    ( cd "$icu_dir/target-build"
      CC="$ndk/$trip-clang" CXX="$ndk/$trip-clang++" \
      CFLAGS="--target=${ARCH}-linux-ohos -fPIC" \
      CXXFLAGS="--target=${ARCH}-linux-ohos -stdlib=libc++ -fPIC" \
      LDFLAGS="-static" \
      "$src/configure" --host=aarch64-linux-gnu --prefix="$icu_dir/install" \
        --enable-static --disable-shared --disable-tests --disable-samples \
        --with-cross-build="$icu_dir/host-build" >/dev/null
      make -j"$(nproc)" >/dev/null
      make install >/dev/null )
  fi
  [ -d "$icu_dir/install/lib" ] || { echo "ERROR: ICU build failed" >&2; exit 5; }
  log "ICU ready: $icu_dir/install"
}

install_ndk
install_openssl
install_icu

cat <<EOF
export OHOS_NDK_HOME="$PREFIX/ohos-sdk"
export OPENSSL_DIR="$PREFIX/openssl/install"
export ICU_DIR="$PREFIX/icu/install"
EOF
