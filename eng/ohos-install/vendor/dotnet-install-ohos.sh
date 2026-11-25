#!/bin/sh
# Copyright (c) .NET Foundation and contributors. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# HarmonyOS/OpenHarmony entry point for dotnet-install.sh.
#
# HarmonyOS ships mksh as /bin/sh and does not put bash on PATH, while
# dotnet-install.sh requires bash. This wrapper locates a bash (for example the
# one shipped by harmonybrew), prepares a writable TMPDIR for the application
# sandbox, and then delegates to dotnet-install.sh.
#
# Usage: sh dotnet-install-ohos.sh [dotnet-install.sh options]
#   sh dotnet-install-ohos.sh --version 11.0.100 --feed https://example/feed
#   sh dotnet-install-ohos.sh --url https://example/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz \
#       --sha256 <hex> --version 11.0.100
#
# The script is idempotent and safe to re-run.

set -u

script_dir=$(cd "$(dirname "$0")" && pwd)

# /tmp is read-only inside the HarmonyOS application sandbox.
if [ -z "${TMPDIR:-}" ] || [ ! -w "${TMPDIR:-}" ]; then
    TMPDIR="${HOME}/.tmp"
    mkdir -p "$TMPDIR" 2>/dev/null || true
    export TMPDIR
fi

# GitHub release assets can stall on some HarmonyOS networks. Default to the same
# gh-proxy fallback used by the OHOS SDK installer; set DOTNET_INSTALL_GITHUB_PROXY=""
# to disable it.
DOTNET_INSTALL_GITHUB_PROXY="${DOTNET_INSTALL_GITHUB_PROXY-https://gh-proxy.com}"
export DOTNET_INSTALL_GITHUB_PROXY

if [ -z "${BASH_VERSION:-}" ]; then
    for candidate in \
        "${DOTNET_INSTALL_BASH:-}" \
        "$(command -v bash 2>/dev/null || true)" \
        "${HOME}/.harmonybrew/bin/bash" \
        /usr/bin/bash \
        /bin/bash; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            exec "$candidate" "$script_dir/dotnet-install.sh" "$@"
        fi
    done

    printf 'ERROR: bash is required by dotnet-install.sh but was not found.\n' >&2
    printf '       Install bash (for example with harmonybrew) or set DOTNET_INSTALL_BASH.\n' >&2
    exit 1
fi

exec bash "$script_dir/dotnet-install.sh" "$@"
