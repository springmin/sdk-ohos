#!/usr/bin/env python3
"""Pre-sign every OHOS ELF inside directories / .nupkg / .tar.gz.

Moved from the device-side install-dotnet-ohos.sh sign_all() so artifacts are
signed on the build host BEFORE packaging/uploading. Device only executes ELF
with a .codesign section (unsigned -> EACCES).

Idempotent: ELF already carrying .codesign is skipped.

Usage:
  sign-ohos-pre.py <selfsign-binary> <target> [<target> ...]
    target = a directory  -> walk it, sign every ELF in place
             a *.nupkg    -> extract, sign every ELF, repack (deflate)
             a *.tar.gz   -> extract, sign every ELF, repack (gzip)
"""
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

SELFSIGN = None


def is_elf(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


def has_codesign(path):
    try:
        out = subprocess.run(["readelf", "-S", path], capture_output=True, text=True).stdout
        return ".codesign" in out
    except (OSError, subprocess.SubprocessError):
        return False


def sign_elf(path):
    # already signed -> skip (idempotent)
    if has_codesign(path):
        return False
    subprocess.run([SELFSIGN, path], check=True, capture_output=True)
    return True


def sign_dir(root):
    n = 0
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(dirpath, f)
            if is_elf(p):
                try:
                    n += int(sign_elf(p))
                except (subprocess.CalledProcessError, OSError) as e:
                    print(f"  WARN: signing failed: {p}: {e}", file=sys.stderr)
    return n


def _repack(src, dst, mode):
    tmp = tempfile.mkdtemp(prefix="ohos-sign-")
    try:
        if mode == "zip":
            zipfile.ZipFile(src).extractall(tmp)
        else:
            with tarfile.open(src, "r:gz") as t:
                t.extractall(tmp, filter="data")
        n = sign_dir(tmp)
        if not n:
            return 0  # nothing signed — leave original untouched
        if mode == "zip":
            with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zo:
                for dirpath, _d, files in os.walk(tmp):
                    for f in files:
                        p = os.path.join(dirpath, f)
                        zo.write(p, os.path.relpath(p, tmp))
        else:
            with tarfile.open(dst, "w:gz") as to:
                for dirpath, _d, files in os.walk(tmp):
                    for f in files:
                        p = os.path.join(dirpath, f)
                        to.add(p, os.path.relpath(p, tmp))
        return n
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    global SELFSIGN
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    SELFSIGN = os.path.abspath(sys.argv[1])
    if not os.path.isfile(SELFSIGN) or not os.access(SELFSIGN, os.X_OK):
        sys.exit(f"selfsign not executable: {SELFSIGN}")
    total = 0
    for target in sys.argv[2:]:
        t = os.path.abspath(target)
        if not os.path.exists(t):
            print(f"  skip (missing): {target}")
            continue
        if os.path.isdir(t):
            n = sign_dir(t)
            print(f"sign: {n} ELF in {target}")
        elif t.endswith(".nupkg"):
            tmp = t + ".sig"
            n = _repack(t, tmp, "zip")
            if n:
                os.replace(tmp, t)
            elif os.path.exists(tmp):
                os.remove(tmp)
            print(f"sign: {n} ELF in {os.path.basename(target)}")
        elif t.endswith(".tar.gz"):
            tmp = t + ".sig"
            n = _repack(t, tmp, "tar")
            if n:
                os.replace(tmp, t)
            elif os.path.exists(tmp):
                os.remove(tmp)
            print(f"sign: {n} ELF in {os.path.basename(target)}")
        else:
            print(f"  skip (unknown type): {target}")
        total += n
    print(f"total ELF signed: {total}")


if __name__ == "__main__":
    main()
