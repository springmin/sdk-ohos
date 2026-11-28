#!/bin/sh
# Stable hdc wrapper for the local OpenHarmony self-hosted runner.
# The MateBook exposes wireless debugging on a per-session port; hdcp4 is
# already authorized (unlike a fresh hdc server key), so prefer it.
set -eu
HDC="${OHOS_HDCP4:-/storage/Users/currentUser/.ohos-tools/hdcp4}"
PORT="$(param get persist.hdc.port 2>/dev/null | tr -d ' \r\n')"
[ -n "$PORT" ] || PORT="${OHOS_HDC_PORT:-44165}"
TARGET="127.0.0.1:${PORT}"
export HOME="${OHOS_HDC_HOME:-/storage/Users/currentUser}"
if ! timeout 5 "$HDC" list targets 2>/dev/null | grep -q "$TARGET"; then
    timeout 10 "$HDC" tconn "$TARGET" >/dev/null 2>&1 || true
fi
exec timeout 600 "$HDC" -t "$TARGET" "$@"
