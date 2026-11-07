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

    # remap_file_range 函数定义整体包裹 + 4.19 用 dedupe_file_range 做真转发
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
        # 4.19: 提供等价的 dedupe_file_range 转发，保持文件代理完整性
        out.append('')
        out.append('#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)')
        out.append('/* 4.19: 没有 remap_file_range / REMAP_FILE_DEDUP，')
        out.append('   等价接口是 dedupe_file_range(file_in, pos_in, file_out, pos_out, len)。')
        out.append('   它的语义固定为「去重」，对应 5.0+ 里 REMAP_FILE_DEDUP 那一支：')
        out.append('   源用 file_in 的原始文件，目标用 file_out 的原始文件。 */')
        out.append('static int ksu_wrapper_dedupe_file_range(struct file *file_in, loff_t pos_in,')
        out.append('                                         struct file *file_out, loff_t pos_out, u64 len)')
        out.append('{')
        out.append('    struct ksu_file_wrapper *data_in = file_in->private_data;')
        out.append('    struct ksu_file_wrapper *data_out = file_out->private_data;')
        out.append('    struct file *orig_in;')
        out.append('    struct file *orig_out;')
        out.append('')
        out.append('    if (!data_in || !data_out)')
        out.append('        return -EINVAL;')
        out.append('    orig_in = data_in->orig;')
        out.append('    orig_out = data_out->orig;')
        out.append('    if (!orig_in || !orig_out || !orig_in->f_op || !orig_in->f_op->dedupe_file_range)')
        out.append('        return -EOPNOTSUPP;')
        out.append('')
        out.append('    return orig_in->f_op->dedupe_file_range(orig_in, pos_in, orig_out, pos_out, len);')
        out.append('}')
        out.append('#endif /* dedupe_file_range: < 5.0 */')
        changes.append('remap fn wrapped + dedupe forwarding'); continue

    # ops 赋值包裹
    if s.startswith('p->ops.iopoll'):
        out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)', l, '#endif']
        changes.append('ops.iopoll wrapped'); i += 1; continue
    if s.startswith('p->ops.remap_file_range'):
        out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)', l, '#endif']
        changes.append('ops.remap_file_range wrapped'); i += 1; continue
    if s.startswith('p->ops.fadvise'):
        # 4.19: 挂 dedupe_file_range 转发，保证文件代理完整性不削弱
        out += ['#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)',
                '    p->ops.dedupe_file_range = fp->f_op->dedupe_file_range ? ksu_wrapper_dedupe_file_range : NULL;',
                '#endif']
        out.append(l)
        changes.append('ops.dedupe_file_range added'); i += 1; continue

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

# ---------- 兜底补丁 5：uapi/linux/mount.h（5.11 引入，但文件中未实际使用）----------
SMN="KernelSU/kernel/infra/su_mount_ns.c"
if [ -f "$SMN" ]; then
  python3 - "$SMN" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding='utf-8', errors='surrogateescape').read().split('\n')
out, changed = [], False
for l in lines:
    if '<uapi/linux/mount.h>' in l:
        out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0)', l, '#endif']
        changed = True
    else:
        out.append(l)
if changed:
    open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write('\n'.join(out))
    print('[apply-kernelsu] su_mount_ns 4.19 适配: uapi/linux/mount.h 已加版本保护')
else:
    print('[apply-kernelsu] su_mount_ns 无需适配')
PY
fi

# ---------- 兜底补丁 6：path_umount / path_mount 在 4.19 上走 ksys_umount / ksys_mount ----------
# 这两个是 KSU 的真实功能（模块卸载、mount namespace 隔离），不能降级为 no-op。
# LOS 4.19 没有 path_umount / path_mount（5.12 引入），但有等价物：
#   int ksys_umount(char __user *name, int flags)
#   int ksys_mount(char __user *dev, char __user *dir, char __user *type,
#                  unsigned long flags, void *data)
# 二者都未 EXPORT_SYMBOL，但 CONFIG_KSU=y 编进内核，extern 声明即可调用。
# 4.19 仍有 set_fs()/KERNEL_DS（5.10 才移除），用它把内核字符串传给这两个 API。
# 这是老内核上的标准做法，功能完整保留。
KU="KernelSU/kernel/feature/kernel_umount.c"
SMN2="KernelSU/kernel/infra/su_mount_ns.c"

if [ -f "$KU" ]; then
  python3 - "$KU" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
if 'ksys_umount' in src:
    print('[apply-kernelsu] kernel_umount 已适配 ksys_umount，跳过')
else:
    old_decl = 'extern int path_umount(struct path *path, int flags);'
    new_decl = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
extern int path_umount(struct path *path, int flags);
#else
extern int ksys_umount(char __user *name, int flags);
#endif'''
    old_body = '''    int err = path_umount(path, flags);
    if (err) {'''
    new_body = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
    int err = path_umount(path, flags);
#else
    /* 4.19: path_umount 不存在，用 ksys_umount + set_fs(KERNEL_DS) 真正执行卸载 */
    mm_segment_t old_fs;
    int err;
    (void)path;
    old_fs = get_fs();
    set_fs(KERNEL_DS);
    err = ksys_umount((char __user *)mnt, flags);
    set_fs(old_fs);
#endif
    if (err) {'''
    if old_decl not in src or old_body not in src:
        print('[apply-kernelsu] !! kernel_umount 锚点不匹配，未修改')
    else:
        src = src.replace(old_decl, new_decl).replace(old_body, new_body)
        if '#include <linux/uaccess.h>' not in src:
            src = '#include <linux/version.h>\n#include <linux/uaccess.h>\n' + src
        open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write(src)
        print('[apply-kernelsu] kernel_umount 4.19: path_umount -> ksys_umount + set_fs (功能完整)')
PY
fi

if [ -f "$SMN2" ]; then
  python3 - "$SMN2" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
if 'ksys_mount' in src:
    print('[apply-kernelsu] su_mount_ns 已适配 ksys_mount，跳过')
else:
    old_decl = '''extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,
                      void *data_page);'''
    new_decl = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,
                      void *data_page);
#else
extern int ksys_mount(char __user *dev_name, char __user *dir_name, char __user *type, unsigned long flags,
                      void *data);
#endif'''
    old_body = '''    struct path root_path;
    get_fs_root(current->fs, &root_path);
    int pm_ret = path_mount(NULL, &root_path, NULL, MS_PRIVATE | MS_REC, NULL);
    path_put(&root_path);'''
    new_body = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
    struct path root_path;
    get_fs_root(current->fs, &root_path);
    int pm_ret = path_mount(NULL, &root_path, NULL, MS_PRIVATE | MS_REC, NULL);
    path_put(&root_path);
#else
    /* 4.19: path_mount 不存在，用 ksys_mount + set_fs(KERNEL_DS) 真正把 root remount 为 private */
    mm_segment_t old_fs = get_fs();
    int pm_ret;
    set_fs(KERNEL_DS);
    pm_ret = ksys_mount(NULL, (char __user *)"/", NULL, MS_PRIVATE | MS_REC, NULL);
    set_fs(old_fs);
#endif'''
    if old_decl not in src or old_body not in src:
        print('[apply-kernelsu] !! su_mount_ns 锚点不匹配，未修改')
    else:
        src = src.replace(old_decl, new_decl).replace(old_body, new_body)
        if '#include <linux/uaccess.h>' not in src:
            src = src.replace('#include <linux/version.h>',
                              '#include <linux/version.h>\n#include <linux/uaccess.h>', 1)
        open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write(src)
        print('[apply-kernelsu] su_mount_ns 4.19: path_mount -> ksys_mount + set_fs (功能完整)')
PY
fi

# ---------- 兜底补丁 7：fsnotify_ops 回调名在 4.19 上是 handle_event（5.9 才改为 handle_inode_event）----------
# LOS 4.19:
#   int (*handle_event)(struct fsnotify_group *group, struct inode *inode, u32 mask,
#                       const void *data, int data_type, const unsigned char *file_name,
#                       u32 cookie, struct fsnotify_iter_info *iter_info);
# 5.9+:
#   int (*handle_inode_event)(struct fsnotify_mark *mark, u32 mask, struct inode *inode,
#                             struct inode *dir, const struct qstr *file_name, u32 cookie);
# 4.19 的 handle_event 同样拿得到 file_name / mask，判断逻辑完整可移植，功能不降级。
# 其余 fsnotify_init_mark / fsnotify_add_inode_mark / fsnotify_alloc_group 4.19 签名一致。
PO="KernelSU/kernel/manager/pkg_observer.c"
if [ -f "$PO" ]; then
  python3 - "$PO" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
if 'ksu_handle_event' in src:
    print('[apply-kernelsu] pkg_observer 已适配 4.19 handle_event，跳过')
else:
    old_fn = '''static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir,
                                  const struct qstr *file_name, u32 cookie)
{
    if (!file_name)
        return 0;
    if (mask & FS_ISDIR)
        return 0;
    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        ksu_defer_track_throne();
    }
    return 0;
}

static const struct fsnotify_ops ksu_ops = {
    .handle_inode_event = ksu_handle_inode_event,
};'''
    new_fn = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir,
                                  const struct qstr *file_name, u32 cookie)
{
    if (!file_name)
        return 0;
    if (mask & FS_ISDIR)
        return 0;
    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        ksu_defer_track_throne();
    }
    return 0;
}

static const struct fsnotify_ops ksu_ops = {
    .handle_inode_event = ksu_handle_inode_event,
};
#else
/* 4.19: fsnotify_ops 用的是 handle_event，参数里同样带 mask 和 file_name，
   判断逻辑与 5.9+ 版本完全等价，功能不降级。 */
static int ksu_handle_event(struct fsnotify_group *group, struct inode *inode, u32 mask, const void *data,
                            int data_type, const unsigned char *file_name, u32 cookie,
                            struct fsnotify_iter_info *iter_info)
{
    (void)group;
    (void)inode;
    (void)data;
    (void)data_type;
    (void)cookie;
    (void)iter_info;

    if (!file_name)
        return 0;
    if (mask & FS_ISDIR)
        return 0;
    if (strncmp((const char *)file_name, "packages.list", 13) == 0 &&
        (file_name[13] == '\\0' || file_name[13] == '/')) {
        pr_info("packages.list detected: %d\\n", mask);
        ksu_defer_track_throne();
    }
    return 0;
}

static const struct fsnotify_ops ksu_ops = {
    .handle_event = ksu_handle_event,
};
#endif'''
    if old_fn not in src:
        print('[apply-kernelsu] !! pkg_observer 锚点不匹配，未修改')
    else:
        src = src.replace(old_fn, new_fn)
        open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write(src)
        print('[apply-kernelsu] pkg_observer 4.19: handle_inode_event -> handle_event (功能完整)')
PY
fi

