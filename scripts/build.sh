#!/usr/bin/env bash
# 4.19-kona-ksu-a16fix-oc 构建脚本
# 用法：
#   PHASE=0 KERNEL_DIR=kernel CLANG_DIR=clang bash scripts/build.sh configure
#   PHASE=0 KERNEL_DIR=kernel CLANG_DIR=clang bash scripts/build.sh build
#   bash scripts/build.sh checksums
set -euo pipefail

PHASE="${PHASE:-0}"
KERNEL_DIR="$(cd "${KERNEL_DIR:-kernel}" && pwd)"
CLANG_DIR="$(cd "${CLANG_DIR:-clang}" && pwd)"
LOCALVERSION="${LOCALVERSION:-kona-ksu-a16fix-oc}"
OUT="${OUT:-$(pwd)/out}"
MINIMAL="${MINIMAL:-0}"

export PATH="$CLANG_DIR/bin:$PATH"
export LOCALVERSION="-$LOCALVERSION"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-YangXin2026}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-nx659j-builder}"

ARCH_ARGS=(O="$OUT" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- )

configure() {
  export ARCH=arm64
  mkdir -p "$OUT"
  local CFG_DIR
  CFG_DIR="$(pwd)/configs"
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" vendor/kona-perf_defconfig
  if [ "${MINIMAL:-0}" != "1" ]; then
    ( cd "$KERNEL_DIR" && ./scripts/kconfig/merge_config.sh -O "$OUT" "$OUT/.config" \
        arch/arm64/configs/vendor/nx659j.config )
  fi
  ( cd "$KERNEL_DIR" && ./scripts/kconfig/merge_config.sh -O "$OUT" "$OUT/.config" \
      "$CFG_DIR/base-fix.config" )
  if [ -f "$CFG_DIR/device-min.config" ]; then
    ( cd "$KERNEL_DIR" && ./scripts/kconfig/merge_config.sh -O "$OUT" "$OUT/.config" \
        "$CFG_DIR/device-min.config" )
  fi
  if [ "$PHASE" = "1" ]; then
    local FRAG
    if [ "${MINIMAL:-0}" = "1" ]; then FRAG="$CFG_DIR/ksu-min.config"; else FRAG="$CFG_DIR/a16fix.config"; fi
    ( cd "$KERNEL_DIR" && ./scripts/kconfig/merge_config.sh -O "$OUT" "$OUT/.config" "$FRAG" )
  fi
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" olddefconfig
  echo "===== 关键配置检查 ====="
  grep -E '^CONFIG_(MODULES|KPROBES|KRETPROBES|KALLSYMS|KALLSYMS_ALL|KSU|KSU_SUSFS|KPM|LTO_CLANG|EXT4_FS|COMPAT)' "$OUT/.config" || true
}

build() {
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" -j"$(nproc)" Image.gz
}

checksums() {
  cd "$OUT" 2>/dev/null || exit 0
  : > sha256sums.txt
  for f in arch/arm64/boot/Image.gz arch/arm64/boot/Image vmlinux System.map .config; do
    [ -f "$f" ] && sha256sum "$f" >> sha256sums.txt
  done
  cat sha256sums.txt 2>/dev/null || true
}

case "${1:-}" in
  configure) configure ;;
  build) build ;;
  checksums) checksums ;;
  *) echo "usage: $0 configure|build|checksums"; exit 1 ;;
esac
