#!/usr/bin/env python3
"""Patch Microsoft.Build.Framework.dll in the built SDK so MSBuild named pipes
live under Path.GetTempPath() (TMPDIR) instead of the hardcoded /tmp.

OpenHarmony denies AF_UNIX bind() in /tmp (EACCES), which makes MSBuild task
hosts / the out-of-proc server / worker nodes crash with exit code 134 and the
parent fail with MSB4216 after 30 s x 5 connect retries. One IL instruction in
Microsoft.Build.Shared.NamedPipeUtil::GetPlatformSpecificPipeName(string)
(`ldstr "/tmp"` -> `call System.IO.Path::GetTempPath()`) fixes all of them at
once (verified on device: Blazor WASM build 5:06 failure -> 15.4 s success).

Targets:
  * the redist layout  <sdk>/artifacts/bin/redist/<config>/dotnet/sdk/*/...,
  * the shipping tarball <sdk>/artifacts/packages/<config>/Shipping/dotnet-sdk-*-<rid>.tar.gz
    (same members, stream-rewritten).
Reference assemblies under .../ref/ have no method bodies and are skipped.
"""
import argparse
import glob
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

DLL = "Microsoft.Build.Framework.dll"


def is_target(name: str) -> bool:
    if os.path.basename(name) != DLL:
        return False
    norm = name.replace("\\", "/")
    return "/ref/" not in norm and not norm.startswith("ref/")


def run_patcher(dotnet: str, patcher: str, src: str, dst: str) -> None:
    r = subprocess.run(
        [dotnet, patcher, src, dst],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout)
        raise SystemExit(f"ERROR: patcher failed (rc={r.returncode}) for {src}")


def patch_layout(dotnet: str, patcher: str, sdk_root: str, config: str, work: str) -> int:
    root = os.path.join(sdk_root, "artifacts", "bin", "redist", config, "dotnet", "sdk")
    n = 0
    for f in glob.glob(os.path.join(root, "*", "**", DLL), recursive=True):
        rel = os.path.relpath(f, os.path.join(sdk_root, "artifacts", "bin", "redist", config, "dotnet"))
        if not is_target(rel):
            continue
        out = os.path.join(work, "layout-out.dll")
        run_patcher(dotnet, patcher, f, out)
        shutil.copyfile(out, f)
        n += 1
        print(f"  layout patched: {rel}")
    return n


def patch_tarball(dotnet: str, patcher: str, tar_path: str, work: str) -> int:
    new_tar = os.path.join(work, "sdk.tar.gz")
    n = 0
    with tarfile.open(tar_path, "r:gz") as src, tarfile.open(new_tar, "w:gz") as dst:
        for m in src:
            if m.isfile() and is_target(m.name):
                f = src.extractfile(m)
                srcf = os.path.join(work, "tar-in.dll")
                with open(srcf, "wb") as o:
                    shutil.copyfileobj(f, o)
                outf = os.path.join(work, "tar-out.dll")
                run_patcher(dotnet, patcher, srcf, outf)
                data = open(outf, "rb").read()
                nm = tarfile.TarInfo(m.name)
                nm.size = len(data)
                nm.mode = m.mode
                nm.mtime = m.mtime
                nm.uid = m.uid
                nm.gid = m.gid
                nm.uname = m.uname
                nm.gname = m.gname
                nm.type = m.type
                dst.addfile(nm, io.BytesIO(data))
                n += 1
                print(f"  tarball patched: {m.name}")
            else:
                dst.addfile(m, src.extractfile(m) if m.isfile() else None)
    st = os.stat(tar_path)
    os.replace(new_tar, tar_path)
    os.chmod(tar_path, st.st_mode)
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk-root", required=True)
    ap.add_argument("--config", default="Release")
    ap.add_argument("--rid", required=True)
    ap.add_argument("--dotnet", required=True)
    ap.add_argument("--patcher", required=True)
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="msbuild-pipe-patch-")
    try:
        n_layout = patch_layout(args.dotnet, args.patcher, args.sdk_root, args.config, work)
        tars = sorted(glob.glob(os.path.join(
            args.sdk_root, "artifacts", "packages", args.config, "Shipping",
            f"dotnet-sdk-*-{args.rid}.tar.gz")))
        if not tars:
            raise SystemExit(f"ERROR: no dotnet-sdk-*-{args.rid}.tar.gz under artifacts/packages/{args.config}/Shipping")
        n_tar = 0
        for t in tars:
            n_tar += patch_tarball(args.dotnet, args.patcher, t, work)
        print(f"msbuild-pipe-patch: layout={n_layout} tarball_members={n_tar} tarballs={len(tars)}")
        if n_layout + n_tar == 0:
            raise SystemExit("ERROR: no Microsoft.Build.Framework.dll was patched")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
