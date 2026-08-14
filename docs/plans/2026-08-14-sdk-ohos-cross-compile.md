# HarmonyOS (ohos) 交叉编译 dotnet/sdk 执行记录

**日期:** 2026-08-14
**分支:** `feature/ohos-cross-sdk`
**目标:** 通过仿 linux-musl 模式添加 `linux-ohos` 目标支持，交叉编译出完整的 dotnet SDK
（`artifacts/bin/redist/<Configuration>/dotnet/`，含 muxer + hostfxr + sdk/ + shared/ 全布局）。

## 一、执行纪律（与 runtime 一致的用户约定）

1. **所有执行先分析**：每个阶段先分析/记录方案，再执行。
2. **问题循环**：执行中遇到问题 → 记录问题 → 找解决方案 → 验证方案可行性 → 执行方案 → 验证执行结果 → 记录解决过程。
3. **终止条件**：编译出 ohos 二进制的 dotnet SDK（`artifacts/bin/redist/Release/dotnet/` 下含
   muxer + hostfxr + sdk/11.0.100-dev + shared/Microsoft.NETCore.App/11.0.0-dev）。
4. 每个问题记录为独立小节，格式：
   ```
   ### 问题 N: <标题>
   - **现象**: <错误输出/行为>
   - **根因**: <分析>
   - **方案**: <解决方案>
   - **验证**: <如何确认方案有效>
   - **结果**: <执行结果>
   ```

## 二、环境事实（已验证）

- **前置依赖**: dotnet/runtime 的 ohos 交叉编译已完成（`feature/ohos-cross-runtime` 分支，
  见 `~/springmin/sources/runtime/docs/plans/2026-08-13-ohos-cross-compile.md`），产物 15 个
  `linux-ohos-arm64` 包在 `~/springmin/sources/runtime/artifacts/packages/Release/Shipping/`。
- **OHOS NDK**: `OHOS_NDK_HOME=/home/springmin/hmos-tools/sdk/default/openharmony`，API 22。
  工具链 `native/llvm/bin/` clang-15 + `aarch64-unknown-linux-ohos-clang` wrapper；sysroot
  `native/sysroot/usr/lib/aarch64-linux-ohos/`（**musl libc**）；`ohos.toolchain.cmake` 可用。
- **SDK 仓库**: `/home/springmin/sources/sdk`，`global.json` 钉 bootstrap SDK
  `11.0.100-preview.6.26359.118` + Arcade `11.0.0-beta.26410.101`。
- **版本对齐**: SDK 依赖 runtime 包版本 `11.0.0-rc.1.26410.101`（`eng/Version.Details.xml` 钉死），
  而 runtime ohos 产物是 `11.0.0-dev` → 需版本覆盖 + 本地 feed。
- **RID 图**: 官方 `Microsoft.NETCore.Platforms` 包（rc.1）不含 linux-ohos；runtime 分支已改
  `runtime.json` 但未改 `PortableRuntimeIdentifierGraph.json` → 需本地注入。
- **磁盘/网络**: 683G 可用；网络可达官方 blob，但 arm64 musl 包下载不稳定。

## 三、修改点清单（全部完成，4 commits）

