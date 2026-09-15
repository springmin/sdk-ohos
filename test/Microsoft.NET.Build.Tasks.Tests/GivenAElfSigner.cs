// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Security.Cryptography;

namespace Microsoft.NET.Build.Tasks.UnitTests
{
    /// <summary>
    /// Byte-level coverage for the OpenHarmony ELF signer: the fs-verity descriptor layout
    /// (including the reserved regions the kernel requires to be zero), the SHA-256 signature
    /// digest, trailing-data preservation, re-sign skipping and codesign stripping.
    /// </summary>
    [TestClass]
    public class GivenAElfSigner
    {
        private const int PageSize = 4096;
        private const int DescriptorSize = 256;

        [TestMethod]
        public void SignElf_KeepsDataAppendedAfterTheSectionHeaderTable()
        {
            byte[] trailer = Enumerable.Range(0, 5000).Select(i => (byte)(i & 0xff)).ToArray();
            byte[] elf = CreateMinimalElf(trailer);
            int trailerOffset = elf.Length - trailer.Length;

            byte[] signed = ElfSigner.SignElf(elf, force: false);

            signed.AsSpan(trailerOffset, trailer.Length).ToArray().Should().Equal(trailer);
            FindSection(signed, ".codesign").Should().NotBeNull();
        }

        [TestMethod]
        public void SignElf_WritesAWellFormedFsVerityDescriptor()
        {
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);

            (int csOffset, int csSize) = FindSection(signed, ".codesign")!.Value;
            csSize.Should().Be(PageSize);

            ReadU32(signed, csOffset).Should().Be(1); // ElfSignInfo type
            ReadU32(signed, csOffset + 4).Should().Be(DescriptorSize + 32); // descriptor + signature

            int descriptor = csOffset + 8;
            signed[descriptor].Should().Be(1); // version
            signed[descriptor + 1].Should().Be(1); // hashAlgorithm = SHA-256
            signed[descriptor + 2].Should().Be(12); // log2BlockSize = 4096
            signed[descriptor + 3].Should().Be(0); // saltSize
            ReadU32(signed, descriptor + 4).Should().Be(32); // signSize
            ReadU64(signed, descriptor + 8).Should().Be((ulong)signed.Length); // dataSize

            // The OHOS kernel requires the rootHash padding, salt, reserved1 and reserved2
            // regions to be zero; only the last byte carries csVersion.
            signed.AsSpan(descriptor + 48, 64).ToArray().Should().OnlyContain(b => b == 0);
            ReadU32(signed, descriptor + 112).Should().Be(0x10); // FLAG_SELF_SIGN
            signed.AsSpan(descriptor + 116, 139).ToArray().Should().OnlyContain(b => b == 0);
            signed[descriptor + 255].Should().Be(3); // csVersion

            signed.AsSpan(descriptor + 16, 32).ToArray().Should().NotEqual(new byte[32]);

            // signature = SHA-256 of the descriptor with signSize zeroed
            byte[] descriptorForDigest = signed.AsSpan(descriptor, DescriptorSize).ToArray();
            descriptorForDigest[4] = descriptorForDigest[5] = descriptorForDigest[6] = descriptorForDigest[7] = 0;
            byte[] expectedSignature;
            using (SHA256 sha = SHA256.Create())
            {
                expectedSignature = sha.ComputeHash(descriptorForDigest);
            }

            signed.AsSpan(descriptor + DescriptorSize, 32).ToArray().Should().Equal(expectedSignature);
        }

        [TestMethod]
        public void SignFileInPlace_SkipsAnAlreadyValidSignature()
        {
            string path = Path.Combine(Path.GetTempPath(), $"ohos-sign-{Guid.NewGuid():N}");
            try
            {
                File.WriteAllBytes(path, CreateMinimalElf());

                ElfSigner.SignFileInPlace(path).Should().Be(ElfSigner.SignOutcome.Signed);
                ElfSigner.SignFileInPlace(path).Should().Be(ElfSigner.SignOutcome.AlreadyValid);
                ElfSigner.SignFileInPlace(path, force: true).Should().Be(ElfSigner.SignOutcome.Signed);
            }
            finally
            {
                File.Delete(path);
            }
        }

        [TestMethod]
        public void StripCodesign_RemovesTheSectionAndAllowsResigning()
        {
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);

            byte[] stripped = ElfSigner.StripCodesign(signed, out bool removed);

            removed.Should().BeTrue();
            FindSection(stripped, ".codesign").Should().BeNull();
            ElfSigner.IsElf64(stripped).Should().BeTrue();

