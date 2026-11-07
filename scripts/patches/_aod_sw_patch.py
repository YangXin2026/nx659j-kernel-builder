#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NX659J GSI 自定义 AOD 状态机（内核层，补丁21）

问题链：
  GSI 的 AOD/LP1 会执行 dsi_panel_set_lp1()（dmesg 里成对的
  "Regulator ibb was not found" 就是它的 dsi_pwr_panel_regulator_mode_set），
  该函数无条件发 dsi_panel_notifier(MSM_DRM_AOD_EVENT, MSM_DRM_MAJOR_AOD_ON)；
  但触摸 IC 的 synaptics_rmi4_fb_notifier_cb 从未被触发（dmesg 里连
  [LCD_OFF] 都没有），tp_mode_state 永远停在 AOD_OFF。
  于是 synaptics_nubia_fp_mode_store 写 1 只置 FP_ENTER，
  synaptics_nubiactl_resume() 看到 LCD_ON_AOD_OFF_FP_ENTER 立刻
  &= FP_EXIT 并 resume -> 熄屏指纹手势模式进不去。

做法（用户要求的「自己定义低功耗状态」，但不碰供电时序）：
  dsi_panel.c 在 LP1 / NOLP 时通过一个弱符号直接把 AOD_ON+FP_ENTER /
  AOD_OFF+FP_EXIT 推给触摸驱动；触摸驱动导出该函数并复用原有
  synaptics_nubiactl_resume() 状态机。
  - 不改 ibb regulator、不改 dtbo、不动 system/vendor
  - 不需要任何 Magisk/KSU 模块或用户态轮询
  - LP1 原路径照走，功耗不因此增加
  - 弱符号保证 TP 驱动未编入时 dsi_panel.c 仍可编译/链接

幂等：以 NX659J_AOD_SW 为标记，重复执行自动跳过。
"""
import os
import sys

MARK = "NX659J_AOD_SW"
PANEL = "techpack/display/msm/dsi/dsi_panel.c"
TP = "drivers/input/touchscreen/synaptics_dsx_nubia/synaptics_dsx_core.c"


def read(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
        f.write(s)


def patch_panel(path):
    s = read(path)
    if MARK in s:
        print("SKIP dsi_panel.c: already patched")
        return False

    # 1) 弱声明，放在已有的 CONFIG_MACH_NUBIA_NX659J include 块里
    old_inc = """#ifdef CONFIG_MACH_NUBIA_NX659J
#include <linux/msm_drm_notify.h>
#endif
"""
    new_inc = """#ifdef CONFIG_MACH_NUBIA_NX659J
#include <linux/msm_drm_notify.h>

/* NX659J_AOD_SW: GSI 自定义 AOD 状态机。
 * 触摸驱动的入口做成弱符号，未编入 TP 驱动时链接仍成立。 */
extern void synaptics_nubia_aod_fp_enable(bool on) __attribute__((weak));
#endif
"""
    if old_inc not in s:
        raise SystemExit("FAIL dsi_panel.c: include anchor not found")
    s = s.replace(old_inc, new_inc, 1)

    # 2) LP1 -> AOD_ON
    old_lp1 = """#ifdef CONFIG_MACH_NUBIA_NX659J
	dsi_panel_notifier(MSM_DRM_AOD_EVENT, MSM_DRM_MAJOR_AOD_ON);
#endif
"""
    new_lp1 = """#ifdef CONFIG_MACH_NUBIA_NX659J
	dsi_panel_notifier(MSM_DRM_AOD_EVENT, MSM_DRM_MAJOR_AOD_ON);
	/* NX659J_AOD_SW: 标准 fb notifier 链在 GSI 上没送到触摸 IC，
	 * 直接把 AOD_ON + FP_ENTER 推过去，让 TP 进入指纹手势监听。
	 * 供电 / LP1 DSI 命令保持原样，不引入额外功耗。 */
	if (synaptics_nubia_aod_fp_enable)
		synaptics_nubia_aod_fp_enable(true);
	pr_info("NX659J_AOD_SW: LP1 -> AOD_ON (tp=%s)\\n",
		synaptics_nubia_aod_fp_enable ? "pushed" : "absent");
#endif
"""
    if old_lp1 not in s:
        raise SystemExit("FAIL dsi_panel.c: set_lp1 AOD_ON anchor not found")
    s = s.replace(old_lp1, new_lp1, 1)

    # 3) NOLP -> AOD_OFF
    old_nolp = "\tdsi_panel_notifier(MSM_DRM_AOD_EVENT, MSM_DRM_MAJOR_AOD_OFF);\n"
    new_nolp = """	dsi_panel_notifier(MSM_DRM_AOD_EVENT, MSM_DRM_MAJOR_AOD_OFF);
	/* NX659J_AOD_SW: 亮屏退出 AOD，恢复普通触摸 */
	if (synaptics_nubia_aod_fp_enable)
		synaptics_nubia_aod_fp_enable(false);
	pr_info("NX659J_AOD_SW: NOLP -> AOD_OFF\\n");
