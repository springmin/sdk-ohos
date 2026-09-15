#!/usr/bin/env python3
"""Re-version a nupkg (nuspec + nupkg.metadata) and repack.

Used when a consumer pins a restore key that differs from the version we
built/published (round-21 aspnetcore 26452.110, ILLink.Tasks 26451.109).
Prefer SDK-side version overrides (build-ohos-all.sh stage4) over this where
possible; this is the fallback for keys nothing can override.

Usage: reversion-nupkg.py <in.nupkg> <old-version> <new-version> [out.nupkg]
  out defaults to <in>.reversioned.nupkg
"""
import sys
import zipfile

nupkg, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
out = sys.argv[4] if len(sys.argv) > 4 else nupkg.replace(".nupkg", ".reversioned.nupkg")
z = zipfile.ZipFile(nupkg)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
    for n in z.namelist():
        data = z.read(n)
        if n.endswith(".nuspec") or n.endswith(".nupkg.metadata"):
            data = data.decode().replace(old, new).encode()
        zo.writestr(n, data)
print(f"re-versioned {nupkg}: {old} -> {new} -> {out}")