# ---------- 兜底补丁 8：TWA_RESUME（5.8 引入枚举）在 4.19 上等价于 task_work_add 的 bool notify=true ----------
# LOS 4.19: int task_work_add(struct task_struct *task, struct callback_head *twork, bool);
# 5.8+:     int task_work_add(struct task_struct *task, struct callback_head *twork, enum task_work_notify_mode mode);
#          TWA_RESUME = (1 << 0)，语义上就等于 4.19 的 notify=true（恢复时执行）。
# pkg_observer.c 本来就有这个兼容宏，只是 allowlist.c / supercall.c 漏了。
# 这里给漏掉的源文件补上同样的宏，行为完全一致，不是降级。
python3 - KernelSU/kernel <<'PY'
import sys, os
root = sys.argv[1]
compat = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0) && !defined(TWA_RESUME)
/* 4.19: task_work_add 第三参是 bool notify，true 等价于 5.8+ 的 TWA_RESUME */
#define TWA_RESUME true
#endif
'''
targets = ['policy/allowlist.c', 'supercall/supercall.c', 'manager/pkg_observer.c']
for rel in targets:
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        continue
    src = open(p, encoding='utf-8', errors='surrogateescape').read()
    if 'task_work_add' not in src:
        continue
    if 'define TWA_RESUME' in src:
        print(f'[apply-kernelsu] {rel}: TWA_RESUME 兼容宏已存在')
        continue
    # 插在最后一个 #include 之后，保证 <linux/version.h> 已生效
    lines = src.split('\n')
    last_inc = -1
    for i, l in enumerate(lines):
        if l.startswith('#include'):
            last_inc = i
    if last_inc < 0:
        print(f'[apply-kernelsu] !! {rel} 没有 #include，跳过')
        continue
    lines.insert(last_inc + 1, '\n' + compat.rstrip())
    open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write('\n'.join(lines))
    print(f'[apply-kernelsu] {rel}: 已补 TWA_RESUME 兼容宏（等价 true）')
PY

# put_task_struct / get_task_struct 在 4.19 需 <linux/sched/task.h>
python3 - KernelSU/kernel/policy/allowlist.c <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
if '#include <linux/sched/task.h>' in src:
    print('[apply-kernelsu] allowlist.c: sched/task.h 已存在')
else:
    src = src.replace('#include <linux/task_work.h>',
                      '#include <linux/task_work.h>\n#include <linux/sched/task.h>', 1)
    open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write(src)
    print('[apply-kernelsu] allowlist.c: 已补 <linux/sched/task.h>（put_task_struct 声明）')
PY

# ---------- 兜底补丁 9：clocksource->vdso_clock_mode（5.1 引入）在 4.19 上是 archdata.vdso_direct ----------
# 目的：让 vDSO 走 ARCHTIMER 直读，cpu_spoof 伪造 CPU 时用。
#   LOS 4.19 (arch/arm64/include/asm/vdso/vsyscall.h):
#       __arm64_get_clock_mode(tk) -> !tk->tkr_mono.clock->archdata.vdso_direct
#   即 4.19 由 clocksource->archdata.vdso_direct (bool) 决定，
#   drivers/clocksource/arm_arch_timer.c 里就是 clocksource_counter.archdata.vdso_direct = vdso_default;
#   5.1+ 才改成 clocksource->vdso_clock_mode = VDSO_CLOCKMODE_ARCHTIMER。
# 两者语义一一对应，且我们 CONFIG_ARCH_CLOCKSOURCE_DATA=y，因此可真正等价移植。
# vdso_default 全局变量是 5.1+ 才有的符号，4.19 上设置 archdata.vdso_direct 即达到同样效果。
CS="KernelSU/kernel/extension/cpu_spoof.c"
if [ -f "$CS" ]; then
  python3 - "$CS" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
if 'archdata.vdso_direct' in src:
    print('[apply-kernelsu] cpu_spoof 已适配 vdso_direct，跳过')
else:
    old1 = '''                    if (curr_cs_ptr && *curr_cs_ptr) {
                        (*curr_cs_ptr)->vdso_clock_mode =
                            VDSO_CLOCKMODE_ARCHTIMER;
                    } else {'''
    new1 = '''                    if (curr_cs_ptr && *curr_cs_ptr) {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)
                        (*curr_cs_ptr)->vdso_clock_mode =
                            VDSO_CLOCKMODE_ARCHTIMER;
#else
                        /* 4.19: 由 archdata.vdso_direct 决定 vDSO 是否直读，
                           等价于 5.1+ 的 vdso_clock_mode = VDSO_CLOCKMODE_ARCHTIMER */
                        (*curr_cs_ptr)->archdata.vdso_direct = true;
#endif
                    } else {'''
    old2 = '''                {
                    enum vdso_clock_mode *vd_default =
                        (enum vdso_clock_mode *)find_kernel_symbol_exact(
                            "vdso_default");
                    if (vd_default) {
                        *vd_default = VDSO_CLOCKMODE_ARCHTIMER;
                    } else {
                        pr_warn("ksu: set_spoof_cpu failed to resolve 'vdso_default'\\n");
                        ++missing;
                    }
                }'''
    new2 = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)
                {
                    enum vdso_clock_mode *vd_default =
                        (enum vdso_clock_mode *)find_kernel_symbol_exact(
                            "vdso_default");
                    if (vd_default) {
                        *vd_default = VDSO_CLOCKMODE_ARCHTIMER;
                    } else {
                        pr_warn("ksu: set_spoof_cpu failed to resolve 'vdso_default'\\n");
                        ++missing;
                    }
                }
#endif
                /* 4.19 无需单独处理 vdso_default：上面设置的
                   clocksource->archdata.vdso_direct 已经让 vDSO 直读 arch timer */'''
    ok1 = old1 in src
    ok2 = old2 in src
    print(f'[apply-kernelsu] cpu_spoof 锚点: vdso_clock_mode={ok1}, vdso_default={ok2}')
    if ok1:
        src = src.replace(old1, new1)
    if ok2:
        src = src.replace(old2, new2)
    if ok1 or ok2:
        open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n').write(src)
        print('[apply-kernelsu] cpu_spoof 4.19: vdso_clock_mode -> archdata.vdso_direct (功能等价)')
PY
fi

# ---------- 兜底补丁 10：SELinux 子系统 4.19 legacy 移植（最关键的一块）----------
# 问题：SukiSU v4.3.0 的 selinux/{rules,sepolicy}.c 与 feature/selinux_hide.c 依赖
#   Linux 5.7 才引入的 struct selinux_policy，以及 struct selinux_state 里的
#   policy / policy_mutex 两个成员。
#
# LOS 4.19 的真实结构（已从源码逐行确认）：
#   struct selinux_state { ...; struct selinux_avc *avc; struct selinux_ss *ss; };
#   struct selinux_ss   { struct sidtab *sidtab; struct policydb policydb;
#                         rwlock_t policy_rwlock; u32 latest_granting;
#                         struct selinux_map map; struct page *status_page;
#                         struct mutex status_lock; };
#   void selinux_ss_init(struct selinux_ss **ss) { *ss = &selinux_ss; }
#   —— 是静态全局，没有可原子替换的 policy 指针，policydb 直接内嵌其中。
#   4.19 里 struct selinux_policy 这个名字根本不存在（搜到的都是
#   selinux_policycap_* 函数名）。
#
# 移植依据（两处独立印证，结论一致）：
#   A) 本内核自带的 security_load_policy()（security/selinux/ss/services.c）：
#          memcpy(oldpolicydb, policydb, sizeof(*policydb));
#          write_lock_irq(&state->ss->policy_rwlock);
#          memcpy(&state->ss->policydb, newpolicydb, sizeof(*newpolicydb));
#          write_unlock_irq(&state->ss->policy_rwlock);
#      即：不换指针，整结构体 memcpy 回去 + policy_rwlock 保护。
#   B) Redmi K40 游戏增强版 4.14.186 (ares) 的 ReSukiSU 分支
#      cooollawf/Redmi-ares-K40G-4.14.186-Stardust-Kernel-ReSukiSU
#      在 rules.c 里显式区分「4.14 - 5.10」与「5.10+」两条路径，
#      老内核走的正是同样的 memcpy + policy_rwlock。
#
# 结论：4.19 有完整等价机制，SELinux 规则注入与 selinux_hide 隐藏功能全部保留，
#      没有任何功能被删掉或降级为桩。
#
# 本补丁做四件事：
#   1) sepolicy.h：struct selinux_policy 声明改为版本分支；legacy 下定义一个
#      布局与 5.7+ 一致（sidtab / policydb / latest_granting）的影子结构，
#      让上层代码无需改动即可编译和运行。
#   2) sepolicy.c：新增 legacy 实现
#        ksu_get_shadow_sepolicy()   —— 用 selinux_ss 的真实数据填充影子结构
#        ksu_dup_policydb_only()     —— policydb_write -> 缓冲 -> policydb_read
#        ksu_destroy_policydb_only() —— policydb_destroy 包装
#   3) rules.c：apply_kernelsu_rules() 与 handle_sepolicy() 两处
#      「取策略 -> 改策略 -> 提交」流程加 legacy 分支，提交方式与内核自身一致。
#   4) feature/selinux_hide.c：backup 释放路径与 policy 读取路径适配 legacy。
SEL="KernelSU/kernel/selinux"
HIDE="KernelSU/kernel/feature/selinux_hide.c"
if [ -d "$SEL" ]; then
  python3 - "$SEL" "$HIDE" <<'KSU_SELINUX_LEGACY_PY'
import sys, os

sel = sys.argv[1]
hide = sys.argv[2] if len(sys.argv) > 2 else ''
NL = chr(10)
V = 'LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0) || defined(KSU_COMPAT_HAS_POLICY_MUTEX)'
NV = 'LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0) && !defined(KSU_COMPAT_HAS_POLICY_MUTEX)'
done = []

def rd(p):
    return open(p, encoding='utf-8', errors='surrogateescape').read()

def wr(p, s):
    open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(s)

# ---------------- 1) sepolicy.h ----------------
p = os.path.join(sel, 'sepolicy.h')
if not os.path.exists(p):
    print('[apply-kernelsu] !! sepolicy.h 不存在')
    sys.exit(0)
src = rd(p)
if 'ksu_get_shadow_sepolicy' in src:
    print('[apply-kernelsu] sepolicy.h 已适配')
else:
    old = '''struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol);

void ksu_destroy_sepolicy(struct selinux_policy *orig);'''
    new = '''#if __V__
struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol);

void ksu_destroy_sepolicy(struct selinux_policy *orig);
#else
/*
 * 4.19 legacy: the kernel has no struct selinux_policy (added in 5.7).
 * policydb / sidtab are embedded directly in the static selinux_ss, so there
 * is no policy pointer that could be atomically swapped. We provide a
 * layout-compatible shadow struct plus policydb-level helpers; upper layers
 * (selinux_hide etc.) keep working unchanged.
 */
struct selinux_policy {
    struct sidtab *sidtab;
    struct policydb policydb;
    u32 latest_granting;
};

struct selinux_policy *ksu_get_shadow_sepolicy(void);
int ksu_dup_policydb_only(struct policydb *old_db, struct policydb *new_db);
void ksu_destroy_policydb_only(struct policydb *db);
#endif'''.replace('__V__', V)
    if old not in src:
        print('[apply-kernelsu] !! sepolicy.h 锚点不匹配')
    else:
        wr(p, src.replace(old, new, 1))
        done.append('sepolicy.h')

# ---------------- 2) sepolicy.c ----------------
p = os.path.join(sel, 'sepolicy.c')
if os.path.exists(p):
    src = rd(p)
    if 'ksu_dup_policydb_only' in src:
        print('[apply-kernelsu] sepolicy.c 已适配')
    else:
        legacy = '''
#if __NV__
/*
 * ===== 4.19 legacy SELinux support =====
 * Same mechanism the kernel's own security_load_policy() uses on < 5.7:
 * no pointer swap, just memcpy the whole policydb back into selinux_ss.
 * Full functionality preserved (rule injection + selinux_hide).
 */
static struct selinux_policy ksu_shadow_policy;

struct selinux_policy *ksu_get_shadow_sepolicy(void)
{
    struct selinux_ss *ss = selinux_state.ss;

    if (!ss)
        return NULL;

    ksu_shadow_policy.sidtab = ss->sidtab;
    ksu_shadow_policy.latest_granting = ss->latest_granting;
    memcpy(&ksu_shadow_policy.policydb, &ss->policydb, sizeof(ss->policydb));
    return &ksu_shadow_policy;
}

/* Serialize-copy a policydb into an independent instance. */
int ksu_dup_policydb_only(struct policydb *old_db, struct policydb *new_db)
{
    struct policy_file fp = { 0 };
    void *data;
    int ret, len;

    if (!old_db || !new_db)
        return -EINVAL;

    len = (int)(old_db->len + (size_t)old_db->p_types.nprim * (sizeof(u32) + sizeof(u64)));
    if (len <= 0)
        return -EINVAL;

    data = vmalloc(len);
    if (!data)
        return -ENOMEM;

    fp.data = data;
    fp.len = len;

    ret = policydb_write(old_db, &fp);
    if (ret) {
        pr_err("sepolicy: policydb_write: %d__NL__", ret);
        vfree(data);
        return ret;
    }
    len -= fp.len;

    if (len >= 20 + (int)sizeof(u32)) {
        u32 *config_ptr = (u32 *)((char *)data + 20);
#ifdef POLICYDB_CONFIG_ANDROID_NETLINK_ROUTE
        if (old_db->android_netlink_route)
            *config_ptr |= POLICYDB_CONFIG_ANDROID_NETLINK_ROUTE;
#endif
#ifdef POLICYDB_CONFIG_ANDROID_NETLINK_GETNEIGH
        if (old_db->android_netlink_getneigh)
            *config_ptr |= POLICYDB_CONFIG_ANDROID_NETLINK_GETNEIGH;
#endif
    }

    fp.data = data;
    fp.len = len;

    ret = policydb_read(new_db, &fp);
    if (ret) {
        pr_err("sepolicy: policydb_read: %d__NL__", ret);
        vfree(data);
        return ret;
    }

    new_db->len = (u32)len;
    vfree(data);
    return len;
}

void ksu_destroy_policydb_only(struct policydb *db)
{
    if (db)
        policydb_destroy(db);
}
#endif /* 4.19 legacy SELinux */
'''.replace('__NV__', NV).replace('__NL__', '\\n')
        wr(p, src.rstrip(NL) + NL + legacy)
        done.append('sepolicy.c')

# ---------------- 3) rules.c ----------------
p = os.path.join(sel, 'rules.c')
if os.path.exists(p):
    src = rd(p)
    if 'ksu_policy_legacy' in src:
        print('[apply-kernelsu] rules.c 已适配')
    else:
        ok = True

        old_bp = 'struct selinux_policy *backup_sepolicy;'
        new_bp = '''#if __V__
struct selinux_policy *backup_sepolicy;
#else
/* 4.19 legacy: backup holds an independent policydb copy */
static struct policydb *backup_policydb;

static inline struct selinux_policy *ksu_policy_legacy(void)
{
    return ksu_get_shadow_sepolicy();
}
#endif'''.replace('__V__', V)
        if old_bp not in src:
            ok = False
            print('[apply-kernelsu] !! rules.c backup 锚点不匹配')
        else:
            src = src.replace(old_bp, new_bp, 1)

        old_head = '''    struct selinux_policy *pol, *old_pol;
    struct policydb *db;

    if (!getenforce()) {
        pr_info("SELinux permissive or disabled, apply rules!\\n");
    }

    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));'''
        new_head = '''    struct policydb *db;

    if (!getenforce()) {
        pr_info("SELinux permissive or disabled, apply rules!\\n");
    }

#if __V__
    struct selinux_policy *pol, *old_pol;
    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));'''.replace('__V__', V)
        if old_head not in src:
            ok = False
            print('[apply-kernelsu] !! rules.c 头部锚点不匹配')
        else:
            src = src.replace(old_head, new_head, 1)

        old_dup = '''    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) {
        pr_err("failed to dup selinux_policy: %ld\\n", PTR_ERR(pol));
        goto out_unlock;
    }

    db = &pol->policydb;
'''
        new_dup = '''    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) {
        pr_err("failed to dup selinux_policy: %ld\\n", PTR_ERR(pol));
        goto out_unlock;
    }

    db = &pol->policydb;
#else
    /*
     * 4.19 legacy: make an independent copy of the live policydb, patch it,
     * then memcpy it back inside policy_rwlock (exactly what the kernel's own
     * security_load_policy() does).
     */
    backup_policydb = kzalloc(sizeof(*backup_policydb), GFP_KERNEL);
    if (backup_policydb) {
        int blen = ksu_dup_policydb_only(&selinux_state.ss->policydb, backup_policydb);
        if (blen < 0) {
            pr_err("failed to dup backup policydb: %d\\n", blen);
            kfree(backup_policydb);
            backup_policydb = NULL;
        } else {
            pr_info("backup sepolicy success!\\n");
        }
    }

    db = kzalloc(sizeof(*db), GFP_KERNEL);
    if (!db) {
        pr_err("failed to alloc working policydb\\n");
        return;
    }
    {
        int dlen = ksu_dup_policydb_only(&selinux_state.ss->policydb, db);
        if (dlen < 0) {
            pr_err("failed to dup policydb: %d\\n", dlen);
            kfree(db);
            return;
        }
    }
#endif
'''
        if old_dup not in src:
            ok = False
            print('[apply-kernelsu] !! rules.c dup 锚点不匹配')
        else:
            src = src.replace(old_dup, new_dup, 1)

        old_commit = '''    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);

    reset_avc_cache();
out_unlock:
    mutex_unlock(&selinux_state.policy_mutex);
}'''
        new_commit = '''#if __V__
    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);
#else
    {
        struct selinux_ss *ss = selinux_state.ss;

        write_lock_irq(&ss->policy_rwlock);
        memcpy(&ss->policydb, db, sizeof(ss->policydb));
        write_unlock_irq(&ss->policy_rwlock);

        /*
         * 补丁17（use-after-free）：memcpy 只是把 db 的指针抄进 ss->policydb，
         * 内存所有权已经交给内核正在用的那份 policydb 了。此处再 destroy(db)
         * 等于把 htable / flex_array / ebitmap 全部 free 掉，紧接着的第一次
         * 策略查询就会踩在已释放的堆上（现象：hashtab_search 里出现用户态区间
         * 的乱码地址）。内核自己的 security_load_policy() 在 4.19 上是先
         * memcpy(oldpolicydb, policydb, ...) 保存旧壳，装完只 destroy 旧的。
         * 这里只释放 shell，旧内容是一次性泄漏，换来的是不再 UAF。
         */
        kfree(db);
    }
#endif

    reset_avc_cache();
#if __V__
out_unlock:
    mutex_unlock(&selinux_state.policy_mutex);
#endif
}'''.replace('__V__', V)
        if old_commit not in src:
            ok = False
            print('[apply-kernelsu] !! rules.c 提交锚点不匹配')
        else:
            src = src.replace(old_commit, new_commit, 1)

        # ---- handle_sepolicy ----
        old_decl = '''    struct selinux_policy *pol, *old_pol;
    struct policydb *db;
    struct sepol_batch_cursor cursor;'''
        new_decl = '''    struct policydb *db;
#if __V__
    struct selinux_policy *pol, *old_pol;
#endif
    struct sepol_batch_cursor cursor;'''.replace('__V__', V)
        if old_decl not in src:
            ok = False
            print('[apply-kernelsu] !! handle_sepolicy 声明锚点不匹配')
        else:
            src = src.replace(old_decl, new_decl, 1)

        old_acq = '''    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) {
        ret = PTR_ERR(pol);
        pr_err("ksu_dup_sepolicy err: %d\\n", ret);
        goto out_unlock;
    }
    db = &pol->policydb;
'''
        new_acq = '''#if __V__
    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) {
        ret = PTR_ERR(pol);
        pr_err("ksu_dup_sepolicy err: %d\\n", ret);
        goto out_unlock;
    }
    db = &pol->policydb;
#else
    /* 4.19 legacy: work on an independent policydb copy */
    db = kzalloc(sizeof(*db), GFP_KERNEL);
    if (!db) {
        ret = -ENOMEM;
        goto out_free;
    }
    {
        int dlen = ksu_dup_policydb_only(&selinux_state.ss->policydb, db);
        if (dlen < 0) {
            pr_err("ksu_dup_policydb err: %d\\n", dlen);
            ret = dlen;
            kfree(db);
            goto out_free;
        }
    }
#endif
'''.replace('__V__', V)
        if old_acq not in src:
            ok = False
            print('[apply-kernelsu] !! handle_sepolicy 取策略锚点不匹配')
        else:
            src = src.replace(old_acq, new_acq, 1)

        old_cmt = '''    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);

    reset_avc_cache();
    ret = success_cmd_count;
    goto out_unlock;

out_drop_new_policy:
    ksu_destroy_sepolicy(pol);
out_unlock:
    mutex_unlock(&selinux_state.policy_mutex);
out_free:
    kvfree(payload);

    return ret;
}'''
        new_cmt = '''#if __V__
    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);
#else
    {
        struct selinux_ss *ss = selinux_state.ss;

        write_lock_irq(&ss->policy_rwlock);
        memcpy(&ss->policydb, db, sizeof(ss->policydb));
        write_unlock_irq(&ss->policy_rwlock);

        /*
         * 补丁17（use-after-free）：memcpy 只是把 db 的指针抄进 ss->policydb，
         * 内存所有权已经交给内核正在用的那份 policydb 了。此处再 destroy(db)
         * 等于把 htable / flex_array / ebitmap 全部 free 掉，紧接着的第一次
         * 策略查询就会踩在已释放的堆上（现象：hashtab_search 里出现用户态区间
         * 的乱码地址）。内核自己的 security_load_policy() 在 4.19 上是先
         * memcpy(oldpolicydb, policydb, ...) 保存旧壳，装完只 destroy 旧的。
         * 这里只释放 shell，旧内容是一次性泄漏，换来的是不再 UAF。
         */
        kfree(db);
    }
#endif

    reset_avc_cache();
    ret = success_cmd_count;
    goto out_unlock;

out_drop_new_policy:
#if __V__
    ksu_destroy_sepolicy(pol);
#else
    ksu_destroy_policydb_only(db);
    kfree(db);
#endif
out_unlock:
#if __V__
    mutex_unlock(&selinux_state.policy_mutex);
#endif
out_free:
    kvfree(payload);

    return ret;
}'''.replace('__V__', V)
        if old_cmt not in src:
            ok = False
            print('[apply-kernelsu] !! handle_sepolicy 提交锚点不匹配')
        else:
            src = src.replace(old_cmt, new_cmt, 1)

        if ok:
            wr(p, src)
            done.append('rules.c')

# ---------------- 4) feature/selinux_hide.c ----------------
if hide and os.path.exists(hide):
    src = rd(hide)
    if 'ksu_get_shadow_sepolicy' in src:
        print('[apply-kernelsu] selinux_hide.c 已适配')
    else:
        ok = True
        old_drop = '''    if (!ksu_selinux_hide_running && backup_sepolicy) {
        pr_info("selinux_hide is not enabled - drop backup_sepolicy\\n");
        sidtab_destroy(backup_sepolicy->sidtab);
        kfree(backup_sepolicy->sidtab);
        ksu_destroy_sepolicy(backup_sepolicy);
        backup_sepolicy = NULL;
    }'''
        new_drop = '''    if (!ksu_selinux_hide_running && backup_sepolicy) {
        pr_info("selinux_hide is not enabled - drop backup_sepolicy\\n");
#if __V__
        sidtab_destroy(backup_sepolicy->sidtab);
        kfree(backup_sepolicy->sidtab);
        ksu_destroy_sepolicy(backup_sepolicy);
#else
        /* 4.19 legacy: backup_sepolicy is a shadow struct that only holds a
           copy of the policydb; the sidtab pointer is borrowed from
           selinux_ss, so it must NOT be destroyed or freed here. */
        ksu_destroy_policydb_only(&backup_sepolicy->policydb);
        kfree(backup_sepolicy);
#endif
        backup_sepolicy = NULL;
    }'''.replace('__V__', V)
        if old_drop not in src:
            ok = False
            print('[apply-kernelsu] !! selinux_hide 释放锚点不匹配')
        else:
            src = src.replace(old_drop, new_drop, 1)

        old_rd = '    orig_policy = rcu_dereference(selinux_state.policy);'
        new_rd = '''#if __V__
    orig_policy = rcu_dereference(selinux_state.policy);
#else
    /* 4.19 legacy: no swappable policy pointer; use the shadow view of selinux_ss */
    orig_policy = ksu_get_shadow_sepolicy();
#endif'''.replace('__V__', V)
        if old_rd not in src:
            ok = False
            print('[apply-kernelsu] !! selinux_hide 读取锚点不匹配')
        else:
            src = src.replace(old_rd, new_rd, 1)

        if ok:
            wr(hide, src)
            done.append('selinux_hide.c')

if done:
    print('[apply-kernelsu] SELinux 4.19 legacy 移植完成: ' + ', '.join(done))
else:
    print('[apply-kernelsu] SELinux legacy 无改动')
KSU_SELINUX_LEGACY_PY
fi



# ---------- 兜底补丁 10b：sepolicy.c 的 4.19 数据结构适配 ----------
# 补丁 10 解决的是「策略从哪来 / 怎么提交」，这一块解决「policydb 内部结构差异」。
# 4.19 与 5.x 在三处结构上不同：
#
# 1) filename_trans
#    5.9+ :
#      struct filename_trans_key   { u32 ttype; u16 tclass; char *name; };
#      struct filename_trans_datum { ebitmap stypes; u32 otype; ... *next; };
#      policydb->filename_trans 是 `struct hashtab *` 以外的内联对象，
#      hashtab_insert(h, k, d, key_params) 四参，hash/cmp 为 (const void *)
#    4.19  :
#      struct filename_trans       { u32 stype, ttype; u16 tclass; const char *name; };
#      struct filename_trans_datum { u32 otype; };          // 无 stypes / 无 next
#      policydb->filename_trans 是 `struct hashtab *`，
#      hashtab_insert(h, k, d) 三参，hash/cmp 为 (struct hashtab *, const void *)
#      —— 一个 (stype,ttype,tclass,name) 元组只存一条规则，重复即覆盖。
#
# 2) type_attr_map_array / type_val_to_struct / sym_val_to_name
#    5.4+ : 普通指针数组，用 ksu_kvrealloc 扩容
#    4.19 : 三个都是 `struct flex_array *`（policydb_init 时按 p_types.nprim 预分配），
#           用 flex_array_get_ptr / flex_array_put_ptr 存取，不需要 realloc。
#    4.19 也没有 db->type_val_to_struct，对应的是 type_val_to_struct_array。
#
# 以上都属于同语义不同布局，按真实接口移植，功能不降级。
SEP="KernelSU/kernel/selinux/sepolicy.c"
if [ -f "$SEP" ]; then
  python3 - "$SEP" <<'KSU_SEPOLICY_419_PY'
import sys, os

p = sys.argv[1]
NL = chr(10)
src = open(p, encoding='utf-8', errors='surrogateescape').read()

if 'ksu419_filenametr_hash' in src:
    print('[apply-kernelsu] sepolicy.c 4.19 结构适配已存在')
    sys.exit(0)

anchor_fn = '''static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,
                               const char *o)
{'''
if anchor_fn not in src:
    print('[apply-kernelsu] !! sepolicy.c add_filename_trans 锚点不匹配')
    sys.exit(0)

compat_block = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
/*
 * 4.19 filename_trans layout:
 *   struct filename_trans       { u32 stype, ttype; u16 tclass; const char *name; };
 *   struct filename_trans_datum { u32 otype; };
 *   policydb->filename_trans is a `struct hashtab *` created with
 *   filenametr_hash / filenametr_cmp (both take (struct hashtab*, const void*))
 *   and filled via hashtab_insert(h, key, datum).
 * There is no per-datum stypes bitmap and no ->next chain: one rule per
 * (stype, ttype, tclass, name) tuple, so a duplicate is simply overwritten.
 */
static u32 ksu419_filenametr_hash(struct hashtab *h, const void *k)
{
    const struct filename_trans *ft = k;
    unsigned long hash;
    unsigned int byte_num;
    unsigned char focus;

    hash = ft->stype ^ ft->ttype ^ ft->tclass;

    byte_num = 0;
    while ((focus = ft->name[byte_num++]))
        hash = partial_name_hash(focus, hash);
    return hash & (h->size - 1);
}

static int ksu419_filenametr_cmp(struct hashtab *h, const void *k1, const void *k2)
{
    const struct filename_trans *ft1 = k1;
    const struct filename_trans *ft2 = k2;
    int v;

    (void)h;

    v = ft1->stype - ft2->stype;
    if (v)
        return v;

    v = ft1->ttype - ft2->ttype;
    if (v)
        return v;

    v = ft1->tclass - ft2->tclass;
    if (v)
        return v;

    return strcmp(ft1->name, ft2->name);
}

static struct filename_trans_datum *ksu419_filenametr_search(struct policydb *db, struct filename_trans *key)
{
    return hashtab_search(db->filename_trans, key);
}
#endif /* < 5.9 */

''' + anchor_fn
src = src.replace(anchor_fn, compat_block, 1)

old_decl = '''    struct type_datum *src, *tgt, *def;
    struct class_datum *cls;
    struct filename_trans_key *new_key = NULL;
    int rc;
'''
new_decl = '''    struct type_datum *src, *tgt, *def;
    struct class_datum *cls;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    struct filename_trans_key *new_key = NULL;
#else
    struct filename_trans *new_key = NULL;
#endif
    int rc;
'''
if old_decl not in src:
    print('[apply-kernelsu] !! add_filename_trans 声明锚点不匹配')
else:
    src = src.replace(old_decl, new_decl, 1)
    print('[apply-kernelsu] add_filename_trans 声明已适配')

old_region = '''    struct filename_trans_key key;
    key.ttype = tgt->value;
    key.tclass = cls->value;
    key.name = (char *)o;

    struct filename_trans_datum *last = NULL;
'''
if old_region not in src:
    print('[apply-kernelsu] !! filename_trans key 锚点不匹配')
else:
    # find the whole >=5.9 block that ends right before "free_name:"
    start = src.index(old_region)
    tail_marker = '''    db->compat_filename_trans_count++;
    return ebitmap_set_bit(&trans->stypes, src->value - 1, 1) == 0;
'''
    tail = src.index(tail_marker, start)
    end = tail + len(tail_marker)
    new_block = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)' + NL + src[start:end] + '''#else
    /*
     * 4.19: the key IS the struct filename_trans (it carries stype), and the
     * datum is just { u32 otype; }. A duplicate tuple is overwritten in place.
     */
    struct filename_trans key;
    key.stype = src->value;
    key.ttype = tgt->value;
    key.tclass = cls->value;
    key.name = (char *)o;

    struct filename_trans_datum *trans = ksu419_filenametr_search(db, &key);

    if (trans != NULL) {
        /* Exact (stype,ttype,tclass,name) already present: just retarget it. */
        trans->otype = def->value;
        return true;
    }

    trans = (struct filename_trans_datum *)kcalloc(1, sizeof(*trans), GFP_KERNEL);
    if (!trans) {
        pr_err("add_filename_trans: alloc filename_trans_datum failed''' + '\\n' + '''");
        goto out;
    }
    trans->otype = def->value;

    new_key = (struct filename_trans *)kzalloc(sizeof(*new_key), GFP_KERNEL);
    if (!new_key) {
        pr_err("add_filename_trans: alloc filename_trans failed''' + '\\n' + '''");
        goto free_trans;
    }
    *new_key = key;
    new_key->name = kstrdup(key.name, GFP_KERNEL);
    if (!new_key->name) {
        pr_err("add_filename_trans: kstrdup name failed''' + '\\n' + '''");
        goto free_key;
    }

    rc = hashtab_insert(db->filename_trans, new_key, trans);
    if (rc) {
        pr_err("add_filename_trans: hashtab_insert failed: %d''' + '\\n' + '''", rc);
        goto free_name;
    }

    /* ttype now has rules, so record it for the fast-path lookup */
    if (ebitmap_set_bit(&db->filename_trans_ttypes, tgt->value, 1)) {
        pr_err("add_filename_trans: set ttype bitmap failed''' + '\\n' + '''");
        goto free_name;
    }

    return true;
#endif
'''
    src = src[:start] + new_block + src[end:]
    print('[apply-kernelsu] add_filename_trans 主体已适配')

old_tav = '''    struct ebitmap *new_type_attr_map_array =
        ksu_kvrealloc(db->type_attr_map_array, value * sizeof(struct ebitmap), (value - 1) * sizeof(struct ebitmap));
'''
if old_tav not in src:
    print('[apply-kernelsu] !! type_attr_map_array 锚点不匹配')
else:
    tav_tail = '''    db->sym_val_to_name[SYM_TYPES] = new_val_to_name_types;
    db->sym_val_to_name[SYM_TYPES][value - 1] = key;
'''
    s2 = src.index(old_tav)
    e2 = src.index(tav_tail, s2) + len(tav_tail)
    orig_tav = src[s2:e2]
    new_tav = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)' + NL + orig_tav + '''#else
    /*
     * 4.19: type_attr_map_array / type_val_to_struct_array / sym_val_to_name[]
     * are all `struct flex_array *` containers pre-sized to p_types.nprim by
     * policydb_init(). Only the counters grow here; the containers do not.
     */
    if (value > db->p_types.nprim) {
        pr_err("add_type: flex_array overflow (%d > %d)''' + '\\n' + '''", value, db->p_types.nprim);
        return false;
    }

    {
        struct ebitmap *attr_map_slot = flex_array_get_ptr(db->type_attr_map_array, value - 1);
        if (!attr_map_slot) {
            pr_err("add_type: no type_attr_map slot for value %d''' + '\\n' + '''", value);
            return false;
        }
        ebitmap_init(attr_map_slot);
        ebitmap_set_bit(attr_map_slot, value - 1, 1);
    }

    if (flex_array_put_ptr(db->type_val_to_struct_array, value - 1, type, GFP_KERNEL)) {
        pr_err("add_type: flex_array_put type_val_to_struct failed''' + '\\n' + '''");
        return false;
    }

    if (flex_array_put_ptr(db->sym_val_to_name[SYM_TYPES], value - 1, key, GFP_KERNEL)) {
        pr_err("add_type: flex_array_put val_to_name failed''' + '\\n' + '''");
        return false;
    }
#endif''')
    src = src[:s2] + new_tav + src[e2:]
    print('[apply-kernelsu] type_attr_map_array 已适配')

old_attr = '''    struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];
    ebitmap_set_bit(sattr, attr->value - 1, 1);'''
new_attr = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)
    struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];
