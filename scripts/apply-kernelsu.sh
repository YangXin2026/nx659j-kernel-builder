#!/usr/bin/env bash
# KernelSU 系列 vendoring（支持非 GKI 4.14/4.19）
#
#   # 默认：SukiSU-Ultra（main 分支，kprobe 自动 hook，支持 Non-GKI）
#   bash scripts/apply-kernelsu.sh kernel
#
#   # 覆盖示例
#   REPO=tiann/KernelSU KSU_TAG=v3.3.1 bash scripts/apply-kernelsu.sh kernel
#   REPO=ReSukiSU/ReSukiSU KSU_TAG=v4.2.0-rc3 bash scripts/apply-kernelsu.sh kernel
#
# 为什么选 SukiSU-Ultra 而不是 ReSukiSU（针对 4.19 + KPROBES 内核）：
#   - SukiSU main 分支走「运行时注册 kprobe/kretprobe」，Kconfig 依赖
#     KPROBES && EXT4_FS，Kbuild 明确分档 Non-GKI / GKI 1.0 / GKI 2.0。
#   - ReSukiSU 只有两条路：CONFIG_KSU_TRACEPOINT_HOOK（仅 GKI 2.0 / 5.10+）
#     和 CONFIG_KSU_MANUAL_HOOK（要手工往 fs/exec.c 等插钩子），没有 kprobe 模式。
#
# 已知需要修补的点：
#   SukiSU-Ultra v4.3.0 的 kernel/core/init.c 里
#       #if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
#       MODULE_IMPORT_NS("VFS_internal_...");
#       #else
#       MODULE_IMPORT_NS(VFS_internal_...);   <-- 无外层版本保护
#       #endif
#   MODULE_IMPORT_NS 是 Linux 5.10 才引入的宏，4.19 上不存在，会报
#   "declaration specifier missing, defaulting to 'int'"。
#   下面的兜底补丁会做守卫分析，只注释掉「没有被 >=5.0 保护」的那一行。
set -euo pipefail

KERNEL_DIR="${1:-kernel}"
KSU_TAG="${KSU_TAG:-v4.3.0}"
REPO="${REPO:-SukiSU-Ultra/SukiSU-Ultra}"
NAME=$(echo "$REPO" | cut -d'/' -f2)
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/${REPO}/${KSU_TAG}/kernel/setup.sh}"

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

# ---------- 兜底补丁 2：file_wrapper.c 的 file_operations 4.19 适配 ----------
# LOS 4.19 的 struct file_operations 缺两个成员（已比对 include/linux/fs.h 确认）：
#   iopoll            5.1 引入
#   remap_file_range  4.19 里叫 dedupe_file_range（签名也不同）
# REMAP_FILE_DEDUP 常量同样不存在。4.19 上跳过这两个 op 即可：
# p->ops 由 kzalloc 清零，保持 NULL 是安全的，不影响 root 功能。
FW="KernelSU/kernel/infra/file_wrapper.c"
if [ -f "$FW" ]; then
  python3 - "$FW" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read().split('\n')
out, i, n, changes = [], 0, len(src), []

while i < n:
    l, s = src[i], src[i].strip()

    # iopoll：>= 6.1 分支后的 #else 提升为 #elif >= 5.1
    if s == '#else' and i >= 1:
        if 'f_op->iopoll(kiocb, icb, v)' in '\n'.join(src[max(0, i-15):i]):
            out.append('#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)')
            changes.append('iopoll #else->#elif 5.1'); i += 1; continue

    # remap_file_range 函数定义整体包裹
    if s.startswith('static loff_t ksu_wrapper_remap_file_range('):
        out.append('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)')
        depth, started = 0, False
        while i < n:
            out.append(src[i])
            depth += src[i].count('{') - src[i].count('}')
            if '{' in src[i]: started = True
            i += 1
            if started and depth <= 0: break
        out.append('#endif /* remap_file_range: 5.0+ only */')
        changes.append('remap fn wrapped'); continue

    # ops 赋值包裹
    if s.startswith('p->ops.iopoll'):
        out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)', l, '#endif']
        changes.append('ops.iopoll wrapped'); i += 1; continue
    if s.startswith('p->ops.remap_file_range'):
        out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)', l, '#endif']
        changes.append('ops.remap_file_range wrapped'); i += 1; continue

    out.append(l); i += 1

if changes:
    open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write('\n'.join(out))
    print('[apply-kernelsu] file_wrapper 4.19 适配: ' + ', '.join(changes))
else:
    print('[apply-kernelsu] file_wrapper 无需适配（已是 4.19 兼容写法）')
PY
fi

# ---------- 兜底补丁 3：seccomp action cache（5.9 引入）在 4.19 上降级为 no-op ----------
# LOS 4.19 的 struct seccomp 只有 { int mode; struct seccomp_filter *filter; }，
# 没有 filter_count；也没有 SECCOMP_ARCH_NATIVE_NR / SECCOMP_ARCH_COMPAT_NR，
# struct seccomp_filter 里也没有 cache 字段（这套位图缓存是 Linux 5.9 才加的）。
# 4.19 的 seccomp 每次都实时评估，不存在缓存拦截，因此这两个函数写空实现即可。
SC="KernelSU/kernel/infra/seccomp_cache.c"
if [ -f "$SC" ]; then
  python3 - "$SC" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
guard = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)'
if guard in src:
    print('[apply-kernelsu] seccomp_cache 已适配，跳过')
else:
    idx = src.find('struct action_cache {')
    if idx < 0:
        print('[apply-kernelsu] seccomp_cache 结构不符，跳过')
    else:
        src = src[:idx] + guard + '\n' + src[idx:]
        src += '''
#else /* < 5.9: seccomp action cache 不存在，无可清理/放行 */
void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}
#endif /* LINUX_VERSION_CODE >= 5.9 */
'''
        open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write(src)
        print('[apply-kernelsu] seccomp_cache 4.19 适配: 两个函数降级为 no-op')
PY
fi

# ---------- 兜底补丁 4：struct seccomp.filter_count（5.9 引入）----------
AP="KernelSU/kernel/policy/app_profile.c"
[ -f "$AP" ] || AP="KernelSU/kernel/feature/app_profile.c"
if [ -f "$AP" ]; then
  python3 - "$AP" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding='utf-8', errors='surrogateescape').read().split('\n')
out, changed = [], False
for l in lines:
    s = l.strip()
    if 'current->seccomp.filter_count' in s and s.startswith('atomic_set'):
        out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)', l, '#endif']
        changed = True
    else:
        out.append(l)
if changed:
    open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write('\n'.join(out))
    print('[apply-kernelsu] app_profile 4.19 适配: filter_count 已加版本保护')
else:
    print('[apply-kernelsu] app_profile 无需适配')
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
