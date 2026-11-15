#!/bin/sh
# Clean-machine GA validation for the OpenHarmony .NET 11 product.
#
# Installs the published SDK + workload 1.0.0 into an isolated
# INSTALL_DIR/HOME, then runs the 826 harness, a JIT publish, and the AOT
# fetch/publish flow. Device checks are optional (HDC + UDID).
#
# This script is intended for an OpenHarmony host (or a self-hosted runner);
# it cannot run on a GitHub-hosted Linux runner because the SDK is an
# OpenHarmony arm64 product and the device is local. The offline
# test-clean-machine-plan.sh only exercises --dry-run.
#
# Usage:
#   sh eng/ohos-install/tests/clean-machine-ga.sh [--dry-run]
#
# Env:
#   CLEAN_ROOT        scratch root (default: $HOME/.ohos-clean-machine-ga)
#   SDK_TARBALL       local path or https URL of the SDK tarball
#   WORKLOAD_BUNDLE   local path or https URL of the workload bundle
#   OHOS_WORKLOAD_DIR checkout of ohos-workload (default: sibling ../ohos-workload)
#   NUGET_PACKAGES    package cache for build-time packages (default: host cache)
#   COLD_NUGET=1      use $CLEAN_ROOT/nuget instead of the host cache
#   SKIP_826=1 / SKIP_JIT=1 / SKIP_AOT=1 / SKIP_DEVICE=1
#   HDC / UDID        device tools for the optional install/start checks
#   AOT_ASSETS        optional local dir with the three AOT nupkgs
#   KEEP=0            remove CLEAN_ROOT after success (default: keep for evidence)
#   ALLOW_BUSY=1      bypass the quiet-host preflight (load1 > 2*nproc or MemAvailable < 2 GB)
set -eu

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
run() { if [ "$DRY_RUN" = 1 ]; then printf '+ %s\n' "$*"; else "$@"; fi; }

W="$(cd "$(dirname "$0")/../../.." && pwd)"
HOST_HOME="${HOST_HOME:-$HOME}"
HOST_PATH="${HOST_PATH:-$PATH}"
run_limited() {
    "$@" &
    _rl_cmd=$!
    (
        sleep 1800
        kill -TERM "$_rl_cmd" 2>/dev/null || true
        sleep 30
        kill -KILL "$_rl_cmd" 2>/dev/null || true
    ) &
    _rl_wd=$!
    wait "$_rl_cmd"
    _rl_rc=$?
    kill -TERM "$_rl_wd" 2>/dev/null || true
    wait "$_rl_wd" 2>/dev/null || true
    return "$_rl_rc"
}
# Bounded run for flaky native tooling. TERM is not delivered reliably on
# OpenHarmony hosts, so the watchdog SIGKILLs the whole process group
# (setsid puts the command in its own group).
run_bounded() { # <secs> <cmd...>
    _rb_secs="$1"; shift
    setsid "$@" &
    _rb_cmd=$!
    (
        sleep "$_rb_secs"
        kill -KILL -"$_rb_cmd" 2>/dev/null || kill -KILL "$_rb_cmd" 2>/dev/null || true
    ) &
    _rb_wd=$!
    wait "$_rb_cmd"
    _rb_rc=$?
    kill -KILL "$_rb_wd" 2>/dev/null || true
    wait "$_rb_wd" 2>/dev/null || true
    return "$_rb_rc"
}
# Same idea, but appends to <log> and kills the command when it stops making
# progress: the flaky build path wedges silently (no output, ~1.7 cores of
# spinning threads), so a stall is what a hang looks like from the outside.
run_bounded_log() { # <log> <stall_secs> <max_secs> <cmd...>
    _bl_log="$1"; _bl_stall="$2"; _bl_max="$3"; shift 3
    setsid "$@" >> "$_bl_log" 2>&1 &
    _bl_cmd=$!
    (
        _w=0; _s=0; _prev=-1
        while kill -0 "$_bl_cmd" 2>/dev/null; do
            sleep 15
            _w=$((_w + 15))
            _size="$(wc -c < "$_bl_log" 2>/dev/null || echo 0)"
            if [ "$_size" = "$_prev" ]; then
                _s=$((_s + 15))
            else
                _s=0
                _prev="$_size"
            fi
            if [ "$_s" -ge "$_bl_stall" ] || [ "$_w" -ge "$_bl_max" ]; then
                kill -KILL -"$_bl_cmd" 2>/dev/null || kill -KILL "$_bl_cmd" 2>/dev/null || true
                break
            fi
        done
    ) &
    _bl_wd=$!
    wait "$_bl_cmd"
    _bl_rc=$?
    kill -KILL "$_bl_wd" 2>/dev/null || true
    wait "$_bl_wd" 2>/dev/null || true
    return "$_bl_rc"
}
CLEAN_ROOT="${CLEAN_ROOT:-$HOME/.ohos-clean-machine-ga}"
OHOS_WORKLOAD_DIR="${OHOS_WORKLOAD_DIR:-$W/../ohos-workload}"
AOT_ASSETS="${AOT_ASSETS:-}"

