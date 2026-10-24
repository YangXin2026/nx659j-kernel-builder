#!/usr/bin/env bash
# 统一内核补丁：vdso32 跳过、compat 类型 fallback、vdso32 头移除
set -euo pipefail
K="${1:-kernel}"

python3 - "$K" <<'PY'
import os, re, sys
k = sys.argv[1]

# 1) vdso32 Makefile：用 arm gcc，去掉 --target append
p = os.path.join(k, 'arch/arm64/kernel/vdso32/Makefile')
if os.path.exists(p):
    s = open(p).read()
    s = s.replace('CC_COMPAT ?= $(CC)', 'CC_COMPAT := arm-linux-gnueabi-gcc')
    s = s.replace('LD_COMPAT ?= $(LD)', 'LD_COMPAT := arm-linux-gnueabi-ld')
    s = re.sub(r'^CC_COMPAT \+= --target=arm-linux-gnueabi\n', '', s, flags=re.M)
    open(p, 'w').write(s)

# 2) vdso.h：不引用 vdso32 offsets
p = os.path.join(k, 'arch/arm64/include/asm/vdso.h')
if os.path.exists(p):
    s = open(p).read().replace('#include <generated/vdso32-offsets.h>\n', '')
    open(p, 'w').write(s)

# 3) filter.h：非 COMPAT 下补 compat_uptr_t / compat_ptr
p = os.path.join(k, 'include/linux/filter.h')
if os.path.exists(p):
    s = open(p).read()
    if 'typedef u32 compat_uptr_t' not in s and '#include <linux/compat.h>' in s:
        block = (
            '#ifndef CONFIG_COMPAT\n'
            'typedef u32 compat_uptr_t;\n'
            'static inline void __user *compat_ptr(compat_uptr_t uptr) '
            '{ return (void __user *)(unsigned long)uptr; }\n'
            '#endif\n'
        )
        s = s.replace('#include <linux/compat.h>',
                      '#include <linux/compat.h>\n' + block, 1)
        open(p, 'w').write(s)

print('kernel patches applied')
PY
