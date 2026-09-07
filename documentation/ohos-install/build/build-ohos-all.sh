#!/usr/bin/env bash
# ============================================================================
# build-ohos-all.sh — Build the complete OHOS (OpenHarmony) .NET product set
# from source in one invocation, mirroring official CI build-leg logic.
#
#   runtime (cross, -os ohos) ──packs/feed──▶ aspnetcore (App.Runtime) ──▶ sdk (redist)
#
# Official CI has no single pipeline chaining the three repos; they are wired
# by darc/feed version flow. This script reproduces that locally: each repo is
# built with its official build-leg parameters and the intermediate nupkgs /
# runtime tarball are handed over through a local NuGet directory + asset dir.
#
# CI-alignment notes (2026-09-04 audit, docs/plans round-14c):
#  - runtime subset clr+libs+host+packs == official runtime.yml AllSubsets_CoreCLR*
#    cross legs (linux-musl-arm64 etc.); -os ohos + --cross carry the OHOS sysroot.
#  - ILCompiler packs via clr.aot+packs + explicit NativeAOT.sfxproj == fork plan C.7
#    (DotNetBuildAllRuntimePacks=true would also trigger Mono cross-AOT).
#  - ReadyToRun CoreLib uses the OFFICIAL NuGet crossgen2 + pack CoreLib swap:
#    OHOS-only (fork crossgen2_inbuild hangs; no PGO in ohos). Intentional deviation.
#  - aspnetcore: os-name=ohos passes through (no whitelist); PublishReadyToRun=false
#    + NativeAotSupported=false are OHOS kill switches; PublicBaseURL local server
#    stands in for ci.dot.net feeds. Version overrides replace darc pins.
#  - sdk: no -pack (SDK assemblies stay IL; official R2Rs them) and
#    IncludeAspNetCoreRuntime=false (ASP.NET Core ships in the separate
#    aspnetcore-ohos release) are intentional deviations — full-support =true
#    variant is in sdk docs/plans 12.4.
#  - Pre-package .codesign signing (sign-ohos-pre.py) is OHOS-only (device loads
#    only signed ELF); moved from install-dotnet-ohos.sh sign_all().
#
# Usage:
#   sh build-ohos-all.sh [--arch arm64] [--rid ohos-arm64] [--config Release]
#                        [--buildid 20260901.1] [--skip-runtime|--skip-aspnetcore|--skip-sdk]
#                        [--stage-only 1|3]        # run only one stage (1=runtime …)
#
# Required env:
#   OHOS_NDK_HOME     OHOS NDK root (e.g. /home/springmin/hmos-tools/sdk/default/openharmony)
#   RUNTIME_REPO SDK_REPO ASCORE_REPO  (defaults to $HOME/sources/{runtime,sdk,aspnetcore-ohos})
#   OPENSSL_DIR ICU_DIR                (cross-compiled OpenSSL + ICU for the target)
#
# Version flow (keep the three repos on ONE version so feeds resolve):
#   LABEL=rc, PRE=1, OFFICIALBUILDID=<id>  →  11.0.0-rc.1.<yyMMdd>.<id>
#   sdk uses 11.0.100-rc.1.<...>  (SDK band 100 vs runtime 0) via its own build.
# ============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
ARCH="${ARCH:-arm64}"
RID="ohos-${ARCH}"
CONFIG="${CONFIG:-Release}"
LABEL="${LABEL:-rc}"
PRE="${PRE:-1}"
BUILDID="${BUILDID:-20260901.109}"
VERSION_BAND="${VERSION_BAND:-11.0.0}"          # runtime/aspnetcore
SDK_BAND="${SDK_BAND:-11.0.100}"                # sdk
RIDGRAPH_SDKVER="${RIDGRAPH_SDKVER:-11.0.100-preview.6.26359.118}"  # bootstrap SDK whose RID graph carries ohos
HOME_DIR="${HOME:-/home/springmin}"
RUNTIME_REPO="${RUNTIME_REPO:-$HOME_DIR/sources/runtime}"
SDK_REPO="${SDK_REPO:-$HOME_DIR/sources/sdk}"
ASCORE_REPO="${ASCORE_REPO:-$HOME_DIR/sources/aspnetcore-ohos}"
# Runtime work dir (feed/assets/log/selfsign/stock tools). Defaults to a
# .work dir under this build/ folder (git-ignored) so a fresh clone can run.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$(dirname "$SCRIPT_DIR")/.work}"
FEED="$WORK/feed"              # local NuGet directory feed
ASSETS="$WORK/assets"          # runtime tarball assets for aspnetcore
LOG="$WORK/build.log"
OHOS_NDK_HOME="${OHOS_NDK_HOME:-}"
OPENSSL_DIR="${OPENSSL_DIR:-/tmp/openssl-ohos/install}"
ICU_DIR="${ICU_DIR:-/tmp/icu-ohos-install}"
# Official crossgen2 used to produce the ReadyToRun CoreLib image. Our fork-built
# crossgen2_inbuild (self-contained, embedded host) hangs at startup on its own
# EventSource/AdvSimd path (see runtime docs/plans round-13); the OFFICIAL NuGet
# crossgen2 compiles the ohos CoreLib R2R fine (18.9MB, PGO). Matches how the
# official CI's crossgen2 runs against the previously-published host runtime.
STOCK_CROSSGEN2_VERSION="${STOCK_CROSSGEN2_VERSION:-11.0.0-rc.1.26427.131}"
STOCK_CROSSGEN2_DIR="$WORK/stock-crossgen2/$STOCK_CROSSGEN2_VERSION"

