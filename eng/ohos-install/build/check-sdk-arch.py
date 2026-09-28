#!/usr/bin/env python3
"""Guard the OpenHarmony SDK against foreign-architecture dotnet-aot libraries.

Background
----------
The SDK layout under artifacts/bin/redist/<config>/ is reused between builds and
the SDK build does not remove stale files from it. OpenHarmony has no NativeAOT
toolchain, so `_ShouldPublishDotnetAot` is false and the build intentionally does
not produce the dotnet-aot native library. A copy left behind by an earlier
host-RID build or a local dotnet-aot test run therefore survives in the layout
and gets archived into the release tarball. The CoreCLR muxer looks for that
library next to dotnet.dll on every startup, tries to load it, and prints

    Failed to load .../libdotnet-aot.so, error: Error loading shared library
    ld-linux-x86-64.so.2: (needed by .../libdotnet-aot.so)

before falling back to the managed CLI. It is not fatal, but it is noise on
every `dotnet` invocation, and an arm64 SDK must not ship an x86-64 binary.

Usage
-----
  check-sdk-arch.py prune  <layout-dir> [<layout-dir> ...]
  check-sdk-arch.py verify <tarball> [<tarball> ...] [--list-foreign]

prune   removes every dotnet-aot native library from the given layout tree(s).
        Called before the SDK build so a stale library cannot be packaged.
        Idempotent: a second run removes nothing and still succeeds.
verify  streams the given SDK tarball(s) and fails if a dotnet-aot member is
        present that is not an AArch64 ELF. A genuine AArch64 dotnet-aot built
        for openharmony would be loadable on the target, so only foreign
        architectures (or non-ELF files) are rejected. --list-foreign adds a
        non-fatal report of any other non-AArch64 ELF member; the SDK ships
        cross-RID NuGet runtimes/ payloads, so that report is informational.
"""
import argparse
import os
import struct
import sys
import tarfile

# Native library names used by PublishDotnetAot in GenerateLayout.targets.
AOT_LIB_NAMES = frozenset((
    "libdotnet-aot.so",
    "libdotnet-aot.dylib",
    "libdotnet-aot.dll",
    "dotnet-aot.dll",
))

ELF_MAGIC = b"\x7fELF"
EM_386 = 0x03
EM_ARM = 0x28
EM_X86_64 = 0x3E
EM_AARCH64 = 0xB7
MACHINE_NAMES = {
    EM_386: "i386",
    EM_ARM: "armv7",
    EM_X86_64: "x86-64",
    EM_AARCH64: "aarch64",
}
TARGET_MACHINE = EM_AARCH64


def machine_name(machine):
    return MACHINE_NAMES.get(machine, "machine 0x%x" % machine)


def read_machine(blob):
    """Return the e_machine of an ELF header blob, or None if it is not ELF."""
    if len(blob) < 20 or blob[:4] != ELF_MAGIC:
        return None
    return struct.unpack_from("<H", blob, 18)[0]


def prune(paths):
    removed = 0
    for root in paths:
        if not os.path.isdir(root):
            sys.stderr.write("ERROR: not a directory: %s\n" % root)
            return 2
        for dirpath, _dirnames, filenames in os.walk(root):
            for filename in filenames:
                if filename not in AOT_LIB_NAMES:
                    continue
                path = os.path.join(dirpath, filename)
                try:
                    os.remove(path)
                except OSError as exc:
                    sys.stderr.write("ERROR: cannot remove %s: %s\n" % (path, exc))
                    return 1
                print("removed stale %s: %s" % (filename, path))
                removed += 1
    print("prune: %d stale dotnet-aot library file(s) removed" % removed)
    return 0


def verify(tarballs, list_foreign):
    failed = False
    for path in tarballs:
        found = 0
        with tarfile.open(path, "r|gz") as tar:
            for member in tar:
                if not member.isfile():
                    continue
                basename = os.path.basename(member.name)
                if basename not in AOT_LIB_NAMES and not list_foreign:
                    continue
                f = tar.extractfile(member)
                blob = f.read(20) if f is not None else b""
                if basename in AOT_LIB_NAMES:
                    found += 1
                    machine = read_machine(blob)
                    if machine is None:
                        sys.stderr.write(
                            "ERROR: %s: %s is not an ELF file\n" % (path, member.name))
                        failed = True
                    elif machine != TARGET_MACHINE:
                        sys.stderr.write(
                            "ERROR: %s: %s is %s, expected %s\n"
                            % (path, member.name, machine_name(machine),
                               machine_name(TARGET_MACHINE)))
                        failed = True
                elif list_foreign:
                    machine = read_machine(blob)
                    if (machine is not None and machine != TARGET_MACHINE
                            and "/runtimes/" not in member.name):
                        print("note: %s: non-target ELF %s (%s)"
                              % (path, member.name, machine_name(machine)))
        if found == 0:
            print("verify: %s contains no dotnet-aot native library" % path)
        else:
            print("verify: %s contains %d dotnet-aot native library file(s)" % (path, found))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    p_prune = sub.add_parser("prune", help="remove dotnet-aot libraries from a layout tree")
    p_prune.add_argument("paths", nargs="+", metavar="LAYOUT-DIR")
    p_verify = sub.add_parser("verify", help="check SDK tarballs for foreign dotnet-aot libraries")
    p_verify.add_argument("paths", nargs="+", metavar="TARBALL")
    p_verify.add_argument("--list-foreign", action="store_true",
                          help="also list other non-aarch64 ELF members (informational)")
    args = parser.parse_args()

    if args.mode == "prune":
        return prune(args.paths)
    return verify(args.paths, args.list_foreign)


if __name__ == "__main__":
    sys.exit(main())
