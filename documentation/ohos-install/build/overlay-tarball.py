#!/usr/bin/env python3
"""Overlay ReadyToRun images into a runtime tarball (.tar.gz).

Replaces members under shared/Microsoft.NETCore.App or lib/net whose basename
matches a file in the overlay directory, preserving member metadata. Used by
build-ohos-all.sh so the runtime tarball (and the SDK redist that consumes it)
carries the R2R framework, mirroring the pack overlay.

Usage: overlay-tarball.py <tarball.tar.gz> <overlay-dir>
"""
import io
import os
import shutil
import sys
import tarfile


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    tarball, overlaydir = sys.argv[1], sys.argv[2]
    overlay = {f: os.path.join(overlaydir, f)
               for f in os.listdir(overlaydir) if f.endswith(".dll")}
    tmp = tarball + ".tmp"
    replaced = set()
    with tarfile.open(tarball, "r:gz") as tin, \
            tarfile.open(tmp, "w:gz") as tout:
        for m in tin:
            name = os.path.basename(m.name)
            is_lib = ("shared/Microsoft.NETCore.App" in m.name) or ("/lib/net" in m.name)
            if m.isfile() and name in overlay and is_lib:
                with open(overlay[name], "rb") as f:
                    data = f.read()
                m2 = tarfile.TarInfo(m.name)
                m2.size = len(data)
                m2.mode = m.mode
                m2.mtime = m.mtime
                m2.uid, m2.gid = m.uid, m.gid
                m2.uname, m2.gname = m.uname, m.gname
                m2.type = m.type
                tout.addfile(m2, io.BytesIO(data))
                replaced.add(name)
            else:
                f = tin.extractfile(m) if m.isfile() else None
                tout.addfile(m, f)
    shutil.move(tmp, tarball)
    print(f"overlay-tarball: replaced {len(replaced)}/{len(overlay)} entries in {tarball}")
    unmatched = sorted(set(overlay) - replaced)
    if unmatched:
        print(f"overlay-tarball warning: not found: {unmatched[:10]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