| # | 文件 | 修改内容 | commit |
|---|------|----------|--------|
| 1 | `src/Layout/Directory.Build.props` | `SharedFrameworkRid` 加 `linux-ohos` 分支（仿 musl）；`UsePortableLinuxSharedFramework` 排除 ohos；`_DotnetAotIsNativeBuild/_IsCrossBuild` 排除 ohos；`SkipBuildingInstallers` 加 ohos | `4012a12b54` |
| 2 | `src/Layout/redist/targets/GenerateBundledVersions.targets` | `Net110AppHostRids`/`Net110RuntimePackRids`/`Net110Crossgen2SupportedRids`/`Net110ILCompilerSupportedRids` 加 `linux-ohos-*` | `4012a12b54` |
| 3 | `src/Layout/redist/targets/GenerateLayout.targets` | `PublishRuntimeIdentifierGraphFiles` 支持 RID 图源覆盖（`RidGraphOverrideRuntimeJson`/`RidGraphOverridePortableJson`） | `4012a12b54` |
| 4 | `eng/RuntimeIdentifierGraph.ohos.json` + `eng/PortableRuntimeIdentifierGraph.ohos.json` | 注入 linux-ohos 的 RID 图（来自 runtime 分支 + 手工注入 portable） | `4012a12b54` |
| 5 | `Directory.Build.props` + `Directory.Build.targets` | `NativeAotSupported` 对 linux-musl/linux-ohos 强制 false；Host/Runtime 版本别名加 `== ''` 守卫（可 `/p:` 覆盖） | `cc48483f09` |
| 6 | `src/Cli/dotnet-aot/dotnet-aot.csproj` + `src/Cli/dn/dn.csproj` | `PublishAot`/`IsAotCompatible` gate 于 `NativeAotSupported`（防 restore 拉 ILCompiler 失败） | `cc48483f09` |
| 7 | `test/dotnet-aot.Tests/dotnet-aot.Tests.csproj` | 补 `EXCLUDE_ASPNETCORE` 宏（与 dotnet-aot 一致） | `539a350cc4` |

## 四、实施阶段

### Phase 0: 前置验证
- [x] 0.1 本地 feed 验证：`Microsoft.NETCore.App.Host.linux-ohos-arm64.11.0.0-dev` 能从本地目录 restore ✅
- [x] 0.2 RID 图检查：runtime.json 已含 ohos（`3d6b5d7fbc5`），**PortableRuntimeIdentifierGraph.json 缺 ohos** → 需注入
- [x] 0.3 bootstrap SDK 安装（dotnetup 下载 11.0.100-preview.6 + 6 个运行时，慢速网络 ~40 分钟）

### Phase 1: 源码修改（7 项，3 commits）✅

### Phase 2: 构建验证
- [x] 2.1 `./build.sh -os linux-ohos -arch arm64 -c Release`（版本覆盖 + 本地 feed + RID 图注入）→ **Build succeeded, 0 errors**

### Phase 3: 产物验证
- [x] 3.1 `file` 检查：muxer/dotnet = aarch64 musl ELF（`/lib/ld-musl-aarch64.so.1`）
- [x] 3.2 `qemu-aarch64 dotnet --info` → RID `linux-ohos-arm64`，SDK `11.0.100-dev`，runtime `11.0.0-dev` 全部正确
- [x] 3.3 与官方 linux-musl SDK 对比（结构/RID/依赖/R2R 差异）✅

## 五、问题日志

### 问题 1: NETSDK1083 / NETSDK1203 — RID 'linux-ohos-arm64' 不识别 + AOT 不支持
- **现象**: restore 报 `NETSDK1083: The specified RuntimeIdentifier 'linux-ohos-arm64' is not recognized` + `NETSDK1203: Ahead-of-time compilation is not supported`
- **根因**: bootstrap SDK 的 RID 图（Microsoft.NETCore.Platforms 官方包）无 linux-ohos；且 dotnet-aot.csproj 的 `RuntimeIdentifier=$(TargetRid)` 在 `NativeAotSupported` 为 true 时激活（vendored props 排除表无 ohos）
- **方案**: (a) RID 图注入（GenerateLayout.targets 覆盖源 + eng/ 注入文件）；(b) `Directory.Build.props` 提前置 `NativeAotSupported=false`（早于 vendored props 的 `== ''` 判定）
- **验证**: restore 通过
- **结果**: 已解决

### 问题 2: NU1102 — runtime.linux-x64.Microsoft.DotNet.ILCompiler 11.0.0-dev 找不到
- **现象**: dotnet-aot restore 拉 `runtime.linux-x64.Microsoft.DotNet.ILCompiler (= 11.0.0-dev)` 失败
- **根因**: `PublishAot=true` 硬编码（不受 NativeAotSupported 影响）→ restore 无条件拉 ILCompiler 包
- **方案**: dotnet-aot.csproj 的 `PublishAot`/`IsAotCompatible` 加 `Condition="'$(NativeAotSupported)' == 'true'"`
- **验证**: 单独 restore 通过
- **结果**: 已解决

