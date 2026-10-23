# Phase 1 · 4.19 手动 hook 补丁（待生成）

SukiSU Ultra `builtin` 分支不使用 kprobes，需要内核源码调用 hook 入口。
本目录需要放入 `4.19-manual-hooks.patch`，由 `scripts/apply-sukisu.sh` 在 Phase 1 应用。

补丁需要覆盖的入口（以 builtin 分支头文件为准）：

| hook | 目标文件（4.19 LOS） | 头文件 |
|---|---|---|
| `ksu_handle_execveat_sucompat` / `ksu_handle_execve_sucompat` | `fs/exec.c`（`do_execveat_common`） | `kernel/feature/sucompat.h` |
| `ksu_handle_faccessat` | `fs/open.c`（`do_faccessat`） | `kernel/feature/sucompat.h` |
| `ksu_handle_stat` | `fs/stat.c`（`vfs_statx` / `vfs_fstatat`） | `kernel/feature/sucompat.h` |
| `ksu_handle_umount` | `fs/namespace.c`（`ksys_umount`） | `kernel/feature/kernel_umount.h` |
| `ksu_handle_execveat_ksud` | `fs/exec.c`（与 sucompat 同处） | `kernel/runtime/ksud.h` |
| `on_post_fs_data` / `on_module_mounted` / `on_boot_completed` | 对应内核事件点 | `kernel/runtime/ksud.h` |

要求：
- 逐函数核对 4.19 实际签名（builtin 头文件提供 `struct filename **` 与 `const char __user **` 两种变体）；
- 4.19 不需要 backport `set_memory.h`；
- 保持 `CONFIG_KALLSYMS=y`、`CONFIG_KALLSYMS_ALL=y`；
- 补丁应用失败时 Phase 1 必须失败，不能静默继续。
