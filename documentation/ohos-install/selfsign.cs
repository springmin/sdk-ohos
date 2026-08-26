// Standalone OpenHarmony ELF self-sign tool
// Extracted from OhosCodesign.cs (ElfSelfSigner), byte-identical algorithm.
// Usage: selfsign <input_elf> [output_elf] [--force] [--strip]
using System;
using System.IO;
using System.Security.Cryptography;

internal static class ElfSelfSigner
    {
        private const int DescSize = 256;
        private const int PageSize = 4096;
        private const uint FlagSelfSign = 0x10;
        private const uint FsVerityDescriptorType = 1;
        private const int HashOut = 32;

        // ELF64 header field offsets
        private const int EShOff = 0x28;
        private const int EShentsize = 0x3a;
        private const int EShnum = 0x3c;
        private const int EShstrndx = 0x3e;

        // ".codesign\0" including the trailing NUL (10 bytes)
        private static readonly byte[] CodesignName = new byte[] { (byte)'.', (byte)'c', (byte)'o', (byte)'d', (byte)'e', (byte)'s', (byte)'i', (byte)'g', (byte)'n', 0 };

        public static bool TrySignFileInPlace(string path)
        {
            if (!File.Exists(path))
            {
                return false;
            }

            byte[] raw = File.ReadAllBytes(path);
            if (!IsElf64(raw))
            {
                return false;
            }

            byte[] signed = SignElf(raw, force: true);
            // FileMode.Create truncates the existing inode in place, preserving its Unix permissions.
            File.WriteAllBytes(path, signed);
            return true;
        }

        private static bool IsElf64(byte[] data) =>
            data.Length >= 64 &&
            data[0] == 0x7f && data[1] == (byte)'E' && data[2] == (byte)'L' && data[3] == (byte)'F' &&
            data[4] == 2; // ELFCLASS64

        private static ushort ReadU16(byte[] b, int off) => (ushort)(b[off] | (b[off + 1] << 8));

        private static uint ReadU32(byte[] b, int off) =>
            (uint)(b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24));

        private static ulong ReadU64(byte[] b, int off) =>
            (ulong)b[off] | ((ulong)b[off + 1] << 8) | ((ulong)b[off + 2] << 16) | ((ulong)b[off + 3] << 24) |
            ((ulong)b[off + 4] << 32) | ((ulong)b[off + 5] << 40) | ((ulong)b[off + 6] << 48) | ((ulong)b[off + 7] << 56);

        private static void WriteU16(byte[] b, int off, ushort v)
        {
            b[off] = (byte)v;
            b[off + 1] = (byte)(v >> 8);
        }

        private static void WriteU32(byte[] b, int off, uint v)
        {
            b[off] = (byte)v;
            b[off + 1] = (byte)(v >> 8);
            b[off + 2] = (byte)(v >> 16);
            b[off + 3] = (byte)(v >> 24);
        }

        private static void WriteU64(byte[] b, int off, ulong v)
        {
            b[off] = (byte)v;
            b[off + 1] = (byte)(v >> 8);
            b[off + 2] = (byte)(v >> 16);
            b[off + 3] = (byte)(v >> 24);
            b[off + 4] = (byte)(v >> 32);
            b[off + 5] = (byte)(v >> 40);
            b[off + 6] = (byte)(v >> 48);
            b[off + 7] = (byte)(v >> 56);
        }

        private static ulong AlignUp(ulong v, ulong a) => (v + a - 1) / a * a;

        private static byte[] Sha256(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
            {
                return sha.ComputeHash(data);
            }
        }

        private static (ulong eShOff, ushort eShnum, ushort eShstrndx) ParseElfHeader(byte[] elf)
        {
            if (!IsElf64(elf))
            {
                throw new InvalidDataException("not ELF64");
            }

            ulong eShOff = ReadU64(elf, EShOff);
            ushort eShentsize = ReadU16(elf, EShentsize);
            ushort eShnum = ReadU16(elf, EShnum);
            ushort eShstrndx = ReadU16(elf, EShstrndx);
            if (eShentsize != 64 || eShOff == 0 || eShnum == 0 || eShstrndx >= eShnum)
            {
                throw new InvalidDataException("ELF has no usable section header table");
            }

            if (eShOff > (ulong)elf.Length || (ulong)eShnum > ((ulong)elf.Length - eShOff) / 64)
            {
                throw new InvalidDataException("section header table out of bounds");
            }

            return (eShOff, eShnum, eShstrndx);
        }

        private static long FindSectionByName(byte[] elf, ulong eShOff, ushort eShnum, ushort eShstrndx, byte[] name)
        {
            int nameLen = name.Length;
            ulong shstrE = eShOff + (ulong)eShstrndx * 64;
            ulong shstrOff = ReadU64(elf, (int)(shstrE + 24));
            ulong shstrSz = ReadU64(elf, (int)(shstrE + 32));
            if (shstrOff > (ulong)elf.Length || shstrSz > (ulong)elf.Length - shstrOff)
            {
                return -1;
            }

            for (int i = 0; i < eShnum; i++)
            {
                ulong e = eShOff + (ulong)i * 64;
                uint nameOff = ReadU32(elf, (int)e);
                if ((ulong)nameOff + (ulong)nameLen <= shstrSz)
                {
                    int start = (int)(shstrOff + nameOff);
                    if (start + nameLen <= elf.Length && ByteArrayEquals(elf, start, name))
                    {
                        return (long)e;
                    }
                }
            }

            return -1;
        }

        private static bool ByteArrayEquals(byte[] b, int off, byte[] name)
        {
            for (int i = 0; i < name.Length; i++)
            {
                if (b[off + i] != name[i])
                {
                    return false;
                }
            }

            return true;
        }

        private static bool HasCodesignSection(byte[] elf)
        {
            (ulong eShOff, ushort eShnum, ushort eShstrndx) = ParseElfHeader(elf);
            return FindSectionByName(elf, eShOff, eShnum, eShstrndx, CodesignName) >= 0;
        }

        private static ushort NewShstrndx(ushort oldShstrndx, int csIdx) =>
            csIdx < oldShstrndx ? (ushort)(oldShstrndx - 1) : oldShstrndx;

        internal static byte[] StripCodesign(byte[] buf, out bool removed)
        {
            removed = false;
            (ulong eShOff, ushort eShnum, ushort eShstrndx) = ParseElfHeader(buf);

            long csEntryOff = FindSectionByName(buf, eShOff, eShnum, eShstrndx, CodesignName);
            if (csEntryOff < 0)
            {
                return buf;
            }

            removed = true;
            int csIdx = (int)((ulong)csEntryOff - eShOff) / 64;

            ulong shstrE = eShOff + (ulong)eShstrndx * 64;
            ulong shstrOff = ReadU64(buf, (int)(shstrE + 24));
            ulong shstrSz = ReadU64(buf, (int)(shstrE + 32));
            if (shstrOff > (ulong)buf.Length || shstrSz > (ulong)buf.Length - shstrOff)
            {
                throw new InvalidDataException("shstrtab out of bounds");
            }

            uint csNameOff = ReadU32(buf, (int)csEntryOff);
            int csNameLen = CodesignName.Length;
            int shstrStart = (int)shstrOff;
            byte[] newShstr = new byte[shstrSz - (ulong)csNameLen];
            Buffer.BlockCopy(buf, shstrStart, newShstr, 0, (int)csNameOff);
            Buffer.BlockCopy(buf, shstrStart + (int)csNameOff + csNameLen, newShstr, (int)csNameOff, (int)(shstrSz - (ulong)csNameOff - (ulong)csNameLen));
            int newShstrSz = newShstr.Length;

            int newShnum = eShnum - 1;
            byte[] newSht = new byte[newShnum * 64];
            int dst = 0;
            for (int i = 0; i < eShnum; i++)
            {
                if (i == csIdx)
                {
                    continue;
                }

                Buffer.BlockCopy(buf, (int)eShOff + i * 64, newSht, dst, 64);
                dst += 64;
            }

            ulong csSecOff = ReadU64(buf, (int)csEntryOff + 24);
            int keepLen = (int)Math.Min(csSecOff, (ulong)buf.Length);
            int newShstrOff = keepLen;
            int newShtOff = (int)AlignUp((ulong)(newShstrOff + newShstrSz), 8);
            int newTotal = newShtOff + newShnum * 64;

            byte[] outBuf = new byte[newTotal];
            Buffer.BlockCopy(buf, 0, outBuf, 0, keepLen);
            Buffer.BlockCopy(newShstr, 0, outBuf, newShstrOff, newShstrSz);
            Buffer.BlockCopy(newSht, 0, outBuf, newShtOff, newShnum * 64);

            int shstrEntryOffInNew = NewShstrndx(eShstrndx, csIdx) * 64;
            WriteU64(outBuf, newShtOff + shstrEntryOffInNew + 24, (ulong)newShstrOff);
            WriteU64(outBuf, newShtOff + shstrEntryOffInNew + 32, (ulong)newShstrSz);

            for (int i = 0; i < newShnum; i++)
            {
                int e = newShtOff + i * 64;
                uint noff = ReadU32(outBuf, e);
                if (noff > csNameOff)
                {
                    WriteU32(outBuf, e, noff - (uint)csNameLen);
                }
            }

            WriteU64(outBuf, EShOff, (ulong)newShtOff);
            WriteU16(outBuf, EShnum, (ushort)newShnum);
            if (csIdx < eShstrndx)
            {
                WriteU16(outBuf, EShstrndx, (ushort)(eShstrndx - 1));
            }

            return outBuf;
        }

        private static (byte[] buf, int csOff) InjectCodesignSection(byte[] elf)
        {
            (ulong eShOff, ushort eShnum, ushort eShstrndx) = ParseElfHeader(elf);

            ulong shstrE = eShOff + (ulong)eShstrndx * 64;
            ulong shstrOff = ReadU64(elf, (int)(shstrE + 24));
            ulong shstrSz = ReadU64(elf, (int)(shstrE + 32));
            if (shstrOff > (ulong)elf.Length || shstrSz > (ulong)elf.Length - shstrOff)
            {
                throw new InvalidDataException("shstrtab out of bounds");
            }

            ulong curEnd = eShOff + (ulong)eShnum * 64;
            for (int i = 0; i < eShnum; i++)
            {
                ulong e = eShOff + (ulong)i * 64;
                uint shType = ReadU32(elf, (int)(e + 4));
                ulong off = ReadU64(elf, (int)(e + 24));
                ulong sz = shType == 8 ? 0 : ReadU64(elf, (int)(e + 32));
                if (off + sz > curEnd)
                {
                    curEnd = off + sz;
                }
            }

            int csOff = (int)AlignUp(curEnd, PageSize);

            int shstrStart = (int)shstrOff;
            byte[] newShstr = new byte[shstrSz + (ulong)CodesignName.Length];
            Buffer.BlockCopy(elf, shstrStart, newShstr, 0, (int)shstrSz);
            Buffer.BlockCopy(CodesignName, 0, newShstr, (int)shstrSz, CodesignName.Length);
            int newShstrSz = newShstr.Length;
            uint csShname = (uint)shstrSz;

            int newShstrOff = csOff + PageSize;
            int newShtOff = (int)AlignUp((ulong)(newShstrOff + newShstrSz), 8);
            int newShnum = eShnum + 1;
            int newTotal = newShtOff + newShnum * 64;

            byte[] buf = new byte[newTotal];
            int copyLen = Math.Min(elf.Length, Math.Min(newTotal, csOff));
            Buffer.BlockCopy(elf, 0, buf, 0, copyLen);

            Buffer.BlockCopy(newShstr, 0, buf, newShstrOff, newShstrSz);
            Buffer.BlockCopy(elf, (int)eShOff, buf, newShtOff, (int)eShnum * 64);

            int csE = newShtOff + (int)eShnum * 64;
            WriteU32(buf, csE, csShname); // sh_name
            WriteU32(buf, csE + 4, 1); // sh_type = SHT_PROGBITS
            WriteU64(buf, csE + 24, (ulong)csOff); // sh_offset
            WriteU64(buf, csE + 32, PageSize); // sh_size
            WriteU64(buf, csE + 48, PageSize); // sh_addralign

            int shstrENew = newShtOff + (int)eShstrndx * 64;
            WriteU64(buf, shstrENew + 24, (ulong)newShstrOff);
            WriteU64(buf, shstrENew + 32, (ulong)newShstrSz);

            WriteU64(buf, EShOff, (ulong)newShtOff);
            WriteU16(buf, EShnum, (ushort)newShnum);

            return (buf, csOff);
        }

        private static byte[] MerkleRootHash(byte[] data, int csOff, int csLen)
        {
            if (data.Length == 0)
            {
                return Sha256(new byte[PageSize]);
            }

            int npages = (data.Length + PageSize - 1) / PageSize;
            int csPageBegin = csOff / PageSize;
            int csPageEnd = (csOff + csLen + PageSize - 1) / PageSize;

            byte[] hashes = new byte[npages * HashOut];
            for (int i = 0; i < npages; i++)
            {
                if (csLen > 0 && i >= csPageBegin && i < csPageEnd)
                {
                    continue; // codesign pages: zero leaf hash
                }

                byte[] page = new byte[PageSize];
                int off = i * PageSize;
                int n = Math.Min(PageSize, data.Length - off);
                Buffer.BlockCopy(data, off, page, 0, n);
                byte[] h = Sha256(page);
                Buffer.BlockCopy(h, 0, hashes, i * HashOut, HashOut);
            }

            if (npages == 1)
            {
                byte[] root = new byte[HashOut];
                Buffer.BlockCopy(hashes, 0, root, 0, HashOut);
                return root;
            }

            byte[] cur = hashes;
            while (true)
            {
                int packed = cur.Length;
                if (packed <= PageSize)
                {
                    byte[] page = new byte[PageSize];
                    Buffer.BlockCopy(cur, 0, page, 0, packed);
                    return Sha256(page);
                }

                int nextPages = (packed + PageSize - 1) / PageSize;
                byte[] next = new byte[nextPages * HashOut];
                for (int i = 0; i < nextPages; i++)
                {
                    byte[] page = new byte[PageSize];
                    int off = i * PageSize;
                    int n = Math.Min(PageSize, packed - off);
                    Buffer.BlockCopy(cur, off, page, 0, n);
                    byte[] h = Sha256(page);
                    Buffer.BlockCopy(h, 0, next, i * HashOut, HashOut);
                }

                cur = next;
            }
        }

        private static byte[] BuildDescriptor(uint signSize, ulong fileSize, byte[] root, uint flags)
        {
            byte[] d = new byte[DescSize];
            d[0] = 1; // version
            d[1] = 1; // hashAlgorithm = SHA-256
            d[2] = 12; // log2BlockSize = 2^12 = 4096
            d[3] = 0; // saltSize
            WriteU32(d, 4, signSize);
            WriteU64(d, 8, fileSize);
            Buffer.BlockCopy(root, 0, d, 16, HashOut); // rootHash left-aligned
            WriteU32(d, 112, flags);
            d[255] = 3; // csVersion
            return d;
        }

        internal static byte[] SignElf(byte[] elf, bool force)
        {
            if (!IsElf64(elf))
            {
                throw new InvalidDataException("not ELF64");
            }

            byte[] buf = elf;
            if (HasCodesignSection(buf))
            {
                if (!force)
                {
                    throw new InvalidDataException("already has a .codesign section; strip first or use --force");
                }

                buf = StripCodesign(buf, out _);
            }

            (byte[] tmp0, int csOff) = InjectCodesignSection(buf);
            ulong fileSize = (ulong)tmp0.Length;

            byte[] root = MerkleRootHash(tmp0, csOff, PageSize);

            byte[] descForDigest = BuildDescriptor(0, fileSize, root, FlagSelfSign);
            byte[] signature = Sha256(descForDigest);
            byte[] descOnDisk = BuildDescriptor(32, fileSize, root, FlagSelfSign);

            byte[] payload = new byte[4 + 4 + DescSize + HashOut];
            WriteU32(payload, 0, FsVerityDescriptorType); // type
            WriteU32(payload, 4, (uint)(DescSize + HashOut)); // length = 288
            Buffer.BlockCopy(descOnDisk, 0, payload, 8, DescSize);
            Buffer.BlockCopy(signature, 0, payload, 8 + DescSize, HashOut);

            Buffer.BlockCopy(payload, 0, tmp0, csOff, payload.Length);
            return tmp0;
        }
    }
