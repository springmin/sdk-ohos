// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// Standalone OpenHarmony ELF signer. The signing algorithm is shared with the SDK's
// OpenHarmonyCodesign MSBuild task; both compile src/Tasks/Microsoft.NET.Build.Tasks/OpenHarmony/ElfSigner.cs.
using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.NET.Build.Tasks;

internal static class Program
{
    private static int Main(string[] args)
    {
        bool force = false;
        bool stripOnly = false;
        var positional = new List<string>();
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
                byte[] stripped = ElfSigner.StripCodesign(raw, out bool removed);
                if (!removed)
                {
                    Console.WriteLine($"no .codesign section to strip: {inPath}");
                    return 0;
                }

                File.WriteAllBytes(outPath, stripped);
                Console.WriteLine($"strip ok: {inPath} -> {outPath} ({stripped.Length} bytes)");
                return 0;
            }

            if (inPath == outPath)
            {
                switch (ElfSigner.SignFileInPlace(inPath, force))
                {
                    case ElfSigner.SignOutcome.Signed:
                        Console.WriteLine($"selfsign ok: {inPath} (in-place{(force ? ", forced" : string.Empty)})");
                        break;
                    case ElfSigner.SignOutcome.AlreadyValid:
                        Console.WriteLine($"selfsign skipped (signature already valid): {inPath}");
                        break;
                    default:
                        Console.WriteLine($"not an ELF64: {inPath}");
                        break;
                }

                return 0;
            }

            byte[] data = File.ReadAllBytes(inPath);
            byte[] signed = ElfSigner.SignElf(data, force);
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