#else
    struct ebitmap *sattr = flex_array_get_ptr(db->type_attr_map_array, type->value - 1);
    if (!sattr) {
        pr_err("add_typeattribute: no attr map slot for value %d''' + '\\n' + '''", type->value);
        return;
    }
#endif
    ebitmap_set_bit(sattr, attr->value - 1, 1);'''
if old_attr not in src:
    print('[apply-kernelsu] !! add_typeattribute_raw 锚点不匹配')
else:
    src = src.replace(old_attr, new_attr, 1)
    print('[apply-kernelsu] add_typeattribute_raw 已适配')

# ---- C) avtab hash slots: 4.19 uses flex_array, 5.4+ uses plain pointer array ----
if 'ksu419_avtab_slot' not in src:
    _h = chr(10)
    helper = ''.join([
        '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)', _h,
        '/* 4.19 keeps avtab hash slots inside a flex_array, not a plain pointer array. */', _h,
        'static inline struct avtab_node *ksu419_avtab_slot(struct avtab *h, u32 i)', _h,
        '{', _h,
        '    return (struct avtab_node *)flex_array_get_ptr(h->htable, i);', _h,
        '}', _h,
        _h,
        'static inline void ksu419_avtab_set_slot(struct avtab *h, u32 i, struct avtab_node *n)', _h,
        '{', _h,
        '    flex_array_put_ptr(h->htable, i, n, GFP_KERNEL);', _h,
        '}', _h,
        '#endif', _h,
        _h,
        'static bool remove_avtab_node(struct policydb *db, struct avtab_node *node)', _h,
        '{'])
    old_sig = 'static bool remove_avtab_node(struct policydb *db, struct avtab_node *node)' + _h + '{'
    if old_sig in src:
        src = src.replace(old_sig, helper, 1)
        print('[apply-kernelsu] avtab slot helper 已加入')
    else:
        print('[apply-kernelsu] !! remove_avtab_node 锚点不匹配')

    old_loop = ''.join([
        '    for (i = 0; i < db->te_avtab.nslot; i++) {', _h,
        '        prev = NULL;', _h,
        '        for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {'])
    new_loop = ''.join([
        '    for (i = 0; i < db->te_avtab.nslot; i++) {', _h,
        '        prev = NULL;', _h,
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)', _h,
        '        for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {', _h,
        '#else', _h,
        '        for (n = ksu419_avtab_slot(&db->te_avtab, i); n; prev = n, n = n->next) {', _h,
        '#endif'])
    if old_loop in src:
        src = src.replace(old_loop, new_loop, 1)
        print('[apply-kernelsu] avtab 遍历槽位已适配')
    else:
        print('[apply-kernelsu] !! avtab 遍历锚点不匹配')

    old_set = ''.join([
        '            if (prev)', _h,
        '                prev->next = n->next;', _h,
        '            else', _h,
        '                db->te_avtab.htable[i] = n->next;', _h])
    new_set = ''.join([
        '            if (prev)', _h,
        '                prev->next = n->next;', _h,
        '            else {', _h,
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)', _h,
        '                db->te_avtab.htable[i] = n->next;', _h,
        '#else', _h,
        '                ksu419_avtab_set_slot(&db->te_avtab, i, n->next);', _h,
        '#endif', _h,
        '            }', _h])
    if old_set in src:
        src = src.replace(old_set, new_set, 1)
        print('[apply-kernelsu] avtab 槽位置空已适配')
    else:
        print('[apply-kernelsu] !! avtab 置空锚点不匹配')

    old_rem = ''.join([
        '            n->next = NULL;', _h,
        '            removed.htable[0] = n;', _h,
        '            removed.nel = 1;'])
    new_rem = ''.join([
        '            n->next = NULL;', _h,
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)', _h,
        '            removed.htable[0] = n;', _h,
        '#else', _h,
        '            ksu419_avtab_set_slot(&removed, 0, n);', _h,
        '#endif', _h,
        '            removed.nel = 1;'])
    if old_rem in src:
        src = src.replace(old_rem, new_rem, 1)
        print('[apply-kernelsu] avtab removed 槽位已适配')
    else:
        print('[apply-kernelsu] !! avtab removed 锚点不匹配')

open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(src)
lines = src.split(NL)
a = sum(1 for l in lines if l.lstrip().startswith('#if'))
b = sum(1 for l in lines if l.lstrip().startswith('#endif'))
print('[apply-kernelsu] sepolicy.c 4.19 适配完成  #if=%d #endif=%d balanced=%s' % (a, b, a == b))
KSU_SEPOLICY_419_PY
fi
# ---------- 兜底补丁 11：sulog/event.c 的 4.19 头文件适配 ----------
# SukiSU v4.3.0 的 kernel/sulog/event.c 引用了 <linux/minmax.h>，
# 该头文件是 Linux 5.8 才从 linux/kernel.h 里拆出来的，4.19 不存在。
#
# 注意（重要，避免再踩坑）：
#   * <linux/overflow.h> 在 4.19 里是【存在】的（4.6 起就有），
#     所以绝不能给它做 shim，否则会和内核自己的 check_add_overflow 冲突
#     （-Werror,-Wmacro-redefined）。
#   * <linux/kernel.h> 在任何版本都存在，5.8+ 的 kernel.h 内部又会包含
#     minmax.h，因此「统一改 include linux/kernel.h」对 4.19 和 5.8+ 都正确，
#     而且不需要 LINUX_VERSION_CODE，也就不会踩到「version.h 尚未包含」的坑
#     （-Werror,-Wundef）。
SULOG_EVENT="KernelSU/kernel/sulog/event.c"
if [ -f "$SULOG_EVENT" ]; then
  python3 - "$SULOG_EVENT" <<'KSU_SULOG_419_PY'
import sys

p = sys.argv[1]
NL = chr(10)
src = open(p, encoding='utf-8', errors='surrogateescape').read()

if '#include <linux/minmax.h>' not in src:
    print('[apply-kernelsu] sulog/event.c 无需适配（或已适配）')
    sys.exit(0)

src = src.replace(
    '#include <linux/minmax.h>',
    '/* 4.19: min/max/clamp/min_t/max_t 在 linux/kernel.h 中；' + NL +
    ' * 5.8+ 的 kernel.h 也会包含 minmax.h，两者都安全。 */' + NL +
    '#include <linux/kernel.h>',
    1)

open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(src)

lines = src.split(NL)
a = sum(1 for l in lines if l.lstrip().startswith('#if'))
b = sum(1 for l in lines if l.lstrip().startswith('#endif'))
print('[apply-kernelsu] sulog/event.c: minmax.h -> kernel.h  #if=%d #endif=%d' % (a, b))
KSU_SULOG_419_PY
fi

# ---------- 兜底补丁 12：supercall/dispatch.c 的 4.19 头文件适配 ----------
# dispatch.c 的 do_set_init_pgrp() 用到 4 个符号，但没包含声明它们的头文件：
#   tasklist_lock               -> include/linux/sched/task.h   (4.19 L40: extern rwlock_t)
#   init_task                   -> include/linux/sched/task.h   (4.19 L44: extern struct task_struct)
#   task_pgrp() / task_session()-> include/linux/sched/signal.h (4.19 L631/L636: static inline)
#
# 新版内核靠间接包含碰巧编过，4.19 的头文件层级不同，直接报
#   "use of undeclared identifier 'tasklist_lock'"
#   "implicit declaration of function 'task_pgrp'"
#   "use of undeclared identifier 'init_task'"
# 并连带把 task_pgrp(p) != init_group 判成指针/整数比较（-Werror,-Wpointer-integer-compare）。
# 这两个头文件在所有内核版本里都存在且幂等，无条件补齐即可，功能无任何改动。
DISPATCH="KernelSU/kernel/supercall/dispatch.c"
if [ -f "$DISPATCH" ]; then
  python3 - "$DISPATCH" <<'KSU_DISPATCH_419_PY'
import sys

p = sys.argv[1]
NL = chr(10)
src = open(p, encoding='utf-8', errors='surrogateescape').read()

if 'ksu419 sched includes' in src:
    print('[apply-kernelsu] supercall/dispatch.c 已适配')
    sys.exit(0)

anchor = '#include <linux/thread_info.h>'
if anchor not in src:
    print('[apply-kernelsu] !! dispatch.c 锚点不匹配，跳过')
    sys.exit(0)

block = (anchor + NL +
         '/* ksu419 sched includes: tasklist_lock / init_task / task_pgrp / task_session */' + NL +
         '#include <linux/sched/signal.h>' + NL +
         '#include <linux/sched/task.h>')

src = src.replace(anchor, block, 1)
open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(src)

lines = src.split(NL)
a = sum(1 for l in lines if l.lstrip().startswith('#if'))
b = sum(1 for l in lines if l.lstrip().startswith('#endif'))
print('[apply-kernelsu] supercall/dispatch.c: 已补 sched/signal.h + sched/task.h  #if=%d #endif=%d' % (a, b))
KSU_DISPATCH_419_PY
fi

# ---------- 兜底补丁 13：selinux_hide.c / sepolicy.h 的 4.19 深度适配 ----------
# 补丁 10 解决了「策略从哪来、怎么提交」，补丁 13 解决剩下的结构差异：
#
# 1) sepolicy.h 用了 LINUX_VERSION_CODE 却没有包含 <linux/version.h>
#    （version.h 在 selinux_hide.c 是第 13 行才引入，头文件里看不到）
#    -> sepolicy.h:8: 'LINUX_VERSION_CODE' is not defined [-Werror,-Wundef]
#
# 2) symtab_search() 是 5.9 才有的符号，sepolicy.c 自己定义了宏，
#    但 selinux_hide.c 也用它 -> implicit declaration
#    -> 把宏提到 sepolicy.h 里，两处共用
#
# 3) selinux_state.status_lock / status_page
#    5.7+ : 在 struct selinux_state 里
#    4.19 : 在 struct selinux_ss 里（selinux_state.ss->...）
#
# 4) sidtab 条目与字符串缓存
#    5.4+ : sidtab_search_entry() 返回 struct sidtab_entry *，
#           还有 sidtab_sid2str_get/put 缓存
#    4.19 : sidtab_search() 直接返回 struct context *，没有字符串缓存
#           所以 sidtab_entry_to_string + security_sid_to_context_with_policy
#           两个函数在 4.19 下合并成一个直接转换
#
# 5) policydb->type_val_to_struct / type_attr_map_array
#    5.4+ : 普通指针数组
#    4.19 : struct flex_array *，要用 flex_array_get_ptr()
#
# 全部改动都包在 #if LINUX_VERSION_CODE 里：新内核走原路径，功能零变动。
# 注意：必须先做文本替换、再插入兼容宏，否则宏自身的 selinux_state.xxx
#       会被一起替换成 #define ksu_status_lock (ksu_status_lock) 自引用。
SEL_H="KernelSU/kernel/selinux/sepolicy.h"
SEL_C="KernelSU/kernel/selinux/sepolicy.c"
HIDE_C="KernelSU/kernel/feature/selinux_hide.c"
if [ -f "$HIDE_C" ]; then
  python3 - "$SEL_H" "$SEL_C" "$HIDE_C" <<'KSU_HIDE419_PY'
import sys, io, os

sel_h, sel_c, hide_c = sys.argv[1], sys.argv[2], sys.argv[3]
NL = chr(10)
done = []


def rd(p):
    return io.open(p, encoding='utf-8', errors='surrogateescape').read()


def wr(p, s):
    io.open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(s)


def bal(s):
    a = sum(1 for l in s.split(NL) if l.lstrip().startswith('#if'))
    b = sum(1 for l in s.split(NL) if l.lstrip().startswith('#endif'))
    return a, b


# ---------------- 1) sepolicy.h : version.h + symtab_search ----------------
if os.path.exists(sel_h):
    s = rd(sel_h)
    if 'ksu419 symtab' in s:
        print('[apply-kernelsu] sepolicy.h 已适配')
    else:
        anchor = '#include "ss/policydb.h"'
        if anchor not in s:
            print('[apply-kernelsu] !! sepolicy.h 锚点不匹配')
        else:
            add = (anchor + NL + NL +
                   '/* ksu419 symtab: version.h for LINUX_VERSION_CODE, and symtab_search' + NL +
                   ' * which only exists since 5.9 (hashtab_insert/search changed signature). */' + NL +
                   '#include <linux/version.h>' + NL + NL +
                   '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)' + NL +
                   '#ifndef symtab_search' + NL +
                   '#define symtab_search(s, name) hashtab_search((s)->table, name)' + NL +
                   '#endif' + NL +
                   '#endif')
            s = s.replace(anchor, add, 1)
            wr(sel_h, s)
            done.append('sepolicy.h')
            print('[apply-kernelsu] sepolicy.h: 已补 version.h + symtab_search  %d/%d' % bal(s))

# ---------------- 2) sepolicy.c : 避免宏重定义 ----------------
if os.path.exists(sel_c):
    s = rd(sel_c)
    old = '#define symtab_search(s, name) hashtab_search((s)->table, name)'
    if '#ifndef symtab_search' not in s and old in s:
        s = s.replace(old, '#ifndef symtab_search' + NL + old + NL + '#endif', 1)
        wr(sel_c, s)
        done.append('sepolicy.c(macro)')
        print('[apply-kernelsu] sepolicy.c: symtab_search 宏已加 #ifndef 保护')

# ---------------- 3) selinux_hide.c ----------------
if not os.path.exists(hide_c):
    print('[apply-kernelsu] !! selinux_hide.c 不存在')
    sys.exit(0)

s = rd(hide_c)

if 'ksu419 status/type compat' in s:
    print('[apply-kernelsu] selinux_hide.c 已适配')
else:
    # --- 3a) 先替换 status_lock / status_page（避免宏自身被替换） ---
    n1 = s.count('&selinux_state.status_lock')
    s = s.replace('&selinux_state.status_lock', 'ksu_status_lock')
    n2 = s.count('selinux_state.status_page')
    s = s.replace('selinux_state.status_page', 'ksu_status_page')
    print('[apply-kernelsu] selinux_hide.c: status_lock x%d, status_page x%d' % (n1, n2))

    # --- 3b) type_val_to_struct / type_attr_map_array ---
    reps = [
        ('policydb->type_val_to_struct[scontext->type - 1]',
         'ksu_type_by_val(policydb, scontext->type - 1)'),
        ('policydb->type_val_to_struct[tcontext->type - 1]',
         'ksu_type_by_val(policydb, tcontext->type - 1)'),
        ('&policydb->type_attr_map_array[scontext->type - 1]',
         'ksu_type_attr_map(policydb, scontext->type - 1)'),
        ('&policydb->type_attr_map_array[tcontext->type - 1]',
         'ksu_type_attr_map(policydb, tcontext->type - 1)'),
    ]
    for a, b in reps:
        if a in s:
            s = s.replace(a, b)
            print('[apply-kernelsu] selinux_hide.c: %s' % a.strip())
        else:
            print('[apply-kernelsu] !! 未找到: %s' % a.strip())

    # --- 3c) 最后插入兼容宏 ---
    anchor = 'static DEFINE_MUTEX(selinux_hide_mutex);'
    mac = '''/* ksu419 status/type compat */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0)
