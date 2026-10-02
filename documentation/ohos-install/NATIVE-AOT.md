# NativeAOT on OpenHarmony（实验）

> 状态：**实验可用（2026-09-24 在 HarmonyOS 设备上端到端验证；2026-09-29 起镜像
> 与本文更新到 rc.2 线）**。
> 本文覆盖：前置条件、命令、SDK 内部的 RID → pack 解析映射、离线 pack 获取、
> 已复现的验证结果与已知限制。
> rc.2 线环境：SDK `11.0.100-rc.2.26451.112` + workload `1.0.0-preview.28`；本机用
> `~/.dotnet.rc2-fix` + feed（dnceng/离线，见 ohos-workload `docs/rc2-line-notes.md`），
> 默认根 `~/.dotnet` 保留 rc.1 回滚线。

NativeAOT 把托管程序编译成单个原生 ELF（`ilc` 编译 + 原生链接），发布产物
在设备上直接 `execve`，不经过 CoreCLR/JIT —— 因此绕开了 HarmonyOS 对匿名
可执行内存（JIT）的限制。发布输出仍由 SDK 自动签名（`OpenHarmonyCodesign`）。

---

## 1. 前置条件

| 项 | 要求 |
|---|---|
| SDK | `sdk-ohos` 构建的 SDK，rc.2 线 `11.0.100-rc.2.26451.112` 及之后（RID 图 + ILCompiler/NativeAOT RID 列表已内嵌；rc.1 线 `11.0.100-rc.1.26451.109` 仍可用 rc.1 镜像）。官方 stock SDK 需要叠加 §4 的离线 pack 和 RID 图覆盖 |
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

> 上例为 rc.1 线（26425.128 回落）实测留档。rc.2 线的 host ilc =
> `Microsoft.DotNet.ILCompiler@11.0.0-rc.2.26451.112`，精确匹配镜像的
> `runtime.openharmony-arm64…` 包（rc.2 镜像不含 `linux-musl` 回落件，见 §4）。

| 角色 | 当前 SDK（优先精确匹配） | 回落（stock/旧 SDK） |
|---|---|---|
| host ILCompiler pack | `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler` | `runtime.<hostRID>.Microsoft.DotNet.ILCompiler`（如 `linux-musl-arm64` / `win-x64`） |
| target AOT runtime pack | `Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64` | `Microsoft.NETCore.App.Runtime.NativeAOT.linux-musl-arm64` |
| 主 runtime pack（非 AOT） | `Microsoft.NETCore.App.Runtime.openharmony-arm64` | 不受影响（workload 提供） |

## 4. 离线获取 pack

`springmin/sdk-ohos` Release **`aot-packs-11.0.0-rc.2`** 镜像了 rc.2 线的两件原生包
（`SHA256SUMS` 随附、asset id `597667550`；来源 = `runtime-ohos`
`feature/openharmony` 的 rc.2 线构建）：

| 资产 | 用途 | sha256 |
|---|---|---|
| `Microsoft.NETCore.App.Runtime.NativeAOT.openharmony-arm64.11.0.0-rc.2.26451.112-r2.nupkg` | 设备端目标 runtime pack（原生，推荐；asset id `601289590`） | `542058cf953a3e9c1a42cbf287c5df1177bc5c9f4de70957ca384d472570e4a2` |
| `runtime.openharmony-arm64.Microsoft.DotNet.ILCompiler.11.0.0-rc.2.26451.112.nupkg` | 设备端 host ilc（原生，推荐；asset id `597667138`） | `1c518a461cdb6d76640561b97170c2dc7d0e75fb55b475d00944a2e3cd7e67cd` |

