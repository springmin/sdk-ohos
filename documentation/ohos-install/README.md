# .NET for OpenHarmony — 安装指南

在 OpenHarmony 设备上安装 .NET SDK / Runtime（含 ASP.NET Core），自动完成
OHOS 特有的代码签名。

**适用于**：2026-08-26 及之后构建的产物（SDK 内嵌全部 OHOS 修复 + ASP.NET Core runtime）。

---

## 1. 下载产物（GitHub Release）

三个仓库的 Release 提供交叉编译好的 `linux-ohos-arm64` 产物：

| 仓库 | Release | 内容 | 下载 |
|---|---|---|---|
| [springmin/sdk-ohos](https://github.com/springmin/sdk-ohos/releases) | `v11.0.100-dev-ohos` | **SDK**（含 ASP.NET Core runtime + 全部修复，175MB） | `dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz` |
| [springmin/runtime-ohos](https://github.com/springmin/runtime-ohos/releases) | `v11.0.0-dev-ohos` | **Runtime**（仅运行，15MB） | `dotnet-runtime-11.0.0-dev-linux-ohos-arm64.tar.gz` |
| [springmin/aspnetcore-ohos](https://github.com/springmin/aspnetcore-ohos/releases) | `11.0.0-dev-ohos` | **ASP.NET Core**（单独分发用，19MB） | `aspnetcore-runtime-11.0.0-dev-linux-ohos-arm64.tar.gz` |

> **推荐**：直接安装 **SDK** 即可——它已内嵌 ASP.NET Core runtime，
> 一个包同时满足编译与运行（含 web 应用）。Runtime 包仅用于只想运行 .NET
> 应用的场景。

> ⚠️ **重要**：文件下载后请移动到当前用户可读的目录（如 `Download/`）。
> 若文件位于其他应用沙箱内（如微信收到的文件），OpenHarmony 会拒绝读取。

## 2. 安装

### 方式 A：一键脚本（推荐）

```sh
# 1. 下载脚本到设备（任意可写目录）
#    从 sdk-ohos 仓库获取，或本地已有

# 2. 安装最新 SDK（含 ASP.NET Core）
sh install-dotnet-ohos.sh sdk

# 3. 或安装最新 Runtime
sh install-dotnet-ohos.sh runtime

# 4. 或用本地文件 / 自定义 URL
sh install-dotnet-ohos.sh ~/Download/dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz
sh install-dotnet-ohos.sh https://github.com/springmin/sdk-ohos/releases/download/v11.0.100-dev-ohos/dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz

# 5. 自定义安装目录
INSTALL_DIR=/data/xxx/dotnet sh install-dotnet-ohos.sh sdk
```

脚本自动完成：
1. 从 GitHub Release 下载（或使用本地 tar.gz）
2. 解压到 `$HOME/.dotnet`（默认）
3. 为所有 ELF 二进制添加 `.codesign` 签名段
4. 写入 `DOTNET_ROOT` + `PATH` 到 `~/.bashrc` / `~/.zshrc` / `~/.profile`（已存在则跳过）
5. `dotnet --list-runtimes` 验证

### 方式 B：手动安装

```sh
export DOTNET_ROOT=$HOME/.dotnet
mkdir -p "$DOTNET_ROOT"
tar zxf dotnet-sdk-11.0.100-dev-linux-ohos-arm64.tar.gz -C "$DOTNET_ROOT"
# 签名（见 §3）
export PATH=$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools
dotnet --list-runtimes
```

## 3. 代码签名（OHOS 特有）

OpenHarmony 只执行带 `.codesign` 段的 ELF。**Release 产物未预签名**，
解压后必须签名（`execve` 未签名 → `EACCES`）。

脚本按顺序使用签名工具：
1. `binary-sign-tool`（OHOS SDK / harmonybrew，自动探测）
2. `selfsign`（仓库提供的 C# AOT 单文件签名工具，见下方）

`selfsign` 使用说明（源码见本目录 `selfsign.cs` + `selfsign.csproj`）：

```sh
# 在设备上构建（需要 .NET SDK）：
#   复制 selfsign.cs + selfsign.csproj 到设备，然后：
dotnet publish selfsign.csproj -c Release -r linux-ohos-arm64   # AOT 单文件
# 或普通模式（需 .NET runtime）：
dotnet publish selfsign.csproj -c Release -p:PublishAot=false

# 用法与 binary-sign-tool 兼容：
selfsign <input_elf> [output_elf] [--force] [--strip]
```

> `selfsign` 是 SDK 内置 `OpenHarmonyCodesign` MSBuild task（`ElfSelfSigner`）的
> 独立单文件版本，算法与官方 `binary-sign-tool` 字节级一致，可在设备上
> 独立运行（不依赖 MSBuild）。已在 qemu（aarch64 OHOS 环境）验证签名结果
> 与官方工具字节级一致。

## 4. 验证

```sh
dotnet --list-sdks        # 应显示 11.0.100-dev
dotnet --list-runtimes    # 应显示 11.0.0-dev（含 Microsoft.AspNetCore.App）
dotnet --info             # RID: linux-ohos-arm64

# 编译并运行一个 ASP.NET Core 应用（SDK 已内嵌 aspnetcore runtime）
dotnet new web -o hello && cd hello
dotnet run                # 自动 codesign 产物，开箱即用
```

## 5. 内嵌修复说明（2026-08-26 起）

SDK/Runtime 已内嵌全部 OHOS 沙箱修复，**不再需要**外部 wrapper / LD_PRELOAD shim：

| 修复 | 内嵌方式 |
|---|---|
| SIGSYS（get_mempolicy 被 seccomp 拦截） | runtime `numasupport.cpp` `TARGET_OPENHARMONY` 排除（编译期消灭） |
| JIT W^X 被沙箱拒绝 | SDK runtimeconfig 烘焙 `EnableWriteXorExecute=false` |
| 无 ICU | SDK runtimeconfig 烘焙 `Invariant=true` |
| `/tmp` 只读 | runtime 共享内存改走 `Path.GetTempPath()`（TMPDIR） |
| 构建产物签名 | `OpenHarmonyCodesign` MSBuild task（Build/Publish 后自动） |
| 子进程环境 | `OpenHarmonyEnvironmentDefaults`（TMPDIR/遥测/nologo） |

详见同目录 [`../../../installonohos/OHOS-内嵌修复-变更记录.md`](../../installonohos/OHOS-内嵌修复-变更记录.md)。

## 6. 常见问题

**Q: 报错 `tarball not readable`**
文件在另一个应用的私有沙箱里。用文件管理器把文件移到 `Download` 后重试。

**Q: 报错 `binary-sign-tool not found` + 无 `selfsign`**
两种签名工具都缺失。安装 OHOS SDK / harmonybrew，或把 `selfsign` 加入 PATH。

**Q: `dotnet --version` 提示 "No SDKs were found"**
装的是 Runtime 包。运行/编译应用需安装 SDK 包（`sh install-dotnet-ohos.sh sdk`）。

**Q: 签名报 `failed=N`**
个别文件签名失败不会中断（仅警告），但 `failed > 0` 会终止安装。重跑脚本即可。
