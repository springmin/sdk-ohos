# OHOS 修复内嵌 — 变更记录与安装说明

**日期:** 2026-08-26
**分支:** sdk `feature/ohos-cross-sdk` + runtime `feature/ohos-cross-runtime`
**目标:** 把原先 `dotnet-ohos` wrapper + `libnuma-shim.so` 的外部处理全部内嵌进 dotnet 二进制内部，安装/使用不再需要额外工具。

---

## 1. 背景：外部处理的来源

`dotnet-ohos-安装运行总结.md`（阶段二）记录了在 OpenHarmony 沙箱上运行 .NET 需要跨过的 6 层故障。修复当时以外部手段实现：

| # | 故障 | 外部修复（旧） |
|---|---|---|
| 1 | seccomp 拦截 `get_mempolicy`（syscall 236）→ SIGSYS | `libnuma-shim.so` LD_PRELOAD 拦截 syscall |
| 2 | JIT W^X mprotect 被拒 → SIGSEGV | wrapper 导出 `DOTNET_EnableWriteXorExecute=0` |
| 3 | 无 libicu | wrapper 导出 `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` |
| 4 | `/tmp` 只读（erofs） | shim 拦截路径 syscall `/tmp/*` → `$TMPDIR/*` |
| 5 | MSBuild NullReference（AT_SYMLINK_NOFOLLOW 常量） | shim 修正常量 |
| 6 | 构建产物 EPERM（apphost 每次重写失效） | wrapper `sign_runfile` 无条件重签 |

## 2. 内嵌方案（本次变更）

### 2.1 runtime 仓库（2 处根治）

**A. `src/coreclr/gc/unix/numasupport.cpp` — 消灭 SIGSYS（问题 1）**

`get_mempolicy` 探测在 `NUMASupportInitialize()` 中，受 `#if defined(TARGET_LINUX) && !defined(TARGET_ANDROID)` 保护。OHOS 目标映射为 `TARGET_LINUX`（musl 路径），因此该保护**不排除 OHOS**，导致 GC 初始化时必然触发 syscall 236。

修改：全部 5 处 guard 增加 `&& !defined(TARGET_OHOS)`（include、`GetNodeNum`、`NUMASupportInitialize`、`GetNumaNodeNumByCpu`、`BindMemoryPolicy`）。`g_numaAvailable` 保持 false，GC NUMA 感知完全关闭，`mbind`/`GetNumaNodeNumByCpu` 的调用点（gcenv.unix.cpp）因 `CanEnableGCNumaAware()` 返回 false 而同样不可达。

**验证**: ohos-arm64 交叉编译 `numasupport.cpp.o` 后 `NUMASupportInitialize` 为空桩（仅 `ret`），零 `svc` 指令，无 mempolicy/mbind 符号。

**B. `src/libraries/System.Private.CoreLib/src/System/IO/SharedMemoryManager.Unix.cs` — 消灭 /tmp 失败（问题 4）**

共享内存文件路径硬编码 `/tmp/`（`InitalizeSharedFilesPath()`）。修改为 `Path.GetTempPath()`，在 Unix 上读取 `TMPDIR` 环境变量（无则回退 `/tmp/`），与运行时其余临时路径行为一致。PAL 层临时目录本已支持 TMPDIR，此处是唯一硬编码点。

**验证**: `Path.GetTempPath()` 为 public、同 `System.IO` 命名空间，编译无歧义。

### 2.2 SDK 仓库（4 处内嵌）

**C. `src/Tasks/Microsoft.NET.Build.Tasks/OhosCodesign.cs` — 签名内嵌（问题 6）**

新增 MSBuild task `OhosCodesign`（+ 内部 `ElfSelfSigner`），是 ohos-bst-light `selfsign.rs`（0BSD）的 C# 字节级移植：
- SHA-256（BCL）+ ELF64 段表解析 + `.codesign` 段注入/剥离 + fs-verity 风格描述符 + Merkle 根哈希
- `TrySignFileInPlace()`: 非 ELF 跳过；ELF64 强制重签（先剥离已有 `.codesign` 再注入），原位写入保留 Unix 权限

