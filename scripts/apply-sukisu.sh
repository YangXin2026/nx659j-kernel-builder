#!/usr/bin/env bash
# Phase 1：把 SukiSU Ultra（main 分支，kprobe hook）以源码方式并入内核树。
# 4.19 走 CONFIG_KPROBES，无需手动 hook 补丁。
set -euo pipefail

KERNEL_DIR="${1:-kernel}"
SUKISU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra"
SUKISU_BRANCH="main"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[*] Clone SukiSU Ultra ${SUKISU_BRANCH}"
git clone --depth 1 --branch "$SUKISU_BRANCH" "$SUKISU_REPO" "$WORK/sukisu"

test -d "$WORK/sukisu/kernel" || { echo "[!] 没有 kernel/ 目录"; exit 1; }

echo "[*] 拷贝 kernel/ -> drivers/kernelsu"
rm -rf "$KERNEL_DIR/drivers/kernelsu"
cp -r "$WORK/sukisu/kernel" "$KERNEL_DIR/drivers/kernelsu"

grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile" || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

echo "[+] SukiSU Ultra vendoring 完成（kprobe 模式）"