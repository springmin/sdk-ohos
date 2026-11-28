# OpenHarmony device runner setup

The clean-machine gate needs an authorized hdc connection on the self-hosted
runner. On the MateBook the local wireless debugging port changes when the
toggle is restarted, and a fresh `hdc` server key is not trusted; use the
already-authorized `hdcp4` server instead.

## Prerequisites

- Developer options: **USB debugging** on (`persist.sys.usb.config=hdc_debug`).
- **Wireless debugging** on; get the current port with:
  ```sh
  param get persist.hdc.port
  ```
- `hdcp4` at `/storage/Users/currentUser/.ohos-tools/hdcp4` (or set
  `OHOS_HDCP4`).

## Setup

```sh
cd <sdk-ohos checkout>
sh eng/ohos-install/setup-device-runner.sh
```

The script connects to `127.0.0.1:<port>`, runs `shell echo hdc-ok`, reads the
UDID, and prints the `gh secret set OHOS_UDID` command.

The workflow uses `eng/ohos-install/hdc-wireless.sh` as `HDC`; the helper
reads the port dynamically and keeps the existing hdcp4 server/key. Do not start
a new hdc server or kill the authorized one.

## If the connection is lost

1. Keep USB debugging on.
2. Toggle wireless debugging off/on.
3. Run the setup script again.
4. If the device shows a new authorization dialog, approve it.
5. Do not delete `~/.harmony/hdckey*`; the old encrypted key cannot be
   recovered without the HUKS credential service.
