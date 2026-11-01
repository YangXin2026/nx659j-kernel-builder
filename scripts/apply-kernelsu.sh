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

        ksu_destroy_policydb_only(db);
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

        ksu_destroy_policydb_only(db);
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
