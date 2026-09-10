#!/usr/bin/env python3
"""Assemble the runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler nupkg in the
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

Usage: assemble-ilc-pack.py <ilc-published-dir> <reference-pack> <out-nupkg> [runtime-pack.nupkg] [framework-version]
  ilc-published   artifacts/bin/coreclr/openharmony.arm64.Release/ilc-published
  reference       existing ILCompiler nupkg (non-tools metadata reused; may be
                  the same path as out — written atomically via temp + move)
  out-nupkg       target (Shipping pack path)
  runtime-pack    Microsoft.NETCore.App.Runtime.<rid>.<ver>.nupkg from the same
                  build (framework overlay: native/ -> tools/, lib/ -> tools/).
                  Optional; when omitted the pack is assembled as-is (ilc-only).
  framework-version  Version string for the deps.json runtimepack entry. This
                  must be the framework version the ilc was built against (the
                  bootstrap SDK runtime, e.g. 11.0.0-rc.1.26420.103) - NOT the
                  runtime pack file version: hostpolicy resolves libcoreclr.so
                  from the runtimepack entry version, and a mismatch yields
                  "Could not resolve CoreCLR path" on device. Defaults to the
                  runtime pack file version.
"""
import os
import sys
import zipfile
import json

pub, ref, out = sys.argv[1], sys.argv[2], sys.argv[3]
rtpk = sys.argv[4] if len(sys.argv) > 4 else None
fw_ver = sys.argv[5] if len(sys.argv) > 5 else None

if fw_ver is None and rtpk:
    base = os.path.basename(rtpk)
    ver = base.replace("Microsoft.NETCore.App.Runtime.", "").replace(".nupkg", "")
    rid = ver.split(".", 1)[0]
    fw_ver = ver[len(rid) + 1:]

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
tmp = out + ".tmp"
all_tools = dict(pub_files)
for f, data in framework.items():
    if f not in all_tools:
        all_tools[f] = data

# When a framework overlay was applied, the ilc.deps.json produced by the
# publish (UseBootstrapLayout) does not list the framework assemblies; with
# includedFrameworks self-contained layout the hostpolicy resolves
# libcoreclr.so and the TPA from deps.json, so the runtimepack entry must
# reference every dll present in tools/. Rewrite it in-memory.
deps_rewritten = False
if rtpk and "ilc.deps.json" in all_tools:
    try:
        deps = json.loads(all_tools["ilc.deps.json"])
        dlls = sorted(f for f in all_tools if f.endswith(".dll") and not f.endswith(".pdb"))
        for tfm, targets in deps.get("targets", {}).items():
            if "/" not in tfm:
                continue
            # includedFrameworks self-contained hostpolicy resolves
            # libcoreclr.so + TPA from a runtimepack-style target entry; the
            # bootstrap-layout publish omits it, so create/refresh one that
            # lists every dll present in tools/ (mirrors the hand-assembled
            # round-17 pack that runs on device).
            rtpk_entry = None
            for pkg in targets:
                if "runtimepack" in pkg:
                    rtpk_entry = pkg
                    break
            if rtpk_entry is None:
                rid = ""
                if rtpk:
                    base = os.path.basename(rtpk)
                    ver = base.replace("Microsoft.NETCore.App.Runtime.", "").replace(".nupkg", "")
                    rid = ver.split(".", 1)[0]
                rtpk_entry = f"runtimepack.Microsoft.NETCore.App.Runtime.{rid}/{fw_ver}"
            # runtimepack entry lists only FRAMEWORK assemblies (the ilc-private
            # dlls stay under their own package entries); mirror the
            # hand-assembled round-17 pack shape.
            EXCLUDE = ("ILCompiler.", "ilc.dll", "Microsoft.DiaSymReader", "System.CommandLine.dll")
            fw_dlls = sorted(
                f for f in dlls
                if not f.startswith(EXCLUDE)
            )
            # native files present in tools/ (framework .so + createdump). The
            # hostpolicy locates libcoreclr.so/libhostfxr.so through this list;
            # without it a self-contained apphost fails with
            # "Could not resolve CoreCLR path".
            native_files = {
                f: {"fileVersion": "0.0.0.0"}
                for f in sorted(all_tools)
                if f == "createdump" or f.endswith(".so")
            }
            targets[rtpk_entry] = {
                "runtime": {f: {} for f in fw_dlls},
                "native": native_files,
                "dependencies": {},
            }
            # hostpolicy treats the runtimepack as the self-contained
            # framework only when the ilc entry references it (by bare name,
            # no version - matching the hand-assembled round-17 pack):
            # without this edge the apphost cannot resolve libcoreclr.so
            # ("Could not resolve CoreCLR path").
            ilc_key = next((k for k in targets if k.startswith("ilc/")), None)
            if ilc_key:
                targets[ilc_key].setdefault("dependencies", {})
                bare = rtpk_entry.split("/", 1)[0]
                targets[ilc_key]["dependencies"][bare] = rtpk_entry.split("/", 1)[1]
            # also add to libraries section so restore/probe metadata is sane
            deps.setdefault("libraries", {})[rtpk_entry] = {
                "type": "runtimepack",
                "serviceable": False,
                "sha512": "",
            }
            deps_rewritten = True
        if deps_rewritten:
            all_tools["ilc.deps.json"] = json.dumps(deps, indent=2).encode()
    except Exception as e:
        print(f"assemble-ilc-pack: WARN deps rewrite failed: {e}")

with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
    for n in meta:
        zo.writestr(n, rz.read(n))
    added = 0
    for f, data in all_tools.items():
        zo.writestr(f"tools/{f}", data)
        added += 1
    print(f"assemble-ilc-pack: {added} tools files (deps rewritten: {deps_rewritten}) -> {out}")
os.replace(tmp, out)