/* 4.19: status_page / status_lock live in struct selinux_ss (moved in 5.7) */
#define ksu_status_lock (&selinux_state.ss->status_lock)
#define ksu_status_page (selinux_state.ss->status_page)
#else
#define ksu_status_lock (&selinux_state.status_lock)
#define ksu_status_page (selinux_state.status_page)
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)
/* 4.19: policydb keeps flex_array, not plain pointer arrays */
#define ksu_type_by_val(p, i) \\
    ((struct type_datum *)flex_array_get_ptr((p)->type_val_to_struct_array, (i)))
#define ksu_type_attr_map(p, i) \\
    ((struct ebitmap *)flex_array_get_ptr((p)->type_attr_map_array, (i)))
#else
#define ksu_type_by_val(p, i) ((p)->type_val_to_struct[(i)])
#define ksu_type_attr_map(p, i) (&(p)->type_attr_map_array[(i)])
#endif

static DEFINE_MUTEX(selinux_hide_mutex);'''
    if anchor in s:
        s = s.replace(anchor, mac, 1)
    else:
        print('[apply-kernelsu] !! selinux_hide 宏锚点不匹配')

    # --- 3d) sidtab 块：整段包进 #if/#else/#endif ---
    a_i = s.find('static int sidtab_entry_to_string(')
    b_i = s.find('static void avd_init(')
    if a_i < 0 or b_i < 0 or b_i <= a_i:
        print('[apply-kernelsu] !! selinux_hide sidtab 块锚点不匹配')
    else:
        legacy = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)
/*
 * 4.19: sidtab_search() returns the struct context * directly (stable while
 * RCU-locked) and there is no SID->string cache, so the entry helper and the
 * sid2str cache collapse into one direct conversion.
 */
static int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid,
                                               char **scontext, u32 *scontext_len)
{
    struct policydb *policydb;
    struct sidtab *sidtab;
    struct context *context;

    if (scontext)
        *scontext = NULL;
    *scontext_len = 0;

    policydb = &policy->policydb;
    sidtab = policy->sidtab;

    context = sidtab_search(sidtab, sid);
    if (!context) {
        pr_err("SELinux: %s:  unrecognized SID %d ksu_nl", __func__, sid);
        return -EINVAL;
    }

    return context_struct_to_string(policydb, context, scontext, scontext_len);
}
#else
'''.replace(' ksu_nl', '\\n')
        s = s[:a_i] + legacy + s[a_i:b_i] + '#endif' + NL + NL + s[b_i:]
        print('[apply-kernelsu] selinux_hide.c: sidtab 块已按 4.19 分叉')

    wr(hide_c, s)
    done.append('selinux_hide.c')
    print('[apply-kernelsu] selinux_hide.c: #if=%d #endif=%d' % bal(s))

