# NativeAOT on OpenHarmony（实验）

> 状态：**实验可用（2026-09-24 在 HarmonyOS 设备上端到端验证）**。
> 本文覆盖：前置条件、命令、SDK 内部的 RID → pack 解析映射、离线 pack 获取、
> 已复现的验证结果与已知限制。

NativeAOT 把托管程序编译成单个原生 ELF（`ilc` 编译 + 原生链接），发布产物
在设备上直接 `execve`，不经过 CoreCLR/JIT —— 因此绕开了 HarmonyOS 对匿名
可执行内存（JIT）的限制。发布输出仍由 SDK 自动签名（`OpenHarmonyCodesign`）。

---

## 1. 前置条件

| 项 | 要求 |
|---|---|
| SDK | `sdk-ohos` 构建的 SDK，`11.0.100-rc.1.26451.109` 及之后（RID 图 + ILCompiler/NativeAOT RID 列表已内嵌）。官方 stock SDK 需要叠加 §4 的离线 pack 和 RID 图覆盖 |
| RID | `openharmony-arm64`（对外命名不变；内部解析见 §3） |
| 工具链 | OpenHarmony NDK 的 `clang` + `lld`（harmonybrew：`~/.harmonybrew/bin/clang` 或 DevEco `native/llvm/bin`），`clang` 目标为 `aarch64-unknown-linux-ohos` |
| 运行库 | 设备端 `ilc`（本地 host 编译时使用）需要 `libstdc++.so.6` + `libgcc_s.so.1`，`install-dotnet-ohos.sh` 会自动从 ILCompiler pack 提取部署 |
| Packs | AOT runtime pack + host ILCompiler pack（§4，离线可用） |

## 2. 命令（设备端编译）

```sh
export DOTNET_ROOT=$HOME/.dotnet
export PATH=$DOTNET_ROOT:$PATH

dotnet publish -r openharmony-arm64 -p:PublishAot=true
# 本机 clang 若报 "--compress-debug-sections: LLVM was not built with LLVM_ENABLE_ZLIB"
# （harmonybrew clang 23 的已知构建差异），追加：
dotnet publish -r openharmony-arm64 -p:PublishAot=true -p:CompressSymbols=false
```

输出：`bin/<Config>/net11.0/openharmony-arm64/publish/<AssemblyName>`（单个 ELF，
含 `.codesign` 段）。自包含、无 runtimeconfig，不需要 apphost
（SDK 在 `PublishAot=true` 时把 `_RuntimeIdentifierUsesAppHost` 置为 false）。

Windows/其它桌面 host 交叉编译同理：`dotnet publish -r openharmony-arm64 -p:PublishAot=true`
（host ILCompiler pack 会自动选当前 host 的 RID，例如 `runtime.win-x64.Microsoft.DotNet.ILCompiler`）。

## 3. SDK 内部解析：RID → AOT pack 映射

关键点：**对外 TFM/RID 始终是 `openharmony-arm64`；只有内部 pack 解析经
portable RID 图回落**（`eng/PortableRuntimeIdentifierGraph.openharmony.json`）：

```jsonc
"openharmony-arm64": { "#import": ["openharmony", "linux-musl-arm64"] },  // 新增回落
"openharmony-arm":   { "#import": ["openharmony", "linux-musl-arm"] },
"openharmony-x64":   { "#import": ["openharmony", "linux-musl-x64"] }
```

`ProcessFrameworkReferences`（Microsoft.NET.Build.Tasks）用该图做
`GetBestMatchingRid`：候选集中同时存在 `openharmony-*` 与 `linux-musl-*`
时，**精确匹配的 openharmony pack 优先**；当前 SDK 的 RID 列表不含
openharmony（stock/旧 kit）时，自动选中 `linux-musl-*` 的官方 pack，
而不是报 `NETSDK1203`（目标 RID 不支持 AOT）/`NETSDK1204`（host RID 不支持）。

选中结果（本次验证的 diag 输出）：

```
Best RID for 'Microsoft.DotNet.ILCompiler@11.0.0-rc.1.26425.128' is 'linux-musl-arm64'
Added PackageDownload for Microsoft.NETCore.App.Runtime.NativeAOT.linux-musl-arm64@11.0.0-rc.1.26425.128
        for cross-targeting compilation for openharmony-arm64
```

