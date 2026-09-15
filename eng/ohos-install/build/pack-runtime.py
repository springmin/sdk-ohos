#!/usr/bin/env python3
"""Assemble the Microsoft.NETCore.App.Runtime.<rid> nupkg from the built
layout when the sfxproj pack step emits an empty zip (0 files).

Metadata and non-runtimes files are copied from a reference pack of the same
version; RID strings in entry names and text metadata are rewritten to the
layout's RID. RuntimeList-declared paths missing from the layout walk are
filled from the layout by basename (the R2R CoreLib lives under native/ in
the layout but is declared under lib/<tfm>/ as Managed).

Usage: pack-runtime.py <layout-dir> <reference-pack> <out-nupkg>
  layout-dir   artifacts/bin/microsoft.netcore.app.runtime.openharmony-arm64/Release
               (contains runtimes/<rid>/...)
  reference    a known-good nupkg of the same product (metadata reused)
"""
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

layout, ref, out = sys.argv[1], sys.argv[2], sys.argv[3]

# Target RID: the single runtimes/<rid>/ tree in the layout.
rt = os.path.join(layout, "runtimes")
rids = sorted(d for d in os.listdir(rt) if os.path.isdir(os.path.join(rt, d))) if os.path.isdir(rt) else []
if len(rids) != 1:
    sys.exit(f"expected one runtimes/<rid>/ under {layout}, found: {rids}")
trid = rids[0]

rz = zipfile.ZipFile(ref)
names = rz.namelist()

# Source RID: from the reference nuspec id, else its first runtimes/<rid>/ path.
srid = None
for n in names:
    if n.endswith(".nuspec"):
        m = re.search(rb"<id>Microsoft\.NETCore\.App\.Runtime\.([^<]+)</id>", rz.read(n))
        if m:
            srid = m.group(1).decode()
            break
if srid is None:
    srid = next((m.group(1) for n in names for m in [re.match(r"runtimes/([^/]+)/", n)] if m), None)
if srid is None:
    sys.exit(f"cannot derive source RID from {ref}")

meta = [n for n in names if not n.startswith("runtimes/")]
TEXT = (".xml", ".nuspec", ".psmdcp", ".rels", ".txt", ".md", ".json")
print(f"reference: {len(names)} files, {len(meta)} non-runtimes; RID {srid} -> {trid}")


def rw(n, d):
    return d.replace(srid.encode(), trid.encode()) if n.lower().endswith(TEXT) else d


files = {}
for root, _dirs, fs in os.walk(layout):
    for f in fs:
        p = os.path.join(root, f)
        a = os.path.relpath(p, layout).replace(os.sep, "/")
        if a.startswith(f"runtimes/{trid}/"):
            files[a] = p

fills = {}
rl = next((n for n in meta if n.endswith("RuntimeList.xml")), None)
if rl:
    by = {}
    for a in files:
        by.setdefault(os.path.basename(a), []).append(a)
    for f in ET.fromstring(rw(rl, rz.read(rl)).decode("utf-8-sig")):
        p = f.get("Path")
        if p and p not in files:
            c = by.get(os.path.basename(p), [])
            if len(c) == 1:
                fills[p] = files[c[0]]
            else:
                print(f"WARN: cannot fill {p} (candidates: {c})", file=sys.stderr)

print(f"layout files: {len(files)}, fills: {len(fills)}")
for k in sorted(fills):
    print(f"  fill {k} <- {fills[k]}")

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
    for n in meta:
        zo.writestr(n.replace(srid, trid), rw(n, rz.read(n)))
    for a, p in files.items():
        zo.write(p, a)
    for a, p in fills.items():
        zo.write(p, a)
print(f"wrote {out} ({os.path.getsize(out)} bytes)")