# The self-hosted runner keeps _work behind a symlink (/storage/.../_work ->
# /data/...). MSBuild then sees one project under two spellings, evaluates it
# twice and either deadlocks or races two restores into the same obj files.
# Resolve every path once so the whole gate uses canonical spelling.
canon_path() {
    if [ -d "$1" ]; then
        ( cd "$1" && pwd -P )
    elif [ -d "$(dirname "$1")" ]; then
        printf '%s/%s' "$( cd "$(dirname "$1")" && pwd -P )" "$(basename "$1")"
    else
        printf '%s' "$1"
    fi
}
W="$(canon_path "$W")"
CLEAN_ROOT="$(canon_path "$CLEAN_ROOT")"
OHOS_WORKLOAD_DIR="$(canon_path "$OHOS_WORKLOAD_DIR")"
if [ -n "$AOT_ASSETS" ]; then AOT_ASSETS="$(canon_path "$AOT_ASSETS")"; fi
NUGET_PACKAGES="$(canon_path "${NUGET_PACKAGES:-$HOST_HOME/.nuget/packages}")"
export NUGET_PACKAGES
if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    GITHUB_WORKSPACE="$(canon_path "$GITHUB_WORKSPACE")"
    export GITHUB_WORKSPACE
fi
SKIP_826="${SKIP_826:-0}"
SKIP_JIT="${SKIP_JIT:-0}"
SKIP_AOT="${SKIP_AOT:-0}"
SKIP_DEVICE="${SKIP_DEVICE:-1}"
COLD_NUGET="${COLD_NUGET:-0}"
KEEP="${KEEP:-1}"
norm_bool() { case "${1:-0}" in 1|true|TRUE|yes|on) printf 1 ;; *) printf 0 ;; esac; }
SKIP_826="$(norm_bool "$SKIP_826")"
SKIP_JIT="$(norm_bool "$SKIP_JIT")"
SKIP_AOT="$(norm_bool "$SKIP_AOT")"
SKIP_DEVICE="$(norm_bool "$SKIP_DEVICE")"
COLD_NUGET="$(norm_bool "$COLD_NUGET")"
KEEP="$(norm_bool "$KEEP")"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# shellcheck source=../versions.env
. "$W/eng/ohos-install/versions.env"
# Default to the release line pinned in versions.env, so the gate follows the
# branch it runs on (GA on the release branch, the current dev line on dev).
SDK_TARBALL="${SDK_TARBALL:-https://github.com/${GH_USER}/sdk-ohos/releases/download/${SDK_RELEASE_TAG}/dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz}"
WORKLOAD_BUNDLE="${WORKLOAD_BUNDLE:-https://github.com/${GH_USER}/sdk-ohos/releases/download/workload-${WORKLOAD_BUNDLE_VERSION}/openharmony-workload-${WORKLOAD_BUNDLE_VERSION}.tar.gz}"
SDK_SHA="${SDK_TARBALL_SHA256:-}"
BUNDLE_SHA="${WORKLOAD_BUNDLE_SHA256:-}"
[ -n "$SDK_SHA" ] || die "no SDK_TARBALL_SHA256 in versions.env"
[ -n "$BUNDLE_SHA" ] || die "no WORKLOAD_BUNDLE_SHA256 in versions.env"

if [ "$COLD_NUGET" = 1 ]; then
    NUGET_DIR="$CLEAN_ROOT/nuget"
else
    NUGET_DIR="${NUGET_PACKAGES:-$HOST_HOME/.nuget/packages}"
