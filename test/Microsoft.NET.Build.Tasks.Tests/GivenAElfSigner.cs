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

            // The OpenHarmony kernel requires the rootHash padding, salt, reserved1 and reserved2
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
            string path = TempPath();
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

        // ---------------------------------------------------------------------------------
        // Regression coverage for the data-loss, symlink, foreign-signature and idempotence
        // defects (D-1/D-2/D-3/D-5/C1/C2).
        // ---------------------------------------------------------------------------------

        [TestMethod]
        public void SignFileInPlace_PreservesDataAppendedAfterTheSignatureBlock()
        {
            // The shape PublishSingleFile produces: an apphost/singlefilehost that already has a
            // .codesign section with the bundle appended after it. Re-signing must cover the
            // bundle, not truncate the file at the signature block (D-1).
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);
            byte[] bundle = Enumerable.Range(0, 256 * 1024).Select(i => (byte)((i * 31) & 0xff)).ToArray();
            byte[] withBundle = signed.Concat(bundle).ToArray();

            string path = TempPath();
            try
            {
                File.WriteAllBytes(path, withBundle);

                ElfSigner.SignFileInPlace(path).Should().Be(ElfSigner.SignOutcome.Signed);
                byte[] result = File.ReadAllBytes(path);

                result.Length.Should().Be(withBundle.Length);
                result.AsSpan(signed.Length, bundle.Length).ToArray().Should().Equal(bundle);
                (int csOffset, _) = FindSection(result, ".codesign")!.Value;
                ReadU64(result, csOffset + 8 + 8).Should().Be((ulong)result.Length);

                // The signature now covers the bundle, so the file is validly signed as-is.
                ElfSigner.SignFileInPlace(path).Should().Be(ElfSigner.SignOutcome.AlreadyValid);
            }
            finally
            {
                File.Delete(path);
            }
        }

        [TestMethod]
        public void SignFileInPlace_ReSignsInPlaceAndLeavesEveryByteOutsideTheBlockAlone()
        {
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);
            byte[] trailer = Enumerable.Range(0, 9000).Select(i => (byte)(i & 0x7f)).ToArray();
            byte[] input = signed.Concat(trailer).ToArray();
            (int csOffset, int csSize) = FindSection(input, ".codesign")!.Value;

            string path = TempPath();
            try
            {
                File.WriteAllBytes(path, input);

                ElfSigner.SignFileInPlace(path, force: true).Should().Be(ElfSigner.SignOutcome.Signed);
                byte[] result = File.ReadAllBytes(path);

                result.Length.Should().Be(input.Length);
                for (int i = 0; i < input.Length; i++)
                {
                    if (i >= csOffset && i < csOffset + csSize)
                    {
                        continue;
                    }

                    result[i].Should().Be(input[i], $"byte {i} is data, not signature");
                }
            }
            finally
            {
                File.Delete(path);
            }
        }

        [TestMethod]
        public void SignFileInPlace_ForceIsIdempotentAndDoesNotGrowTheFile()
        {
            // sign_all in the installer always uses --force; re-signing an already signed file
            // must rewrite the existing block instead of appending a fresh page every round (D-5).
            string path = TempPath();
            try
            {
                File.WriteAllBytes(path, CreateMinimalElf());
                ElfSigner.SignFileInPlace(path).Should().Be(ElfSigner.SignOutcome.Signed);

                long size = new FileInfo(path).Length;
                byte[] bytes = File.ReadAllBytes(path);
                for (int i = 0; i < 3; i++)
                {
                    ElfSigner.SignFileInPlace(path, force: true).Should().Be(ElfSigner.SignOutcome.Signed);
                    new FileInfo(path).Length.Should().Be(size, "force re-signs must not grow the file");
                }

                File.ReadAllBytes(path).Should().Equal(bytes);
            }
            finally
            {
                File.Delete(path);
            }
        }

        [TestMethod]
        public void StripCodesign_KeepsDataAppendedAfterTheSignatureBlock()
        {
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);
            byte[] bundle = Enumerable.Range(0, PageSize).Select(i => (byte)(i ^ 0x5a)).ToArray();
            byte[] withBundle = signed.Concat(bundle).ToArray();

            byte[] stripped = ElfSigner.StripCodesign(withBundle, out bool removed);

            removed.Should().BeTrue();
            FindSection(stripped, ".codesign").Should().BeNull();
            ElfSigner.IsElf64(stripped).Should().BeTrue();
            stripped.AsSpan(signed.Length, bundle.Length).ToArray().Should().Equal(bundle);

            byte[] resigned = ElfSigner.SignElf(stripped, force: false);
            FindSection(resigned, ".codesign").Should().NotBeNull();
        }

        [TestMethod]
        public void SignFileInPlace_RejectsACodesignSectionThatOverlapsAnotherSection()
        {
            // A .codesign entry retargeted into real section data must be refused instead of
            // silently rewriting (and thereby destroying) the body (D-2).
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);
            byte[] malformed = (byte[])signed.Clone();
            (int shstrtabOffset, int shstrtabSize) = FindSection(malformed, ".shstrtab")!.Value;
            int csEntry = FindSectionEntry(malformed, ".codesign");
            WriteU64(malformed, csEntry + 24, (ulong)shstrtabOffset);
            WriteU64(malformed, csEntry + 32, (ulong)shstrtabSize);

            string path = TempPath();
            try
            {
                File.WriteAllBytes(path, malformed);

                Action sign = () => ElfSigner.SignFileInPlace(path);
                sign.Should().Throw<InvalidDataException>();
                File.ReadAllBytes(path).Should().Equal(malformed);
            }
            finally
            {
                File.Delete(path);
            }
        }

        [TestMethod]
        public void SignElf_RejectsDuplicateCodesignSections()
        {
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);
            byte[] malformed = (byte[])signed.Clone();
            int csEntry = FindSectionEntry(malformed, ".codesign");
            int shstrtabEntry = FindSectionEntry(malformed, ".shstrtab");
            WriteU32(malformed, shstrtabEntry, ReadU32(malformed, csEntry));

            Action sign = () => ElfSigner.SignElf(malformed, force: true);
            sign.Should().Throw<InvalidDataException>();
        }

        [TestMethod]
        public void SignFileInPlace_RejectsASelfReferencingCodesignNameTable()
        {
            // e_shstrndx pointing at the section named .codesign used to crash with an
            // IndexOutOfRangeException while rebuilding the section header table (D-6); it must
            // now be a readable, fail-closed error.
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);
            byte[] malformed = (byte[])signed.Clone();
            int csEntry = FindSectionEntry(malformed, ".codesign");
            int csIndex = (int)(((ulong)csEntry - ReadU64(malformed, 0x28)) / 64);
            byte[] name = Encoding.ASCII.GetBytes(".codesign\0");
            const int plantedOffset = 64;
            Buffer.BlockCopy(name, 0, malformed, (int)ReadU64(malformed, csEntry + 24) + plantedOffset, name.Length);
            WriteU32(malformed, csEntry, plantedOffset);
            WriteU16(malformed, 0x3e, (ushort)csIndex);

            string path = TempPath();
            try
            {
                File.WriteAllBytes(path, malformed);

                Action sign = () => ElfSigner.SignFileInPlace(path, force: true);
                sign.Should().Throw<InvalidDataException>();
                File.ReadAllBytes(path).Should().Equal(malformed);
            }
            finally
            {
                File.Delete(path);
            }
        }

        [TestMethod]
        public void SignFileInPlace_RetainsForeignSignaturesWithoutForce()
        {
            // Replacing a .codesign section this signer did not create requires the explicit
            // force opt-in; it must never happen silently during a build (C2).
            byte[] signed = ElfSigner.SignElf(CreateMinimalElf(), force: false);
            byte[] foreign = (byte[])signed.Clone();
            (int csOffset, _) = FindSection(foreign, ".codesign")!.Value;
            Array.Clear(foreign, csOffset + 8 + 112, 4); // clear FLAG_SELF_SIGN

            string path = TempPath();
            try
            {
                File.WriteAllBytes(path, foreign);

                ElfSigner.SignFileInPlace(path).Should().Be(ElfSigner.SignOutcome.ForeignSignatureRetained);
                File.ReadAllBytes(path).Should().Equal(foreign);

                ElfSigner.SignFileInPlace(path, force: true).Should().Be(ElfSigner.SignOutcome.Signed);
                ElfSigner.SignFileInPlace(path).Should().Be(ElfSigner.SignOutcome.AlreadyValid);
            }
            finally
            {
                File.Delete(path);
            }
        }

        [TestMethod]
        [OSCondition(OperatingSystems.Linux | OperatingSystems.OSX)]
        public void EnumerateFilesWithoutLinks_SkipsFileDirectoryAndCyclicLinks()
        {
            // A link placed in the signed tree must never make the signer rewrite the linked
            // target (D-3/C1); a link cycle must not recurse.
            string root = Path.Combine(Path.GetTempPath(), $"openharmony-sign-links-{Guid.NewGuid():N}");
            Directory.CreateDirectory(root);
            string outside = Path.Combine(root, "outside");
            Directory.CreateDirectory(outside);
            File.WriteAllBytes(Path.Combine(outside, "victim.so"), CreateMinimalElf());
            string stage = Path.Combine(root, "stage");
            Directory.CreateDirectory(stage);
            File.WriteAllBytes(Path.Combine(stage, "real.so"), CreateMinimalElf());
            File.CreateSymbolicLink(Path.Combine(stage, "filelink.so"), Path.Combine(outside, "victim.so"));
            Directory.CreateSymbolicLink(Path.Combine(stage, "dirlink"), outside);
            File.CreateSymbolicLink(Path.Combine(stage, "cycle"), stage);

            try
            {
                byte[] victim = File.ReadAllBytes(Path.Combine(outside, "victim.so"));
                var warnings = new List<string>();

                List<string> files = ElfSigner.EnumerateFilesWithoutLinks(stage, warnings.Add).ToList();

                files.Should().HaveCount(1);
                Path.GetFileName(files[0]).Should().Be("real.so");
                warnings.Should().HaveCount(3);

                foreach (string file in files)
                {
                    ElfSigner.SignFileInPlace(file);
                }

                File.ReadAllBytes(Path.Combine(outside, "victim.so")).Should().Equal(victim);
                ElfSigner.IsSymbolicLink(Path.Combine(stage, "dirlink")).Should().BeTrue();
            }
            finally
            {
                Directory.Delete(root, recursive: true);
            }
        }

        private static string TempPath() => Path.Combine(Path.GetTempPath(), $"openharmony-sign-{Guid.NewGuid():N}");

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

        /// <summary>Offset of a named section header entry inside the section header table.</summary>
        private static int FindSectionEntry(byte[] elf, string name)
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
                        return entry;
                    }
                }
            }

            throw new InvalidOperationException($"section {name} not found");
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