### 问题 3: NU1603 — Microsoft.NET.ILLink.Tasks (>= 11.0.0-dev) 版本降级
- **现象**: `NU1603 Warning As Error: depends on Microsoft.NET.ILLink.Tasks (>= 11.0.0-dev) but 11.0.0-dev was not found`
- **根因**: `MicrosoftNETCoreAppRefPackageVersion=11.0.0-dev` 全局覆盖 → `KnownILLinkPack ILLinkPackVersion` 跟随变 dev，但 feed 无 dev ILLink
- **方案**: 双管齐下：(a) 别名加 `== ''` 守卫，只覆盖 Host/Runtime 版本（Ref 保持 rc.1）；(b) 官方 rc.1 ILLink.Tasks 重打包为 11.0.0-dev 入本地 feed
- **验证**: restore 通过
- **结果**: 已解决

### 问题 4: NU1102 — Microsoft.NETCore.App.Runtime.win-x64 11.0.0-dev 找不到
- **现象**: Resolvers 项目拉 `Microsoft.NETCore.App.Runtime.win-{x86,x64,arm64} (= 11.0.0-dev)` 失败
- **根因**: Resolvers 的 `PackageDownload` 用 `$(MicrosoftNETCoreAppRuntimePackageVersion)` 下载官方 win 包，全局 dev 覆盖破坏
- **方案**: 官方 rc.1 win-x86/x64/arm64 Runtime 包下载后重打包为 11.0.0-dev 入本地 feed
- **验证**: MSBuildSdkResolver restore 通过
- **结果**: 已解决

### 问题 5: CS0103 — The name 'AspNetCore' does not exist
- **现象**: dotnet-aot.Tests 编译报 `AspNetCoreCertificateGenerator.cs(15,9): error CS0103: The name 'AspNetCore' does not exist`
- **根因**: `IncludeAspNetCoreRuntime=false` 时 dotnet.csproj 定义 `EXCLUDE_ASPNETCORE` 宏使方法体为空，但测试项目（经 AotSourceFiles.props 引入同源文件）未定义该宏 → 编译 `#if !EXCLUDE_ASPNETCORE` 块时无 AspNetCore 包引用
- **方案**: dotnet-aot.Tests.csproj 补 `DefineConstants` 的 `EXCLUDE_ASPNETCORE`（同 dotnet-aot）
- **验证**: 单独 build 通过
- **结果**: 已解决