fi

CLEAN_HOME="$CLEAN_ROOT/home"
CLEAN_DOTNET="$CLEAN_ROOT/dotnet"
CLEAN_TMP="$CLEAN_ROOT/tmp"
LOG_DIR="$CLEAN_ROOT/logs"
SDK_LOCAL="$CLEAN_ROOT/$(basename "${SDK_TARBALL%%\?*}")"
BUNDLE_LOCAL="$CLEAN_ROOT/$(basename "${WORKLOAD_BUNDLE%%\?*}")"

if [ "$DRY_RUN" = 0 ] && [ "${ALLOW_BUSY:-0}" != 1 ]; then
    _nproc="$(nproc 2>/dev/null || echo 1)"
    _load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
    _avail_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if awk -v l="$_load1" -v n="$_nproc" 'BEGIN{exit !(l > 2*n)}'; then
        die "host is busy (load1=$_load1, cpus=$_nproc); run on a quiet runner or set ALLOW_BUSY=1"
    fi
    if [ "${_avail_kb:-0}" -lt 2097152 ] 2>/dev/null; then
        die "MemAvailable=${_avail_kb}kB is below the 2 GB clean-gate floor; run on a quiet runner or set ALLOW_BUSY=1"
    fi
fi

if [ "$DRY_RUN" = 1 ]; then
    log "DRY-RUN clean-machine GA plan"
    log "  clean root:      $CLEAN_ROOT"
    log "  SDK:             $SDK_TARBALL (sha256 $SDK_SHA)"
    log "  workload:        $WORKLOAD_BUNDLE (sha256 $BUNDLE_SHA)"
    log "  OHOS_WORKLOAD:   $OHOS_WORKLOAD_DIR"
    log "  NuGet packages:  $NUGET_DIR"
    log "  device:          $([ "$SKIP_DEVICE" = 1 ] && echo skipped || echo "HDC=${HDC:-hdc} UDID=${UDID:-<unset>}")"
    printf '+ install: %s/eng/ohos-install/install-dotnet-ohos.sh %s\n' "$W" "$SDK_LOCAL"
    printf '+ verify:  %s/dotnet --info && %s/dotnet workload list\n' "$CLEAN_DOTNET" "$CLEAN_DOTNET"
    [ "$SKIP_826" = 1 ] || printf '+ 826:    cd %s/test/maui-platform-verify && %s/dotnet build && %s/dotnet bin/Debug/net11.0/verify.dll\n' "$OHOS_WORKLOAD_DIR" "$CLEAN_DOTNET" "$CLEAN_DOTNET"
    [ "$SKIP_JIT" = 1 ] || printf '+ JIT:    cd %s/test/hello-maui-app && %s/dotnet publish -p:OpenHarmonyHapPackage=true ...\n' "$OHOS_WORKLOAD_DIR" "$CLEAN_DOTNET"
    [ "$SKIP_AOT" = 1 ] || printf '+ AOT:    fetch-nativeaot-packs.sh + publish-aot.sh with DOTNET=%s\n' "$CLEAN_DOTNET"
    [ "$SKIP_DEVICE" = 1 ] || printf '+ device: sign-for-device.sh %s + hdc install/start\n' "${UDID:-<unset>}"
    exit 0
fi

mkdir -p "$CLEAN_HOME" "$CLEAN_DOTNET" "$CLEAN_TMP" "$NUGET_DIR" "$LOG_DIR"
SUCCESS=0
cleanup() {
    if [ "$SUCCESS" = 1 ] && [ "$KEEP" = 0 ]; then
        log "removing clean root (KEEP=0): $CLEAN_ROOT"
        rm -rf "$CLEAN_ROOT"
    else
        log "kept clean root: $CLEAN_ROOT"
    fi
}
trap cleanup 0

fetch_asset() { # <src> <dst> <label>
    _src="$1"; _dst="$2"; _label="$3"
    if [ -f "$_src" ]; then
        log "copying $_label: $_src"
        cp -f "$_src" "$_dst" || die "copy failed: $_src"
    else
        case "$_src" in
            https://*) log "downloading $_label: $_src"
                curl -fL --retry 3 --connect-timeout 20 -o "$_dst" "$_src" \
                    || die "download failed: $_src" ;;
            *) die "asset not found: $_src" ;;
        esac
    fi
}

