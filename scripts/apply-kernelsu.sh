#!/usr/bin/env bash
# KernelSU / SukiSU-Ultra vendoring（支持非 GKI 4.19）
# 用法：
#   KSU_TAG=v3.3.1 REPO=tiann/KernelSU bash scripts/apply-kernelsu.sh kernel
#   KSU_TAG=v4.3.0 REPO=SukiSU-Ultra/SukiSU-Ultra bash scripts/apply-kernelsu.sh kernel
#
# 默认使用 SukiSU-Ultra v4.3.0（更活跃，支持更多架构）
set -euo pipefail

KERNEL_DIR="${1:-kernel}"
KSU_TAG="${KSU_TAG:-v4.3.0}"
REPO="${REPO:-SukiSU-Ultra/SukiSU-Ultra}"
OWNER=$(echo "$REPO" | cut -d'/' -f1)
NAME=$(echo "$REPO" | cut -d'/' -f2)
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/${REPO}/${KSU_TAG}/kernel/setup.sh}"

log() { echo "[apply-kernelsu] $*"; }

[ -d "$KERNEL_DIR/drivers" ] || { log "ERROR: $KERNEL_DIR/drivers 不存在"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "下载 setup.sh: $KSU_SETUP_URL"
curl -fsSL "$KSU_SETUP_URL" -o "$TMP/setup.sh"

cd "$KERNEL_DIR"
# setup.sh 从 $(pwd) 找 drivers/，clone ${REPO} 到 $(pwd)/KernelSU，checkout 指定 tag
sh "$TMP/setup.sh" "$KSU_TAG"

# 修复 SukiSU-Ultra v4.3.0 在旧 Clang 下的编译错误
if [ -f KernelSU/kernel/core/init.c ]; then
  log "检查 SukiSU-Ultra init.c 补丁"
  if grep -q 'MODULE_IMPORT_NS' KernelSU/kernel/core/init.c; then
    log "应用补丁：MODULE_IMPORT_NS 缺少双引号"
    python3 -c "
import sys
path = 'KernelSU/kernel/core/init.c'
with open(path) as f:
    lines = f.readlines()
patched = False
for i, line in enumerate(lines):
    if 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)' in line and '\"' not in line:
        # Skip if already quoted
        if line.strip().startswith('#'):
            continue
        lines[i] = line.replace('MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)', 'MODULE_IMPORT_NS(\"VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver\")')
        patched = True
        break
if patched:
    with open(path, 'w') as f:
        f.writelines(lines)
    print('patched')
else:
    print('skip')
" || true
  fi
fi

# 校验（避免「CI success 但 KSU 没进内核」）
[ -e drivers/kernelsu ] || { log "ERROR: drivers/kernelsu 未创建"; exit 1; }
grep -q 'kernelsu' drivers/Makefile || { log "ERROR: drivers/Makefile 未注入"; exit 1; }
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || { log "ERROR: drivers/Kconfig 未注入"; exit 1; }

if [ -f KernelSU/kernel/Makefile ]; then
  log "${NAME} 版本信息："
  grep -m3 -E 'KSU_VERSION|KSU_VERSION_BASE|KSU_VERSION_COMMIT' KernelSU/kernel/Makefile || true
fi
log "完成：${NAME} ${KSU_TAG} vendored 到 drivers/kernelsu"