| 角色 | 当前 SDK（优先精确匹配） | 回落（stock/旧 SDK） |
|---|---|---|
| host ILCompiler pack | `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler` | `runtime.<hostRID>.Microsoft.DotNet.ILCompiler`（如 `linux-musl-arm64` / `win-x64`） |
| target AOT runtime pack | `Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64` | `Microsoft.NETCore.App.Runtime.NativeAOT.linux-musl-arm64` |
| 主 runtime pack（非 AOT） | `Microsoft.NETCore.App.Runtime.openharmony-arm64` | 不受影响（workload 提供） |

## 4. 离线获取 pack

`springmin/sdk-ohos` Release **`aot-packs-11.0.0-rc.1`** 镜像了以下资产
（`SHA256SUMS` 随附；官方包来源为 nuget.org，本机构建包来源为
`runtime-ohos` `feature/openharmony` @ `295014191c`）：

| 资产 | 用途 | sha256 |
|---|---|---|
| `Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64.11.0.0-rc.1.26451.109.nupkg` | 设备端目标 runtime pack（原生，推荐） | `5baad9e83604528ffd207d60fe4a828a1f78da82a1695b5345e0d7ee3681d5e4` |
| `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.11.0.0-rc.1.26451.109.nupkg` | 设备端 host ilc（原生，推荐） | `999e73a7b41fdd5af42a613182a2577e9a276026b1a2f65295e29115b1b539e8` |
| `microsoft.netcore.app.runtime.nativeaot.linux-musl-arm64.11.0.0-rc.1.26425.128.nupkg` | 回落目标 pack（官方） | `477b0c0ba48aae50beb973c5c205b98669eba6a4ba997abfae6f6f320c58bbf9` |
| `runtime.linux-musl-arm64.microsoft.dotnet.ilcompiler.11.0.0-rc.1.26425.128.nupkg` | 回落 host ilc（官方；设备端运行受限，见 §5） | `74637dbb6a492bddd963e0a184c1f2faa07ac540154a90ef0618798990e29c63` |
| `runtime.win-x64.microsoft.dotnet.ilcompiler.11.0.0-rc.1.26425.128.nupkg` | Windows host 交叉编译 ilc（官方） | `abd9009e44faa2f44633790625ed448b3a1ac4bf0c102fce7fe6d16410275421` |
| `microsoft.netcore.app.runtime.nativeaot.linux-musl-arm64.11.0.0-rc.1.26451.109.nupkg` | 回落目标 pack（上面官方包的等同重打包，匹配 26451.109 band） | `8cdcb38808dd01a6a4b09c861f519d9619a73577ef38b2a3b487a54e7db4fd59` |
| `runtime.linux-musl-arm64.microsoft.dotnet.ilcompiler.11.0.0-rc.1.26451.109.nupkg` | 回落 host ilc（等同重打包） | `0b0bbd18dea3ddfb1fbc41bfb683be55be2fa4b04e08553044ed583f2de51ce7` |

一键下载（校验 sha256 后放入本地 feed）：

```sh
# 默认下载到 ./aot-packs；也可传目标目录或本地文件所在目录
sh eng/ohos-install/fetch-nativeaot-packs.sh [目录]

# 然后把该目录加为 NuGet 源（项目级 NuGet.config）：
#   <add key="aot-packs" value="/绝对路径/aot-packs" />
# 或在命令行：dotnet restore --source /绝对路径/aot-packs
```

> 脚本先直连 github.com，失败自动回退 `https://gh-proxy.com/<url>`
> （可用 `AOT_PACKS_PROXY=` 关闭或换成其它镜像）；每个资产都用
> `versions.env` 里的 `aot_pack_sha256` 锚校验，截断/替换的下载会被拒绝
> （本环境下直连 release-assets CDN 会 TLS 超时/截断，代理回退已验证）。

> 网络受限时可用镜像 `https://api.nuget.org` → `https://nuget.azure.cn`
> （flatcontainer 重定向）。官方包按 26425.128 发布；26451.109 band 的 SDK
> 使用表中"等同重打包"资产（仅改 nuspec 版本串，内容不变）。

## 5. 已知限制

- **设备端 `linux-musl` ilc 不可执行**：官方 `runtime.linux-musl-arm64...ilc`
  在 HarmonyOS 上触发 SIGSYS（syscall 限制），且未签名时 `execve` 返回
  `EACCES`。设备端请使用本机构建的 `runtime.openharmony-arm64...ILCompiler`
  （本仓库镜像资产），它带平台修复且可直接运行。
