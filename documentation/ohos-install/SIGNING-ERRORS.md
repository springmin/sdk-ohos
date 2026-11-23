# 签名错误码（NETSDK1248–NETSDK1251）

> 适用于 `sdk-ohos` 构建的 .NET for OpenHarmony SDK。构建/发布到
> `openharmony-*` RID 时，SDK 会给输出目录里的 ELF 写入 `.codesign` 段；
> 这些诊断来自 `OpenHarmonyCodesign` / `ElfSigner`。

> **编号说明**：上游 `dotnet/sdk` 已把 `NETSDK1247` 用于
> `PublishInputFileNotFound`，所以 OpenHarmony 的签名错误码从
> **NETSDK1248** 开始，到 **NETSDK1251** 结束。看到 `NETSDK1247` 时请按上游
> 的“publish 输入文件缺失”处理，不要和签名问题混淆。

| 代码 | 含义 | 级别 |
|---|---|---|
| [NETSDK1248](#netsdk1248) | 签名时无法枚举输出目录 | error |
| [NETSDK1249](#netsdk1249) | 单个 ELF 文件签名失败 | error |
| [NETSDK1250](#netsdk1250) | 文件已有其他签名者的 `.codesign`，保留未改 | warning |
| [NETSDK1251](#netsdk1251) | 签名时跳过符号链接 | warning |

## NETSDK1248

```text
NETSDK1248: Failed to enumerate '{0}' while signing OpenHarmony outputs: {1}
```

签名任务无法枚举 `{0}` 目录，`{1}` 是底层 I/O 或权限错误。

处理：

- 确认输出目录存在，且运行构建的用户可读；
- 看 `{1}` 的具体异常（权限、构建期间目录被删、网络盘断开等）；
- 关闭可能锁定输出树的进程（杀毒、编辑器、文件监视器）后重试；
- 自定义 `OutputPath` / `PublishDir` 时，确认路径在构建机上有效。

## NETSDK1249

```text
NETSDK1249: Failed to sign '{0}': {1}
```

签名任务对单个文件 `{0}` 失败，`{1}` 是底层错误。

处理：

- 常见原因：不是合法的 ELF64、只读/被锁定、磁盘满、文件系统不支持原地写；
- 删除 `bin` / `obj` 后重新构建；
- 确认文件可写、没有被其他进程占用；
- 确认输出是目标架构的 ELF64；`.dll`、`.pdb`、`.json`、`.hap` 等已知非可执行
  扩展名会被跳过，其他格式不应出现在可执行输出里；
- 输出目录里有不该签名的文件时，把它移出输出树再签名。

## NETSDK1250

```text
NETSDK1250: '{0}' carries a .codesign section that this signer did not create;
it was left untouched. Run 'dotnet selfsign --force' to replace it with a
self-signature.
```

文件已有其他签名者写入的 `.codesign`，SDK 不静默覆盖，保留原签名并给出警告。

处理：

- 原签名对目标设备有效时，保持默认行为即可；
- 需要换成 SDK 的自签名时：

  ```sh
  dotnet selfsign --force <file>
  ```

  该命令原地重签，下一次 build/publish 会保留新签名。替换签名会改变被签内容，
  只在原签名不是设备要验证的签名时使用。

## NETSDK1251

```text
NETSDK1251: Skipping symbolic link '{0}' while signing OpenHarmony outputs:
signing never follows links outside the output tree.
```

签名器不跟随文件/目录符号链接，避免改写到输出树之外的目标。这是预期警告。

处理：

- 链接指向输出树外时，警告正常；真正要签名的文件应在它实际所在的位置签；
- 需要把链接目标作为输出的一部分签名时，用文件副本替换链接，或单独签真实目标；
- 链接是有意保留、且目标已签名时，无需处理。

## 相关文档

- [安装指南 §3 代码签名](README.md)
- NativeAOT 发布：[NATIVE-AOT.md](NATIVE-AOT.md)