### 问题 6: blob 下载失败 — dotnet-runtime-11.0.0-dev-linux-ohos-arm64.tar.gz
- **现象**: `RestoreLayout.targets(314,5): error : Download from all targets failed`（尝试官方 URL 不存在）
- **根因**: `DownloadBundledComponents` 的 `ShouldDownload=!Exists(DownloadDestination)`，而 DownloadsFolder = `$(IntermediateOutputPath)\redist-downloads\`，redist 是**多目标项目** → 实际路径带 `net11.0/` 子目录
- **方案**: 预置本地 runtime tar.gz 到 `artifacts/obj/redist/Release/net11.0/redist-downloads/`（跳过下载）
- **验证**: 构建通过
- **结果**: 已解决

### 问题 7: qemu 运行缺 arc4random_buf
- **现象**: `libcoreclr.so: arc4random_buf: symbol not found`（Alpine musl 1.2.4 无此符号）
- **根因**: ohos libc 有 arc4random_buf 但 Alpine musl（qemu 验证用）无
- **方案**: zig 交叉编译 shim（`-nostdlib -fno-sanitize`，SYS_getrandom=278 aarch64），LD_PRELOAD 预加载
- **验证**: libcoreclr.so 成功加载，托管代码执行
- **结果**: 已解决

### 问题 8: qemu 下 `.dotnet` 多级探测干扰
- **现象**: `dotnet --info` 报加载 `.dotnet/shared/.../libhostpolicy.so` 缺 libstdc++
- **根因**: 构建机 `.dotnet` bootstrap（x64 glibc 系）被 muxer 多级探测；该目录非 SDK 产物
- **方案**: 验证时临时移开 `.dotnet` → 完全干净输出（真实设备无此目录）
- **验证**: `dotnet --info` 零错误
- **结果**: 已解决（环境干扰，非产物问题）

## 六、构建命令（可复现）

```bash
# 1. 前置：本地 feed（runtime ohos 包 + 重打包官方 dev 包）
mkdir -p artifacts/ohos-local-feed
cp ~/springmin/sources/runtime/artifacts/packages/Release/Shipping/*.nupkg artifacts/ohos-local-feed/
# 补充（重打包为 11.0.0-dev）：Microsoft.NET.ILLink.Tasks,
#   Microsoft.NETCore.App.Runtime.win-{x86,x64,arm64}
# 预置 blob（跳下载）：
mkdir -p artifacts/obj/redist/Release/net11.0/redist-downloads
cp ~/springmin/sources/runtime/artifacts/packages/Release/Shipping/dotnet-runtime-11.0.0-dev-linux-ohos-arm64.tar.gz \
   artifacts/obj/redist/Release/net11.0/redist-downloads/

# 2. 构建
./build.sh -os linux-ohos -arch arm64 -c Release \
  /p:MicrosoftNETCoreAppHostPackageVersion=11.0.0-dev \
  /p:MicrosoftNETCoreAppRuntimePackageVersion=11.0.0-dev \
  /p:RestoreAdditionalProjectSources=$PWD/artifacts/ohos-local-feed \
  /p:RidGraphOverrideRuntimeJson=$PWD/eng/RuntimeIdentifierGraph.ohos.json \
  /p:RidGraphOverridePortableJson=$PWD/eng/PortableRuntimeIdentifierGraph.ohos.json \
  /p:IncludeAspNetCoreRuntime=false
```

## 七、产物验证（Phase 3 结果）

- **布局**: `artifacts/bin/redist/Release/dotnet/` 完整（muxer + host/fxr/11.0.0-dev + sdk/11.0.100-dev + shared/Microsoft.NETCore.App/11.0.0-dev + packs/Microsoft.NETCore.App.Host.linux-ohos-arm64）
- **二进制**: 全部 aarch64 musl ELF（`/lib/ld-musl-aarch64.so.1`）
- **RID 链**: `linux-ohos-arm64 → linux-ohos → linux-arm64 → linux → unix-arm64 → unix → any → base`
- **qemu 运行**: RID/SDK/runtime 正确识别，CoreCLR 绑定，托管代码执行

## 八、与官方 linux-musl SDK 的差异（对比结论）

| 维度 | 官方 musl | ohos 构建 | 说明 |
|------|-----------|-----------|------|
| C++ ABI | GNU libstdc++ | **LLVM libc++** | ohos NDK 工具链，HarmonyOS 原生 |
| RID 体系 | linux-musl-* | linux-ohos-* | 结构完全同构 |
| Net.Security / LTTNG | ✅ | ❌ | ohos 无 krb5/gssapi、禁 LTTNG |
| aspnetcoretools | ✅ | ❌ | 无 ohos NativeAOT 工具包 |
| R2R | 完整 | 部分（缺 PGO） | 启动稍慢，功能完整 |

## 九、遗留事项

- [ ] 完整 R2R + PGO 数据（runtime 侧，性能优化）
- [ ] AspNetCore 组件（aspnetcore repo 产 ohos 包）
- [ ] 真实设备运行验证（当前为 qemu 模拟）
- [ ] CI 集成（sdk-job-matrix.yml 加 ohos leg）
- [ ] 上游化（runtime.json 补 portable 图 + SDK RID 列表正式入库）
