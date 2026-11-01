#!/usr/bin/env bash
# 4.19-kona A16FIX-KSU 构建脚本
# 用法：
#   PHASE=0 KERNEL_DIR=kernel CLANG_DIR=clang bash scripts/build.sh configure
#   PHASE=0 KERNEL_DIR=kernel CLANG_DIR=clang bash scripts/build.sh build
#   bash scripts/build.sh checksums
set -euo pipefail

PHASE="${PHASE:-0}"
KERNEL_DIR="$(cd "${KERNEL_DIR:-kernel}" && pwd)"
CLANG_DIR="$(cd "${CLANG_DIR:-clang}" && pwd)"
# 内核版本名：A16FIX-KSU-<年月日>-<时分>（北京时间）
# 注：内核硬限制 64 字符；本内核自带前缀 "4.19.325-cip135-st19-perf-" 占 26 字符，
#     所以必须同时关掉 CONFIG_LOCALVERSION_AUTO（见 configs/base-fix.config），
#     否则 scripts/setlocalversion 会再追加 "-g<hash>-dirty"，直接超长编译失败。
#     GPU 超频尚未实现，故名称中不含 OC。
LOCALVERSION="${LOCALVERSION:-A16FIX-KSU}"
case "$LOCALVERSION" in
  *-20[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]) : ;;  # 调用方已带时间戳
  *) LOCALVERSION="${LOCALVERSION}-$(TZ=Asia/Shanghai date +%Y%m%d-%H%M)" ;;
esac
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
  if [ "${STOCK:-0}" = "1" ] && [ -f "$CFG_DIR/stock-linux.config" ]; then
    cp "$CFG_DIR/stock-linux.config" "$OUT/.config"
    echo "[*] using stock config"
    # STOCK 分支原先不合并任何 fragment，导致 phase=1 时 KSU 一行都不会编（能 success 但没 root）。
    # stock-linux.config 里是 `# CONFIG_KPROBES is not set`，必须靠 stock-ksu.config 翻转。
    if [ "$PHASE" = "1" ] && [ -f "$CFG_DIR/stock-ksu.config" ]; then
      ( cd "$KERNEL_DIR" && ./scripts/kconfig/merge_config.sh -O "$OUT" "$OUT/.config" \
          "$CFG_DIR/stock-ksu.config" )
      echo "[*] merged stock-ksu.config"
    fi
  else
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
  fi
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" olddefconfig
  echo "===== 关键配置检查 ====="
  grep -E '^CONFIG_(MODULES|KPROBES|KRETPROBES|KALLSYMS|KALLSYMS_ALL|KSU|KSU_SUSFS|KPM|LTO_CLANG|EXT4_FS|COMPAT)' "$OUT/.config" || true
  # Phase 1 必须硬失败：CI success 但没 KSU 是这个项目最贵的坑
  if [ "$PHASE" = "1" ]; then
    if ! grep -q '^CONFIG_KSU=y' "$OUT/.config"; then
      echo "[!] PHASE=1 但 .config 没有 CONFIG_KSU=y" >&2; exit 1
    fi
    if ! grep -q '^CONFIG_KPROBES=y' "$OUT/.config"; then
      echo "[!] PHASE=1 但 .config 没有 CONFIG_KPROBES=y" >&2; exit 1
    fi
  fi
}

build() {
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" -j"$(nproc)" Image.gz
  # 同时编译 dtb（nx659j 设备树），供 repack_boot.py 替换 boot 里的 dtb
  make -C "$KERNEL_DIR" "${ARCH_ARGS[@]}" -j"$(nproc)" dtbs || true
}

checksums() {
  local ROOT
  ROOT="$(pwd)"
  [ -d "$OUT" ] || exit 0
  : > "$ROOT/sha256sums.txt"
  for f in arch/arm64/boot/Image.gz arch/arm64/boot/Image arch/arm64/boot/dtbo.img vmlinux System.map .config; do
    if [ -f "$OUT/$f" ]; then
      ( cd "$OUT" && sha256sum "$f" ) >> "$ROOT/sha256sums.txt"
    fi
  done
  # 收集所有 dtb 产物
  if [ -d "$OUT/arch/arm64/boot/dts" ]; then
    find "$OUT/arch/arm64/boot/dts" -name '*.dtb' -exec sha256sum {} \; >> "$ROOT/sha256sums.txt" 2>/dev/null || true
  fi
  cat "$ROOT/sha256sums.txt"
}

case "${1:-}" in
  configure) configure ;;
  build) build ;;
  dtbo) dtbo ;;
  checksums) checksums ;;
  *) echo "usage: $0 configure|build|dtbo|checksums"; exit 1 ;;
esac

