# .NET on OpenHarmony — 安装运行总结

**会话周期**：2026-08-14 至 2026-08-18
**最终成果**：.NET SDK 10/11 双版本 + Runtime 10/11 + ASP.NET Core 11 全部在 OpenHarmony 设备上安装、签名、运行验证通过（含 HTTP 服务实测）。

---

## 1. 背景与目标

在 OpenHarmony（HarmonyOS）沙箱环境（`HOME=/storage/Users/currentUser`，uid 20220077）中：

1. 安装 .NET Runtime 11（按微软 manual install 逻辑）
2. 安装 .NET SDK 11，实现 `dotnet run hello.cs` 直接执行单文件
3. 覆盖重装 .NET 10 + 11 双版本（旧版本不支持 AOT，新版本支持）
4. 安装 ASP.NET Core Runtime 11 并实测 HTTP 服务

---

## 2. 环境约束（重要背景）

| 约束 | 说明 |
|---|---|
| 沙箱权限 | 无法读取其他 app 私有沙箱（如微信 appdata）内的文件 |
| 代码签名 | OHOS 只执行带 `.codesign` 段的 ELF；未签名 → EACCES，已签名文件被修改 → EPERM |
| seccomp | 沙箱拦截 `get_mempolicy`（syscall 236）→ SIGSYS 杀进程 |
| JIT W^X | 沙箱拒绝 JIT 的 W^X mprotect → SIGSEGV |
| 无 libicu | OHOS 无 ICU 库 |
| `/tmp` 只读 | erofs 挂载；.NET 共享内存硬编码 `/tmp/.dotnet`，TMPDIR 无效 |
| 离线 | 无 nuget.org 访问（或缺少 linux-ohos-arm64 专用包） |

---

## 3. 阶段一：Runtime 11 安装（08-14）

**突破 3 层障碍**：

1. **微信沙箱权限**：tarball 在 WeChat 私有沙箱（uid 20220167），本进程无法 `open()` → 移至 `Download` 解决
2. **签名机制（最重要发现）**：OHOS 只执行带 `.codesign` 段的 ELF。通过读 harmonybrew 的 `ohos-sdk.rb` formula 找到签名命令：
   ```sh
   binary-sign-tool sign -inFile X -outFile X -selfSign 1
   ```
3. 签完 14 个 ELF 后 runtime 正常运行

**产出**：
- `install-dotnet-runtime.sh`（幂等可重跑，修了管道子 shell 计数器 bug）
- `README-install-dotnet-runtime.md`

---

## 4. 阶段二：SDK 11 安装 — 连破 6 层故障（08-14）

| # | 症状 | 根因 | 修复 |
|---|---|---|---|
| 1 | SIGSYS (Signal 31) | seccomp 拦截 syscall 236 = `get_mempolicy`（CoreCLR GC 初始化探测 NUMA） | 手写汇编 LD_PRELOAD shim（`libnuma-shim.so`）拦截 `syscall()`，236 → ENOSYS |
| 2 | SIGSEGV | JIT W^X 内存保护被沙箱拒绝 | `DOTNET_EnableWriteXorExecute=0` |
| 3 | 缺 ICU | OHOS 无 libicu | `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` |
| 4 | `/tmp` 只读 | .NET 共享内存硬编码 `/tmp/.dotnet`，TMPDIR 无效 | 扩展 shim 拦截路径类 syscall + libc 文件函数，`/tmp/*` → `$TMPDIR/*` |
| 5 | MSBuild NullReference | shim 里 `AT_SYMLINK_NOFOLLOW` 用错值（1 vs arm64 的 **0x100**）→ lstat EINVAL | 修正常量 |
| 6 | 运行产物 EPERM | OHOS AppHostTemplate 自带无效 .codesign 段（路径替换后签名失效），且 build 每次重写 apphost | wrapper 对产物无条件重签 |

**里程碑**：托管代码在 HarmonyOS 跑通；`dotnet-ohos run hello.cs` 一键可用（单文件 app 需 `#:property PublishAot=false`，因 NativeAOT 包不在 nuget.org）。

**产出**：
- `~/.dotnet/libnuma-shim.so`（签名）+ 源码 `numa-shim.S` / `numa-shim.c`
- `~/.dotnet/dotnet-ohos` wrapper（注入全部环境变量 + 自动重签 + run/build 拦截）

---

## 5. 阶段三：重装 .NET 10 + 11 双版本（08-17）

