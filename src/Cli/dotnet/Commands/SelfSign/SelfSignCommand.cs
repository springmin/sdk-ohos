// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.CommandLine;
using System.IO;
using Microsoft.NET.Build.Tasks;

namespace Microsoft.DotNet.Cli.Commands.SelfSign;

/// <summary>
/// Signs (or strips signatures from) OpenHarmony ELF binaries in place. The algorithm is
/// shared with the SDK's OpenHarmonyCodesign MSBuild task and the standalone selfsign tool
/// (src/Tasks/Microsoft.NET.Build.Tasks/ElfSigner.cs); files whose existing
/// .codesign section is still valid are skipped unless --force is used.
///
/// Directories are walked without following symbolic links (file or directory links), so a
/// link placed in the tree can never make the command rewrite a file outside it. An explicit
/// path that is not an ELF64 file is reported as a failure instead of being silently counted.
/// </summary>
internal static class SelfSignCommand
{
    public static int Run(ParseResult parseResult)
    {
        var definition = (SelfSignCommandDefinition)parseResult.CommandResult.Command;
        string[] paths = parseResult.GetValue(definition.PathsArgument) ?? Array.Empty<string>();
        bool force = parseResult.GetValue(definition.ForceOption);
        bool strip = parseResult.GetValue(definition.StripOption);

        int signed = 0, stripped = 0, skipped = 0, retained = 0, notElf = 0, failed = 0;

        foreach (string path in paths)
        {
            if (Directory.Exists(path))
            {
                if (ElfSigner.IsSymbolicLink(path))
                {
                    skipped++;
                    Console.Error.WriteLine($"selfsign skipped (symbolic link): {path}");
                    continue;
                }

                try
                {
                    foreach (string file in ElfSigner.EnumerateFilesWithoutLinks(path, WarnLink))
                    {
                        Process(file, explicitFile: false);
                    }
                }
                catch (Exception e)
                {
                    failed++;
                    Console.Error.WriteLine($"selfsign failed: {path}: {e.Message}");
                }
            }
            else
            {
                if (ElfSigner.IsSymbolicLink(path))
                {
                    skipped++;
                    Console.Error.WriteLine($"selfsign skipped (symbolic link): {path}");
                    continue;
                }

                Process(path, explicitFile: true);
            }
        }

        Console.WriteLine($"selfsign: signed={signed} stripped={stripped} skipped={skipped} retained={retained} not-elf={notElf} failed={failed}");
        return failed == 0 ? 0 : 1;

        void WarnLink(string link)
        {
            skipped++;
            Console.Error.WriteLine($"selfsign skipped (symbolic link): {link}");
        }

        void Process(string file, bool explicitFile)
        {
            try
            {
                byte[] raw = File.ReadAllBytes(file);
                if (!ElfSigner.IsElf64(raw))
                {
                    if (explicitFile)
                    {
                        // A named file that is not a signable ELF64 is a caller error: an exit
                        // code of 0 would let a signing gate accept an unsigned/invalid artifact.
                        failed++;
                        Console.Error.WriteLine($"selfsign failed: {file}: not an ELF64 file");
                    }
                    else
                    {
                        notElf++;
                    }

                    return;
                }

                if (strip)
                {
                    byte[] without = ElfSigner.StripCodesign(raw, out bool removed);
                    if (!removed)
                    {
                        skipped++;
                        return;
                    }

                    File.WriteAllBytes(file, without);
                    stripped++;
                    Console.WriteLine($"stripped: {file}");
                    return;
                }

                switch (ElfSigner.SignFileInPlace(file, force))
                {
                    case ElfSigner.SignOutcome.Signed:
                        signed++;
                        Console.WriteLine($"selfsign ok: {file}");
                        break;
                    case ElfSigner.SignOutcome.AlreadyValid:
                        skipped++;
                        Console.WriteLine($"selfsign skipped (signature already valid): {file}");
                        break;
                    case ElfSigner.SignOutcome.ForeignSignatureRetained:
                        retained++;
                        Console.Error.WriteLine($"selfsign skipped (foreign .codesign retained, use --force to replace): {file}");
                        break;
                    default:
                        notElf++;
                        break;
                }
            }
            catch (Exception e)
            {
                failed++;
                Console.Error.WriteLine($"selfsign failed: {file}: {e.Message}");
            }
        }
    }
}
