// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.IO;
using Microsoft.Build.Framework;

namespace Microsoft.NET.Build.Tasks
{
    /// <summary>
    /// Applies an OpenHarmony self-signature (.codesign section) to ELF64 binaries under the
    /// target/publish directories. OpenHarmony only executes signed ELF files, and a signed file
    /// whose content changed (e.g. the apphost, rewritten on every build) fails with EPERM; files
    /// with a still-valid signature are skipped.
    /// </summary>
    public sealed class OpenHarmonyCodesign : TaskBase
    {
        [Required]
        public string[] Directories { get; set; }

        protected override void ExecuteCore()
        {
            foreach (string directory in Directories)
            {
                if (!Directory.Exists(directory))
                {
                    continue;
                }

                try
                {
                    foreach (string path in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
                    {
                        try
                        {
                            if (ElfSigner.SignFileInPlace(path) == ElfSigner.SignOutcome.Signed)
                            {
                                Log.LogMessage(MessageImportance.Low, "OpenHarmonyCodesign: signed {0}", path);
                            }
                        }
                        catch (Exception ex)
                        {
                            Log.LogError(Strings.OpenHarmonyCodesignFailedToSign, path, ex.Message);
                        }
                    }
                }
                catch (Exception ex)
                {
                    Log.LogError(Strings.OpenHarmonyCodesignFailedToEnumerate, directory, ex.Message);
                }
            }
        }
    }
}
