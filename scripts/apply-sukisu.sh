#!/usr/bin/env bash
# Phase 1：SukiSU Ultra old 分支（老内核兼容版，扁平结构 + kernel_compat.h）
set -euo pipefail

KERNEL_DIR="${1:-kernel}"
SUKISU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra"
SUKISU_BRANCH="old"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[*] Clone SukiSU Ultra ${SUKISU_BRANCH}"
git clone --depth 1 --branch "$SUKISU_BRANCH" "$SUKISU_REPO" "$WORK/sukisu"

test -d "$WORK/sukisu/kernel" || { echo "[!] 没有 kernel/ 目录"; exit 1; }

echo "[*] 拷贝 kernel/ -> drivers/kernelsu"
rm -rf "$KERNEL_DIR/drivers/kernelsu"
cp -r "$WORK/sukisu/kernel" "$KERNEL_DIR/drivers/kernelsu"

# 旧分支的 uapi 头（若有）
if [ -d "$WORK/sukisu/uapi" ]; then
  cp -r "$WORK/sukisu/uapi" "$KERNEL_DIR/drivers/kernelsu/uapi"
fi

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
echo "[+] SukiSU old vendoring 完成"

# 4.19 没有 MODULE_IMPORT_NS
grep -rl 'MODULE_IMPORT_NS' "$KERNEL_DIR/drivers/kernelsu" 2>/dev/null | while read f; do
  sed -i '/MODULE_IMPORT_NS/d' "$f"
done

# 4.19 allowlist: TWA_RESUME / put_task_struct
AL="$KERNEL_DIR/drivers/kernelsu/allowlist.c"
if [ -f "$AL" ]; then
  grep -q 'linux/sched/task.h' "$AL" || sed -i '1i #include <linux/sched/task.h>' "$AL"
  sed -i 's/TWA_RESUME/true/g' "$AL"
  echo "allowlist TWA_RESUME"
fi

# 4.19 struct seccomp 没有 filter_count（old 分支）
AP="$KERNEL_DIR/drivers/kernelsu/app_profile.c"
if [ -f "$AP" ]; then
  python3 - "$AP" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'^\s*atomic_set\(&(?:current|tsk)->seccomp\.filter_count, 0\);\n','',s,flags=re.M)
open(p,'w').write(s)
print('app_profile filter_count old')
PY
fi

# 4.19: pkg_observer 新 fsnotify API，stub
PO="$KERNEL_DIR/drivers/kernelsu/pkg_observer.c"
if [ -f "$PO" ]; then
  cat > "$PO" <<'EOF'
#include <linux/kernel.h>

int ksu_observer_init(void)
{
    return 0;
}

void ksu_observer_exit(void)
{
}
EOF
  echo "pkg_observer stub"
fi

# 4.19 setuid_hook 兼容
SH="$KERNEL_DIR/drivers/kernelsu/setuid_hook.c"
if [ -f "$SH" ]; then
  sed -i '1i #define ksu_seccomp_allow_cache(...) do { } while (0)\n#define ksu_seccomp_clear_cache(...) do { } while (0)' "$SH"
  sed -i 's/TWA_RESUME/true/g' "$SH"
  grep -q 'linux/sched/task.h' "$SH" || sed -i '1i #include <linux/sched/task.h>' "$SH"
  echo "setuid_hook 4.19"
fi

# 4.19: 全局替换 TWA_RESUME
grep -rl 'TWA_RESUME' "$KERNEL_DIR/drivers/kernelsu" 2>/dev/null | while read f; do
  sed -i 's/TWA_RESUME/true/g' "$f"
done
echo "TWA_RESUME global"

# 4.19 file_wrapper 兼容
FW="$KERNEL_DIR/drivers/kernelsu/file_wrapper.c"
if [ -f "$FW" ]; then
  python3 - "$FW" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('return orig->f_op->iopoll(kiocb, icb, v);','return -EOPNOTSUPP;')
s=s.replace('return orig->f_op->iopoll(kiocb, spin);','return -EOPNOTSUPP;')
s=re.sub(r'^\s*p->ops\.iopoll = .*\n','',s,flags=re.M)
s=re.sub(r'^\s*p->ops\.remap_file_range = .*\n','',s,flags=re.M)
s=re.sub(r'static loff_t ksu_wrapper_remap_file_range.*?\n}\n\n','',s,flags=re.S)
open(p,'w').write(s)
print('file_wrapper 4.19 old')
PY
fi

# 4.19: file_wrapper 整体 stub
FW="$KERNEL_DIR/drivers/kernelsu/file_wrapper.c"
if [ -f "$FW" ]; then
  cat > "$FW" <<'EOF'
#include "file_wrapper.h"

int ksu_install_file_wrapper(int fd)
{
    (void)fd;
    return 0;
}

void ksu_file_wrapper_init(void)
{
}
EOF
  echo "file_wrapper stub"
fi
