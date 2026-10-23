#!/usr/bin/env bash
# Phase 1：把 SukiSU Ultra（builtin 分支，固定 commit）以源码方式并入内核树。
# 不使用官方 KernelSU v0.9.5 的 setup.sh，也不使用 SukiSU 的 setup.sh 自动流程；
# 这里做可复现的 vendoring + 两行 Makefile/Kconfig + 手动 hook 补丁。
#
# 用法：bash scripts/apply-sukisu.sh kernel
set -euo pipefail

KERNEL_DIR="${1:-kernel}"
SUKISU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra"
SUKISU_BRANCH="builtin"
SUKISU_COMMIT="ce75122bec74"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[*] Fetch SukiSU Ultra ${SUKISU_BRANCH} @ ${SUKISU_COMMIT}"
git -C "$WORK" init -q
git -C "$WORK" remote add origin "$SUKISU_REPO"
if git -C "$WORK" fetch --depth 1 origin "$SUKISU_COMMIT" 2>/dev/null; then
  git -C "$WORK" checkout -q FETCH_HEAD
else
  echo "[!] 直接 fetch commit 失败，退回 shallow clone 分支并校验 HEAD"
  rm -rf "$WORK" && mkdir -p "$WORK"
  git clone --depth 1 --branch "$SUKISU_BRANCH" "$SUKISU_REPO" "$WORK/sukisu"
  WORK="$WORK/sukisu"
  HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
  case "$HEAD_SHA" in
    "$SUKISU_COMMIT"*) echo "[+] HEAD 与固定 commit 一致" ;;
    *) echo "[!] 警告：分支 HEAD=${HEAD_SHA} 与固定 commit=${SUKISU_COMMIT} 不一致（上游已移动）" ;;
  esac
fi

test -d "$WORK/kernel" || { echo "[!] SukiSU 源码里没有 kernel/ 目录"; exit 1; }

echo "[*] 拷贝 kernel/ -> drivers/kernelsu"
rm -rf "$KERNEL_DIR/drivers/kernelsu"
cp -r "$WORK/kernel" "$KERNEL_DIR/drivers/kernelsu"

echo "[*] 注册到 drivers/Makefile 与 drivers/Kconfig"
grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile" || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

echo "[*] 应用 4.19 手动 hook 补丁"
PATCH="$(pwd)/scripts/patches/4.19-manual-hooks.patch"
if [ -f "$PATCH" ]; then
  git -C "$KERNEL_DIR" apply --whitespace=nowarn "$PATCH"
  echo "[+] hook 补丁已应用"
else
  echo "[!] 缺少 $PATCH"
  echo "    Phase 1 需要为 4.19 准备手动 hook 补丁（exec/open/stat/namespace/...），"
  echo "    否则内核能编译但 root 不工作。请先生成该补丁再跑 Phase 1。"
  exit 2
fi

echo "[+] SukiSU Ultra vendoring 完成"