if done:
    print('[apply-kernelsu] 补丁13 完成: ' + ', '.join(done))
KSU_HIDE419_PY
fi

# ---------- 兜底补丁 14：链接期两个未定义符号 ----------
# 走到链接说明所有 .c 都编过了。剩余两个符号：
#
# A) seccomp_filter_release
#    policy/app_profile.c 里 disable_seccomp() 直接调用它，并自己写了声明。
#    该函数是 5.9 才加入的（commit 0d8315dddd28）。4.19 的等价物是
#    put_seccomp_filter(task_struct *)，见 include/linux/seccomp.h:83 声明、
#    kernel/seccomp.c:524 定义（非 static，可链接）。
#    语义一致：fake 是 current 在清空 seccomp.filter 之前的副本，
#    put_seccomp_filter(fake) 正好释放旧 filter 的那一份引用。
#
# B) backup_sepolicy
#    补丁 10 把它挪进了「5.10+ 或 KSU_COMPAT_HAS_POLICY_MUTEX」分支，
#    4.19 分支改用 backup_policydb。但 include/ksu.h 里仍无条件
#    extern struct selinux_policy *backup_sepolicy;，feature/selinux_hide.c
#    到处在用它 => 链接失败。
#    正确做法不是删掉引用，而是让 4.19 分支也真正提供 backup_sepolicy：
#    一个自带 policydb 副本 + 独立 sidtab（policydb_load_isids 装载）的
#    shadow 结构，selinux_hide 就能像新内核一样对着「原始策略」做转换。
APP_PROF="KernelSU/kernel/policy/app_profile.c"
RULES_C="KernelSU/kernel/selinux/rules.c"
HIDE_C2="KernelSU/kernel/feature/selinux_hide.c"
if [ -f "$APP_PROF" ] && [ -f "$RULES_C" ]; then
  python3 - "$APP_PROF" "$RULES_C" "$HIDE_C2" <<'KSU_LINK419_PY'