"""
    if old_nolp not in s:
        raise SystemExit("FAIL dsi_panel.c: set_nolp AOD_OFF anchor not found")
    s = s.replace(old_nolp, new_nolp, 1)

    write(path, s)
    print("OK  dsi_panel.c: weak decl + LP1/NOLP hooks (%d marks)" % s.count(MARK))
    return True


def patch_tp(path):
    s = read(path)
    if MARK in s:
        print("SKIP synaptics_dsx_core.c: already patched")
        return False

    # 1) 导出函数：插在 synaptics_nubiactl_resume 前向声明之后（该声明已存在）
    anchor = "static void synaptics_nubiactl_resume(struct synaptics_rmi4_data *rmi4_data);\n"
    if anchor not in s:
        raise SystemExit("FAIL tp: forward decl anchor not found")

    fn = anchor + """
/* NX659J_AOD_SW: 由 dsi_panel_set_lp1()/set_nolp() 驱动的自定义 AOD 状态。
 * GSI 上 CONFIG_DRM_MSM 未开、标准 fb notifier 链是空实现，AOD_ON 事件
 * 到不了本驱动；这里给显示侧一个直接入口，复用原有状态机。 */
void synaptics_nubia_aod_fp_enable(bool on)
{
	struct synaptics_rmi4_data *rmi4_data = g_rmi4_data;

	if (!rmi4_data) {
		pr_info("NX659J_AOD_SW: tp not ready, AOD %s ignored\\n",
			on ? "ON" : "OFF");
		return;
	}

	if (on) {
		rmi4_data->tp_mode_state |= AOD_ON;
		rmi4_data->tp_mode_state |= FP_ENTER;
		rmi4_data->enable_fod_gesture = 1;
	} else {
		rmi4_data->tp_mode_state &= AOD_OFF;
		rmi4_data->tp_mode_state &= FP_EXIT;
		rmi4_data->enable_fod_gesture = 0;
	}
	synaptics_nubiactl_resume(rmi4_data);
	pr_info("NX659J_AOD_SW: AOD %s -> state=%d gesture=%d\\n",
		on ? "ON" : "OFF", rmi4_data->tp_mode_state,
		rmi4_data->enable_fod_gesture);
}
EXPORT_SYMBOL(synaptics_nubia_aod_fp_enable);
"""
    s = s.replace(anchor, fn, 1)

    # 2) notifier 回调入口诊断日志（确认事件到底有没有送达）
    cb_head = """static int synaptics_rmi4_fb_notifier_cb(struct notifier_block *self,
		unsigned long event, void *data)
{
	int *transition;
"""
    cb_new = """static int synaptics_rmi4_fb_notifier_cb(struct notifier_block *self,
		unsigned long event, void *data)
{
	int *transition;
"""
    if cb_head not in s:
        raise SystemExit("FAIL tp: notifier cb anchor not found")
    # 不改函数体，只在 mndata 声明之后插入日志
    mndata = """	struct msm_drm_notifier *mndata = data;

	if (!mndata || (mndata->id != 0))
"""
    mndata_new = """	struct msm_drm_notifier *mndata = data;

	/* NX659J_AOD_SW: 诊断这条链是否真的有事件进来 */
	if (event == MSM_DRM_AOD_EVENT || event == MSM_DRM_EARLY_EVENT_BLANK)
		pr_info("NX659J_AOD_SW: notifier ev=%lu id=%d val=%d\\n",
			event, mndata ? (int)mndata->id : -1,
			(mndata && mndata->data) ? *(int *)mndata->data : -1);

	if (!mndata || (mndata->id != 0))
"""
    if mndata not in s:
        print("WARN tp: notifier mndata anchor not found, skip diag log")
    else:
        s = s.replace(mndata, mndata_new, 1)

    write(path, s)
    print("OK  synaptics_dsx_core.c: exported hook + diag (%d marks)" % s.count(MARK))
    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    for rel in (PANEL, TP):
        p = os.path.join(root, rel)
        if not os.path.isfile(p):
            print("WARN missing %s (skip)" % p)
            continue
        if rel == PANEL:
            patch_panel(p)
        else:
            patch_tp(p)


if __name__ == "__main__":
    main()
