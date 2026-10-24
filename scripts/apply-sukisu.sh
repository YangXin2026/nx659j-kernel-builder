#!/usr/bin/env bash
# Phase 1：SukiSU Ultra（main，kprobe hook）+ 4.19 KPROBES 修正 + uapi 头
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

# 仓库根的 uapi/ 是 policy 需要的头（app_profile.h 等）
if [ -d "$WORK/sukisu/uapi" ]; then
  rm -rf "$KERNEL_DIR/drivers/kernelsu/uapi"
  cp -r "$WORK/sukisu/uapi" "$KERNEL_DIR/drivers/kernelsu/uapi"
  echo "[+] uapi/ -> drivers/kernelsu/uapi"
fi

grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile" || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

echo "[*] 检查 Kconfig 注入"
grep -n 'kernelsu' "$KERNEL_DIR/drivers/Kconfig" | tail -2 || true
ls -l "$KERNEL_DIR/drivers/kernelsu/Kconfig" || true
ls -l "$KERNEL_DIR/drivers/kernelsu/uapi/app_profile.h" 2>/dev/null || true

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

# 4.19 没有 MODULE_IMPORT_NS，去掉 KSU 的命名空间导入
INIT="$KERNEL_DIR/drivers/kernelsu/core/init.c"
if [ -f "$INIT" ]; then
  python3 - "$INIT" <<'PY2'
import sys
p=sys.argv[1]; s=open(p).read()
for pat in [
 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);',
 'MODULE_IMPORT_NS("VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver");',
]:
    s=s.replace(pat,'')
open(p,'w').write(s)
print('removed MODULE_IMPORT_NS for 4.19')
PY2
fi