import sys, io, os

app, rules, hide = sys.argv[1], sys.argv[2], sys.argv[3]
NL = chr(10)
done = []


def rd(p):
    return io.open(p, encoding='utf-8', errors='surrogateescape').read()


def wr(p, s):
    io.open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(s)


# ---------------- A) app_profile.c : seccomp_filter_release ----------------
s = rd(app)
if 'ksu419 seccomp' in s:
    print('[apply-kernelsu] app_profile.c seccomp 已适配')
else:
    decl = 'void seccomp_filter_release(struct task_struct *tsk);'
    new_decl = ('''/* ksu419 seccomp */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
void seccomp_filter_release(struct task_struct *tsk);
#endif''')
    if decl in s:
        s = s.replace(decl, new_decl, 1)
    else:
        print('[apply-kernelsu] !! app_profile 声明锚点不匹配')

    call = '    seccomp_filter_release(fake);'
    new_call = ('''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    seccomp_filter_release(fake);
#else
    /* 4.19: seccomp_filter_release() arrived in 5.9. The equivalent is
     * put_seccomp_filter() (include/linux/seccomp.h), which drops this task's
     * reference to seccomp.filter and frees single-reference chains.
     * `fake` is a copy of current taken before seccomp.filter was cleared, so
     * it still holds the old filter reference we need to release here. */
    put_seccomp_filter(fake);
#endif''')
    if call in s:
        s = s.replace(call, new_call, 1)
    else:
        print('[apply-kernelsu] !! app_profile 调用锚点不匹配')

    # 确保能看到 put_seccomp_filter 的声明（CONFIG_SECCOMP=n 时是空内联）
    if '#include <linux/seccomp.h>' not in s:
        idx = s.find('#include <linux/')
        if idx >= 0:
            s = s[:idx] + '#include <linux/seccomp.h>' + NL + s[idx:]
            print('[apply-kernelsu] app_profile.c: 已补 linux/seccomp.h')
    wr(app, s)
    done.append('app_profile.c')

