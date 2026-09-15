#!/usr/bin/env python3
"""Overlay ReadyToRun images into a runtime pack nupkg.

For every entry under runtimes/*/lib/net* or runtimes/*/native whose basename
matches a file in the overlay directory, the entry is replaced with the overlay
bytes. Used by build-ohos-all.sh after crossgen-framework.py (same repack
approach as replace-pack-corelib.py, generalized to the framework list).

Usage: overlay-pack.py <pack.nupkg> <overlay-dir>
"""
import os
import shutil
import sys
import zipfile


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    nupkg, overlaydir = sys.argv[1], sys.argv[2]
    overlay = {f: os.path.join(overlaydir, f)
               for f in os.listdir(overlaydir) if f.endswith(".dll")}
    tmp = nupkg + ".tmp"
    replaced = set()
    with zipfile.ZipFile(nupkg) as zin, \
            zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = None
            name = os.path.basename(item.filename)
            is_lib = ("/lib/net" in item.filename) or ("/native/" in item.filename)
            if name in overlay and is_lib and item.filename.endswith(".dll"):
                with open(overlay[name], "rb") as f:
                    data = f.read()
                replaced.add(name)
            if data is None:
                data = zin.read(item.filename)
            zout.writestr(item, data)
    shutil.move(tmp, nupkg)
    print(f"overlay: replaced {len(replaced)}/{len(overlay)} entries in {nupkg}")
    unmatched = sorted(set(overlay) - replaced)
    if unmatched:
        print(f"overlay warning: not found in pack: {unmatched[:10]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