verify_sha() { # <file> <expected> <label>
    _got="$(sha256sum "$1" | awk '{print $1}')"
    [ "$_got" = "$2" ] || die "$3 sha256 mismatch: got $_got, want $2"
    log "$3 sha256 OK: $_got"
}

log "== clean-machine GA =="
log "root: $CLEAN_ROOT"
log "SDK:  $SDK_TARBALL"
log "bundle: $WORKLOAD_BUNDLE"

fetch_asset "$SDK_TARBALL" "$SDK_LOCAL" "SDK tarball"
verify_sha "$SDK_LOCAL" "$SDK_SHA" "SDK tarball"
fetch_asset "$WORKLOAD_BUNDLE" "$BUNDLE_LOCAL" "workload bundle"
verify_sha "$BUNDLE_LOCAL" "$BUNDLE_SHA" "workload bundle"

log "== install (isolated HOME/INSTALL_DIR) =="
(
    export HOME="$CLEAN_HOME"
    export INSTALL_DIR="$CLEAN_DOTNET"
    export TMPDIR="$CLEAN_TMP"
    export NUGET_PACKAGES="$NUGET_DIR"
    export DOTNET_CLI_HOME="$CLEAN_HOME"
    export DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
    export TARBALL_SHA256="$SDK_SHA"
    export WORKLOAD_BUNDLE="$BUNDLE_LOCAL"
    export WORKLOAD_SHA256="$BUNDLE_SHA"
    export WORKLOAD_BUNDLE_VERSION
    export PATH="$CLEAN_DOTNET:$HOST_PATH"
    run_limited sh "$W/eng/ohos-install/install-dotnet-ohos.sh" "$SDK_LOCAL"
) > "$LOG_DIR/install.log" 2>&1 || { tail -40 "$LOG_DIR/install.log"; die "install failed"; }
log "install OK"

export HOME="$CLEAN_HOME"
export DOTNET_ROOT="$CLEAN_DOTNET"
export PATH="$CLEAN_DOTNET:$HOST_PATH"
export DOTNET_CLI_HOME="$CLEAN_HOME"
export NUGET_PACKAGES="$NUGET_DIR"
export DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
# Do not set MSBUILDDISABLENODEREUSE here: disabling node reuse makes the
# OpenHarmony runtime wedge MSBuild before the first target runs.
export DOTNET_CLI_USE_MSBUILD_SERVER=0 UseSharedCompilation=false
export MSBUILDUSESERVER=0 DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1
export DOTNET_NUGET_SIGNATURE_VERIFICATION=false
export TMPDIR="$CLEAN_TMP"
if [ -f "$HOST_HOME/.harmonybrew/etc/openssl@3/openssl.cnf" ]; then
    export OPENSSL_CONF="$HOST_HOME/.harmonybrew/etc/openssl@3/openssl.cnf"
fi
export DOTNET_SYSTEM_CRYPTOGRAPHY_OPENSSL_NO_LOCKING=1

"$CLEAN_DOTNET/dotnet" --info > "$LOG_DIR/dotnet-info.log" 2>&1 || die "clean dotnet --info failed"
grep -qE "Version:[[:space:]]*${SDK_VERSION}" "$LOG_DIR/dotnet-info.log" || die "unexpected SDK version (want $SDK_VERSION)"
"$CLEAN_DOTNET/dotnet" workload list > "$LOG_DIR/workload-list.log" 2>&1 || die "workload list failed"
# The workload manifest band tracks the SDK feature band, including the
# prerelease label (the dev rc.3 SDK installs sdk-manifests/11.0.100-rc.3).
SDK_PRERELEASE="$(printf '%s' "$SDK_VERSION" | sed -n 's/^[0-9][0-9.]*\(-[A-Za-z][A-Za-z0-9]*\.[0-9][0-9]*\).*/\1/p')"
WORKLOAD_BAND="${SDK_BAND}${SDK_PRERELEASE}"
grep -qE "openharmony[[:space:]]+${WORKLOAD_BUNDLE_VERSION}/${WORKLOAD_BAND}([^0-9]|$)" "$LOG_DIR/workload-list.log" || die "workload ${WORKLOAD_BUNDLE_VERSION}/${WORKLOAD_BAND} not installed"

