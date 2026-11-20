#!/usr/bin/env python3
"""Check the ELF machine of a file or of an entry inside a nupkg.

The OpenHarmony build produces two ilc packs: the device compiler
(openharmony-arm64) and the desktop host compiler (linux-x64 on CI).  A
cross build can accidentally pack the target-arch ilc under the host RID
(that is what happened before the host re-publish), and the resulting pack
only fails much later, when the build host tries to execute `tools/ilc`.
This check fails closed at pack time instead.

Usage:
  check-elf-arch.py <file|nupkg> --expect <x86-64|aarch64> [--entry tools/ilc]

`--entry` reads the named entry from a nupkg (zip) instead of the file itself.
Exit code 0 means the ELF machine matches; 1 means a mismatch or an
unreadable/unexpected artifact.
"""
import argparse
import sys
import zipfile

# ELF e_machine values used by the build host and the OpenHarmony device.
MACHINES = {
    62: "x86-64",
    183: "aarch64",
}


def read_header(path, entry):
    if entry is None:
        with open(path, "rb") as f:
            return f.read(20)
    try:
        with zipfile.ZipFile(path) as zf:
            with zf.open(entry) as f:
                return f.read(20)
    except KeyError:
        raise SystemExit(f"check-elf-arch: {path} has no entry {entry!r}")
    except zipfile.BadZipFile:
        raise SystemExit(f"check-elf-arch: {path} is not a nupkg (bad zip)")


def elf_machine(header):
    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise SystemExit("check-elf-arch: not an ELF file")
    if header[5] != 1:
        raise SystemExit("check-elf-arch: only little-endian ELF is supported")
    machine = int.from_bytes(header[18:20], "little")
    return MACHINES.get(machine, f"machine-{machine}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="ELF file or nupkg")
    parser.add_argument(
        "--expect",
        required=True,
        choices=sorted(MACHINES.values()),
        help="expected ELF machine",
    )
    parser.add_argument(
        "--entry",
        help="entry name inside the nupkg (for example tools/ilc)",
    )
    args = parser.parse_args()

    actual = elf_machine(read_header(args.path, args.entry))
    where = args.path if args.entry is None else f"{args.path}:{args.entry}"
    print(f"check-elf-arch: {where} -> {actual} (expected {args.expect})")
    if actual != args.expect:
        raise SystemExit(
            f"check-elf-arch: wrong architecture: got {actual}, want {args.expect}"
        )


if __name__ == "__main__":
    main()
