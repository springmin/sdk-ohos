#!/usr/bin/env python3
"""Assemble the runtime.ohos-arm64.Microsoft.DotNet.ILCompiler nupkg in the
round-9/16 CoreCLR SPLIT-LAYOUT shape (ilc apphost + ilc.dll + managed deps +
native .so alongside — the ONLY device-PASSED ilc shape). The clr.aot+packs
subset produces a CoreCLR single-file ilc (device startup FAIL, rounds 14-15),
so the script overrides ILCompiler_publish with PublishSingleFile=false and
reassembles the pack from that output.

The split-layout publish runs with UseBootstrapLayout=true, so it does NOT
copy the Microsoft.NETCore.App framework files next to the apphost (they are
resolved from the bootstrap SDK during the build). On the DEVICE there is no
bootstrap SDK, so the pack must carry the framework itself. The runtime pack
nupkg produced by the same build provides exactly that (native/ .so + CoreLib,
lib/ managed dlls); pass it as the 4th argument and this script overlays the
framework files into tools/.

Usage: assemble-ilc-pack.py <ilc-published-dir> <reference-pack> <out-nupkg> [runtime-pack.nupkg]
  ilc-published   artifacts/bin/coreclr/ohos.arm64.Release/ilc-published
  reference       existing ILCompiler nupkg (non-tools metadata reused; may be
                  the same path as out — written atomically via temp + move)
  out-nupkg       target (Shipping pack path)
  runtime-pack    Microsoft.NETCore.App.Runtime.<rid>.<ver>.nupkg from the same
                  build (framework overlay: native/ -> tools/, lib/ -> tools/).
                  Optional; when omitted the pack is assembled as-is (ilc-only).
"""
import os
import sys
import zipfile

pub, ref, out = sys.argv[1], sys.argv[2], sys.argv[3]
rtpk = sys.argv[4] if len(sys.argv) > 4 else None

# framework files to overlay from the runtime pack: everything under
# runtimes/<rid>/native (CoreLib R2R image + native .so) and lib (managed dlls).
def framework_files_from_runtime_pack(rtp):
    rz = zipfile.ZipFile(rtp)
    # find the runtimes/<rid>/ prefix
    prefixes = set()
    for n in rz.namelist():
        parts = n.split("/")
        if len(parts) >= 3 and parts[0] == "runtimes" and parts[2] == "native":
            prefixes.add("/".join(parts[:3]))
        if len(parts) >= 4 and parts[0] == "runtimes" and parts[2] == "lib":
            prefixes.add("/".join(parts[:4]))
    if not prefixes:
        raise SystemExit(f"no runtimes/<rid>/ layout found in {rtp}")
    # prefer native (has CoreLib) prefix for .so + CoreLib; lib for managed dlls
    native_pfx = next((p for p in prefixes if p.endswith("/native")), None)
    lib_pfx = next((p for p in prefixes if p.endswith("/lib/net11.0")), None)
    files = {}
    for n in rz.namelist():
        if native_pfx and n.startswith(native_pfx + "/"):
            base = os.path.basename(n)
            if base.endswith((".so", ".a", ".dll", ".dbg")):
                files[base] = rz.read(n)
        if lib_pfx and n.startswith(lib_pfx + "/"):
            base = os.path.basename(n)
            if base.endswith(".dll"):
                # tools layout already has ilc's own managed dlls (ILCompiler.*,
                # System.CommandLine, DiaSymReader) - keep the runtime's version
                # only when the file is a framework assembly the ilc needs at
                # runtime (System.*, Microsoft.*, netstandard etc.). Prefer the
                # runtime pack copy for framework dlls; ilc-private dlls (already
                # in tools/) must NOT be overwritten by framework lookalikes.
                files.setdefault(base, rz.read(n))
    return files

rz = zipfile.ZipFile(ref)
meta = [n for n in rz.namelist() if not n.startswith("tools/")]
framework = framework_files_from_runtime_pack(rtpk) if rtpk else {}

# dlls the ilc publish itself produced (ilc-private: ILCompiler.*, ilc.dll,
# System.CommandLine, DiaSymReader) - these win over framework copies.
pub_files = {}
for f in sorted(os.listdir(pub)):
    if f.endswith(".pdb"):
        continue
    p = os.path.join(pub, f)
    if os.path.isfile(p):
        pub_files[f] = open(p, "rb").read()

tmp = out + ".tmp"
with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
    for n in meta:
        zo.writestr(n, rz.read(n))
    added = 0
    # 1) ilc publish files (highest priority - never overwrite)
    for f, data in pub_files.items():
        zo.writestr(f"tools/{f}", data)
        added += 1
    # 2) framework overlay (only files not already present)
    fw = 0
    for f, data in framework.items():
        if f not in pub_files:
            zo.writestr(f"tools/{f}", data)
            fw += 1
    print(f"assemble-ilc-pack: {added} ilc tools files + {fw} framework files -> {out}")
os.replace(tmp, out)
