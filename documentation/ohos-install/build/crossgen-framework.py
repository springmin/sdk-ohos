#!/usr/bin/env python3
"""Crossgen framework assemblies to ReadyToRun (mac-model pack production).

Used by build-ohos-all.sh: compiles every PureIL managed assembly of the
runtime layout/pack with the stock (official NuGet) crossgen2, so the SDK can
skip already-R2R framework assemblies during device-side
`dotnet publish -p:PublishReadyToRun=true --self-contained` publishes.

- Already-R2R inputs are skipped.
- Per-assembly failures are tolerated (facades/forwarders/no-IL assemblies are
  expected to fail); they simply stay PureIL and get compiled on device.
- Exit code: 0 when at least one assembly compiled, 1 otherwise.
"""
import argparse
import concurrent.futures
import os
import struct
import subprocess
import sys
import time


def is_r2r(path: str) -> bool:
    """True when the PE has a non-zero COR20 ManagedNativeHeader (R2R image)."""
    try:
        with open(path, "rb") as f:
            d = f.read()
    except OSError:
        return False
    try:
        e = struct.unpack_from("<I", d, 0x3C)[0]
        if d[e:e + 4] != b"PE\0\0":
            return False
        nsec = struct.unpack_from("<H", d, e + 6)[0]
        optsize = struct.unpack_from("<H", d, e + 20)[0]
        opt = e + 24
        magic = struct.unpack_from("<H", d, opt)[0]
        dd = opt + (112 if magic == 0x20B else 96)
        cor_rva = struct.unpack_from("<I", d, dd + 14 * 8)[0]
        sh = opt + optsize
        for i in range(nsec):
            base = sh + i * 40
            vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", d, base + 8)
            if va <= cor_rva < va + max(vsize, rawsize):
                cor_off = rawptr + (cor_rva - va)
                return struct.unpack_from("<I", d, cor_off + 68)[0] != 0
    except Exception:
        return False
    return False


def compile_one(crossgen2, libdir, outdir, name, refs):
    out = os.path.join(outdir, name)
    cmd = [crossgen2, f"-o:{out}"]
    cmd += [f"-r:{r}" for r in refs]
    cmd += ["--targetarch:arm64", "--obj-format:pe", "--targetos:linux", "-O",
            os.path.join(libdir, name)]
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True,
                       cwd=os.path.dirname(crossgen2))
    dt = time.time() - t0
    ok = p.returncode == 0 and os.path.exists(out) and is_r2r(out)
    if not ok:
        try:
            os.remove(out)
        except OSError:
            pass
        lines = [l for l in (p.stderr or p.stdout or "").splitlines() if l.strip()]
        err = next((l for l in lines if l.startswith("Error:")),
                   lines[0] if lines else "")
        return name, False, dt, p.returncode, err[:200]
    return name, True, dt, 0, ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--crossgen2", required=True, help="stock crossgen2 executable")
    ap.add_argument("--libdir", required=True, help="dir with the PureIL framework assemblies")
    ap.add_argument("--refdir", default="",
                    help="dir with reference assemblies (defaults to --libdir); pass a set "
                         "that includes System.Private.CoreLib")
    ap.add_argument("--outdir", required=True, help="output dir for R2R images")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--only", default="", help="comma list (test/debug subset)")
    ap.add_argument("--skip", default="System.Private.CoreLib.dll")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    refdir = args.refdir or args.libdir
    refs = [os.path.join(refdir, f)
            for f in sorted(os.listdir(refdir)) if f.endswith(".dll")]
    skip = {s.strip() for s in args.skip.split(",") if s.strip()}
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    targets = []
    for r in refs:
        name = os.path.basename(r)
        if name in skip or (only and name not in only):
            continue
        if is_r2r(r):
            print(f"skip (already R2R): {name}", flush=True)
            continue
        targets.append(name)

    print(f"framework R2R: {len(targets)} assemblies to compile "
          f"({len(refs)} refs, jobs={args.jobs})", flush=True)
    compiled = failed = 0
    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        futs = {ex.submit(compile_one, args.crossgen2, args.libdir, args.outdir, n, refs): n
                for n in targets}
        for fut in concurrent.futures.as_completed(futs):
            name, ok, dt, rc, err = fut.result()
            if ok:
                compiled += 1
                print(f"  R2R {name} ({dt:.1f}s)", flush=True)
            else:
                failed += 1
                print(f"  FAIL {name} rc={rc} ({dt:.1f}s) {err}", flush=True)
    print(f"framework R2R: compiled={compiled} failed={failed} total={len(targets)} "
          f"in {time.time() - t0:.0f}s", flush=True)
    return 0 if compiled > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
