#!/usr/bin/env bash
# KernelSU v0.9.5 vendoring（非 GKI 4.19，kprobe hook）
# 用法：KSU_TAG=v0.9.5 bash scripts/apply-kernelsu.sh kernel
#
# 与旧的 apply-sukisu.sh 的区别：不再手写 selinux/rules.c 之类的 4.19 stub，
# 直接用 KernelSU 官方 setup.sh（clone → checkout tag → symlink drivers/kernelsu →
# 注入 drivers/{Makefile,Kconfig}）。v0.9.5 是最后支持非 GKI 内核的版本。
set -euo pipefail

KERNEL_DIR="${1:-kernel}"
KSU_TAG="${KSU_TAG:-v0.9.5}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/tiann/KernelSU/${KSU_TAG}/kernel/setup.sh}"

log() { echo "[apply-kernelsu] $*"; }

[ -d "$KERNEL_DIR/drivers" ] || { log "ERROR: $KERNEL_DIR/drivers 不存在"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "下载 setup.sh: $KSU_SETUP_URL"
curl -fsSL "$KSU_SETUP_URL" -o "$TMP/setup.sh"

cd "$KERNEL_DIR"
# setup.sh 从 $(pwd) 找 drivers/，clone KernelSU 到 $(pwd)/KernelSU，checkout 指定 tag
sh "$TMP/setup.sh" "$KSU_TAG"

# 校验（避免「CI success 但 KSU 没进内核」）
[ -e drivers/kernelsu ] || { log "ERROR: drivers/kernelsu 未创建"; exit 1; }
grep -q 'kernelsu' drivers/Makefile || { log "ERROR: drivers/Makefile 未注入"; exit 1; }
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || { log "ERROR: drivers/Kconfig 未注入"; exit 1; }

if [ -f KernelSU/kernel/Makefile ]; then
  log "KernelSU 版本信息："
  grep -m3 -E 'KSU_VERSION|KSU_VERSION_BASE|KSU_VERSION_COMMIT' KernelSU/kernel/Makefile || true
fi
log "完成：$KSU_TAG vendored 到 drivers/kernelsu"
