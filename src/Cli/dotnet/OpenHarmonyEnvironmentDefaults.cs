// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace Microsoft.DotNet.Cli;

/// <summary>
/// OpenHarmony sandbox defaults for processes spawned by the CLI. The sandbox blocks JIT W^X
/// mprotect and ships no ICU; baked runtimeconfig options cover the SDK's own processes,
/// and these environment defaults cover every child process (MSBuild, csc, apphosts) that
/// inherits the CLI's environment. Only active on OpenHarmony. TMPDIR is deliberately not
/// set here: the runtime reads it through Path.GetTempPath(), and the sandbox host (the
/// install script persists it into the shell profiles) points it at a writable directory —
/// the same contract as on other Unix platforms.
/// </summary>
internal static class OpenHarmonyEnvironmentDefaults
{
    public static void Apply()
    {
        if (!OperatingSystem.IsOSPlatform("openharmony"))
        {
            return;
        }

        // TMPDIR is intentionally not set: Path.GetTempPath() honors the host-provided
        // TMPDIR (falling back to /tmp), matching the runtime contract; the install script
        // persists a writable value for the on-device shells.
        SetDefault("DOTNET_EnableWriteXorExecute", "0");
        SetDefault("DOTNET_SYSTEM_GLOBALIZATION_INVARIANT", "1");
        SetDefault(EnvironmentVariableNames.TELEMETRY_OPTOUT, "1");
        SetDefault(EnvironmentVariableNames.DOTNET_NOLOGO, "1");
    }

    private static void SetDefault(string name, string value)
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable(name)))
        {
            Environment.SetEnvironmentVariable(name, value);
        }
    }
}
