#!/usr/bin/env bash
# Phase 1：SukiSU Ultra（main，kprobe hook）+ 修 4.19 KPROBES 可选性
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

echo "[*] 检查 Kconfig 注入"
grep -n 'kernelsu' "$KERNEL_DIR/drivers/Kconfig" | tail -2 || true
ls -l "$KERNEL_DIR/drivers/kernelsu/Kconfig" || true

echo "[*] 修 4.19 KPROBES：去掉 depends on MODULES 判定"
python3 - "$KERNEL_DIR/arch/Kconfig" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
new = re.sub(r'(config KPROBES\n\tbool "Kprobes"\n)(\tdepends on MODULES\n)', r'\1', s, count=1)
if new == s:
    print("[!] 未匹配到 KPROBES 定义，保持原样")
else:
    open(p, 'w').write(new)
    print("[+] arch/Kconfig KPROBES 依赖已调整")
PY

grep -A4 '^config KPROBES' "$KERNEL_DIR/arch/Kconfig" | head -6
echo "[+] SukiSU vendoring 完成（kprobe 模式）"
# 修正 KSU policy 的 uapi 头路径
AP=$(find "$KERNEL_DIR/drivers/kernelsu" -name app_profile.h 2>/dev/null | head -1)
if [ -n "$AP" ]; then
  mkdir -p "$KERNEL_DIR/drivers/kernelsu/policy/uapi"
  cp "$AP" "$KERNEL_DIR/drivers/kernelsu/policy/uapi/app_profile.h"
  echo "[+] app_profile.h -> policy/uapi"
fi
