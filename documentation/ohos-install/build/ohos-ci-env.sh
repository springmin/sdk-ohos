#!/usr/bin/env bash
# ============================================================================
# ohos-ci-env.sh — Prepare the OHOS cross-build environment from scratch.
#
# Builds everything build-ohos-all.sh needs that is NOT obtained by the
# repo builds themselves:
#   NDK      OpenHarmony Public SDK native/ (llvm + sysroot, ohos clang)
#   OpenSSL  3.3.1 cross-compiled static libs for aarch64-ohos
#   ICU      75.1 cross-compiled static libs for aarch64-ohos
#
# Output layout (default PREFIX=~/.ohos-ci-env; override with --prefix):
#   $PREFIX/ndk            -> OHOS_NDK_HOME (native/ contents)
#   $PREFIX/openssl/install-> OPENSSL_DIR (lib/libcrypto.a + headers)
#   $PREFIX/icu/install    -> ICU_DIR (lib/ + include/)
#
# Prints the three env vars to stdout (eval "$(ohos-ci-env.sh ...)") or
# sources them when run as `source ohos-ci-env.sh ...`.
#
# Usage:
#   ohos-ci-env.sh [--prefix DIR] [--arch aarch64] [--config Debug]
#                  [--ndk-url URL] [--keep-sdk-tar]
#   Env overrides: OPENSSL_VERSION ICU_VERSION NDK_URL (mirrors --ndk-url)
#
# Reference for the OpenSSL/ICU incantations (device-verified):
#   runtime docs/plans/2026-08-13-ohos-cross-compile.md (problems 8-15)
# ============================================================================
set -euo pipefail

ARCH=aarch64
CONFIG=Debug
PREFIX="${PREFIX:-$HOME/.ohos-ci-env}"
KEEP_SDK_TAR=0
NDK_URL="${NDK_URL:-https://repo.huaweicloud.com/openharmony/os/6.0.0.1-Release/ohos-sdk-windows_linux-public.tar.gz}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.3.1}"
ICU_VERSION="${ICU_VERSION:-75.1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --config) CONFIG="$2"; shift 2;;
    --ndk-url) NDK_URL="$2"; shift 2;;
    --keep-sdk-tar) KEEP_SDK_TAR=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

mkdir -p "$PREFIX"
log() { printf '\033[1;34m[env]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# NDK — OpenHarmony Public SDK (linux). The SDK tarball contains native/
# (llvm + sysroot) which is what OHOS_NDK_HOME must point at.
# ---------------------------------------------------------------------------
install_ndk() {
  [ -x "$PREFIX/ndk/llvm/bin/${ARCH}-unknown-linux-ohos-clang" ] && { log "NDK present"; return; }
  local sdk_tar="$PREFIX/ohos-sdk-windows_linux-public.tar.gz"
  if [ ! -f "$sdk_tar" ]; then
    log "Downloading OpenHarmony Public SDK (~3GB)..."
    curl -fL --retry 3 -o "$sdk_tar" "$NDK_URL"
  fi
  log "Extracting native/ (NDK) from SDK tarball..."
  # tarball layout: ./linux/ohos-sdk/linux/native/... (Public SDK for linux)
  tar tzf "$sdk_tar" 2>/dev/null | grep -m1 "native/llvm/bin/.*-clang$" || \
    { echo "ERROR: cannot locate native/ in SDK tarball" >&2; exit 3; }
  local tmp="$(mktemp -d)"
  tar xzf "$sdk_tar" -C "$tmp"
  local native="$(dirname "$(find "$tmp" -maxdepth 4 -type d -name native | head -1)")"
  # native dir sits next to its siblings; copy contents
  mv "$tmp"/*/*/native "$PREFIX/ndk" 2>/dev/null || mv "$(find "$tmp" -maxdepth 4 -type d -name native | head -1)" "$PREFIX/ndk"
  rm -rf "$tmp"
  [ "$KEEP_SDK_TAR" = 0 ] && rm -f "$sdk_tar"
  [ -x "$PREFIX/ndk/llvm/bin/${ARCH}-unknown-linux-ohos-clang" ] || \
    { echo "ERROR: NDK clang missing after extract" >&2; exit 3; }
  log "NDK ready: $PREFIX/ndk"
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
    log "Downloading OpenSSL $ver..."
    curl -fL --retry 3 -o "$work/openssl.tar.gz" \
      "https://github.com/openssl/openssl/releases/download/openssl-$ver/openssl-$ver.tar.gz"
    tar xzf "$work/openssl.tar.gz" -C "$work/src"
  fi
  local ndk="$PREFIX/ndk" llvm="$ndk/llvm/bin" wrap="$work/wrap"
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
  local uscore="${ver/./_}" src_archive="$icu_dir/icu4c-${uscore}-src.tgz"
  if [ ! -f "$src_archive" ]; then
    log "Downloading ICU $ver..."
    curl -fL --retry 3 -o "$src_archive" \
      "https://github.com/unicode-org/icu/releases/download/release-${ver}/icu4c-${uscore}-src.tgz"
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
    local ndk="$PREFIX/ndk/llvm/bin" trip="${ARCH}-unknown-linux-ohos"
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
export OHOS_NDK_HOME="$PREFIX/ndk"
export OPENSSL_DIR="$PREFIX/openssl/install"
export ICU_DIR="$PREFIX/icu/install"
EOF
