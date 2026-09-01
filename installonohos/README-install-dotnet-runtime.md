# .NET Runtime 安装脚本 — OpenHarmony (OHOS)

一键在 OpenHarmony 设备上安装 .NET Runtime（来自官方 tar.gz 二进制包），
并自动完成 OHOS 特有的代码签名步骤。

- 脚本：`install-dotnet-runtime.sh`
- 安装位置：默认 `$HOME/.dotnet`
- 逻辑依据：微软官方文档 [在 Linux 上手动安装 .NET](https://learn.microsoft.com/zh-cn/dotnet/core/install/linux-scripted-manual#manual-install)

---

## 1. 前置条件

| 条件 | 说明 |
|---|---|
| .NET Runtime 二进制包 | 形如 `dotnet-runtime-11.0.0-rc.1.26451.1-ohos-arm64.tar.gz`，**必须放在当前用户可读的位置**（如 `Download/`） |
| `binary-sign-tool` | OpenHarmony SDK 自带（`toolchains/lib/binary-sign-tool`），脚本会自动在 PATH、`~/.harmonybrew`、OHOS SDK 目录中查找 |
| `tar` / `file` / `readelf` | 基础工具，脚本启动时会检查 |

> ⚠️ **重要**：文件如果位于其他应用沙箱内（例如微信收到的文件在
> `appdata/.../com.tencent.wechat.pc/...`），OpenHarmony 会拒绝本 shell 读取。
> 请先在文件管理器/微信中把文件移动/另存到 `Download` 等共享目录。

## 2. 快速开始

```sh
# 基本用法
sh install-dotnet-runtime.sh ~/Download/dotnet-runtime-11.0.0-rc.1.26451.1-ohos-arm64.tar.gz

# 指定安装目录（默认 $HOME/.dotnet）
sh install-dotnet-runtime.sh ~/Download/dotnet-runtime-11.0.0-rc.1.26451.1-ohos-arm64.tar.gz /data/xxx/dotnet
```

运行成功后，重新打开终端（或 `source ~/.bashrc`），即可使用：

```sh
dotnet --list-runtimes     # 查看已安装运行时
dotnet --info              # 查看主机信息
```

## 3. 脚本做了什么

| 步骤 | 动作 | 对应官方文档 |
|---|---|---|
| 1 | 检查 tarball 可读、必要工具存在 | — |
| 2 | `mkdir -p` + `tar zxf` 解压到安装目录 | `mkdir -p "$DOTNET_ROOT" && tar zxf "$DOTNET_FILE" -C "$DOTNET_ROOT"` |
| 3 | 找到 `binary-sign-tool`，为所有 ELF 二进制添加 `.codesign` 签名段 | **OHOS 特有（见 §5）** |
| 4 | 向 `~/.bashrc`、`~/.zshrc`、`~/.profile` 写入环境变量（已存在则跳过） | `export DOTNET_ROOT=...` + `export PATH=$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools` |
| 5 | 运行 `dotnet --list-runtimes` 验证 | — |

## 4. 卸载 / 重新安装

```sh
# 卸载：删除安装目录与环境变量
rm -rf ~/.dotnet
# 并从 ~/.bashrc ~/.zshrc ~/.profile 中删除 DOTNET_ROOT / PATH 两行

# 重新安装：直接重跑脚本即可（幂等，可安全重复执行）
sh install-dotnet-runtime.sh ~/Download/dotnet-runtime-11.0.0-rc.1.26451.1-ohos-arm64.tar.gz
```

## 5. 为什么需要签名（OHOS 特有）

OpenHarmony 只允许执行带有 `.codesign` 段的 ELF 二进制。未签名的程序
即使权限为 755、属主正确，`execve()` 也会返回 `EACCES`（"Permission denied"）。
症状：`/bin/sh: xxx: Permission denied`，退出码 126。

脚本使用 OHOS SDK 的 `binary-sign-tool sign -inFile F -outFile F -selfSign 1`
为每个 ELF 文件（`dotnet`、`libhostfxr.so`、`libcoreclr.so` 等）添加签名段。

> 若以后手动替换/重下二进制，记得重新签名，否则会再次无法执行。

## 6. 常见问题

**Q: 报错 `tarball not readable`**
文件在另一个应用的私有沙箱里。用文件管理器把文件移到 `Download` 后重试。

**Q: 报错 `binary-sign-tool not found`**
需要安装 OpenHarmony SDK（或 harmonybrew）并把 `binary-sign-tool` 加入 PATH，
或手动指定其路径。

**Q: `dotnet --version` 提示 "No SDKs were found"**
正常现象。本脚本安装的是 **Runtime**（仅用于运行 .NET 应用）。需要编译
（`dotnet build` / `csc`）时请另外安装 .NET SDK。

**Q: 签名报 `failed=N`**
个别文件签名失败不会中断（仅警告），但 `failed > 0` 会终止安装。
可重新运行脚本重试。

**Q: 重复运行会重复写环境变量吗**
不会。脚本会先检查各 profile 是否已含 `export DOTNET_ROOT=`，已存在则跳过。

---

## 7. 新版本：统一安装脚本

> **2026-08-26 起**推荐使用新的一体化安装脚本（支持 SDK/Runtime 下载 +
> 自动签名 + ASP.NET Core 内嵌）：
>
> 📄 [`documentation/ohos-install/`](../documentation/ohos-install/) —
> `install-dotnet-ohos.sh` + `README.md` + `selfsign.cs`
>
> 本脚本（`install-dotnet-runtime.sh`）保留用于旧版 runtime 包安装。