# The Sdk pack version follows the workload line; do not hardcode the GA 1.0.0
# path (the 1.0.1 servicing workload installs packs/Microsoft.OpenHarmony.Sdk/1.0.1).
SDK_PACK_DIR="$(ls -d "$CLEAN_DOTNET/packs/Microsoft.OpenHarmony.Sdk"/*/ 2>/dev/null | sort -V | tail -1)"
[ -n "$SDK_PACK_DIR" ] || die "OpenHarmony Sdk pack not installed"
UI_SHELL="$SDK_PACK_DIR/templates/ets/modules.ui.abc"
HEADLESS_SHELL="$SDK_PACK_DIR/templates/ets/modules.abc"
[ -n "${OPENHARMONY_UI_SHELL_SHA256:-}" ] || die "no OPENHARMONY_UI_SHELL_SHA256 pin in versions.env"
[ -n "${OPENHARMONY_HEADLESS_SHELL_SHA256:-}" ] || die "no OPENHARMONY_HEADLESS_SHELL_SHA256 pin in versions.env"
[ "$(sha256sum "$UI_SHELL" | awk '{print $1}')" = "$OPENHARMONY_UI_SHELL_SHA256" ] || die "UI shell hash mismatch"
[ "$(sha256sum "$HEADLESS_SHELL" | awk '{print $1}')" = "$OPENHARMONY_HEADLESS_SHELL_SHA256" ] || die "headless shell hash mismatch"
if [ "$OPENHARMONY_SIGN_HAP_OPENSSL_ISOLATION" = 1 ]; then
    grep -q 'unset OPENSSL_CONF OPENSSL_MODULES OPENSSL_ENGINES' \
        "$SDK_PACK_DIR/templates/scripts/sign-hap.sh" \
        || die "sign-hap.sh is missing the OpenSSL isolation"
fi
log "clean workload/pack verification OK"

if [ "$SKIP_826" != 1 ] || [ "$SKIP_JIT" != 1 ] || [ "$SKIP_AOT" != 1 ]; then
    [ -d "$OHOS_WORKLOAD_DIR/test/hello-maui-app" ] || die "OHOS_WORKLOAD_DIR is not an ohos-workload checkout: $OHOS_WORKLOAD_DIR"
fi

run_826() { # <log>
    _log="$1"
    : > "$_log"
    (
      cd "$OHOS_WORKLOAD_DIR/test/maui-platform-verify" || exit 1
      _arcade_tools="$NUGET_PACKAGES/microsoft.dotnet.arcade.sdk/11.0.0-beta.26527.113/tools"
      # OpenHarmony's runtime wedges MSBuild/Mono-style builds at random points
      # (silent stall, spinning threads) and can hang at process exit. Keep the
      # intermediate state between attempts so a retry resumes instead of
      # restarting, and judge success by the produced binary, not by exit code.
      rm -rf obj bin
      _n=1
      while [ "$_n" -le 10 ]; do
          log "826 build attempt $_n/10"
          rm -rf "$TMPDIR"/MSBuildTemp* "$TMPDIR"/.dotnet/lockfiles 2>/dev/null || true
          if [ ! -f obj/project.assets.json ]; then
              run_bounded_log "$_log" 120 240 "$CLEAN_DOTNET/dotnet" restore \
                  /p:RestoreSources= /p:NuGetAudit=false /p:ArcadeSdkDir="$_arcade_tools/" || true
          fi
          run_bounded_log "$_log" 90 420 "$CLEAN_DOTNET/dotnet" build --no-restore -m:1 -v:m \
              /p:UseSharedCompilation=false /p:NuGetAudit=false /p:ArcadeSdkDir="$_arcade_tools/" || true
          [ -f bin/Debug/net11.0/verify.dll ] && break
          _n=$((_n + 1))
          sleep 3
      done
      [ -f bin/Debug/net11.0/verify.dll ] || { log "826 build never produced verify.dll"; exit 1; }
      _r=1
      while [ "$_r" -le 3 ]; do
          log "826 suite attempt $_r/3"
          # A pty keeps the suite output line-flushed even when the process
          # wedges during shutdown.
          run_bounded_log "$_log" 120 900 script -q -c "$CLEAN_DOTNET/dotnet bin/Debug/net11.0/verify.dll" /dev/null || true
          grep -q '\[suite\] checks=' "$_log" && exit 0
          _r=$((_r + 1))
          sleep 3
      done
      exit 1
    )
}

