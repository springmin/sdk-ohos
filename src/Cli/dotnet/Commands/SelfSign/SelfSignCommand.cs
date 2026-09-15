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
/// </summary>
internal static class SelfSignCommand
{
    public static int Run(ParseResult parseResult)
    {
        var definition = (SelfSignCommandDefinition)parseResult.CommandResult.Command;
        string[] paths = parseResult.GetValue(definition.PathsArgument) ?? Array.Empty<string>();
        bool force = parseResult.GetValue(definition.ForceOption);
        bool strip = parseResult.GetValue(definition.StripOption);

        int signed = 0, stripped = 0, skipped = 0, notElf = 0, failed = 0;

        foreach (string path in paths)
        {
            if (Directory.Exists(path))
            {
                try
                {
                    foreach (string file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
                    {
                        Process(file);
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
                Process(path);
            }
        }

        Console.WriteLine($"selfsign: signed={signed} stripped={stripped} skipped={skipped} not-elf={notElf} failed={failed}");
        return failed == 0 ? 0 : 1;

        void Process(string file)
        {
            try
            {
                byte[] raw = File.ReadAllBytes(file);
                if (!ElfSigner.IsElf64(raw))
                {
                    notElf++;
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
