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

export PATH="$CLANG_DIR/bin:$PATH"
export LOCALVERSION="-$LOCALVERSION"

ARCH_ARGS=(O="$OUT" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-)

configure() {
  mkdir -p "$OUT"
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" vendor/kona-perf_defconfig
  "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -O "$OUT" "$OUT/.config" \
    "$KERNEL_DIR/arch/arm64/configs/vendor/nx659j.config"
  if [ "$PHASE" = "1" ]; then
    "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -O "$OUT" "$OUT/.config" \
      "$(pwd)/configs/a16fix.config"
  fi
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" olddefconfig
  echo "===== 关键配置检查 ====="
  grep -E '^CONFIG_(MODULES|KPROBES|KRETPROBES|KALLSYMS|KALLSYMS_ALL|KSU|KSU_SUSFS|KPM|LTO_CLANG|SHADOW_CALL_STACK|EXT4_FS|SECURITY_SELINUX)=' "$OUT/.config" || true
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