- **映射 RID 的 pack 路径**：当 SDK 回落到 `linux-musl-*` 目标 pack 时，
  ilc targets 仍按 `$(RuntimeIdentifier)` 拼 `runtimes/openharmony-arm64/...`
  路径，需要 runtime-ohos 侧 `SingleEntry.targets` 同步按解析 RID 取路径
  （平台切片工作，另行推进）。
- **`-gz=zlib`**：部分 clang 构建未启用 zlib，需 `-p:CompressSymbols=false`
  （仅影响调试符号压缩，不影响产物运行）。
- **未签名的 NuGet 工具**：设备上执行的任何 ELF（包括 ilc）都必须有
  `.codesign` 段；`install-dotnet-ohos.sh` 会对安装目录内 ELF 签名，
  NuGet 缓存中的第三方 ilc 需 `selfsign`/`binary-sign-tool` 手动补签。
- **MAUI 平台切片**：`UseOpenHarmony`、`OpenHarmonyMauiAppHost` 等仍在
  `maui-ohos` 分支开发中；本文的验证基于普通 console 项目。

## 6. 已复现的验证（2026-09-24）

环境：HUAWEI MateBook Pro（HarmonyOS 7.0.0.105），SDK
`11.0.100-rc.1.26451.109`（`dotnet-ohp-test` 安装），harmonybrew clang 23.1.1。

```text
$ dotnet publish -r openharmony-arm64 -p:PublishAot=true \
    -p:BundledRuntimeIdentifierGraphFile=eng/PortableRuntimeIdentifierGraph.openharmony.json \
    -p:CompressSymbols=false
  probe -> .../openharmony-arm64/publish/
$ ./bin/Release/net11.0/openharmony-arm64/publish/probe
hello aot openharmony
```

- 解析阶段（stock RID 列表模拟）：不再出现 NETSDK1203/1204，日志显示选中
  `linux-musl-arm64` 的 host ilc 与 `Microsoft.NETCore.App.Runtime.NativeAOT.linux-musl-arm64`。
- 原生路径：解析到 `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler` +
  `Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64`，ilc 编译、链接、
  签名全部成功，产物在 Publish 后可直接运行。
- 离线路径：清空 NuGet 缓存，仅以 release `aot-packs-11.0.0-rc.1` 的
  `feed-real/` + workload `.feed` 为源，重新 publish 并运行成功。

## 7. Workload / CLI 开关评估

- **workload 无需改动**：AOT 的 host ILCompiler pack 与 target NativeAOT
  runtime pack 是 restore 期的 `PackageDownload`/runtime pack，不是 workload
  pack；OpenHarmony workload（`Microsoft.OpenHarmony.Sdk` 等）只提供
  Ref/Runtime/Sdk，无需新增 pack 定义或 `RuntimeHostConfigurationOption`。
- **`UseAppHost` 无需改动**：SDK 在 `PublishAot=true` 时已经令
  `_RuntimeIdentifierUsesAppHost=false`（`Microsoft.NET.RuntimeIdentifierInference.targets`），
  AOT 产物本身就是可执行体，不需要 apphost。
- **`src/Cli/dotnet-aot` 无需同步**：它是 SDK 自身 NativeAOT 构建用的 host
  （`dn`），不参与用户项目的 publish；SDK 仓库构建对 openharmony 保持
  `NativeAotSupported=false`（`Directory.Build.props`）是有意为之，避免在 SDK
  构建期拉取不存在的 openharmony AOT 工具链。
- **stock SDK（官方 SDK + workload）**：SDK 的 RID 列表不含 openharmony，可
  显式指向随仓库发布的 RID 图并加上镜像 feed：

  ```sh
  dotnet publish -r openharmony-arm64 -p:PublishAot=true \
      -p:BundledRuntimeIdentifierGraphFile=<repo>/eng/PortableRuntimeIdentifierGraph.openharmony.json
  # NuGet.config 加 <add key="aot-packs" value=".../aot-packs" />
  ```

  该路径按 §3 回落到 linux-musl pack（host 为 win-x64 时用镜像的
  `runtime.win-x64...ilc`）。若希望 stock SDK 直接认 openharmony pack，可在
  workload manifest targets 中用 `KnownILCompilerPack Update` 追加 openharmony
  RID（跟随 ohos-workload 发版）——当前版本未包含，作为后续增强。

