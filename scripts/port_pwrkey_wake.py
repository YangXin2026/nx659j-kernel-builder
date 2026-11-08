#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
补丁31：熄屏指纹按下 -> 上报 KEY_POWER -> 亮屏进锁屏 -> 锁屏指纹解锁

用户需求（2026-11-08）：
  "在熄屏里面识别到指纹按下了之后，就亮屏进锁屏，再进行指纹识别"。
  即不做「熄屏直接解锁」，而是复用已打通的锁屏指纹链路：
  手指按下 → 电源键 → 亮屏 → Keyguard → 指纹 HAL 正常识别。

真机实测依据：
  1) 熄屏按压时触摸驱动确实收到 FP_DOWN_DATA（dmesg 多次复现）。
  2) 向 event1（gf9558）注入 KEY_POWER(116)：
       mWakefulness: Dozing -> Awake
       mDreamingLockscreen=true
       system_server 稳定，无崩溃
     （event6 的 KEY_WAKEUP(143) 实测无效，所以必须走 event1）
  3) gf9558 的 keybit 含 0x74=116 KEY_POWER，event6 不含。

实现（最小改动，两处）：
  A. gf_spi.c 追加导出函数 gf_report_power_key()，
     直接用已有的 gf.input 上报 KEY_POWER 按下+抬起。
  B. synaptics_dsx_core.c 在 synaptics_nubia_report_handler() 的
     case FP_DOWN_DATA 里调用（弱符号，gf 驱动没编入也不影响链接）。

安全约束（历史教训）：
  - 绝不向 event6 注入 KEY_POWER —— 之前造成 display-mode 重新协商死锁、
    zygote 被 SIGKILL 的无限重启。
  - 只在 rmi4_data->suspend（熄屏）时触发，亮屏时的指纹触摸不动作。
"""
import os
import sys

MARK = "NX659J_SCRNOFF_PWRKEY"
GF = "drivers/input/fingerprint/gf_spi.c"
TP = "drivers/input/touchscreen/synaptics_dsx_nubia/synaptics_dsx_core.c"

# ---------------------------------------------------------------- gf 侧
GF_ADD = (
    "\n/* " + MARK + ": 熄屏指纹按下时由触摸驱动调用，向 gf9558(event1) 上报 KEY_POWER，\n"
    " * 让系统走原厂电源键路径亮屏并进入锁屏，再由锁屏指纹正常解锁。\n"
    " * 使用的 input 设备与 HAL 的 /dev/goodix_fp 是同一颗芯片，安全。 */\n"
    "void gf_report_power_key(void)\n"
    "{\n"
    "\tif (!gf.input)\n"
    "\t\treturn;\n"
    "\n"
    "\tinput_report_key(gf.input, KEY_POWER, 1);\n"
    "\tinput_sync(gf.input);\n"
    "\tinput_report_key(gf.input, KEY_POWER, 0);\n"
    "\tinput_sync(gf.input);\n"
    "}\n"
    "EXPORT_SYMBOL(gf_report_power_key);\n"
)

# ---------------------------------------------------------------- 触摸侧
TP_DECL = (
    "\n/* " + MARK + ": gf 驱动导出的电源键上报"
    "（gf 未编入时为空指针，不影响链接） */\n"
    "extern void gf_report_power_key(void) __attribute__((weak));\n"
)

TP_HOOK = (
    "\t\tcase FP_DOWN_DATA:\n"
    "\t\t\t/* " + MARK + ": 熄屏时手指按下 -> 发电源键亮屏进锁屏。\n"
    "\t\t\t * 只处理熄屏态，且只在从抬起变为按下时触发一次。 */\n"
    "\t\t\tif (rmi4_data->suspend && !rmi4_data->fp_down_input_flag) {\n"
    "\t\t\t\tif (gf_report_power_key) {\n"
    "\t\t\t\t\tgf_report_power_key();\n"
    "\t\t\t\t\tpr_info(\"" + MARK + ": FP_DOWN on screen-off -> KEY_POWER\\n\");\n"
    "\t\t\t\t} else {\n"
    "\t\t\t\t\tpr_info(\"" + MARK + ": gf not builtin, skip KEY_POWER\\n\");\n"
    "\t\t\t\t}\n"
    "\t\t\t}\n"
)


def read(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
        f.write(s)


def patch_gf(p):
    s = read(p)
    if MARK in s:
        print("SKIP gf_spi.c")
        return
    # 追加到文件末尾（放在所有函数之后，static 变量 gf 已在 L80 定义）
    s = s.rstrip("\n") + "\n" + GF_ADD
    write(p, s)
    print("OK  gf_spi.c: gf_report_power_key() 导出")


def patch_tp(p):
    s = read(p)
    if MARK in s:
        print("SKIP synaptics_dsx_core.c")
        return

    # 1) 弱符号声明，放在 report_handler 定义之前
    anchor = """static int synaptics_nubia_report_handler(struct synaptics_rmi4_data *rmi4_data,
		int nubia_x, int nubia_y, unsigned char gesture_type)
{
	switch (gesture_type) {
		case FP_DOWN_DATA:
"""
    if anchor not in s:
        raise SystemExit("FAIL tp: report_handler FP_DOWN anchor not found")

    new = (TP_DECL + "\n" +
           "static int synaptics_nubia_report_handler(struct synaptics_rmi4_data *rmi4_data,\n"
           "\t\tint nubia_x, int nubia_y, unsigned char gesture_type)\n"
           "{\n"
           "\tswitch (gesture_type) {\n" +
           TP_HOOK)
    s = s.replace(anchor, new, 1)
    write(p, s)
    print("OK  synaptics_dsx_core.c: FP_DOWN -> KEY_POWER 挂钩")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    j = lambda rel: os.path.join(root, rel)
    for rel in (GF, TP):
        if not os.path.isfile(j(rel)):
            raise SystemExit("FAIL missing: %s" % rel)
    patch_gf(j(GF))
    patch_tp(j(TP))
    print("[%s] done" % MARK)


if __name__ == "__main__":
    main()