internal static class Program
{
    private static int Main(string[] args)
    {
        bool force = false;
        bool stripOnly = false;
        var positional = new System.Collections.Generic.List<string>();
        foreach (var a in args)
        {
            if (a == "--force" || a == "-f") force = true;
            else if (a == "--strip") stripOnly = true;
            else positional.Add(a);
        }
        if (positional.Count == 0 || positional.Count > 2)
        {
            Console.Error.WriteLine("usage: selfsign <input_elf> [output_elf] [--force] [--strip]");
            return 1;
        }
        string inPath = positional[0];
        string outPath = positional.Count == 2 ? positional[1] : inPath;
        try
        {
            if (stripOnly)
            {
                byte[] raw = File.ReadAllBytes(inPath);
                byte[] stripped = ElfSelfSigner.StripCodesign(raw, out bool removed);
                if (!removed) { Console.WriteLine($"no .codesign section to strip: {inPath}"); return 0; }
                File.WriteAllBytes(outPath, stripped);
                Console.WriteLine($"strip ok: {inPath} -> {outPath} ({stripped.Length} bytes)");
                return 0;
            }
            if (inPath == outPath)
            {
                if (ElfSelfSigner.TrySignFileInPlace(inPath))
                    Console.WriteLine($"selfsign ok: {inPath} (in-place, {(force ? "force" : "append-only")})");
                else
                    Console.WriteLine($"not an ELF64: {inPath}");
                return 0;
            }
            byte[] data = File.ReadAllBytes(inPath);
            byte[] signed = ElfSelfSigner.SignElf(data, force);
            File.WriteAllBytes(outPath, signed);
            Console.WriteLine($"selfsign ok: {inPath} -> {outPath} ({signed.Length} bytes)");
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"error: {e.Message}");
            return 2;
        }
    }
}
