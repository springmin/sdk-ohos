#!/usr/bin/env python3
"""Alias an OpenHarmony runtime pack as the portable linux-musl-<arch> runtime pack.

The stock/bootstrap SDK's KnownRuntimePack has no openharmony RID, so the injected
RID graph import (openharmony-<arch> -> linux-musl-<arch>) makes self-contained
in-build tool publishes (ILCompiler_publish) resolve
Microsoft.NETCore.App.Runtime.linux-musl-<arch>. That package does not exist at this
build version on any feed, so provide it locally from the OpenHarmony runtime pack
we just built (same musl/arm64 payload, runtime pack layout).

The alias nupkg rewrites the nuspec id/version and the runtimes/<rid>/ paths.

Usage: alias-runtime-pack.py <src.nupkg> <out-dir> <alias-id> <alias-version> <src-rid>
"""
import base64
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile

src, dest, alias_id, alias_ver, src_rid = sys.argv[1:6]
arch = src_rid.split("-")[-1]
alias_rid = f"linux-musl-{arch}"

stage = os.path.join(dest, ".stage")
if os.path.isdir(stage):
    shutil.rmtree(stage)
os.makedirs(stage, exist_ok=True)

prefix = f"runtimes/{src_rid}/"
alias_prefix = f"runtimes/{alias_rid}/"
count = 0
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        name = info.filename
        data = z.read(name)
        if name.endswith(".nuspec"):
            text = data.decode("utf-8")
            text = re.sub(r"<id>[^<]*</id>", f"<id>{alias_id}</id>", text, count=1)
            text = re.sub(r"<version>[^<]*</version>", f"<version>{alias_ver}</version>", text, count=1)
            data = text.encode("utf-8")
        names = [name]
        if name.startswith(prefix):
            # The SDK opens the pack folder by the resolved RID (linux-musl-<arch>)
            # but copies assets using the project RID (openharmony-<arch>); keep
            # both trees so either lookup resolves.
            names.append(alias_prefix + name[len(prefix):])
            count += 1
        for out_name in names:
            out = os.path.join(stage, out_name)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(data)

if count == 0:
    raise SystemExit(f"no runtimes/{src_rid}/ entries found in {src}")

nupkg = os.path.join(dest, f"{alias_id}.{alias_ver}.nupkg")
with zipfile.ZipFile(nupkg, "w", zipfile.ZIP_DEFLATED) as zo:
    for root, _, files in os.walk(stage):
        for fn in files:
            p = os.path.join(root, fn)
            zo.write(p, os.path.relpath(p, stage))
shutil.rmtree(stage)

data = open(nupkg, "rb").read()
h = base64.b64encode(hashlib.sha512(data).digest()).decode()
with open(nupkg + ".sha512", "w") as f:
    f.write(h)
with open(os.path.join(dest, ".nupkg.metadata"), "w") as f:
    json.dump({"version": 2, "contentHash": h, "source": "local"}, f)
with zipfile.ZipFile(nupkg) as z:
    z.extractall(dest)
for x in os.listdir(dest):
    if x.endswith(".nuspec"):
        shutil.copy(os.path.join(dest, x), os.path.join(dest, f"{alias_id}.nuspec"))
        break
print(f"aliased {src_rid} -> {alias_id}@{alias_ver} ({count} runtimes entries)")
