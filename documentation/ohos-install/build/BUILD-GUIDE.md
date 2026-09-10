# OHOS 三仓一键全链构建 · 使用说明

构建 .NET（runtime → aspnetcore → sdk）的 OpenHarmony (OHOS, RID `openharmony-arm64`) 交叉产物。

版本：runtime/aspnetcore `11.0.0-rc.1.26451.109` · SDK `11.0.100-rc.1.26451.109`
（由 `--buildid 20260901.109` 决定；三仓需保持同一版本使 feed 可解析）

---

## 一、入口脚本一览

| 脚本 | 作用 | 位置 |
|---|---|---|
| **`build-ohos-all.sh`** | **全链构建主脚本**（stage0 env 检查 → stage1 runtime → stage2 asset → stage3 aspnetcore → stage4 sdk redist → stage5 collect） | 本目录（git 仓：`documentation/ohos-install/build/`；fork `springmin/sdk-ohos@feature/ohos-cross-sdk` 同路径） |
| `ohos-ci-env.sh` | 干净机一次性环境准备（NDK / OpenSSL / ICU 从零下载编译），供本地与 CI cache 复用 | 同目录 |
| `.github/workflows/ohos-full-build.yml` | CI 版一键全链（workflow_dispatch），环境由 GitHub cache 提供 | sdk 仓根 |
| `install-dotnet-ohos.sh` | **设备端**安装器：从 GitHub release 装 SDK/Runtime 到 OHOS（非构建） | `documentation/ohos-install/` |
| `sign-ohos-release.sh` | 主机侧预签名（OHOS 仅执行带 `.codesign` 的 ELF） | 同目录 |

## 二、一键全链（推荐路径）

### A. GitHub Actions（最省心，干净环境，产物自动上传）
```sh
gh workflow run ohos-full-build.yml --repo springmin/sdk-ohos \
  --ref feature/openharmony -f buildid=20260901.109
```
- runner：ubuntu-24.04（4 核/16GB）；NDK/OpenSSL/ICU 由 cache `ohos-ci-env-openharmony-arm64-<hash>` 提供（首次 ~30 min 准备，之后命中）。
- 产物：run 页 artifact `ohos-build-openharmony-arm64-<buildid>`（28–29 文件，保留 30 天）。

### B. 本地一键（增量，复用已编译环境）
```sh
# 前置 env（deps 已就绪时直接复用；干净机先跑 ./ohos-ci-env.sh 产出同款目录）
export OHOS_NDK_HOME=/home/springmin/dotnet/deps/ohos-sdk
export OPENSSL_DIR=/home/springmin/dotnet/deps/openssl/install
export ICU_DIR=/home/springmin/dotnet/deps/icu/install
export RUNTIME_REPO=/home/springmin/dotnet/runtime-ohos
export SDK_REPO=/home/springmin/dotnet/sdk-ohos
export ASCORE_REPO=/home/springmin/dotnet/aspnetcore-ohos

sh build-ohos-all.sh                    # 默认全链；BUILDID 默认 20260901.109
```
> 脚本内三仓路径默认 `~/sources/{runtime,sdk,aspnetcore-ohos}`；当前完整工作区位于
> `~/dotnet/{runtime-ohos,sdk-ohos,aspnetcore-ohos}`，故用上面的显式 env 指向。

## 三、常用参数

```sh
sh build-ohos-all.sh \
  [--arch arm64] [--rid openharmony-arm64] [--config Release] \
  [--buildid 20260901.109] \
  [--skip-runtime|--skip-aspnetcore|--skip-sdk] \   # 跳过某仓（需其产物已在 feed）
  [--stage-only 1|3|4]                              # 只跑单个 stage（1=runtime…）
```

## 四、前置条件（不是裸跑就能过）

1. 三仓源码在 `RUNTIME_REPO/SDK_REPO/ASCORE_REPO` 指向的路径，且各自 `.dotnet` bootstrap SDK 已就位（runtime `global.json` 用 `11.0.100-rc.1.26420.103`，并已注入 ohos RID graph）。
2. 交叉工具链产物（脚本 stage0 会逐一校验，缺则 die）：
   - `OHOS_NDK_HOME`：OHOS NDK（需含 `native/build/cmake/ohos.toolchain.cmake` + `aarch64-linux-ohos` 编译器 wrapper）
   - `OPENSSL_DIR/lib/libcrypto.a`、`ICU_DIR/lib`：**为目标 RID 交叉编译**的产物
   - 本地已固化于 `/home/springmin/dotnet/deps/{ohos-sdk,openssl,icu}`；干净机用 `ohos-ci-env.sh` 重建。
3. 网络：构建期需访问 dnceng/azureedge/ci.dot.net 拉取官方包（本地偶发停滞时，SDK 构建所需的 6.0.36/7.0.20/8.0.30/9.0.19/10.0.11/11.0.0-rc.1.26452.110 runtime 可预装进 `sdk/.dotnet/shared/` 使 dotnetup 跳过）。

## 五、产物位置

- 本地收集：`sdk-ohos/documentation/ohos-install/.work/output/`（29 文件）
- 各仓自身 Shipping：`<repo>/artifacts/packages/Release/Shipping/`（含
  `dotnet-sdk-11.0.100-rc.1.26451.109-openharmony-arm64.tar.gz` 160MB、runtime/aspnetcore tar、
  NativeAOT/ILCompiler/Host/Crossgen2/Ref 等 nupkg，均已 `.codesign` 预签名）
- SDK redist 目录：`<sdk>/artifacts/bin/redist/Release/dotnet`（内嵌 real runtime 26451.109）
- 设备部署：见 `DEVICE-DEPLOYMENT.md` 示例（hdc 推送 + 自包含应用直跑）。

## 六、验证（qemu-aarch64 冒烟，可选）

用 `~/dotnet/deps/qemu-rootfs`（musl + arc4 shim + libc++_shared）：
`dotnet --info` → RID=`openharmony-arm64`、版本 `11.0.0-rc.1.26451.109`；托管应用 exit 0。
