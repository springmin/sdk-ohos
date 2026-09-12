#!/usr/bin/env python3
"""Assemble the Microsoft.NETCore.App.Crossgen2 nupkg in the CoreCLR SPLIT-LAYOUT
shape (crossgen2 apphost + crossgen2.dll + managed deps + native .so alongside).

The in-build crossgen2 pack is a TRIMMED SINGLE-FILE publish
(crossgen2_publish.csproj PublishTrimmed/PublishSingleFile) whose ILLink pass
strips interface-dispatched methods such as
CustomAttributeTypeProvider.GetPrimitiveType from ILCompiler.TypeSystem.dll
(device TypeLoadException, dotnet/runtime #133296 — the same class of bug the
ilc split publish fixed). Re-publishing crossgen2_publish with
PublishSingleFile=false + PublishTrimmed=false and reassembling the pack from
that output fixes device startup.

The split-layout publish runs with UseBootstrapLayout=true, so it does NOT copy
the Microsoft.NETCore.App framework files next to the apphost (they are resolved
from the bootstrap SDK during the build). On the DEVICE there is no bootstrap
SDK, so the pack must carry the framework itself. The runtime pack nupkg produced
by the same build provides exactly that (native/ .so + CoreLib, lib/ managed dlls).

Usage: assemble-crossgen2-pack.py <cg2-published-dir> <reference-pack> <out-nupkg> [runtime-pack.nupkg] [framework-version]
  cg2-published   artifacts/bin/coreclr/ohos.arm64.Release/crossgen2-published
  reference       existing Crossgen2 nupkg (non-tools metadata reused; may be the
                  same path as out — written atomically via temp + move)
  out-nupkg       target (Shipping pack path)
  runtime-pack    Microsoft.NETCore.App.Runtime.<rid>.<ver>.nupkg from the same
                  build (framework overlay: native/ -> tools/, lib/ -> tools/).
  framework-version  Version string for the deps.json runtimepack entry. Must be
                  the framework the tool was built against (the bootstrap SDK
                  runtime, e.g. 11.0.0-rc.1.26420.103) - NOT the runtime pack file
                  version: hostpolicy resolves libcoreclr.so from the runtimepack
                  entry version and a mismatch yields "Could not resolve CoreCLR
                  path" on device. Defaults to the runtime pack file version.
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


def framework_files_from_runtime_pack(rtp):
    rz = zipfile.ZipFile(rtp)
    prefixes = set()
    for n in rz.namelist():
        parts = n.split("/")
        if len(parts) >= 3 and parts[0] == "runtimes" and parts[2] == "native":
            prefixes.add("/".join(parts[:3]))
        if len(parts) >= 4 and parts[0] == "runtimes" and parts[2] == "lib":
            prefixes.add("/".join(parts[:4]))
    if not prefixes:
        raise SystemExit(f"no runtimes/<rid>/ layout found in {rtp}")
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
                # tools layout already has crossgen2's own managed dlls - keep
                # the runtime's version only for framework assemblies the tool
                # needs at runtime (System.*, Microsoft.*, netstandard, ...).
                files.setdefault(base, rz.read(n))
    return files


rz = zipfile.ZipFile(ref)
meta = [n for n in rz.namelist() if not n.startswith("tools/")]
framework = framework_files_from_runtime_pack(rtpk) if rtpk else {}

# dlls the publish itself produced (crossgen2-private: crossgen2.dll,
# ILCompiler.*, System.CommandLine) - these win over framework copies.
pub_files = {}
for f in sorted(os.listdir(pub)):
    p = os.path.join(pub, f)
    if os.path.isfile(p):
        pub_files[f] = open(p, "rb").read()

all_tools = dict(pub_files)
for f, data in framework.items():
    if f not in all_tools:
        all_tools[f] = data

# The split publish (UseBootstrapLayout) does not list the framework in
# crossgen2.deps.json; with the includedFrameworks self-contained layout the
# hostpolicy resolves libcoreclr.so and the TPA from a runtimepack entry, so
# create/refresh one that lists every framework file present in tools/.
deps_rewritten = False
if rtpk and "crossgen2.deps.json" in all_tools:
    try:
        deps = json.loads(all_tools["crossgen2.deps.json"])
        dlls = sorted(f for f in all_tools if f.endswith(".dll") and not f.endswith(".pdb"))
        for tfm, targets in deps.get("targets", {}).items():
            if "/" not in tfm:
                continue
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
            # only FRAMEWORK assemblies go in the runtimepack entry; the
            # crossgen2-private dlls stay under their own package entries.
            EXCLUDE = ("crossgen2.dll", "ILCompiler.", "System.CommandLine.dll")
            fw_dlls = sorted(f for f in dlls if not f.startswith(EXCLUDE))
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
            # hostpolicy treats the runtimepack as the self-contained framework
            # only when the crossgen2 entry references it (bare name, no version).
            cg2_key = next((k for k in targets if k.startswith("crossgen2/")), None)
            if cg2_key:
                targets[cg2_key].setdefault("dependencies", {})
                bare = rtpk_entry.split("/", 1)[0]
                targets[cg2_key]["dependencies"][bare] = rtpk_entry.split("/", 1)[1]
            deps.setdefault("libraries", {})[rtpk_entry] = {
                "type": "runtimepack",
                "serviceable": False,
                "sha512": "",
            }
            deps_rewritten = True
        if deps_rewritten:
            all_tools["crossgen2.deps.json"] = json.dumps(deps, indent=2).encode()
    except Exception as e:
        print(f"assemble-crossgen2-pack: WARN deps rewrite failed: {e}")

tmp = out + ".tmp"
with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
    for n in meta:
        zo.writestr(n, rz.read(n))
    added = 0
    for f, data in all_tools.items():
        zo.writestr(f"tools/{f}", data)
        added += 1
    print(f"assemble-crossgen2-pack: {added} tools files (deps rewritten: {deps_rewritten}) -> {out}")
os.replace(tmp, out)