> **`-r2` 是 rc.2 runtime pack 的修正版**：原 `...rc.2.26451.112.nupkg`
> （`46d221f2…`）由 2026-09-27 的静态 OpenSSL 全量构建产出，其静态
> `libSystem.Security.Cryptography.Native.OpenSsl.a` 缺 `opensslshim.c.o`
> （`nm --defined-only … | grep -cE 'local_(EVP|SSL|X509)'` = 0），NativeAOT 把该
> 归档链进 app 后凡用到 crypto 即链接/`dlopen` 失败（undefined `EVP_*`/`X509_*`）。
> `-r2` 只替换该归档（用 `FEATURE_DISTRO_AGNOSTIC_SSL=1` 重编 shim 版，判据 5/5），
> 包 id/版本不变（仍为 `11.0.0-rc.2.26451.112`）。fetch 脚本会做同一判据的
> 内容校验（`OpenSSL shim OK (5/5 …)`），无 shim 的包会被拒绝。
> 若本机 NuGet 缓存里已有旧的 `.112` 包，重新 publish 前先删
> `~/.nuget/packages/microsoft.netcore.app.runtime.nativeaot.openharmony-arm64/11.0.0-rc.2.26451.112`
> （NuGet 按 id+版本复用缓存，不会因为 feed 换件而重新解包）。
>
> **结构性修复（2026-10-03）**：`LinkStaticOpenSsl=true` 已按目标拆分对象库——
> 共享 `.so` 静态链 OpenSSL，AOT 静态归档改用 `FEATURE_DISTRO_AGNOSTIC_SSL_STATIC=1`
> 的对象集（仍带 dlopen shim）。`build-ohos-all.sh` 在主构建后校验 libs 布局归档、
> 在 NativeAOT sfxproj 后校验 nupkg 内归档（缺 shim 直接构建失败），fetch 内容校验
> 保留为发布端防线；后续构建不再需要人工 `-r2` 重打。另见 runtime-ohos
> `docs/plans/2026-10-03-ohos-aotpack-structural.md`。

> rc.1 线镜像 **`aot-packs-11.0.0-rc.1`** 保留（含 `linux-musl` / `win-x64` 官方回落件；
> 旧 SDK 或需要映射回落路径时用 `AOT_PACKS_TAG=aot-packs-11.0.0-rc.1`）。

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
> `versions.env` 里的 `aot_pack_sha256` 锚校验，截断/替换的下载会被拒绝，
> 并额外校验 OpenHarmony runtime pack 的 OpenSSL shim（缺 shim 的包拒绝入 feed）
> （本环境下直连 release-assets CDN 会 TLS 超时/截断，代理回退已验证）。

> 网络受限时可用镜像 `https://api.nuget.org` → `https://nuget.azure.cn`
> （flatcontainer 重定向）。rc.2 镜像只含两件 openharmony 原生包：需要
> `linux-musl`/`win-x64` 回落件时用 rc.1 tag 的「等同重打包」资产（仅改 nuspec
> 版本串，内容不变）或从 nuget.org 直接还原。

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

## 6. 已复现的验证

### 6.1 rc.1 线（2026-09-24）

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

### 6.2 rc.2 线（2026-09-29 起）

- 命令与判定同 §2/§3（rc.2 host ilc = `11.0.0-rc.2.26451.112`）；publish/链接/签名
  路径在本机（`~/.dotnet.rc2-fix`，SDK `.112` + workload `preview.28`）已复验，真机
  可启动出画（RSTree `ohos_dotnet_surface` buffer=1）。
- **设备复验包**：rc.2 工具链出的 AOT haps = `aot-haps-v3-rc2.tar.gz`（随
  `device-test-kit` release 发布，asset **599996905**，18,185,012 B / sha256
  `3d24f716fe564bc39151b3fa53ab827884d6e6f71d5be5ca28f2da9c9e638423`；已签 hap
  `332f2d8bb549c2739dbedb5796cab89d706cf543d16ad72bce168b14c1f90f5b`、未签
  `4e3f0b1ad0f861d565d59eaee2002e517b7f419ea3c816b0db1b3b778bef83ac`；本机真机出画已验证，
  RSTree `ohos_dotnet_surface` buffer=1）——以 release 页与随附 `.sha256` 为准。

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

  该路径按 §3 回落到 linux-musl pack（host 为 win-x64 时用 rc.1 tag 镜像的
  `runtime.win-x64...ilc`，或 nuget.org 官方包）。若希望 stock SDK 直接认
  openharmony pack，可在
  workload manifest targets 中用 `KnownILCompilerPack Update` 追加 openharmony
  RID（跟随 ohos-workload 发版）——当前版本未包含，作为后续增强。