### 5.1 完成项

- 4 个 tarball 解压覆盖 `~/.dotnet`，**47 个 ELF 重签（0 失败）**
- 双版本共存验证：
  - SDKs：`10.0.110-dev` + `11.0.100-dev`
  - Runtimes：`10.0.10-dev` + `11.0.0-dev`
- SDK 11：`hello.cs` 运行 OK；SDK 10：修复后运行 OK

### 5.2 新修 2 个问题

1. **SDK 10 无法启动**：runtimeconfig 请求 stable `10.0.10`，本机只有 prerelease `10.0.10-dev`（roll-forward 不能向下回滚）→
   ```sh
   ln -s 10.0.10-dev "$HOME/.dotnet/shared/Microsoft.NETCore.App/10.0.10"
   ```
   文件式应用另需 `#:property RuntimeFrameworkVersion=10.0.10-dev`
2. **wrapper 选错 apphost**：硬编码 `hello` 名 → 改为按 `.cs` 文件名匹配最新产物

### 5.3 AOT 验证（失败 → 用户决定跳过）

- 实测 `PublishAot=true` 发布失败：缺 3 个 linux-ohos-arm64 专用 nupkg（都不在 nuget.org、不在设备上）：
  - `Microsoft.NETCore.App.Runtime.linux-ohos-arm64`
  - `Microsoft.NETCore.App.Runtime.NativeAOT.linux-ohos-arm64`（25.4MB）
  - `runtime.linux-ohos-arm64.Microsoft.DotNet.ILCompiler`（43.4MB）
  - 另有 NU1102：`Microsoft.AspNetCore.App.Runtime.linux-arm64`
- 全设备定向搜索（~/.nuget、Download、springsources/runtime、浏览器目录、local-feed）确认均无
- 文档确认这些包只在**交叉编译机本地 feed**（`artifacts/ohos-local-feed`），未打进 tarball
- **用户决定：先跳过 AOT 验证**

---

## 6. 阶段四：ASP.NET Core Runtime 11 安装（08-18）

### 6.1 研究结论

安装逻辑与普通 runtime 完全相同（微软 manual install），tarball 内容：

| 内容 | 说明 |
|---|---|
| `shared/Microsoft.AspNetCore.App/11.0.0-dev/` | **137 个托管 dll**（纯托管，无原生 .so）— 真正新增的部分 |
| `shared/Microsoft.NETCore.App/11.0.0-dev/` | 完整 base runtime（同版本，覆盖重签） |
| `host/fxr/11.0.0-dev/` + `dotnet` | host 组件（同版本，覆盖重签） |

### 6.2 安装步骤

```sh
sh install-dotnet-runtime.sh <aspnetcore-runtime-*.tar.gz>
```

自动完成：解压 → 签名 → 环境变量 → 验证。结果：**26 个新 ELF 签名，36 个已签名跳过，0 失败**。

### 6.3 遇到的版本错配与修复

AspNetCore.App 的 runtimeconfig 链请求 `Microsoft.NETCore.App 11.0.0-rc.1.26410.101`，本机只有 `11.0.0-dev`（dev < rc.1，hostfxr roll-forward 不能向下）→ 同款软链修复：

```sh
ln -s 11.0.0-dev "$HOME/.dotnet/shared/Microsoft.NETCore.App/11.0.0-rc.1.26410.101"
```

### 6.4 真实运行验证

csc 编译极简 Kestrel 应用（引用 AspNetCore.App 全部 dll）→ 启动监听：

```
Listening on http://127.0.0.1:5123
curl http://127.0.0.1:5123/  →  "Hello from ASP.NET Core 11.0.0.0 on OHOS" ✅
```

---

## 7. 最终交付物清单

| 文件 | 说明 |
|---|---|
| `~/.dotnet/` | SDK 10.0.110-dev + 11.0.100-dev；Runtimes 10.0.10-dev + 11.0.0-dev；AspNetCore.App 10.0.10 + 11.0.0-dev（全部已签名） |
| `~/.dotnet/dotnet-ohos` | wrapper v3（环境注入 + 无条件重签 + 按文件名选 apphost） |
| `~/.dotnet/libnuma-shim.so` | seccomp 236 拦截 + `/tmp` 重定向（源码 `numa-shim.S/.c`） |
| `~/.dotnet/shared/Microsoft.NETCore.App/10.0.10` | SDK10 修复软链 → `10.0.10-dev` |
| `~/.dotnet/shared/Microsoft.NETCore.App/11.0.0-rc.1.26410.101` | ASP.NET Core 修复软链 → `11.0.0-dev` |
| `~/install-dotnet-runtime.sh` + `README-install-dotnet-runtime.md` | 可复现安装方案（对 runtime/SDK/aspnetcore 通用） |
| `~/hello.cs` | SDK11 单文件回归测试 |