# ---------------- B) rules.c : 4.19 分支真正提供 backup_sepolicy ----------------
s = rd(rules)
if 'backup_sepolicy = kzalloc(sizeof(*backup_sepolicy)' in s:
    print('[apply-kernelsu] rules.c backup_sepolicy 已适配')
else:
    old_decl = '''/* 4.19 legacy: backup holds an independent policydb copy */
static struct policydb *backup_policydb;'''
    new_decl = '''/* 4.19 legacy: backup_sepolicy owns an independent policydb copy plus its
 * own sidtab, so feature/selinux_hide.c can convert contexts against the
 * ORIGINAL policy exactly like it does on newer kernels. */
struct selinux_policy *backup_sepolicy;'''
    if old_decl in s:
        s = s.replace(old_decl, new_decl, 1)
        print('[apply-kernelsu] rules.c: 4.19 分支已声明 backup_sepolicy')
    else:
        print('[apply-kernelsu] !! rules.c 声明锚点不匹配')

    old_blk = '''    backup_policydb = kzalloc(sizeof(*backup_policydb), GFP_KERNEL);
    if (backup_policydb) {
        int blen = ksu_dup_policydb_only(&selinux_state.ss->policydb, backup_policydb);
        if (blen < 0) {
            pr_err("failed to dup backup policydb: %d ksu_nl", blen);
            kfree(backup_policydb);
            backup_policydb = NULL;
        } else {
            pr_info("backup sepolicy success! ksu_nl");
        }
    }'''.replace(' ksu_nl', '\\n')

    new_blk = '''    backup_sepolicy = kzalloc(sizeof(*backup_sepolicy), GFP_KERNEL);
    if (backup_sepolicy) {
        int blen = ksu_dup_policydb_only(&selinux_state.ss->policydb, &backup_sepolicy->policydb);
        if (blen < 0) {
            pr_err("failed to dup backup policydb: %d ksu_nl", blen);
            kfree(backup_sepolicy);
            backup_sepolicy = NULL;
        } else {
            backup_sepolicy->latest_granting = selinux_state.ss->latest_granting;
            backup_sepolicy->sidtab = kzalloc(sizeof(struct sidtab), GFP_KERNEL);
            if (!backup_sepolicy->sidtab) {
                pr_err("failed to alloc backup sidtab ksu_nl");
            } else if (policydb_load_isids(&backup_sepolicy->policydb, backup_sepolicy->sidtab)) {
                pr_err("failed to load isids for backup sepolicy! ksu_nl");
                kfree(backup_sepolicy->sidtab);
                backup_sepolicy->sidtab = NULL;
            } else {
                pr_info("backup sepolicy success! ksu_nl");
            }
        }
    }'''.replace(' ksu_nl', '\\n')

    if old_blk in s:
        s = s.replace(old_blk, new_blk, 1)
        print('[apply-kernelsu] rules.c: 4.19 backup_sepolicy 已含 policydb 副本 + sidtab')
    else:
        print('[apply-kernelsu] !! rules.c 备份块锚点不匹配')
    wr(rules, s)
    done.append('rules.c')

# ---------------- C) selinux_hide.c : legacy 释放路径要连 sidtab 一起放 ----------------
if os.path.exists(hide):
    s = rd(hide)
    old_drop = '''        /* 4.19 legacy: backup_sepolicy is a shadow struct that only holds a
           copy of the policydb; the sidtab pointer is borrowed from
           selinux_ss, so it must NOT be destroyed or freed here. */
        ksu_destroy_policydb_only(&backup_sepolicy->policydb);
        kfree(backup_sepolicy);'''
    new_drop = '''        /* 4.19 legacy: backup_sepolicy owns both its policydb copy and its
           own sidtab (allocated in rules.c), so release both. */
        if (backup_sepolicy->sidtab) {
            sidtab_destroy(backup_sepolicy->sidtab);
            kfree(backup_sepolicy->sidtab);
        }
        ksu_destroy_policydb_only(&backup_sepolicy->policydb);
        kfree(backup_sepolicy);'''
    if new_drop in s:
        print('[apply-kernelsu] selinux_hide.c 释放路径已适配')
    elif old_drop in s:
        s = s.replace(old_drop, new_drop, 1)
        wr(hide, s)
        done.append('selinux_hide.c(drop)')
        print('[apply-kernelsu] selinux_hide.c: legacy 释放路径已补 sidtab')
    else:
        print('[apply-kernelsu] !! selinux_hide 释放路径锚点不匹配')

if done:
    print('[apply-kernelsu] 补丁14 完成: ' + ', '.join(done))
else:
    print('[apply-kernelsu] 补丁14 无改动')
KSU_LINK419_PY
fi

# ---------- 兜底补丁 15：patch_memory.c 的 4.19 大页(block)映射支持 —— 最关键的一处 ----------
# 症状（已从 pstore/ramoops 的 console-ramoops-0 实测确认）：
#   KernelSU: welcome to KernelSU version 41130, package name com.sukisu.ultra
#   KernelSU: sys_call_table=0xffffffad772009d8
#   KernelSU: patch syscall 42, 0xffffffad75c91c94 -> 0xffffffad76a9cefc
#   KernelSU: failed to find phy addr for patch dst addr 0xffffffad77200b28
#   KernelSU: patch syscall 42 failed
#   KernelSU: lsm_hook: init, tracked hooks=0
#   0.23 秒后：
#   init: Could not stat("/"), not freeing ramdisk: Function not implemented
#   init: Failed to create FirstStageMount : failed to read default fstab
#   reboot: Restarting system with command 'bootloader'
#
# 根因：kernel/hook/arm64/patch_memory.c 里 phys_from_virt() 用
#     #if defined(pmd_leaf)   /   #if defined(pud_leaf)
# 来识别「大页」。pmd_leaf() 与 pud_leaf() 是 Linux 5.4 才引入的接口，
# 4.19 上根本不存在，于是这两段分支被预处理器整体跳过。
# 而 ARM64 的内核镜像正是用 2MB block 描述符映射的，跳过之后代码继续往下走到
#     if (pmd_none(*pmd) || pmd_bad(*pmd)) goto fail;
# 而 arm64 的 pmd_bad() 定义是 !(pmd_val(pmd) & PTE_TABLE_BIT)，
# block 描述符的 bit1 本来就是 0 —— 于是每个 block 都被判成「坏表项」，
# 必然走到 fail，报 failed to find phy addr。
# 结论：只要内核镜像走大页映射（KASLR 后 image 落在 vmalloc 区时一定是），
# 这条路径 100% 失败，KSU 一个字节都写不进 sys_call_table。
#
# 修法：在 #else 分支里按 4.19 的真实语义识别 block 描述符（PTE_TABLE_BIT 为 0），
# 物理基址取 pmd_val & PMD_MASK。5.4+ 仍然走 pmd_leaf() 原路径，行为完全不变。
# 同时把 phys_from_virt() 里的页表逐层 pr_debug 提升为 pr_info：
# 万一还有下一层问题，刷完直接从 /sys/fs/pstore/console-ramoops-0 就能看到
# 卡在 pgd / p4d / pud / pmd 的哪一层，不必再靠猜。
PM="KernelSU/kernel/hook/arm64/patch_memory.c"
if [ -f "$PM" ]; then
  python3 - "$PM" <<'KSU_PATCHMEM_419_PY'
import sys

p = sys.argv[1]
NL = chr(10)
src = open(p, encoding='utf-8', errors='surrogateescape').read()

if 'ksu419 pmd block' in src:
    print('[apply-kernelsu] patch_memory.c 已适配 4.19 block 映射')
    sys.exit(0)

# PTE_TABLE_BIT / PMD_MASK 来自 asm/pgtable.h，显式带上更保险
if '#include <asm/pgtable.h>' not in src:
    anchor_inc = '#include "asm-generic/fixmap.h"'
    if anchor_inc in src:
        src = src.replace(anchor_inc, anchor_inc + NL + '#include <asm/pgtable.h>', 1)

old = '''#if defined(pmd_leaf)
    if (pmd_leaf(*pmd)) {
        pr_debug("Address 0x%lx maps to a PMD-level huge page\\n", addr);
        return __pmd_to_phys(*pmd) + ((addr & ~PMD_MASK));
    }
#endif'''

