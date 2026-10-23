# kernel-builder · 4.19-kona-ksu-a16fix-oc

用于 NX659J（kona/SM8250，非 GKI 4.19.325）的内核云编译。主线是 **A16/GSI 兼容地基 + FOD 链路可开可关 + GPU 超频（独立 Phase）**；SukiSU Ultra 是 Phase 1 附带项。

## 阶段

| Phase | 内容 | 是否改原 defconfig | CI 是否合并 a16fix.config |
|---|---|---|---|
| **0（先做）** | 基线：无 SukiSU、无超频 | 否 | 否 |
| 1 | SukiSU Ultra builtin @ `ce75122bec74` + hook + Section D | 否 | 是 |
| 2 | A16/GSI 兼容 + FOD 节点/驱动（Section A/B） | 否 | 是 |
| 3 | GPU 超频（Section C，独立构建/可回退） | 否 | 是（单独） |

内核命名：`4.19.325-kona-ksu-a16fix-oc`（由 `LOCALVERSION` 注入）。

## GitHub Actions 用法（推荐）

1. 新建仓库，把本目录内容推上去（仓库根 = `kernel-builder/`）。
2. Actions → `4.19-kona-ksu-a16fix-oc` → Run workflow：
   - `phase=0`（基线）
   - `localversion=kona-ksu-a16fix-oc`
3. 产物：`Image.gz`、`Image`、`vmlinux`、`System.map`、`.config`、`build.log`、`sha256sums.txt`。
4. **CI 不生成/不修改 boot.img，不碰 boot 头字段/AVB。**

## 本地单 runner（WSL2 Ubuntu）——没有 GitHub 仓库时

前置：安装 WSL2 + Ubuntu（约 1GB 内），在 WSL 内：

```bash
sudo apt-get update
sudo apt-get install -y bc bison flex libssl-dev libelf-dev python3 zip unzip cpio rsync git \
  binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu
git clone --depth 1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_nubia_sm8250 kernel
git clone --depth 1 https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b clang
PHASE=0 KERNEL_DIR=kernel CLANG_DIR=clang bash scripts/build.sh configure
PHASE=0 KERNEL_DIR=kernel CLANG_DIR=clang bash scripts/build.sh build 2>&1 | tee build.log
bash scripts/build.sh checksums
```

> 磁盘：内核源码 + 构建产物约 8–12GB，请确保 WSL 所在盘空间足够（当前 E: 约 16GB 可用，偏紧；GitHub Actions 更稳）。

## 本地重打包 boot.img（Phase 0 验证）

```bash
python scripts/repack_boot.py \
  --base D:/rom-los/boot.img \
  --kernel out/arch/arm64/boot/Image.gz \
  --out boot-4.19-kona-ksu-a16fix-oc.img
```

- 以干净 LOS boot 为基（不是 Magisk 版；单 SukiSU 验证用）；
- 仅替换 kernel，ramdisk/dtb/cmdline/base/pagesize/header 等原样保留；
- 输出 sha256；保留 `magisk-boot-gsi.img` 作为回滚 boot。

## fastboot boot 验证（不刷写）

```bash
adb devices
adb reboot bootloader
fastboot devices
fastboot boot boot-4.19-kona-ksu-a16fix-oc.img
adb wait-for-device
adb shell uname -a          # 应含 kona-ksu-a16fix-oc
adb shell getprop sys.boot_completed
```

Phase 0 通过判据：能启动、`sys.boot_completed=1`、显示/触摸/WiFi 基线正常。
Phase 1 额外：SukiSU Manager 显示 Working、`su -c id`；因隐藏符号，`/proc/kallsyms` 看不到 ksu 属正常。

## 目录

```
.github/workflows/build.yml   # CI
configs/a16fix.config         # 分段：A16/GSI / FOD / GPU OC / SukiSU
scripts/build.sh              # configure/build/checksums
scripts/apply-sukisu.sh       # Phase 1 vendoring（固定 commit）
scripts/repack_boot.py        # 本地重打包（不碰 header）
scripts/patches/              # Phase 1 的 4.19 手动 hook 补丁（待生成）
tools/mkbootimg.py            # vendored AOSP 工具
tools/unpack_bootimg.py
```

## 注意
- 不修改 `arch/arm64/configs/vendor/kona-perf_defconfig` 与 `nx659j.config`；只通过 `a16fix.config` 追加。
- Phase 1 的 hook 补丁尚未生成：脚本会检测 `scripts/patches/4.19-manual-hooks.patch`，缺失时直接失败（避免产出"能编译但 root 不工作"的内核）。
- GPU 超频不是 defconfig 能完成的，属 DT/驱动频率表改动，Phase 3 单独分支/单独构建。

## 方案 A：GitHub 仓库 + Actions（两种上手方式）

### A1 全自动（需要 PAT）
1. 创建 PAT（二选一）：
   - 经典 PAT：勾选 `repo` + `workflow`
   - 细粒度 PAT：`Administration: RW`（建仓库）、`Contents: RW`、`Workflows: RW`、`Actions: RW`
2. 在本目录执行（PowerShell）：
   ```powershell
   $env:GITHUB_TOKEN = "ghp_xxx"        # 或用细粒度 token
   python scripts/github_publish.py --repo nx659j-kernel-builder --phase 0 --wait
   ```
   脚本会：建空仓库 → 用 Git Data API 上传全部文件（无需 git）→ 触发 workflow → 等待 → 下载 artifacts zip。
3. 用完建议在 GitHub 设置里吊销 token。

### A2 手动（不需要 token）
1. 把 `kernel-builder.zip` 解压到本地；
2. GitHub 新建空仓库（不要勾 README）；
3. 在仓库页面 **Add file → Upload files**，把解压后的全部内容拖进去（含 `.github/` 目录），Commit；
4. Actions → `4.19-kona-ksu-a16fix-oc` → **Run workflow**：`phase=0`；
5. 构建完成后下载 artifact，把 zip 发我/放到工作区，我做本地 boot 重打包与验证。