#!/usr/bin/env python3
"""Assemble the runtime.ohos-arm64.Microsoft.DotNet.ILCompiler nupkg in the
round-9/16 CoreCLR SPLIT-LAYOUT shape (ilc apphost + ilc.dll + managed deps +
native .so alongside — the ONLY device-PASSED ilc shape). The clr.aot+packs
subset produces a CoreCLR single-file ilc (device startup FAIL, rounds 14-15),
so the script overrides ILCompiler_publish with PublishSingleFile=false and
reassembles the pack from that output.

Usage: assemble-ilc-pack.py <ilc-published-dir> <reference-pack> <out-nupkg>
  ilc-published  artifacts/bin/coreclr/ohos.arm64.Release/ilc-published
  reference      existing ILCompiler nupkg (non-tools metadata reused; may be
                 the same path as out — written atomically via temp + move)
  out-nupkg      target (Shipping pack path)
"""
import os
import sys
import zipfile

pub, ref, out = sys.argv[1], sys.argv[2], sys.argv[3]
rz = zipfile.ZipFile(ref)
meta = [n for n in rz.namelist() if not n.startswith("tools/")]
tmp = out + ".tmp"
with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
    for n in meta:
        zo.writestr(n, rz.read(n))
    added = 0
    for f in sorted(os.listdir(pub)):
        if f.endswith(".pdb"):
            continue
        p = os.path.join(pub, f)
        if os.path.isfile(p):
            zo.write(p, f"tools/{f}")
            added += 1
os.replace(tmp, out)
print(f"assemble-ilc-pack: {added} tools files -> {out}")
