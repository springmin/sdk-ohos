#!/usr/bin/env python3
"""Patch the named-pipe paths that .NET hardcodes to /tmp on Unix, so pipes live
under Path.GetTempPath() (TMPDIR) instead.

OpenHarmony denies AF_UNIX bind() in /tmp (EACCES). The MSBuild side
(Microsoft.Build.Framework.dll: task hosts / MSBuild server / worker nodes crash
with exit 134, parent fails with MSB4216 after 30 s x 5 connect retries) is fixed
by one IL instruction in
Microsoft.Build.Shared.NamedPipeUtil::GetPlatformSpecificPipeName(string)
(`ldstr "/tmp"` -> `call System.IO.Path::GetTempPath()`); verified on device:
Blazor WASM build 5:06 failure -> 15.4 s success.

The Roslyn compiler server has the exact same bug in
Microsoft.CodeAnalysis.NamedPipeUtil::GetPipeNameOrPath(string), which is
compiled into every pipe-bearing Roslyn assembly. Unless all copies are patched
the client connects to /tmp/CoreFxPipe_* while the server cannot bind there, the
connect times out (~20 s) and csc/vbc silently fall back to in-process
compilation. The patcher is run over every shipped copy:

  * Microsoft.Build.Framework.dll
  * Microsoft.Build.Tasks.CodeAnalysis.dll  (Roslyn Csc/Vbc MSBuild task; it
    carries the same client-side BuildServerConnection as csc/vbc, so the
    MSBuild-side and tool-side copies must agree on the TMPDIR-derived path)
  * csc.dll / vbc.dll (compiler clients, /shared mode)
  * VBCSCompiler.dll (the server; its NamedPipeClientConnectionHost binds)

Layouts differ between Roslyn/SDK versions (e.g. Microsoft.CodeAnalysis.dll and
Microsoft.CodeAnalysis.CSharp.dll carry no /tmp literal in 5.12), so files that
do not contain the target method are skipped with a note instead of failing. The
Microsoft.Build.Framework.dll fix is the one hard requirement and still fails
the run when absent.

Targets:
  * the redist layout  <sdk>/artifacts/bin/redist/<config>/dotnet/sdk/*/...,
  * the shipping tarball <sdk>/artifacts/packages/<config>/Shipping/dotnet-sdk-*-<rid>.tar.gz
    (same members, stream-rewritten).
Reference assemblies under .../ref/ have no method bodies and are skipped.

Patcher exit codes (see msbuild-pipe-patch/Program.cs):
  0 patched, 2 no target type, 3 target type without method,
  4 target method without a /tmp literal (already patched); 2/3/4 are benign.
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
from collections import Counter

# MSBuild named-pipe builder; the critical fix, must always be applied.
MBF_DLL = "Microsoft.Build.Framework.dll"
# Roslyn pipe builders. The basename list is empirically "everything that
# contains Microsoft.CodeAnalysis.NamedPipeUtil::GetPipeNameOrPath" in the
# shipped SDK (see the patcher's --scan mode); the big Microsoft.CodeAnalysis*.dll
# have no /tmp literal and are deliberately not loaded.
ROSLYN_DLLS = {
    "Microsoft.Build.Tasks.CodeAnalysis.dll",
    "csc.dll",
    "vbc.dll",
    "VBCSCompiler.dll",
}
PATCH_DLLS = {MBF_DLL} | ROSLYN_DLLS

RC_PATCHED = 0
RC_NO_TARGET_TYPE = 2
RC_NO_TARGET_METHOD = 3
RC_NOTHING_TO_DO = 4
RC_OK = {RC_PATCHED, RC_NO_TARGET_TYPE, RC_NO_TARGET_METHOD, RC_NOTHING_TO_DO}


def is_target(name: str) -> bool:
    if os.path.basename(name) not in PATCH_DLLS:
        return False
    norm = name.replace("\\", "/")
    return "/ref/" not in norm and not norm.startswith("ref/")


def run_patcher(dotnet: str, patcher: str, src: str, dst: str) -> int:
    r = subprocess.run(
        [dotnet, patcher, src, dst],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode not in RC_OK:
        sys.stderr.write(r.stdout)
        raise SystemExit(f"ERROR: patcher failed (rc={r.returncode}) for {src}")
    return r.returncode


def patch_file(dotnet: str, patcher: str, src: str, work: str, label: str,
               rel: str, stats: Counter) -> bytes:
    """Patch one DLL; returns the new bytes (or the original ones on a skip)."""
    srcf = os.path.join(work, "in.dll")
    outf = os.path.join(work, "out.dll")
    shutil.copyfile(src, srcf)
    if os.path.exists(outf):
        os.unlink(outf)
    rc = run_patcher(dotnet, patcher, srcf, outf)
    if rc == RC_PATCHED:
        stats["patched"] += 1
        print(f"  {label} patched: {rel}")
        return open(outf, "rb").read()
    if rc == RC_NOTHING_TO_DO:
        stats["noop"] += 1
        print(f"  {label} no-op (already patched / no literal): {rel}")
        return open(srcf, "rb").read()
    # rc == RC_NO_TARGET_TYPE / RC_NO_TARGET_METHOD
    if os.path.basename(src) == MBF_DLL:
        raise SystemExit(
            f"ERROR: {MBF_DLL} has no patchable pipe method (rc={rc}): {rel}")
    stats["skip"] += 1
    print(f"  {label} skipped (rc={rc}, no pipe target): {rel}")
    return open(srcf, "rb").read()


def patch_layout(dotnet: str, patcher: str, sdk_root: str, config: str,
                 work: str, stats: Counter) -> None:
    root = os.path.join(sdk_root, "artifacts", "bin", "redist", config, "dotnet")
    sdk_dir = os.path.join(root, "sdk")
    for dirpath, _, filenames in os.walk(sdk_dir):
        for fn in filenames:
            if fn not in PATCH_DLLS:
                continue
            f = os.path.join(dirpath, fn)
            rel = os.path.relpath(f, root)
            if not is_target(rel):
                continue
            data = patch_file(dotnet, patcher, f, work, "layout", rel, stats)
            with open(f, "wb") as o:
                o.write(data)


def patch_tarball(dotnet: str, patcher: str, tar_path: str, work: str,
                  stats: Counter) -> None:
    new_tar = os.path.join(work, "sdk.tar.gz")
    with tarfile.open(tar_path, "r:gz") as src, tarfile.open(new_tar, "w:gz") as dst:
        for m in src:
            if not m.isfile():
                dst.addfile(m, None)
                continue
            if is_target(m.name):
                tmp = os.path.join(work, "tar-in.dll")
                f = src.extractfile(m)
                with open(tmp, "wb") as o:
                    shutil.copyfileobj(f, o)
                data = patch_file(dotnet, patcher, tmp, work, "tarball",
                                  m.name, stats)
            else:
                data = src.extractfile(m).read()
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
    st = os.stat(tar_path)
    os.replace(new_tar, tar_path)
    os.chmod(tar_path, st.st_mode)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk-root", required=True)
    ap.add_argument("--config", default="Release")
    ap.add_argument("--rid", required=True)
    ap.add_argument("--dotnet", required=True)
    ap.add_argument("--patcher", required=True)
    args = ap.parse_args()

    stats = Counter()
    work = tempfile.mkdtemp(prefix="msbuild-pipe-patch-")
    try:
        patch_layout(args.dotnet, args.patcher, args.sdk_root, args.config,
                     work, stats)
        tars = sorted(glob.glob(os.path.join(
            args.sdk_root, "artifacts", "packages", args.config, "Shipping",
            f"dotnet-sdk-*-{args.rid}.tar.gz")))
        if not tars:
            raise SystemExit(f"ERROR: no dotnet-sdk-*-{args.rid}.tar.gz under artifacts/packages/{args.config}/Shipping")
        for t in tars:
            patch_tarball(args.dotnet, args.patcher, t, work, stats)
        print(f"msbuild-pipe-patch: patched={stats['patched']} "
              f"noop={stats['noop']} skipped={stats['skip']} tarballs={len(tars)}")
        if stats["patched"] + stats["noop"] == 0:
            raise SystemExit("ERROR: no pipe target was found in the SDK layout or tarball")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
