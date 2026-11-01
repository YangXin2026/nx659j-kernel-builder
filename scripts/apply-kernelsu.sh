#!/usr/bin/env bash
# KernelSU 系列 vendoring（支持非 GKI 4.14/4.19）
#
#   # 默认：ReSukiSU（真正兼容老内核，兼容层覆盖 3.5~6.18）
#   bash scripts/apply-kernelsu.sh kernel
#
#   # 覆盖示例
#   REPO=tiann/KernelSU KSU_TAG=v3.3.1 bash scripts/apply-kernelsu.sh kernel
#   REPO=SukiSU-Ultra/SukiSU-Ultra KSU_TAG=v4.3.0 bash scripts/apply-kernelsu.sh kernel
#
# 为什么默认 ReSukiSU 而不是 SukiSU-Ultra：
#   SukiSU-Ultra v4.3.0 的 kernel/core/init.c 在 #else 分支直接发
#   MODULE_IMPORT_NS(VFS_internal_...)（无引号、无外层版本保护）。
#   MODULE_IMPORT_NS 是 Linux 5.10 才引入的宏，4.19 上根本不存在，
#   编译器会报 "declaration specifier missing, defaulting to 'int'"。
#   ReSukiSU 在同一处包了 #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)，
#   4.19 会整块跳过；且它的 compat/kernel_compat.h 做了从 3.5 起的全量保护。
set -euo pipefail

KERNEL_DIR="${1:-kernel}"
KSU_TAG="${KSU_TAG:-v4.2.0-rc3}"
REPO="${REPO:-ReSukiSU/ReSukiSU}"
NAME=$(echo "$REPO" | cut -d'/' -f2)
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/${REPO}/main/kernel/setup.sh}"

log() { echo "[apply-kernelsu] $*"; }

[ -d "$KERNEL_DIR/drivers" ] || { log "ERROR: $KERNEL_DIR/drivers 不存在"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "下载 setup.sh: $KSU_SETUP_URL"
curl -fsSL "$KSU_SETUP_URL" -o "$TMP/setup.sh"

cd "$KERNEL_DIR"
# setup.sh 从 $(pwd) 找 drivers/，clone 到 $(pwd)/KernelSU，checkout 指定 tag
sh "$TMP/setup.sh" "$KSU_TAG"

# ---------- 兜底补丁：仅当所用版本仍有未保护的 MODULE_IMPORT_NS 时生效 ----------
# 4.19 没有 MODULE_IMPORT_NS（Linux 5.10 引入）。把无保护的裸调用整行注释掉。
# ReSukiSU 不会命中；SukiSU-Ultra / 官方 KernelSU 会命中，属于保险。
INIT_C="KernelSU/kernel/core/init.c"
[ -f "$INIT_C" ] || INIT_C="KernelSU/kernel/core/init.c"
if [ -f "$INIT_C" ]; then
  python3 - "$INIT_C" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read().split('\n')
out, depth_ok, changed = [], [], 0
guard_stack = []
for line in src:
    s = line.strip()
    m = re.match(r'#\s*if.*KERNEL_VERSION\((\d+),\s*(\d+)', s)
    if m:
        guard_stack.append((int(m.group(1)), int(m.group(2))))
    elif re.match(r'#\s*else', s):
        if guard_stack: guard_stack[-1] = (0, 0)   # else 分支：版本上界未知
    elif re.match(r'#\s*endif', s):
        if guard_stack: guard_stack.pop()

    body = s.replace('"', '')
    if 'MODULE_IMPORT_NS(' in body:
        # 是否已被 >= 4.20/5.0 之类的保护覆盖
        protected = any((maj, mn) >= (5, 0) for maj, mn in guard_stack)
        if not protected:
            out.append('/* patched-out: MODULE_IMPORT_NS unavailable on this kernel */')
            changed += 1
            continue
    out.append(line)
if changed:
    open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write('\n'.join(out))
    print(f'[apply-kernelsu] 兜底补丁：注释掉 {changed} 处无保护的 MODULE_IMPORT_NS')
else:
    print('[apply-kernelsu] 无需兜底补丁（MODULE_IMPORT_NS 均有版本保护）')
PY
fi

# ---------- 校验：避免「CI success 但 KSU 没进内核」 ----------
[ -e drivers/kernelsu ] || { log "ERROR: drivers/kernelsu 未创建"; exit 1; }
grep -q 'kernelsu' drivers/Makefile || { log "ERROR: drivers/Makefile 未注入"; exit 1; }
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || { log "ERROR: drivers/Kconfig 未注入"; exit 1; }

log "${NAME} 版本信息："
grep -m3 -E 'KSU_VERSION' KernelSU/kernel/Makefile 2>/dev/null || true
if [ -f KernelSU/kernel/core/init.c ]; then
  log "init.c 中 MODULE_IMPORT_NS 现状："
  grep -n 'MODULE_IMPORT_NS' KernelSU/kernel/core/init.c || echo "  （无，4.19 安全）"
fi

log "完成：${NAME} ${KSU_TAG} vendored 到 drivers/kernelsu"
