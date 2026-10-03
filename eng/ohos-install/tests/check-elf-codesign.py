#!/usr/bin/env python3
# ============================================================================
# check-elf-codesign.py — verify the OpenHarmony `.codesign` section of an ELF64-LE file.
#
# Port of the runtime half of sdk-ohos' ElfSigner.IsValidlySigned: walk the section
# header table for `.codesign`, rebuild the page Merkle root with the codesign pages
# zeroed, hash the descriptor (magic 1/1/12/3, signSize/fileSize/flags) and compare
# the stored signature. Read-only and offline; use it to confirm a signed SDK/ELF
# artifact without the signing toolchain or a device.
#
# Usage: python3 eng/ohos-install/tests/check-elf-codesign.py <elf> [<elf>...]
# Exit:  0 = all valid, 1 = at least one mismatch/unsigned, 2 = usage error.
# ============================================================================
import hashlib
import struct
import sys


def check(elf: bytes):
    if len(elf) < 64 or elf[:4] != b"\x7fELF" or elf[4] != 2 or elf[5] != 1:
        return "not ELF64-LE"
    e_shoff = struct.unpack_from("<Q", elf, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", elf, 0x3a)[0]
    e_shnum = struct.unpack_from("<H", elf, 0x3c)[0]
    e_shstrndx = struct.unpack_from("<H", elf, 0x3e)[0]
    if e_shentsize != 64 or e_shoff == 0 or e_shnum == 0 or e_shstrndx >= e_shnum:
        return "no usable section header table"
    if e_shoff > len(elf) or e_shnum > (len(elf) - e_shoff) // 64:
        return "section header table out of bounds"
    shstr_e = e_shoff + e_shstrndx * 64
    shstr_off = struct.unpack_from("<Q", elf, shstr_e + 24)[0]
    shstr_sz = struct.unpack_from("<Q", elf, shstr_e + 32)[0]
    if shstr_off > len(elf) or shstr_sz > len(elf) - shstr_off:
        return "shstrtab out of bounds"
    name = b".codesign\x00"
    cs_entry = None
    for i in range(e_shnum):
        e = e_shoff + i * 64
        name_off = struct.unpack_from("<I", elf, e)[0]
        if name_off + len(name) <= shstr_sz:
            start = shstr_off + name_off
            if start + len(name) <= len(elf) and elf[start:start + len(name)] == name:
                cs_entry = e
                break
    if cs_entry is None:
        return "no .codesign section"
    cs_off = struct.unpack_from("<Q", elf, cs_entry + 24)[0]
    cs_len = struct.unpack_from("<Q", elf, cs_entry + 32)[0]
    if cs_off > len(elf) or cs_len > len(elf) - cs_off:
        return "section out of bounds"
    cs_off, cs_len = int(cs_off), int(cs_len)
    if cs_len < 8 + 256 + 32:
        return "payload too small"
    typ, length = struct.unpack_from("<II", elf, cs_off)
    d = cs_off + 8
    if typ != 1 or length != 256 + 32:
        return f"bad descriptor header {typ} {length}"
    if elf[d] != 1 or elf[d + 1] != 1 or elf[d + 2] != 12 or elf[d + 255] != 3:
        return "bad descriptor magic"
    sign_size = struct.unpack_from("<I", elf, d + 4)[0]
    file_size = struct.unpack_from("<Q", elf, d + 8)[0]
    flags = struct.unpack_from("<I", elf, d + 112)[0]
    if sign_size != 32 or file_size != len(elf):
        return f"signSize/fileSize mismatch ({sign_size}, {file_size} vs {len(elf)})"
    stored_root = elf[d + 16:d + 16 + 32]
    # Merkle root over pages, codesign pages contribute a zero leaf hash
    n = len(elf)
    npages = (n + 4095) // 4096
    begin, end = cs_off // 4096, (cs_off + cs_len + 4095) // 4096
    hashes = bytearray(npages * 32)
    for i in range(npages):
        if cs_len > 0 and begin <= i < end:
            continue
        page = bytearray(4096)
        off = i * 4096
        page[:min(4096, n - off)] = elf[off:off + 4096]
        hashes[i * 32:(i + 1) * 32] = hashlib.sha256(page).digest()
    if npages == 1:
        root = bytes(hashes[:32])
    else:
        cur = bytes(hashes)
        while True:
            if len(cur) <= 4096:
                page = bytearray(4096)
                page[:len(cur)] = cur
                root = hashlib.sha256(page).digest()
                break
            np = (len(cur) + 4095) // 4096
            nxt = bytearray(np * 32)
            for i in range(np):
                page = bytearray(4096)
                off = i * 4096
                page[:min(4096, len(cur) - off)] = cur[off:off + 4096]
                nxt[i * 32:(i + 1) * 32] = hashlib.sha256(page).digest()
            cur = bytes(nxt)
    if stored_root != root:
        return "root mismatch"
    stored_sig = elf[d + 256:d + 256 + 32]
    desc = bytearray(256)
    desc[0], desc[1], desc[2], desc[3] = 1, 1, 12, 0
    struct.pack_into("<I", desc, 4, 0)
    struct.pack_into("<Q", desc, 8, file_size)
    desc[16:48] = root
    struct.pack_into("<I", desc, 112, flags)
    desc[255] = 3
    if stored_sig != hashlib.sha256(desc).digest():
        return "signature mismatch"
    return f"VALID (flags=0x{flags:x}, root={root.hex()[:16]}..., sig={stored_sig.hex()[:16]}...)"


def main(argv):
    if len(argv) < 2:
        print("usage: check-elf-codesign.py <elf> [<elf>...]", file=sys.stderr)
        return 2
    rc = 0
    for path in argv[1:]:
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as exc:
            print(f"{path}: cannot read: {exc}")
            rc = 1
            continue
        result = check(data)
        print(f"{path}: {result}")
        if not result.startswith("VALID"):
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
