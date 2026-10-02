#!/usr/bin/env python3
"""Assemble the ohos-interpreter-pack tarball from a feature-enabled CoreCLR pair.

The pack is the OpenHarmony/HarmonyOS CoreCLR interpreter overlay:
  native/libcoreclr.so        FEATURE_INTERPRETER=1 openharmony-arm64 Release coreclr
  native/libclrinterpreter.so the CoreCLR interpreter (getJit/jitStartup exports)

It replaces the stock runtime pack's libcoreclr.so (which has the interpreter
compiled out) and adds the interpreter library next to it, so a signed HAP can
run with DOTNET_InterpMode=3 (see the runtime repo's
docs/plans/2026-09-24-ohos-runtime-strategy.md and the RC2-INTERP-FIX note).

Usage:
  package-interp-pack.py --coreclr <libcoreclr.so> --interpreter <libclrinterpreter.so>
      [--stock-pack <runtime-pack-dir>] [--out <dir>] [--tag rc2]
      [--name ohos-interpreter-pack-rc2] [--version 11.0.0-rc.2.26451.112]
      [--extra-doc <VERIFICATION.md>] [--repo <runtime-ohos checkout>]

Output: <out>/<name>.tar.gz + <out>/<name>.tar.gz.sha256. The tar contains
<name>/{native/*.so,README.md,VERIFICATION.md,SHA256SUMS,build-info.json}.

The generated README documents the host-side prerequisites (app thread stack
above the PAL 1.5 MB floor, DOTNET_UseGCWriteBarrierCopy=0 in interpreter-only
mode on images that refuse the RWX commit) so a tester can stage the pack with
the workload's OpenHarmonyRuntimeMode=interp switch.
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(repo: str, *args: str) -> str:
    try:
        return subprocess.check_output(["git", "-C", repo, *args], text=True).strip()
    except Exception:
        return "unknown"


def coreclr_has_interpreter(path: str) -> bool:
    data = open(path, "rb").read()
    return any(w.encode("utf-32-le") in data or w.encode("utf-16-le") in data
               for w in ("clrinterpreter", "InterpMode", "InterpreterName"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--coreclr", required=True)
    ap.add_argument("--interpreter", required=True)
    ap.add_argument("--stock-pack", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--tag", default="rc2")
    ap.add_argument("--name", default="")
    ap.add_argument("--version", default="11.0.0-rc.2.26451.112")
    ap.add_argument("--extra-doc", default="")
    ap.add_argument("--repo", default=os.environ.get("REPO", os.getcwd()))
    args = ap.parse_args()

    name = args.name or f"ohos-interpreter-pack-{args.tag}"
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(args.coreclr)), "pack")
    stage = os.path.join(out, name)

    if not coreclr_has_interpreter(args.coreclr):
        print("error: libcoreclr.so has no clrinterpreter/InterpMode/InterpreterName "
              "wide strings; build it with -clrinterpreter", file=sys.stderr)
        return 1

    print("== 1. stage payload ==")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(os.path.join(stage, "native"))
    shutil.copy2(args.coreclr, os.path.join(stage, "native", "libcoreclr.so"))
    shutil.copy2(args.interpreter, os.path.join(stage, "native", "libclrinterpreter.so"))

    print("== 2. build-info.json + SHA256SUMS ==")
    files = {
        "native/libcoreclr.so": os.path.join(stage, "native", "libcoreclr.so"),
        "native/libclrinterpreter.so": os.path.join(stage, "native", "libclrinterpreter.so"),
    }
    info = {
        "name": name,
        "description": "Feature-enabled (FEATURE_INTERPRETER=1) openharmony-arm64 CoreCLR "
                       "+ CoreCLR interpreter library for DOTNET_InterpMode=3 on OpenHarmony/HarmonyOS",
        "runtime_branch": git(args.repo, "branch", "--show-current"),
        "runtime_commit": git(args.repo, "rev-parse", "HEAD"),
        "version": args.version,
        "rid": "openharmony-arm64",
        "configuration": "Release",
        "subset": "clr.native",
        "feature_interpreter": True,
        "built_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "files": {rel: {"size": os.path.getsize(p), "sha256": sha256(p)} for rel, p in files.items()},
    }
    with open(os.path.join(stage, "build-info.json"), "w") as f:
        json.dump(info, f, indent=2)
    with open(os.path.join(stage, "SHA256SUMS"), "w") as f:
        for rel, meta in info["files"].items():
            f.write(f'{meta["sha256"]}  {rel}\n')
    print(json.dumps(info, indent=2))

    print("== 3. README.md ==")
    core_meta = info["files"]["native/libcoreclr.so"]
    interp_meta = info["files"]["native/libclrinterpreter.so"]
    short = git(args.repo, "rev-parse", "--short=12", "HEAD")
    readme = f"""# {name} — CoreCLR interpreter overlay for OpenHarmony/HarmonyOS