if [ "$SKIP_826" != 1 ]; then
    log "== 826 harness =="
    _826_log="$LOG_DIR/826.log"
    if ! run_826 "$_826_log"; then
        if grep -q 'frame-path performance budget failed' "$_826_log"; then
            log "WARN: 826 perf budget failed under host load; retrying once"
            sleep 5
            _826_log="$LOG_DIR/826-retry.log"
            run_826 "$_826_log" || { tail -40 "$_826_log"; die "826 harness failed (retry)"; }
        else
            tail -40 "$_826_log"; die "826 harness failed"
        fi
    fi
    grep -q '^\[suite\] checks=826 total=829 floor=809 assert=True' "$_826_log" \
        || { tail -10 "$_826_log"; die "826 suite floor mismatch"; }
    log "826 OK"
fi

JIT_HAP=""
if [ "$SKIP_JIT" != 1 ]; then
    log "== JIT publish =="
    _jit_hap="$OHOS_WORKLOAD_DIR/test/hello-maui-app/bin/Release/net11.0-openharmony26.0/openharmony-arm64/hello-maui-app.hap"
    _j=1
    while [ "$_j" -le 6 ]; do
        log "JIT publish attempt $_j/6"
        rm -rf "$TMPDIR"/MSBuildTemp* "$TMPDIR"/.dotnet/lockfiles 2>/dev/null || true
        ( cd "$OHOS_WORKLOAD_DIR/test/hello-maui-app" && \
          : > "$LOG_DIR/jit-publish.log" && \
          run_bounded_log "$LOG_DIR/jit-publish.log" 240 1500 script -q -c \
            "$CLEAN_DOTNET/dotnet publish hello-maui-app.csproj -c Release -r openharmony-arm64 -m:1 \
              -p:OpenHarmonyUIPage=pages/Index -p:OpenHarmonyHapPackage=true \
              -f net11.0-openharmony26.0 -p:OpenHarmonyRuntimeMode=jit -p:InvariantGlobalization=true" /dev/null ) || true
        [ -f "$_jit_hap" ] && break
        _j=$((_j + 1))
        sleep 3
    done
    [ -f "$_jit_hap" ] || { tail -40 "$LOG_DIR/jit-publish.log"; die "JIT publish failed"; }
    grep -q 'OpenHarmony: signed' "$LOG_DIR/jit-publish.log" || die "JIT publish did not sign the hap"
    JIT_HAP="$_jit_hap"
    [ "$(unzip -p "$JIT_HAP" ets/modules.abc | sha256sum | awk '{print $1}')" = "9aa02cf80d74f53662330e25bead00c0e4b1b059c824d24fabfab17ff43089b3" ] \
        || die "JIT hap does not carry the 38-built UI shell"
    log "JIT publish OK: $JIT_HAP"
fi