RUN_RUNTIME=1; RUN_ASCORE=1; RUN_SDK=1
STAGE_ONLY=""
for a in "$@"; do
  case "$a" in
    --arch=*)   ARCH="${a#*=}"; RID="ohos-$ARCH" ;;
    --rid=*)    RID="${a#*=}" ;;
    --config=*) CONFIG="${a#*=}" ;;
    --buildid=*) BUILDID="${a#*=}" ;;
    --skip-runtime) RUN_RUNTIME=0 ;;
    --skip-aspnetcore) RUN_ASCORE=0 ;;
    --skip-sdk) RUN_SDK=0 ;;
    --stage-only=*) STAGE_ONLY="${a#*=}" ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
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

# ensure the OFFICIAL NuGet crossgen2 (downloads if not cached)
ensure_stock_crossgen2() {
  if [ -x "$STOCK_CROSSGEN2_DIR/tools/crossgen2" ]; then
    info "stock crossgen2 ready: $STOCK_CROSSGEN2_VERSION"
    return 0
  fi
  # resolution order: repo-bundled -> NuGet cache -> dnceng public feed
  # (this is an internal-dev build: NOT on nuget.org, which returns 404)
  local nupkg=""
  local bundled="$SCRIPT_DIR/third-party/microsoft.netcore.app.crossgen2.linux-x64.$STOCK_CROSSGEN2_VERSION.nupkg"
  [ -f "$bundled" ] && nupkg="$bundled"
  if [ -z "$nupkg" ]; then
    local cache="$HOME/.nuget/packages/microsoft.netcore.app.crossgen2.linux-x64/$STOCK_CROSSGEN2_VERSION"
    [ -d "$cache" ] && nupkg=$(ls "$cache"/*.nupkg 2>/dev/null | grep -v symbols | head -1)
  fi
  if [ -z "$nupkg" ]; then
    mkdir -p "$HOME/.nuget/packages/microsoft.netcore.app.crossgen2.linux-x64/$STOCK_CROSSGEN2_VERSION"
    nupkg="$HOME/.nuget/packages/microsoft.netcore.app.crossgen2.linux-x64/$STOCK_CROSSGEN2_VERSION/microsoft.netcore.app.crossgen2.linux-x64.$STOCK_CROSSGEN2_VERSION.nupkg"
    info "downloading official crossgen2 $STOCK_CROSSGEN2_VERSION (dnceng dotnet12 feed)..."
    curl -sL --fail --retry 3 -o "$nupkg" \
      "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet12/nuget/v3/flat2/microsoft.netcore.app.crossgen2.linux-x64/$STOCK_CROSSGEN2_VERSION/microsoft.netcore.app.crossgen2.linux-x64.$STOCK_CROSSGEN2_VERSION.nupkg" \
      || die "download official crossgen2 failed (place the nupkg at $SCRIPT_DIR/third-party/ to go offline)"
  fi
  mkdir -p "$STOCK_CROSSGEN2_DIR"
  python3 -c "import zipfile; zipfile.ZipFile('$nupkg').extractall('$STOCK_CROSSGEN2_DIR')" || die "extract crossgen2 failed"
  chmod +x "$STOCK_CROSSGEN2_DIR/tools/crossgen2" 2>/dev/null
  info "stock crossgen2: $STOCK_CROSSGEN2_DIR/tools/crossgen2 ($STOCK_CROSSGEN2_VERSION)"
}


# sign every ELF inside a .nupkg (OHOS .codesign) — idempotent (skips signed)
ensure_selfsign() {
  local selfsign="$WORK/selfsign"
  if [ ! -x "$selfsign" ]; then
    info "building selfsign (sdk documentation/ohos-install)..."
    local dotnet_bin="${DOTNET:-$RUNTIME_REPO/.dotnet/dotnet}"
    (cd "$SDK_REPO/documentation/ohos-install" && \
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
  local nio="$RUNTIME_REPO/artifacts/obj/coreclr/ohos.$ARCH.$CONFIG/debug/runtimeinfo/libruntimeinfo.a"
  if [ ! -s "$nio" ]; then
    info "pre-building libruntimeinfo.a (clean-build link order)..."
    (cd "$RUNTIME_REPO/artifacts/obj/coreclr/ohos.$ARCH.$CONFIG" \
      && ninja debug/runtimeinfo/libruntimeinfo.a) >>"$LOG" 2>&1 || die "libruntimeinfo.a build failed"
  fi
}

# On a clean build the shims (NetFx facade assemblies: System.dll, mscorlib,
# netstandard, ...) are filtered out of libs.sfx by the unix-vs-net11.0 TFM
# mismatch and sfx-finish fails ("...were missing"). Compile all shims (their
# referenced libs are already built at that point) and copy the facades into
# the shared-framework layout, then retry the libs build once.
compile_shims_into_layout() {
  local rsp="$RUNTIME_REPO/.dotnet/sdk/$RIDGRAPH_SDKVER/RuntimeIdentifierGraph.json"
  local layout="$RUNTIME_REPO/artifacts/bin/microsoft.netcore.app.runtime.$RID/$CONFIG/runtimes/$RID/lib/net11.0"
  mkdir -p "$layout"
  info "compiling shims (facade assemblies) and copying into the layout..."
  for P in $(find "$RUNTIME_REPO/src/libraries/shims" -name "*.csproj" -path "*/src/*" | sort); do
    (cd "$RUNTIME_REPO" && ./.dotnet/dotnet build "$P" -c "$CONFIG" \
      -p:TargetOS=ohos -p:TargetArchitecture="$ARCH" -p:PortableOS=ohos -p:UseBootstrapLayout=true \
      "-p:RuntimeIdentifierGraphPath=$rsp" -p:IncludeSymbols=false \
      -p:PreReleaseVersionLabel="$LABEL" -p:PreReleaseVersion="$PRE" -p:OfficialBuildId="$BUILDID" \
      -v:q -nologo) >>"$LOG" 2>&1 || { echo "shim build failed: $P" | tee -a "$LOG"; return 1; }
  done
  for D in "$RUNTIME_REPO"/artifacts/bin/*/Release/net11.0-unix; do
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
  for p in "$packs/11.0.0-rc.1.26451.109" "$packs/11.0.100-rc.1.26420.103" "$packs/$RIDGRAPH_SDKVER" $(ls -d "$packs"/*/ 2>/dev/null); do
    [ -d "$p/ref" ] && [ -f "$p/data/FrameworkList.xml" ] && { sdkref="$p"; break; }
  done
  [ -n "$sdkref" ] || die "no SDK Ref pack to seed bootstrap (looked under $packs)"
  local bdir="$RUNTIME_REPO/artifacts/bootstrap/ohos-$ARCH/microsoft.netcore.app/ref"
  mkdir -p "$bdir"
  cp -rf "$sdkref"/. "$bdir/"
  [ -f "$bdir/data/FrameworkList.xml" ] || die "bootstrap ref seed missing FrameworkList.xml"
  info "seeded bootstrap ref pack from SDK Ref ($(basename "$sdkref"))"
}

build_clr_libs_packs() {
  # Mirror the host linux-x64 runtime packs into the local NuGet feed (flat)
  # so the in-build tool restore (RestoreAdditionalProjectSources=$FEED) and
  # SDK runtime-pack download can resolve them regardless of version source.
  if [ -d /tmp/hostfeed ]; then
    mkdir -p "$FEED"
    find /tmp/hostfeed -name "*.nupkg" -exec cp -n {} "$FEED/" \;
    info "host packs mirrored into FEED ($(ls "$FEED" | grep -c linux-x64) linux-x64 nupkgs)"
  fi
  # The in-build tools resolve the host runtime pack at ProductVersion
  # (11.0.0 base, no suffix) per targetingpacks KnownRuntimePack; re-version
  # the seeded 26451.109 pack to 11.0.0 in both the folder feed and the flat
  # feed (docs/plans problem-4 pattern: repackage to the requested version).
  if [ -f /tmp/hostfeed/microsoft.netcore.app.runtime.linux-x64/11.0.0-rc.1.26451.109/microsoft.netcore.app.runtime.linux-x64.11.0.0-rc.1.26451.109.nupkg ]; then
    for dest in /tmp/hostfeed "$FEED"; do
      mkdir -p "$dest/microsoft.netcore.app.runtime.linux-x64/11.0.0"
      python3 -c "
import zipfile, io
src = '/tmp/hostfeed/microsoft.netcore.app.runtime.linux-x64/11.0.0-rc.1.26451.109/microsoft.netcore.app.runtime.linux-x64.11.0.0-rc.1.26451.109.nupkg'
out = '$dest/microsoft.netcore.app.runtime.linux-x64/11.0.0/microsoft.netcore.app.runtime.linux-x64.11.0.0.nupkg'
zin = zipfile.ZipFile(src)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zout:
    for n in zin.namelist():
        d = zin.read(n)
        if n.endswith('.nuspec') or n.endswith('.nupkg.metadata'):
            d = d.decode().replace('11.0.0-rc.1.26451.109', '11.0.0').encode()
        zout.writestr(n, d)
" && info "re-versioned host pack to 11.0.0 in $dest"
    done
  fi
  # Seed every hostfeed version into the NuGet global cache too (the SDK
  # runtime-pack check looks at ~/.nuget for the resolved version).
  if [ -d /tmp/hostfeed ]; then
    for nupkg in $(find /tmp/hostfeed -name "*.nupkg"); do
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
  # reads NuGet.config sources, not RestoreAdditionalProjectSources; the
  # /tmp/hostfeed folder feed (created by the workflow) must be a NuGet.config
  # source for crossgen2_inbuild/ILCompiler_inbuild to resolve the host
  # linux-x64 runtime pack (NETSDK1112 on clean hosts).
  python3 - "$RUNTIME_REPO/NuGet.config" "$FEED" <<'PYEOF'
import sys
f = sys.argv[1]
s = open(f).read()
if 'local-hostfeed' not in s:
    marker = '  </packageSources>'
    add = '    <add key="local-hostfeed" value="/tmp/hostfeed" />\n    <add key="local-feed" value="' + sys.argv[2] + '" />\n'
    assert marker in s, "packageSources close not found"
    s = s.replace(marker, add + marker, 1)
    open(f, 'w').write(s)
    print("added local-hostfeed folder source to NuGet.config")
PYEOF
  RESTORE_SOURCES="$(grep -oE 'value="[^"]*"' "$RUNTIME_REPO/NuGet.config" | sed 's/value="//; s/"//' | grep -E '^http|^/' | tr '\n' ';')$FEED;/tmp/hostfeed"
  info "restore sources set (NuGet.config + /tmp/hostfeed)"
  # A clean build hits several self-healing failures (all ordering, not our
  # code): singlefilehost links before libruntimeinfo.a is built, sfx-finish
  # runs before the shims (facades) are compiled, and restore needs the
  # bootstrap ref pack before any local ref exists. Handle each once and
  # retry; normal incremental runs never take these paths.
  local attempt=0
  local fixed=""
  local alog="$WORK/build-attempt.log"    # per-attempt output for self-heal detection
  while :; do
    if ./build.sh -os ohos -arch "$ARCH" --cross -c "$CONFIG" -lc "$CONFIG" -rc "$CONFIG" \
        -subset clr+libs+packs \
        /p:UseBootstrapLayout=true /p:BuildHostTools=true /p:ApiCompatValidateAssemblies=false \
        /p:RuntimeIdentifierGraphPath="$rsp" /p:IncludeSymbols=false \
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
      (cd "$RUNTIME_REPO" && ./.dotnet/dotnet build src/libraries/Microsoft.Bcl.Numerics/src/Microsoft.Bcl.Numerics.csproj -f netstandard2.1         -p:TargetOS=ohos -p:TargetArchitecture=arm64 -p:UseBootstrapLayout=true -v:diag 2>&1 |         grep -iE "References=|/r:|netstandard.dll|System.Runtime.dll|ResolveFrameworkReferences|CS0518|netstandard.library" | head -12) 2>/dev/null | tee -a "$LOG" || true
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
    ls "$HOME/.nuget/packages/microsoft.netcore.app.runtime.linux-x64/11.0.0-rc.1.26420.103/" 2>/dev/null | head -6 | tee -a "$LOG"
    echo "--- last attempt log tail ---" | tee -a "$LOG"
    tail -40 "$alog" | tee -a "$LOG"
    echo "--- configure platform lines ---" | tee -a "$LOG"
    grep -iE "CMAKE_SYSTEM_NAME|The C compiler|CMAKE_CROSSCOMPILING|Targeting|System is|CMAKE_TOOLCHAIN_FILE|CMAKE_SYSTEM_PROCESSOR" "$alog" 2>/dev/null | head -12 | tee -a "$LOG"
    die "runtime build (clr+libs+packs) failed (see log tail above)"
  done
}

# pre-seed a host-RID runtime pack into ~/.nuget (clean hosts cannot restore
# the host pack for the in-build toolchain from the feed in some cmake/nuget
# combos — NETSDK1112). ILCompiler_inbuild is SelfContained at the SDK runtime
# version (nuget.org), so try that first, then dnceng dotnet12 candidates.
ensure_nuget_runtime_pack() {
  local rid="$1"
  local id="microsoft.netcore.app.runtime.$rid"
  local ver
  for ver in "$2" "$3" "$4"; do
    [ -n "$ver" ] || continue
    local dir="$HOME/.nuget/packages/$id/$ver"
    [ -d "$dir" ] && return 0
    local url=""
    # GitHub-hosted copy first (CI cannot reliably reach dnceng/nuget.org for
    # these; see sdk-ohos release 'host-runtime-packs'), then the origin feeds.
    case "$ver" in
      11.0.0-rc.1.26420.103) url="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/flat2/$id/$ver/$id.$ver.nupkg" ;;
      11.0.0-rc.1.26431.109|11.0.0-rc.1.26451.109) url="https://github.com/springmin/sdk-ohos/releases/download/host-runtime-packs/$id.$ver.nupkg" ;;
      *) url="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet12/nuget/v3/flat2/$id/$ver/$id.$ver.nupkg" ;;
    esac
    info "pre-seeding $id $ver..."
    local tmp="$(mktemp -d)"
    if curl -fsSL --retry 2 -o "$tmp/p.nupkg" "$url"; then
      mkdir -p "$dir"
      cp "$tmp/p.nupkg" "$dir/$id.$ver.nupkg"
      python3 -c "import hashlib,base64,json; h=base64.b64encode(hashlib.sha512(open('$tmp/p.nupkg','rb').read()).digest()).decode(); open('$dir/$id.$ver.nupkg.sha512','w').write(h); open('$dir/.nupkg.metadata','w').write(json.dumps({'version':2,'contentHash':h,'source':'local'}))"
      (cd "$dir" && python3 -c "import zipfile; zipfile.ZipFile('$tmp/p.nupkg').extractall('.')")
      cp "$dir"/*.nuspec "$dir/$id.nuspec" 2>/dev/null
      rm -rf "$tmp"
      if ls "$dir"/*.nuspec >/dev/null 2>&1; then info "pre-seeded $id $ver"; return 0; fi
    else
      rm -rf "$tmp"
      info "  (not found: $id $ver)"
    fi
  done
  return 1
}

# ---- 1. runtime cross build -------------------------------------------------
RUNTIME_RID_DIR=""       # e.g. artifacts/bin/coreclr/ohos.arm64.Release
stage1() {
  info "Stage 1: runtime cross build (-os ohos -arch $ARCH --cross)"
  export MSBUILDDISABLENODEREUSE=1
  cd "$RUNTIME_REPO"
  # Bootstrap SDK RID graph must carry the ohos entries (independent RID).
  # Inject the repo's eng graphs (complete 802-RID files) into every installed
  # SDK whose graph lacks ohos — the runtime build actually uses the
  # global.json SDK version, which may differ from RIDGRAPH_SDKVER. Covers
  # fresh clones / CI (no pre-seeded .dotnet).
  local eng_rsp="$SDK_REPO/eng/RuntimeIdentifierGraph.ohos.json"
  local eng_prsp="$SDK_REPO/eng/PortableRuntimeIdentifierGraph.ohos.json"
  local gjv=""
  if [ -f "$RUNTIME_REPO/global.json" ]; then
    gjv=$(python3 -c "import json;print(json.load(open('$RUNTIME_REPO/global.json'))['sdk']['version'])" 2>/dev/null || true)
  fi
  for v in $RIDGRAPH_SDKVER $gjv; do
    [ -n "$v" ] || continue
    local sdkdir="$RUNTIME_REPO/.dotnet/sdk/$v"
    [ -d "$sdkdir" ] || continue
    local rsp="$sdkdir/RuntimeIdentifierGraph.json"
    if [ -f "$rsp" ] && ! python3 -c "import json,sys; sys.exit(0 if 'ohos-arm64' in json.load(open('$rsp'))['runtimes'] else 1)" 2>/dev/null; then
      [ -f "$eng_rsp" ] || die "no eng graph at $eng_rsp"
      cp -f "$eng_rsp" "$rsp"
      [ -f "$eng_prsp" ] && cp -f "$eng_prsp" "$sdkdir/PortableRuntimeIdentifierGraph.json"
      info "injected eng/ ohos RID graphs into bootstrap SDK $v"
    fi
  done
  local rsp="$RUNTIME_REPO/.dotnet/sdk/$RIDGRAPH_SDKVER/RuntimeIdentifierGraph.json"
  [ -f "$rsp" ] || die "RID graph not found at $rsp (bootstrap SDK lacks ohos) — inject eng/ graphs first"
  # crossgen2_inbuild publish (self-contained) resolves AppHostSourcePath to
  # artifacts/bootstrap/ohos-arm64/host/apphost when UseBootstrapLayout=true;
  # if the bootstrap layout is stale/missing the publish dies MSB3030. Build
  # the corehost (host subset) when needed, then sync apphost/singlefilehost
  # into the bootstrap host dir. Clean hosts (CI) have no corehost output
  # until the host subset runs.
  local chbin="$RUNTIME_REPO/artifacts/bin/ohos-$ARCH.$CONFIG/corehost"
  local bhdir="$RUNTIME_REPO/artifacts/bootstrap/ohos-$ARCH/host"
  # In-build tools (crossgen2/ILCompiler/R2R) restore the HOST (linux-x64)
  # runtime pack during clr+libs+packs; clean restores miss it (NETSDK1112).
  # ILCompiler_inbuild is SelfContained at the SDK runtime version; seed the
  # SDK version plus dnceng candidates (branch product version, darc baseline).
  ensure_nuget_runtime_pack "linux-x64" \
    "11.0.0-rc.1.26420.103" \
    "11.0.0-$LABEL.$PRE.26451.$(echo "$BUILDID" | cut -d. -f2)" \
    "11.0.0-$LABEL.$PRE.26431.109" || true
  if [ ! -f "$chbin/apphost" ]; then
    info "corehost apphost missing — building host subset"
    (cd "$RUNTIME_REPO" && ./build.sh -os ohos -arch "$ARCH" --cross -c "$CONFIG" \
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
  # ohos RID is independent (no linux-musl fallback) so the prebuilt SDK has no
  # ohos apphost entry; libs/host do not publish apphosts, so host builds disable
  # the SDK apphost resolution (split build, see notes in stage comments).
  # clr+libs+packs — NOT +host: the independent ohos RID has no apphost entry
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
  ensure_nuget_runtime_pack "linux-x64" "$RT_VERSION" "" ""

  # AOT tooling packs via clr.aot+packs + explicit NativeAOT.sfxproj — the
  # fork's authoritative C.7 shape (DotNetBuildAllRuntimePacks=true would also
  # trigger Mono cross-AOT which misfires for ohos).
  ./build.sh -os ohos -arch "$ARCH" --cross -c "$CONFIG" -lc "$CONFIG" -rc "$CONFIG" \
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
  local ilcd="$RUNTIME_REPO/artifacts/bin/coreclr/ohos.$ARCH.$CONFIG/ilc-published"
  info "re-publishing ilc as CoreCLR split layout (PublishSingleFile=false)..."
  ./.dotnet/dotnet build "$ilcp" -c "$CONFIG" -r "$RID" -t:Publish \
    -p:TargetOS=ohos -p:TargetArchitecture="$ARCH" -p:PortableOS=ohos \
    -p:UseBootstrap=true -p:PublishSingleFile=false \
    "/p:RuntimeIdentifierGraphPath=$rsp" -p:IncludeSymbols=false -v:q -nologo \
    2>&1 | tee -a "$LOG" || die "ilc split publish failed"
  pkill -9 -f "MSBuild.*nodem" 2>/dev/null || true; sleep 2
  # device loads the native .so next to the apphost; add NDK libc++_shared
  local ndk_libcxx="$OHOS_NDK_HOME/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so"
  [ -f "$ilcd/libc++_shared.so" ] || cp -f "$ndk_libcxx" "$ilcd/libc++_shared.so"
  local ilcpk="$ship/runtime.ohos-arm64.Microsoft.DotNet.ILCompiler.$RT_VERSION.nupkg"
  local ilc_ref=$(ls "$ship"/runtime.ohos-arm64.Microsoft.DotNet.ILCompiler.*.nupkg 2>/dev/null | grep -v "$RT_VERSION" | head -1)
  [ -n "$ilc_ref" ] || ilc_ref="$ilcpk"  # same-pack metadata is safe (atomic write)
  python3 "$SCRIPT_DIR/assemble-ilc-pack.py" "$ilcd" "$ilc_ref" "$ilcpk" \
    || die "assemble ilc split pack failed"
  ./build.sh -os ohos -arch "$ARCH" --cross -c "$CONFIG" -lc "$CONFIG" -rc "$CONFIG" \
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
  # crossgen2 compiles the ohos CoreLib R2R (PGO when the mibc exists).
  ensure_stock_crossgen2
  local clrbin="$RUNTIME_REPO/artifacts/bin/coreclr/ohos.$ARCH.$CONFIG"
  # Read the CoreLib IL from the compiler obj dir: the bin IL/ copy is clobbered
  # (0-byte) by later build steps, which made crossgen2 die on an empty file.
  local corelib_il="$RUNTIME_REPO/artifacts/obj/coreclr/System.Private.CoreLib/ohos.$ARCH.$CONFIG/System.Private.CoreLib.dll"
  [ -s "$corelib_il" ] || die "CoreLib IL missing: $corelib_il"
  info "producing ReadyToRun CoreLib (official crossgen2, PGO if mibc present)..."
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
  # the sfxproj pack step can emit an EMPTY zip (0 files) on a clean ohos build;
  # detect and reassemble from the layout + reference metadata.
  if [ ! -s "$rtpk" ] || python3 -c "import zipfile,sys; sys.exit(0 if len(zipfile.ZipFile('$rtpk').namelist()) else 1)" 2>/dev/null; then
    info "Runtime pack empty/corrupt — reassembling from layout"
    local refpk="$SCRIPT_DIR/reference-runtime-pack.nupkg"
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
  # refresh the local feed copy
  cp -f "$ship/Microsoft.NETCore.App.Runtime.$RID.$RT_VERSION.nupkg" "$FEED/" 2>/dev/null
  # --- pre-sign every ohos ELF (runtime/nativeaot/host/ilc packs + tarballs) ---
  # device loads these from NuGet/app publish, so they must carry .codesign now.
  info "pre-signing runtime packs (ELF -> .codesign)..."
  # shellcheck disable=SC2045
  for pk in "$ship"/*"$RID"*"$RT_VERSION"*.nupkg; do
    [ -f "$pk" ] && sign_all "$pk"
  done
  for tb in "$ship"/dotnet-runtime-*"$RID"*.tar.gz; do
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
  # start the asset http server the aspnetcore/sdk builds download from
  # (PublicBaseURL=http://localhost:8000/) unless one is already listening
  if ! curl -sf --max-time 2 http://localhost:8000/ >/dev/null 2>&1; then
    (cd "$ASSETS" && nohup python3 -m http.server 8000 >"$WORK/http-server.log" 2>&1 &)
    sleep 1
    curl -sf --max-time 2 http://localhost:8000/ >/dev/null 2>&1 \
      || die "asset http server failed to start on :8000"
    info "asset http server started on :8000 (root $ASSETS)"
  fi
  info "asset: $ASSETS/Runtime/$ASPCORE_TRANSPORT/$(basename "$rt_archive")"
}

# ---- 3. aspnetcore build ----------------------------------------------------
stage3() {
  info "Stage 3: aspnetcore runtime build (App.Runtime + shared framework)"
  [ -f "$WORK/rt-version.txt" ] && RT_VERSION=$(cat "$WORK/rt-version.txt")
  RT_VERSION="${RT_VERSION:-$VERSION_BAND-$LABEL.$PRE.$BUILDID}"
  cd "$ASCORE_REPO"
  local eng_pgraph="$SDK_REPO/eng/PortableRuntimeIdentifierGraph.ohos.json"
  [ -f "$eng_pgraph" ] || die "no eng portable graph at $eng_pgraph"
  for sd in "$ASCORE_REPO"/.dotnet/sdk/*/; do
    local ridgraph="$sd/PortableRuntimeIdentifierGraph.json"
    if [ ! -f "$ridgraph" ] || ! python3 -c "import json,sys; sys.exit(0 if 'ohos-arm64' in json.load(open('$ridgraph'))['runtimes'] else 1)" 2>/dev/null; then
      mkdir -p "$(dirname "$ridgraph")"
      cp -f "$eng_pgraph" "$ridgraph"
      info "injected eng/ portable RID graph into aspnetcore SDK $(basename "$sd")"
    fi
  done
  # NETSDK1083 (ohos-arm64 not recognized) — the aspnetcore bootstrap SDK's
  # RuntimeIdentifierGraph.json also needs the ohos entries. Inject into every
  # installed SDK (the build uses global.json's, which may not be RIDGRAPH_SDKVER).
  for sd in "$ASCORE_REPO"/.dotnet/sdk/*/; do
    local arsp="$sd/RuntimeIdentifierGraph.json"
    [ -f "$arsp" ] || continue
    if ! python3 -c "import json,sys; sys.exit(0 if 'ohos-arm64' in json.load(open('$arsp'))['runtimes'] else 1)" 2>/dev/null; then
      [ -f "$SDK_REPO/eng/RuntimeIdentifierGraph.ohos.json" ] || die "no eng RID graph for aspnetcore inject"
      cp -f "$SDK_REPO/eng/RuntimeIdentifierGraph.ohos.json" "$arsp"
      info "injected eng/ RID graph into aspnetcore SDK $(basename "$sd")"
    fi
  done
  # aspnetcore's darc-flowed runtime versions (e.g. 11.0.0-rc.1.26451.109 from
  # official runtime) point at a feed that has no ohos packs — override the
  # runtime-driven versions to the locally built one so restore hits our feed.
  local rtver="$RT_VERSION"
  ./eng/build.sh --os-name "$(echo "$RID" | cut -d- -f1)" --arch "$ARCH" -c "$CONFIG" \
    --no-build-nodejs \
    --projects "$(pwd)/src/Framework/App.Runtime/src/aspnetcore-runtime.proj" \
    -p:PublicBaseURL="http://localhost:8000/" \
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
  ./build.sh -os ohos -arch "$ARCH" -c "$CONFIG" \
    /p:MicrosoftNETCoreAppHostPackageVersion="$rtver" \
    /p:MicrosoftNETCoreAppRuntimePackageVersion="$rtver" \
    /p:MicrosoftAspNetCoreAppRuntimePackageVersion="$rtver" \
    /p:RestoreAdditionalProjectSources="$FEED" \
    /p:PublicBaseURL=http://localhost:8000/ \
    /p:RidGraphOverrideRuntimeJson="$PWD/eng/RuntimeIdentifierGraph.ohos.json" \
    /p:RidGraphOverridePortableJson="$PWD/eng/PortableRuntimeIdentifierGraph.ohos.json" \
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
