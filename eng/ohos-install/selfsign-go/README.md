# Device-side selfsign (`selfsign-ohos-arm64`)

`selfsign-ohos-arm64` is the signer the OpenHarmony installer deploys next to
`dotnet` (`versions.env`: `SELFSIGN_ASSET`). It must be an arm64 OpenHarmony ELF
that already carries a `.codesign` section; the installer refuses to execute an
unsigned signer unless it can bootstrap it with `binary-sign-tool`.

The checked-in binary is built from `selfsign.go` (stdlib-only) and is published
with every SDK release by `.github/workflows/ohos-full-build.yml`. The installer
verifies it against `SELFSIGN_SHA256` before use.

## Provenance

- Upstream: <https://github.com/hqzing/ohos-selfsign>
- License: 0BSD (see the header in `selfsign.go`)
- Implementation: Go, single file, no third-party modules
- The signed binary is checked in so released assets do not depend on a Go
  toolchain or on the NativeAOT cross-build (which is not device-runnable yet).

## Rebuild and re-sign

Requirements: Go (linux/arm64 host or cross-compile), and a working signer
(the checked-in `selfsign-ohos-arm64`, the linux-x64 `selfsign` built by
`build/ohos-sign-common.sh`, or `binary-sign-tool`).

```sh
cd eng/ohos-install/selfsign-go
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
  -trimpath -buildvcs=false -ldflags='-s -w' \
  -o /tmp/selfsign-ohos-arm64 selfsign.go

# Sign the new binary (in place). Use any signer that runs on the host:
/tmp/selfsign-ohos-arm64 --help >/dev/null 2>&1 || true   # unsigned: will not exec yet
../selfsign-ohos-arm64 /tmp/selfsign-ohos-arm64          # if the checked-in signer runs on this host
# or: binary-sign-tool sign -inFile /tmp/selfsign-ohos-arm64 \
#       -outFile /tmp/selfsign-ohos-arm64 -selfSign 1

cp /tmp/selfsign-ohos-arm64 ../selfsign-ohos-arm64
sha256sum ../selfsign-ohos-arm64
```

Then update `SELFSIGN_SHA256` in `eng/ohos-install/versions.env` to the new
digest. The release workflow fails closed when the checked-in asset and the pin
disagree.

## Release integration

`ohos-full-build.yml` copies this file into
`sdk/artifacts/packages/Release/Shipping/selfsign-ohos-arm64` before generating
`SHA256SUMS`, so `v<SDK_VERSION>-ohos` always carries the asset.
