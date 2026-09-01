// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Runtime.InteropServices;

namespace Microsoft.DotNet.Cli;

/// <summary>
/// OpenHarmony sandbox defaults for processes spawned by the CLI. The sandbox blocks JIT W^X
/// mprotect, ships no ICU, and mounts /tmp read-only; the wrapper script previously exported
/// these before launching dotnet. Baked runtimeconfig options cover the SDK's own processes,
/// and these environment defaults cover every child process (MSBuild, csc, apphosts) that
/// inherits the CLI's environment. Only active when running on a ohos RID.
/// </summary>
internal static class OpenHarmonyEnvironmentDefaults
{
    public static void Apply()
    {
        if (!RuntimeInformation.RuntimeIdentifier.StartsWith("ohos", StringComparison.Ordinal))
        {
            return;
        }

        SetDefault("TMPDIR", "/data/storage/el2/base/tmp");
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
