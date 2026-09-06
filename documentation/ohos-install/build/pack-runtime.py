#!/usr/bin/env python3
"""Assemble the Microsoft.NETCore.App.Runtime.<rid> nupkg from the built
layout when the sfxproj pack step emits an empty zip (0 files). Metadata and
non-runtimes files are copied from a reference pack of the same version.

Usage: pack-runtime.py <layout-dir> <reference-pack> <out-nupkg>
  layout-dir   artifacts/bin/microsoft.netcore.app.runtime.ohos-arm64/Release
               (contains runtimes/<rid>/...)
  reference    a known-good nupkg of the same product (metadata reused)
"""
import sys
import zipfile
import os

layout, ref, out = sys.argv[1], sys.argv[2], sys.argv[3]
rz = zipfile.ZipFile(ref)
meta = [n for n in rz.namelist() if not n.startswith("runtimes/")]
print(f"reference: {len(rz.namelist())} files, {len(meta)} non-runtimes")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
    for n in meta:
        zo.writestr(n, rz.read(n))
    added = 0
    for root, _dirs, files in os.walk(layout):
        for f in files:
            p = os.path.join(root, f)
            arc = os.path.relpath(p, layout)
            if arc.startswith("runtimes/ohos-arm64/"):
                zo.write(p, arc)
                added += 1
    print(f"layout files added: {added}")
print(f"wrote {out} ({os.path.getsize(out)} bytes)")