**D. `src/Tasks/Microsoft.NET.Build.Tasks/targets/Microsoft.NET.Sdk.targets` — 签名触发**

新增 `_OhosCodesignBuildOutputs`（`AfterTargets="Build"`）与 `_OhosCodesignPublishOutputs`（`AfterTargets="Publish"`），条件 `$(_OhosCodesignEnabled)` = `RuntimeIdentifier` 或 `NETCoreSdkRuntimeIdentifier` 以 `linux-ohos` 开头，对 `$(TargetDir)`/`$(PublishDir)` 全量递归签名。覆盖：自包含应用、file-based 应用（`dotnet run file.cs`，RID 取自 `RuntimeInformation.RuntimeIdentifier`）、portable 构建（RID 空但 SDK RID 为 ohos）。

**E. redist/runtimeconfig 烘焙（问题 2、3，SDK 自身进程）**

`src/Layout/redist/redist.csproj` 增加 ohos 条件 `RuntimeHostConfigurationOption`：
- `System.Runtime.EnableWriteXorExecute=false`
- `System.Globalization.Invariant=true`

经 `GenerateCliRuntimeConfigurationFiles` 复制进 `dotnet/MSBuild/NuGet.CommandLine.XPlat` 的 runtimeconfig.json，SDK 自身进程（CLI、MSBuild、NuGet）无需环境变量即可运行。

**F. 应用烘焙 + env 默认值（问题 2、3、子进程）**

- `Microsoft.NET.Sdk.targets` `DefaultRuntimeHostConfigurationOptions` 增加 `EnableWriteXorExecute` MSBuild 属性 → `System.Runtime.EnableWriteXorExecute` 映射（仿 `InvariantGlobalization`）
- `src/Cli/dotnet/OhosEnvironmentDefaults.cs` 新增 `Apply()`：RID 为 `linux-ohos` 时设置 `TMPDIR=/data/storage/el2/base/tmp`、`DOTNET_EnableWriteXorExecute=0`、`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`、遥测 optout、nologo 默认值。接入 managed `Program` 静态构造函数与 NativeAOT `NativeEntryPoint.ExecuteCore`，供子进程（MSBuild、csc、apphost）继承。

## 3. 修复后安装流程（不再需要 wrapper/shim）

```sh
# 1. 解压 runtime/SDK/aspnetcore tarball 到 ~/.dotnet
# 2. 一次性签名全部 ELF（tarball 内已是签名产物，可跳过；解压不改变文件内容）
# 3. 直接使用 dotnet：
export DOTNET_ROOT=~/.dotnet
export TMPDIR=/data/storage/el2/base/tmp   # 可选；SDK 会自动设置默认值
~/.dotnet/dotnet --version
~/.dotnet/dotnet build hello.cs             # 产物自动 codesign
~/.dotnet/dotnet run hello.cs
```

说明：
- **SDK 自身进程**：runtimeconfig 已烘焙 W^X=off + Invariant=true，无需 env
- **构建产物（apphost/自包含）**：`Build`/`Publish` 后自动 codesign，无需 `sign_runfile`
- **file-based app**：`dotnet run file.cs` 产物同样自动签名
- **`dotnet-ohos` wrapper 与 `libnuma-shim.so` 不再需要**（但作为旧版本兼容仍保留在 `installonohos/`）

## 4. 验证记录