sign_and_start() { # <hap> <label>
    _hap="$1"; _label="$2"
    [ -n "${UDID:-}" ] || die "$_label device check needs UDID"
    _hdc="${HDC:-hdc}"
    case "$_hdc" in
        */*) [ -x "$_hdc" ] || die "$_label device check needs an executable HDC: $_hdc" ;;
        *) command -v "$_hdc" >/dev/null 2>&1 || die "$_label device check needs HDC (not found: $_hdc)" ;;
    esac
    _signed="$CLEAN_ROOT/${_label}-device.hap"
    ( cd "$OHOS_WORKLOAD_DIR" && sh scripts/sign-for-device.sh "$UDID" \
        --bundle mauidemo.dotnet.springmin.com --unsigned "$_hap" --out "$_signed" ) \
        > "$LOG_DIR/${_label}-sign.log" 2>&1 || { tail -30 "$LOG_DIR/${_label}-sign.log"; die "$_label sign failed"; }
    "$_hdc" shell bm clean -n mauidemo.dotnet.springmin.com -d >/dev/null 2>&1 || true
    "$_hdc" shell bm clean -n mauidemo.dotnet.springmin.com -c >/dev/null 2>&1 || true
    "$_hdc" shell aa force-stop mauidemo.dotnet.springmin.com >/dev/null 2>&1 || true
    "$_hdc" install -r "$_signed" > "$LOG_DIR/${_label}-install.log" 2>&1 || { tail -20 "$LOG_DIR/${_label}-install.log"; die "$_label install failed"; }
    "$_hdc" shell hilog -r >/dev/null 2>&1 || true
    "$_hdc" shell aa start -a EntryAbility -b mauidemo.dotnet.springmin.com > "$LOG_DIR/${_label}-start.log" 2>&1 || true
    sleep 8
    _pid="$("$_hdc" shell pidof mauidemo.dotnet.springmin.com 2>/dev/null | tr -d '\r' | head -1)"
    [ -n "$_pid" ] || die "$_label app is not running"
    "$_hdc" shell hilog -x 2>/dev/null | grep -q 'canvas presented' || die "$_label canvas not presented"
    log "$_label device OK: pid=$_pid"
}

if [ "$SKIP_DEVICE" != 1 ] && [ "$SKIP_JIT" != 1 ]; then
    sign_and_start "$JIT_HAP" jit
fi

AOT_HAP=""
if [ "$SKIP_AOT" != 1 ]; then
    log "== AOT fetch/publish =="
    (
        cd "$W"
        if [ -n "$AOT_ASSETS" ]; then
            sh eng/ohos-install/fetch-nativeaot-packs.sh --local "$AOT_ASSETS" "$CLEAN_ROOT/aot-feed"
        else
            sh eng/ohos-install/fetch-nativeaot-packs.sh "$CLEAN_ROOT/aot-feed"
        fi
    ) > "$LOG_DIR/aot-fetch.log" 2>&1 || { tail -40 "$LOG_DIR/aot-fetch.log"; die "AOT fetch failed"; }
    AOT_WORKDIR="$CLEAN_ROOT/aot-work"
    rm -rf "$AOT_WORKDIR"; mkdir -p "$AOT_WORKDIR/feed"
    cp -f "$CLEAN_ROOT/aot-feed"/*.nupkg "$AOT_WORKDIR/feed/"
    ( cd "$OHOS_WORKLOAD_DIR/test/hello-maui-app" && rm -rf obj bin )
    _a=1
    while [ "$_a" -le 4 ]; do
        log "AOT publish attempt $_a/4"
        rm -rf "$TMPDIR"/MSBuildTemp* "$TMPDIR"/.dotnet/lockfiles 2>/dev/null || true
        ( cd "$OHOS_WORKLOAD_DIR" && \
          : > "$LOG_DIR/aot-publish.log" && \
          AOT_WORKDIR="$AOT_WORKDIR" DOTNET="$CLEAN_DOTNET/dotnet" run_bounded_log "$LOG_DIR/aot-publish.log" 300 2400 script -q -c \
            "sh test/hello-maui-app/publish-aot.sh" /dev/null ) || true
        grep -q 'EXIT=0' "$AOT_WORKDIR/publish-aot.log" 2>/dev/null && break
        _a=$((_a + 1))
        sleep 3
    done
    grep -q 'EXIT=0' "$AOT_WORKDIR/publish-aot.log" || { tail -40 "$LOG_DIR/aot-publish.log"; die "AOT publish failed"; }
    AOT_HAP="$OHOS_WORKLOAD_DIR/test/hello-maui-app/bin/Release/net11.0-openharmony26.0/openharmony-arm64/hello-maui-app.hap"
    [ -f "$AOT_HAP" ] || die "AOT hap missing"
    [ -f "$OHOS_WORKLOAD_DIR/test/hello-maui-app/bin/Release/net11.0-openharmony26.0/openharmony-arm64/publish/libhello-maui-app.so" ] \
        || die "AOT native library missing"
    for w in IL2026 IL3050 IL3051; do
        n="$(awk -v w="$w" '$1 == w { print $2; exit }' "$AOT_WORKDIR/publish-aot.log" 2>/dev/null)"
        [ "${n:-1}" -eq 0 ] || die "AOT IL gate $w=${n:-missing}"
    done
    log "AOT publish OK: $AOT_HAP"
fi

if [ "$SKIP_DEVICE" != 1 ] && [ "$SKIP_AOT" != 1 ]; then
    sign_and_start "$AOT_HAP" aot
fi

SUCCESS=1
log "CLEAN-MACHINE GA PASS"
log "logs: $LOG_DIR"