            byte[] resigned = ElfSigner.SignElf(stripped, force: false);
            FindSection(resigned, ".codesign").Should().NotBeNull();
        }

        [TestMethod]
        public void IsElf64_RejectsBigEndianBinaries()
        {
            byte[] elf = CreateMinimalElf();
            elf[5] = 2; // ELFDATA2MSB

            ElfSigner.IsElf64(elf).Should().BeFalse();
        }

        /// <summary>
        /// Builds the smallest ELF64 the signer accepts: a header, a .shstrtab and its own
        /// section header table, with optional trailing data (e.g. a SingleFile bundle).
        /// </summary>
        private static byte[] CreateMinimalElf(byte[]? trailer = null)
        {
            byte[] shstrtab = Encoding.ASCII.GetBytes("\0.shstrtab\0");
            int shstrtabOffset = 64;
            int sectionHeaderTableOffset = Align(shstrtabOffset + shstrtab.Length, 8);
            int bodyLength = sectionHeaderTableOffset + 2 * 64;
            byte[] elf = new byte[bodyLength + (trailer?.Length ?? 0)];

            elf[0] = 0x7f;
            elf[1] = (byte)'E';
            elf[2] = (byte)'L';
            elf[3] = (byte)'F';
            elf[4] = 2; // ELFCLASS64
            elf[5] = 1; // ELFDATA2LSB
            elf[6] = 1; // EV_CURRENT
            WriteU16(elf, 0x10, 3); // e_type = ET_DYN
            WriteU16(elf, 0x12, 183); // e_machine = EM_AARCH64
            WriteU32(elf, 0x14, 1); // e_version
            WriteU64(elf, 0x28, (ulong)sectionHeaderTableOffset); // e_shoff
            WriteU16(elf, 0x3a, 64); // e_shentsize
            WriteU16(elf, 0x3c, 2); // e_shnum
            WriteU16(elf, 0x3e, 1); // e_shstrndx

            Buffer.BlockCopy(shstrtab, 0, elf, shstrtabOffset, shstrtab.Length);

            int shstrtabEntry = sectionHeaderTableOffset + 64;
            WriteU32(elf, shstrtabEntry, 1); // sh_name
            WriteU32(elf, shstrtabEntry + 4, 3); // sh_type = SHT_STRTAB
            WriteU64(elf, shstrtabEntry + 24, (ulong)shstrtabOffset); // sh_offset
            WriteU64(elf, shstrtabEntry + 32, (ulong)shstrtab.Length); // sh_size
            WriteU64(elf, shstrtabEntry + 48, 1); // sh_addralign

            if (trailer != null)
            {
                Buffer.BlockCopy(trailer, 0, elf, bodyLength, trailer.Length);
            }

            return elf;
        }

        private static (int offset, int size)? FindSection(byte[] elf, string name)
        {
            ulong sectionHeaderTableOffset = ReadU64(elf, 0x28);
            ushort sectionCount = ReadU16(elf, 0x3c);
            ushort shstrndx = ReadU16(elf, 0x3e);
            int shstrtabEntry = (int)(sectionHeaderTableOffset + (ulong)shstrndx * 64);
            ulong shstrtabOffset = ReadU64(elf, shstrtabEntry + 24);
            ulong shstrtabSize = ReadU64(elf, shstrtabEntry + 32);
            byte[] shstrtab = elf.AsSpan((int)shstrtabOffset, (int)shstrtabSize).ToArray();

            for (int i = 0; i < sectionCount; i++)
            {
                int entry = (int)sectionHeaderTableOffset + i * 64;
                int nameOffset = (int)ReadU32(elf, entry);
                if (nameOffset >= 0 && nameOffset < shstrtab.Length)
                {
                    int terminator = Array.IndexOf(shstrtab, (byte)0, nameOffset);
                    int length = (terminator < 0 ? shstrtab.Length : terminator) - nameOffset;
                    if (Encoding.ASCII.GetString(shstrtab, nameOffset, length) == name)
                    {
                        return ((int)ReadU64(elf, entry + 24), (int)ReadU64(elf, entry + 32));
                    }
                }
            }

            return null;
        }

        private static int Align(int value, int alignment) => (value + alignment - 1) / alignment * alignment;

        private static ushort ReadU16(byte[] b, int offset) => (ushort)(b[offset] | (b[offset + 1] << 8));

        private static uint ReadU32(byte[] b, int offset) =>
            (uint)(b[offset] | (b[offset + 1] << 8) | (b[offset + 2] << 16) | (b[offset + 3] << 24));

        private static ulong ReadU64(byte[] b, int offset) =>
            (ulong)b[offset] | ((ulong)b[offset + 1] << 8) | ((ulong)b[offset + 2] << 16) | ((ulong)b[offset + 3] << 24) |
            ((ulong)b[offset + 4] << 32) | ((ulong)b[offset + 5] << 40) | ((ulong)b[offset + 6] << 48) | ((ulong)b[offset + 7] << 56);

        private static void WriteU16(byte[] b, int offset, ushort value)
        {
            b[offset] = (byte)value;
            b[offset + 1] = (byte)(value >> 8);
        }

        private static void WriteU32(byte[] b, int offset, uint value)
        {
            b[offset] = (byte)value;
            b[offset + 1] = (byte)(value >> 8);
            b[offset + 2] = (byte)(value >> 16);
            b[offset + 3] = (byte)(value >> 24);
        }

        private static void WriteU64(byte[] b, int offset, ulong value)
        {
            for (int i = 0; i < 8; i++)
            {
                b[offset + i] = (byte)(value >> (8 * i));
            }
        }
    }
}