---

## 8. 核心技术沉淀（可复用于其他软件）

1. **OHOS 代码签名**：所有 ELF（含 .so）必须 `binary-sign-tool sign -selfSign 1` 才能执行/加载；已签名文件被修改后签名失效（EPERM），需重签
2. **沙箱兼容层**：
   - seccomp 拦截的系统调用可用 LD_PRELOAD shim 拦截（需纯汇编自实现 syscall，避免 constructor 时机陷阱；shim 本身也要签名）
   - 只读 `/tmp` 可用 shim 路径重定向（`/tmp/*` → `$TMPDIR/*`）
   - arm64 常量注意：`AT_SYMLINK_NOFOLLOW = 0x100`（不是 1）
3. **版本错配修复模式**：prerelease 运行时版本比请求版本低时，用 symlink 目录名补齐（`10.0.10 -> 10.0.10-dev`、`11.0.0-rc.1.26410.101 -> 11.0.0-dev`）
4. **单文件 app**：file-based apps 默认 NativeAOT，缺 AOT 包时需 `#:property PublishAot=false`

---

## 9. 遗留事项

- **AOT**：拿到交叉编译机的 3 个 nupkg 后可建本地 NuGet feed 完成验证（用户已决定暂缓）
- **SDK 10 重装**后需重建软链 `10.0.10 -> 10.0.10-dev`（可考虑写进安装脚本）
- **ASP.NET Core 版本**：AspNetCore.App 11.0.0-dev 依赖 NETCore.App rc.1 版本，软链修复仅在本机布局下有效

---

## 10. 后续：修复已全部内嵌（2026-08-26）

原外部修复（wrapper + libnuma-shim）已内嵌进 SDK/runtime 二进制，详见
[`OHOS-内嵌修复-变更记录.md`](OHOS-内嵌修复-变更记录.md)：

| 原外部修复 | 内嵌方式 | 生效范围 |
|---|---|---|
| LD_PRELOAD shim 拦截 get_mempolicy | runtime `numasupport.cpp` `TARGET_OHOS` 排除 | 所有进程（编译期消灭 SIGSYS） |
| wrapper 导出 W^X=0 | SDK redist runtimeconfig 烘焙 `EnableWriteXorExecute=false` + 应用 MSBuild 属性映射 | SDK 自身进程 + linux-ohos 应用 |
| wrapper 导出 Invariant=1 | SDK redist runtimeconfig 烘焙 `Invariant=true` | SDK 自身进程 |
| shim /tmp 重定向 | runtime `SharedMemoryManager` 改走 `Path.GetTempPath()`（TMPDIR） | 所有进程 |
| wrapper `sign_runfile` | `OhosCodesign` MSBuild task（selfsign.rs C# 移植，字节级一致）AfterTargets Build/Publish | linux-ohos 构建产物（apphost/自包含） |
| wrapper env 导出 | `OhosEnvironmentDefaults.Apply()`（managed Program + AOT ExecuteCore） | 子进程（MSBuild/csc/apphost） |

**新安装流程**（不再需要 `dotnet-ohos` wrapper 与 `libnuma-shim.so`）：

```sh
export DOTNET_ROOT=~/.dotnet
~/.dotnet/dotnet --version
~/.dotnet/dotnet build hello.cs    # apphost 自动 codesign
~/.dotnet/dotnet run hello.cs
```

构建产物验证：SDK tar.gz 内 `dotnet.runtimeconfig.json`/`MSBuild.runtimeconfig.json`/`NuGet.CommandLine.XPlat.runtimeconfig.json`
均含 `System.Runtime.EnableWriteXorExecute=false` + `System.Globalization.Invariant=true`；`Microsoft.NET.Build.Tasks.dll`
含 `OhosCodesign` task（与 rust selfsign 字节级一致）；共享框架 `System.Private.CoreLib.dll`（TMPDIR 修复）与
`libcoreclr.so`（NUMA 修复）哈希与交叉编译产物一致。
