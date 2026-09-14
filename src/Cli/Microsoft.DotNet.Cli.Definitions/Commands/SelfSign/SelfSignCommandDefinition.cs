// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.CommandLine;

namespace Microsoft.DotNet.Cli.Commands.SelfSign;

/// <summary>
/// OpenHarmony ELF self-signing command. Hidden by default: devices that enforce the
/// .codesign section need it, but it is a platform-specific surface that stays out of
/// the general help until the platform support lands upstream.
/// </summary>
internal sealed class SelfSignCommandDefinition : Command
{
    public readonly Argument<string[]> PathsArgument = new("path")
    {
        Description = "ELF file or directory to sign (directories are walked recursively).",
        Arity = ArgumentArity.OneOrMore
    };

    public readonly Option<bool> ForceOption = new("--force", "-f")
    {
        Description = "Re-sign even when the file already carries a valid .codesign section."
    };

    public readonly Option<bool> StripOption = new("--strip")
    {
        Description = "Remove the .codesign section instead of signing."
    };

    public SelfSignCommandDefinition()
        : base("selfsign")
    {
        Hidden = true;

        Arguments.Add(PathsArgument);
        Options.Add(ForceOption);
        Options.Add(StripOption);
    }
}