Feature-enabled (`FEATURE_INTERPRETER=1`) **openharmony-arm64 Release** CoreCLR built from
`springmin/runtime-ohos` @ `{short}` (rc.2 line), plus the CoreCLR interpreter shared
library. It replaces the stock runtime's `libcoreclr.so`, which has the interpreter
compiled *out* (no `clrinterpreter`/`InterpMode`/`InterpreterName` strings) and therefore
ignores `DOTNET_InterpMode=3`.

| file | size | sha256 |
|---|---|---|
| `native/libcoreclr.so` | {core_meta['size']} | `{core_meta['sha256']}` |
| `native/libclrinterpreter.so` | {interp_meta['size']} | `{interp_meta['sha256']}` |

## Combine with a HAP payload (HAP `libs/arm64-v8a/`)

1. Take the publish payload `libs/arm64-v8a/` (or an extracted runtime pack).
2. Replace `libcoreclr.so` with `native/libcoreclr.so`.
3. Add `native/libclrinterpreter.so` next to it.
4. Re-package + re-sign the HAP, or let the workload do it with
   `-p:OpenHarmonyRuntimeMode=interp -p:OpenHarmonyInterpreterPack=<extracted pack>`
   (writes `libs/<abi>/runtime-mode.txt` = `interp`).

## Enable the interpreter (host requirements)

```
DOTNET_InterpMode=3            # full interpreter-only: no JIT, no R2R, no HW intrinsics
DOTNET_EnableWriteXorExecute=0
DOTNET_UseGCWriteBarrierCopy=0 # interpreter-only never uses the mutable write-barrier copy;
                               # images that refuse the RWX commit need this (else the first
                               # memcpy into it faults with SEGV_ACCERR in coreclr_initialize)
```

The managed app thread must also have a stack larger than CoreCLR's PAL 1.5 MB floor
(`ENSURE_PRIMARY_STACK_SIZE`): the OHOS musl default was 1 MB and the probe faulted below
the mapping (`SIGSEGV_MAPERR`/`SEGV_ACCERR` in `EnsureStackSize`). `libopenharmonyhost.so`
from the RC2-INTERP-FIX host source sets 8 MB and the switches above.

## Verification points

* `libclrinterpreter.so` is mapped in the running process (`/proc/self/maps`).
* Interpreter-only startup needs no anonymous executable mapping.
* `DOTNET_InterpreterName=libclrinterpreter-missing.so` must fail to start (negative control).
* The managed app runs normally (no crash in `coreclr_initialize`).

## Provenance

Built with the runtime repo's `scripts/ohos-runtime-interp-fullbuild.sh`; see
`build-info.json` and `VERIFICATION.md`. Development asset; verify `SHA256SUMS` first.
"""
    with open(os.path.join(stage, "README.md"), "w") as f:
        f.write(readme)

    print("== 4. VERIFICATION.md ==")
    if args.extra_doc and os.path.exists(args.extra_doc):
        shutil.copy2(args.extra_doc, os.path.join(stage, "VERIFICATION.md"))
    else:
        with open(os.path.join(stage, "VERIFICATION.md"), "w") as f:
            f.write("(no extra verification notes supplied)\n")

    print("== 5. tar (explicit clobber) ==")
    tarball = os.path.join(out, name + ".tar.gz")
    if os.path.exists(tarball):
        os.remove(tarball)
    with tarfile.open(tarball, "w:gz") as tar:
        tar.add(stage, arcname=name)
    digest = sha256(tarball)
    with open(tarball + ".sha256", "w") as f:
        f.write(f"{digest}  {name}.tar.gz\n")
    print(f"{digest}  {name}.tar.gz")
    print(f"size: {os.path.getsize(tarball)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
