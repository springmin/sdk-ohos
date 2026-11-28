#!/bin/sh
# Setup/check the local device path for the clean-machine gate.
# Run on the OpenHarmony self-hosted runner host.
set -eu
HDC="${OHOS_HDCP4:-/storage/Users/currentUser/.ohos-tools/hdcp4}"
PORT="$(param get persist.hdc.port 2>/dev/null | tr -d ' \r\n')"
[ -n "$PORT" ] || { echo "ERROR: persist.hdc.port is empty; enable wireless debugging" >&2; exit 1; }
TARGET="127.0.0.1:${PORT}"
[ -x "$HDC" ] || { echo "ERROR: hdcp4 not found/executable: $HDC" >&2; exit 1; }
"$HDC" tconn "$TARGET" >/dev/null 2>&1 || true
"$HDC" -t "$TARGET" shell echo hdc-ok
UDID="$("$HDC" -t "$TARGET" shell bm get --udid | tail -1 | tr -d '\r')"
[ -n "$UDID" ] || { echo "ERROR: could not read UDID" >&2; exit 1; }
echo "target: $TARGET"
echo "udid:   $UDID"
echo "workflow HDC: $PWD/eng/ohos-install/hdc-wireless.sh"
echo "set the repo secret with:"
echo "  gh secret set OHOS_UDID --body '$UDID' -R springmin/sdk-ohos"