| 验证 | 结果 |
|---|---|
| SDK 三个工程编译（tasks/dotnet/dotnet-aot，net472+net11.0） | 0 错误 0 警告 |
| ohos 交叉编译 `numasupport.cpp.o`：`NUMASupportInitialize` 空桩、零 syscall | ✅ |
| C# `ElfSelfSigner` vs rust `selfsign`：全新签名、force 重签 | 字节级一致 |
| `OhosCodesign` task 经真实 MSBuild：linux-ohos RID 签名全部 ELF、非 ELF 跳过；linux-x64 RID 不触发 | ✅ |
| redist runtimeconfig 烘焙（OSName=linux-ohos）→ `EnableWriteXorExecute=false` + `Invariant=true` | ✅ |
| `EnableWriteXorExecute` 属性映射 → runtimeconfig configProperties | ✅ |

## 5. 遗留

- runtime 交叉编译产物需重新生成（本地 feed 更新）后重建 SDK tar.gz 并重新发布
- `dotnet-ohos` wrapper 的 `run` 快捷命令（构建+签名+执行）仍可作为可选项保留，但核心修复已内嵌
- 需在真实 OHOS 设备回归：SIGSYS 消除、/tmp 共享内存、W^X、签名执行

## 6. ASP.NET Core 内嵌（2026-08-26 追加）

SDK 构建默认 `IncludeAspNetCoreRuntime=false`（runtime 单独分发）。用户要求 aspnetcore 一直内嵌进 SDK 包，已实现：

**构建方式**：`./build.sh -os linux-ohos -arch arm64 -c Release ... -p:IncludeAspNetCoreRuntime=true -p:MicrosoftAspNetCoreAppRuntimePackageVersion=11.0.0-dev`

**关键处理**（版本对齐）：
1. 交叉编译的 aspnetcore 包（`Microsoft.AspNetCore.App.Runtime.linux-ohos-arm64.11.0.0-dev.nupkg`）内部
   `Microsoft.AspNetCore.App.runtimeconfig.json` 硬编码 framework version `11.0.0-rc.1.26410.101`
   （来自 aspnetcore 的 darc `MicrosoftInternalRuntimeAspNetCoreTransportVersion`）→ 与 SDK 内置
   `11.0.0-dev` runtime 错配（dev < rc.1，roll-forward 不能向下，设备上会启动失败）。
2. **重打包 nupkg**：把 runtimeconfig framework version 改为 `11.0.0-dev`（纯配置改动，无二进制影响）。
3. **重打包 blob**：`aspnetcore-runtime-11.0.0-dev-linux-ohos-arm64.tar.gz` 内同样修 runtimeconfig，
   预置到 `artifacts/obj/redist/Release/net11.0/redist-downloads/`。
4. SDK 构建覆盖 `MicrosoftAspNetCoreAppRuntimePackageVersion` + `MicrosoftAspNetCoreAppRefPackageVersion`
   为 `11.0.0-dev`，让 SDK 从本地 feed 拉 dev 包并铺到 `shared/Microsoft.AspNetCore.App/11.0.0-dev/`。

**产物验证**（`dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz`，175MB）：
- `shared/Microsoft.AspNetCore.App/11.0.0-dev/`：132 个 aspnetcore dll（Kestrel/Mvc/SignalR/Identity 等）
- aspnetcore runtimeconfig 依赖 `11.0.0-dev` ✅（与内置 runtime 对齐）
- `shared/Microsoft.NETCore.App/11.0.0-dev/`：base runtime（含 NUMA/TMPDIR 修复）✅
- 设备上装完 SDK 即可直接运行 ASP.NET Core 应用（`dotnet run` 自动 codesign），无需单独装 aspnetcore runtime

**注意**：aspnetcore 的 dev 包是从 aspnetcore-ohos 仓库（`feature/ohos-cross-compile`）交叉编译的
（8-19），本次仅重打包修 runtimeconfig；若 aspnetcore 源码更新需重新交叉编译后重复本步骤。
aspnetcore 仓库构建时用 `-p:MicrosoftInternalRuntimeAspNetCoreTransportVersion=11.0.0-dev` 会在
restore 阶段因 transport 包无 dev 版本而失败（plan 问题 1），故采用重打包方案。