new = '''#if defined(pmd_leaf)
    if (pmd_leaf(*pmd)) {
        pr_debug("Address 0x%lx maps to a PMD-level huge page\\n", addr);
        return __pmd_to_phys(*pmd) + ((addr & ~PMD_MASK));
    }
#else
    /* ksu419 pmd block: pmd_leaf() does not exist before Linux 5.4.
     * On arm64 a block (leaf) descriptor is exactly the one whose
     * PTE_TABLE_BIT is clear, and the kernel image is mapped with 2 MB
     * blocks. Without this branch the walk falls through to pmd_bad(),
     * which reports every block as a bad table entry, so the whole patch
     * fails with "failed to find phy addr". */
    if (!pmd_none(*pmd) && !(pmd_val(*pmd) & PTE_TABLE_BIT)) {
        pr_info("Address 0x%lx maps to a PMD-level block\\n", addr);
        return (pmd_val(*pmd) & PMD_MASK) + (addr & ~PMD_MASK);
    }
#endif'''

if old not in src:
    print('[apply-kernelsu] !! patch_memory.c pmd 锚点不匹配')
else:
    src = src.replace(old, new, 1)
    print('[apply-kernelsu] patch_memory.c: 已补 4.19 PMD block 映射识别')

# 诊断增强：phys_from_virt 的逐层日志 pr_debug -> pr_info
n = 0
for tag in ('pgd of', 'p4d of', 'pud of', 'pmd of'):
    frag = 'pr_debug("' + tag
    n += src.count(frag)
    src = src.replace(frag, 'pr_info("' + tag)

open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(src)
print('[apply-kernelsu] patch_memory.c: 页表逐层日志提升为 pr_info (%d 处)' % n)
KSU_PATCHMEM_419_PY
fi

# ---------- 兜底补丁 16：4.19 上 SELinux 策略注入把 policydb 写坏 ----------
# 症状（pstore/ramoops 的 dmesg-ramoops-0 实测，PMD15 内核）：
#   KernelSU: sys_call_table=0xffffffafb8a009d8
#   KernelSU: Address 0xffffffafb8a00b28 maps to a PMD-level block
#   KernelSU: dispatcher installed at slot 42          <- 补丁15 生效，表项真的换掉了
#   ...
#   KernelSU: /system/bin/init second_stage executed
#   KernelSU: backup sepolicy success!
#   KernelSU: add_type: no type_attr_map slot for value 3404
#   KernelSU: add_typeattribute: no attr map slot for value 3404
#   KernelSU: add_type: no type_attr_map slot for value 3405
#   KernelSU: class memfd_file does not exist  (x5)
#   9 毫秒后：
#   Unable to handle kernel paging request at virtual address 46dfcaee747d730a
#   pc : hashtab_search+0x28    <- SELinux 策略库的哈希表指针已成乱码
#   Call trace: hashtab_search / string_to_context_struct / security_context_to_sid_core
#               / cache_sid / ksu_handle_execveat_ksud / ksu_syscall_dispatcher
#
# 根因有两处，都在 4.19 的 flex_array 语义上：
#  1) Linux < 5.4 的 policydb 把 type_attr_map_array / type_val_to_struct_array /
#     sym_val_to_name[SYM_TYPES] 全放在 struct flex_array 里，由 policydb_init()
#     按当时的 p_types.nprim 一次性定长分配，之后不可扩容。SELinux 自己从不在
#     运行时加类型，但 KernelSU 要加 ksu / ksu_file 两个域，于是
#     `u32 value = ++db->p_types.nprim;` 只把计数器加了，三张表并没有变大。
#  2) 取元素用错了访问器。type_attr_map_array 的元素是 struct ebitmap 本体，
#     必须用 flex_array_get()，而补丁里写的是 flex_array_get_ptr() —— 后者会
#     把元素首 8 字节当成指针解引用，也就是把 ebitmap 内部的 node 指针返回出来，
#     随后 ebitmap_set_bit() 把一颗真正的 ebitmap_node 当成 ebitmap 去写。
#
# 修法：计数自增前先把三张表按 need+8 扩容（内容原样搬过去），并把
# flex_array_get_ptr() 换成 flex_array_get()。5.4+ 完全不受影响（仍走原分支）。
SP="KernelSU/kernel/selinux/sepolicy.c"
if [ -f "$SP" ]; then
  python3 - "$SP" <<'KSU_SEPOLICY_419_PY'
import sys

p = sys.argv[1]
NL = chr(10)
src = open(p, encoding='utf-8', errors='surrogateescape').read()

if 'ksu419_grow_type_arrays' in src:
    print('[apply-kernelsu] sepolicy.c 已适配 4.19 flex_array')
    sys.exit(0)

done = []

# ---- A) 需要 flex_array API ----
if 'flex_array.h' not in src:
    anchor_inc = '#include <linux/vmalloc.h>'
    if anchor_inc in src:
        src = src.replace(anchor_inc, anchor_inc + NL + '#include <linux/flex_array.h>', 1)
        done.append('flex_array.h')
    else:
        print('[apply-kernelsu] !! sepolicy.c 头文件锚点不匹配')

# ---- B) 扩容辅助函数，插在 add_type 定义之前 ----
helper = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)
/*
 * ksu419 grow: before Linux 5.4 SELinux keeps the per-type tables in
 * struct flex_array, sized once from p_types.nprim by policydb_init() and
 * never resizable.  SELinux itself never adds types at runtime, KernelSU
 * does though.  Bumping p_types.nprim without enlarging these three tables
 * leaves the policydb internally inconsistent, and the first context
 * lookup after the policy has been swapped in walks a slot of the old,
 * smaller table -> "Unable to handle kernel paging request" in
 * hashtab_search().  So enlarge them before the counter moves.
 */
static int ksu419_grow_type_arrays(struct policydb *db, u32 need)
{
    u32 old_nr;
    u32 new_nr;
    u32 i;
    struct flex_array *fa;
    void *e;

    old_nr = (u32)db->type_attr_map_array->total_nr_elements;
    if (need <= old_nr)
        return 0;
    new_nr = need + 8;

    /* 1) type_attr_map_array: elements are struct ebitmap, not pointers */
    fa = flex_array_alloc(sizeof(struct ebitmap), new_nr, GFP_KERNEL | __GFP_ZERO);
    if (!fa)
        return -ENOMEM;
    for (i = 0; i < old_nr; i++) {
        e = flex_array_get(db->type_attr_map_array, i);
        if (!e)
            continue;
        if (flex_array_put(fa, i, e, GFP_KERNEL)) {
            flex_array_free(fa);
            return -ENOMEM;
        }
    }
    flex_array_free(db->type_attr_map_array);
    db->type_attr_map_array = fa;

    /* 2) type_val_to_struct_array: elements are struct type_datum * */
    fa = flex_array_alloc(sizeof(void *), new_nr, GFP_KERNEL | __GFP_ZERO);
    if (!fa)
        return -ENOMEM;
    for (i = 0; i < old_nr; i++) {
        e = flex_array_get_ptr(db->type_val_to_struct_array, i);
        if (!e)
            continue;
        if (flex_array_put_ptr(fa, i, e, GFP_KERNEL)) {
            flex_array_free(fa);
            return -ENOMEM;
        }
    }
    flex_array_free(db->type_val_to_struct_array);
    db->type_val_to_struct_array = fa;

    /* 3) sym_val_to_name[SYM_TYPES]: elements are char * */
    fa = flex_array_alloc(sizeof(void *), new_nr, GFP_KERNEL | __GFP_ZERO);
    if (!fa)
        return -ENOMEM;
    for (i = 0; i < old_nr; i++) {
        e = flex_array_get_ptr(db->sym_val_to_name[SYM_TYPES], i);
        if (!e)
            continue;
        if (flex_array_put_ptr(fa, i, e, GFP_KERNEL)) {
            flex_array_free(fa);
            return -ENOMEM;
        }
    }
    flex_array_free(db->sym_val_to_name[SYM_TYPES]);
    db->sym_val_to_name[SYM_TYPES] = fa;

    pr_info("ksu419: per-type tables grown %u -> %u\\n", old_nr, new_nr);
    return 0;
}
#endif

'''
anchor_def = 'static bool add_type(struct policydb *db, const char *type_name, bool attr)' + NL + '{'
if 'ksu419_grow_type_arrays' not in src and anchor_def in src:
    src = src.replace(anchor_def, helper + anchor_def, 1)
    done.append('grow helper')
else:
    print('[apply-kernelsu] !! sepolicy.c add_type 定义锚点不匹配')

# ---- C) 计数自增前扩容 ----
old_inc = '    u32 value = ++db->p_types.nprim;'
new_inc = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)
    if (ksu419_grow_type_arrays(db, db->p_types.nprim + 1))
        return false;
#endif
    u32 value = ++db->p_types.nprim;'''
if old_inc in src:
    src = src.replace(old_inc, new_inc, 1)
    done.append('grow before nprim++')
else:
    print('[apply-kernelsu] !! sepolicy.c nprim 自增锚点不匹配')

# ---- D) 元素是结构体，必须用 flex_array_get() 而不是 get_ptr() ----
n_fix = src.count('flex_array_get_ptr(db->type_attr_map_array')
if n_fix:
    src = src.replace('flex_array_get_ptr(db->type_attr_map_array',
                      'flex_array_get(db->type_attr_map_array')
    done.append('get_ptr->get x%d' % n_fix)
else:
    print('[apply-kernelsu] !! sepolicy.c type_attr_map_array 访问器未找到')

open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(src)
print('[apply-kernelsu] 补丁16 完成: ' + ', '.join(done))
KSU_SEPOLICY_419_PY
fi

# selinux_hide.c 里同一个坑：早期补丁加的 ksu_type_attr_map() 宏也用了
# flex_array_get_ptr()，而 type_attr_map_array 的元素是 struct ebitmap 本体。
# 它返回的是 ebitmap.node，随后 ebitmap_for_each_positive_bit() 会沿
# ebitmap_node->startbit 当指针走，属于同一类内存损坏，必须一并改掉。
# （ksu_type_by_val() 用的是 type_val_to_struct_array，元素确实是指针，保持不动。）
SH="KernelSU/kernel/feature/selinux_hide.c"
if [ -f "$SH" ]; then
  python3 - "$SH" <<'KSU_SELHIDE_419_PY'
import sys

p = sys.argv[1]
NL = chr(10)
src = open(p, encoding='utf-8', errors='surrogateescape').read()

old = '((struct ebitmap *)flex_array_get_ptr((p)->type_attr_map_array, (i)))'
new = '((struct ebitmap *)flex_array_get((p)->type_attr_map_array, (i)))'

if new in src:
    print('[apply-kernelsu] selinux_hide.c 已适配 type_attr_map_array 访问器')
    sys.exit(0)
if old in src:
    src = src.replace(old, new, 1)
    open(p, 'w', encoding='utf-8', errors='surrogateescape', newline=NL).write(src)
    print('[apply-kernelsu] selinux_hide.c: ksu_type_attr_map 改用 flex_array_get')
else:
    print('[apply-kernelsu] !! selinux_hide.c type_attr_map_array 宏未找到')
KSU_SELHIDE_419_PY
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
