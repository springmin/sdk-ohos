# vendored dotnet-install

Copy of the HarmonyOS/OpenHarmony support added in
`springmin/install-scripts-ohos` (branch `feature/openharmony`), so the
sdk-ohos installer flow is self-contained and does not depend on a sibling
checkout or a network fetch at install time.

| File | Source |
|---|---|
| `dotnet-install.sh` | `springmin/install-scripts-ohos` `src/dotnet-install.sh` @ `f826a78` |
| `dotnet-install-ohos.sh` | `springmin/install-scripts-ohos` `src/dotnet-install-ohos.sh` @ `f826a78` |

Both files keep their MIT headers. `dotnet-install.sh` is a fork of
`dotnet/install-scripts`; the detection-only subset is proposed upstream as
[dotnet/install-scripts#752](https://github.com/dotnet/install-scripts/pull/752).

## Refresh

```sh
# from a install-scripts-ohos checkout
cp src/dotnet-install.sh       <sdk-ohos>/eng/ohos-install/vendor/dotnet-install.sh
cp src/dotnet-install-ohos.sh  <sdk-ohos>/eng/ohos-install/vendor/dotnet-install-ohos.sh
chmod +x <sdk-ohos>/eng/ohos-install/vendor/*.sh
```

Record the source commit in this file when refreshing.
