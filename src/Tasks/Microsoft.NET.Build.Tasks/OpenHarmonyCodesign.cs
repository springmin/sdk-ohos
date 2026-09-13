// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.IO;
using Microsoft.Build.Framework;

namespace Microsoft.NET.Build.Tasks
{
    /// <summary>
    /// Applies an OpenHarmony self-signature (.codesign section) to ELF64 binaries in place under
    /// the target/publish directories. OpenHarmony only executes ELF files that carry a valid
    /// .codesign section; a file that was modified after signing (e.g. the apphost, which the SDK
    /// rewrites on every build) fails with EPERM. Files whose existing signature is still valid are
    /// skipped without being rewritten. The signing algorithm lives in the shared source
    /// src/Tasks/Microsoft.NET.Build.Tasks/OpenHarmony/ElfSigner.cs, shared with the standalone selfsign tool.
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
                        Log.LogError("OpenHarmonyCodesign: failed to sign {0}: {1}", path, ex.Message);
                    }
                }
            }
        }
    }
}
