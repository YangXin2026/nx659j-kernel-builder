#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NX659J GSI 熄屏指纹：AOD 下 fod_ui 通知桥（内核层，补丁22）

=== 为什么需要它（实机证据链，2026-11-07）===
亮屏锁屏：input swipe 540 2156 800ms -> fod_ui 0->1(约400ms)->0，
          [GF_HAL] 完整采图（get_raw_data_time=129ms / onAcquired(6)）。整条链通。
AOD/DOZE：同样的注入 -> fod_ui 全程 0、GF_HAL 零日志、屏幕始终 DOZE。

资料库 03-指纹与FOD/FOD-GSI-SOLUTION.md：
  vendor HAL (fingerprint@2.3-service.nubia) 内含 libudfpshandler.so，
  轮询 /sys/.../dsi-display-primary/fod_ui：
      fod_ui 1 -> IGoodixFingerprintDaemon::sendCommand(1536)  // finger down
      fod_ui 0 -> sendCommand(1537)                            // finger up
  fod_ui 由 sde_connector_pre_update_fod_hbm() 依据
  sde_connector_is_fod_enabled()（CRTC 上是否有 FOD dim layer）翻转。
  GSI AOD 态不画 UDFPS 图层 -> fod_ui 恒 0 -> HAL 一次都不采图。

补丁21 已把触摸 IC 推进 AOD 手势态（AOD_ON|FP_ENTER），dmesg 实证
能识别 FP_DOWN_DATA(32)/FP_UP_DATA(33) 9 次；但那是「原厂 gesture->goodix IRQ」
路线，与 GSI 的「UDFPS 图层->fod_ui->HAL」不是同一条，二者不能混用
（资料库 11-原厂机制/04-指纹与FOD.md §6.2 已警告）。

=== 本补丁做什么 ===
把触摸驱动 synaptics_nubia_report_handler() 在 AOD 手势态已经识别到的
FP_DOWN / FP_UP，用弱符号直接桥接到 dsi_panel_set_fod_ui()：
  - 该函数自带 sysfs_notify，正是 vendor HAL 轮询所需的信号
  - 加保护位，防止显示栈 sde_connector_pre_update_fod_hbm() 在
    下一次 commit 时把 fod_ui 又清回 0
  - 只在 AOD/LP1 窗口内生效（nx659j_aod_panel 非空）；NOLP 立即复位
  - 把当年 Magisk 模块 fp-fod-trigger 干的事下沉到内核：
    不改 system/vendor、不需要任何用户态守护、不是「软件模块」

=== 刻意不做（重要）===
不改 HBM、不改背光、不改 dtbo、不动 framework RRO。
补丁20 曾因整屏 HBM 常亮被用户实测「闪瞎」，本补丁零亮度改动。
若 HAL 能采图但图像质量不足，再单独评估温和打光。

幂等：以 NX659J_AOD_FOD 为标记，重复执行自动跳过。
"""
import os
import sys

MARK = "NX659J_AOD_FOD"
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

    # 1) 内核符号导出头 + 全局状态，插在 dsi_panel_get_fod_ui 之前
    anchor = "bool dsi_panel_get_fod_ui(struct dsi_panel *panel)\n"
    if anchor not in s:
        raise SystemExit("FAIL dsi_panel.c: get_fod_ui anchor not found")

    glob = """/* NX659J_AOD_FOD: 自定义 AOD 指纹通知桥。
 * GSI 的 AOD 不画 UDFPS 调光层，fod_ui 恒 0，vendor HAL 不会采图。
 * 这里允许触摸驱动在 AOD 手势态直接驱动 fod_ui（自带 sysfs_notify）。
 * 注意：只补通知，不改 HBM / 背光 / 供电，避免整屏过亮。 */
static struct dsi_panel *nx659j_aod_panel;
static bool nx659j_aod_fod_down;

"""
    s = s.replace(anchor, glob + anchor, 1)

    # 2) 给 dsi_panel_set_fod_ui 加保护：AOD 手指按着时禁止显示栈清 0
    old_set = """void dsi_panel_set_fod_ui(struct dsi_panel *panel, bool status)
{
	panel->fod_ui = status;

	sysfs_notify(&panel->parent->kobj, NULL, "fod_ui");
}
"""
    new_set = """void dsi_panel_set_fod_ui(struct dsi_panel *panel, bool status)
{
	/* NX659J_AOD_FOD: 自定义 AOD 指纹按下期间，显示栈每次 commit 都会
	 * 以 "没有 FOD dim layer" 为由把 fod_ui 清 0；那会打断 HAL 采图。
	 * 手指抬起（nx659j_aod_fod_down 已先置 false）后即恢复正常路径。 */
	if (nx659j_aod_fod_down && !status)
		return;

	panel->fod_ui = status;

	sysfs_notify(&panel->parent->kobj, NULL, "fod_ui");
}

/* NX659J_AOD_FOD: 供触摸驱动调用的入口（built-in，弱符号引用）。 */
void nx659j_aod_fod_notify(bool down)
{
	struct dsi_panel *panel = nx659j_aod_panel;

	if (!panel) {
		pr_debug("NX659J_AOD_FOD: not in AOD, FP_%s ignored\\n",
			down ? "DOWN" : "UP");
		return;
	}

	/* 先改保护位：down 时启用、up 时放行 set_fod_ui(false) */
	nx659j_aod_fod_down = down;
	dsi_panel_set_fod_ui(panel, down);
	pr_info("NX659J_AOD_FOD: FP_%s -> fod_ui=%d (HAL cmd %s)\\n",
		down ? "DOWN" : "UP", down ? 1 : 0,
		down ? "1536" : "1537");
}
EXPORT_SYMBOL(nx659j_aod_fod_notify);
"""
    if old_set not in s:
        raise SystemExit("FAIL dsi_panel.c: set_fod_ui body not found")
    s = s.replace(old_set, new_set, 1)

    # 3) EXPORT_SYMBOL 需要的头（dsi_panel.c 原本没有 include）
    inc = "#include <linux/pwm.h>\n"
    if inc not in s:
        raise SystemExit("FAIL dsi_panel.c: pwm include anchor not found")
    s = s.replace(inc, inc + "#include <linux/export.h> /* NX659J_AOD_FOD */\n", 1)

    # 4) LP1：记录 panel，打开 AOD 指纹窗口（锚点用补丁21 已有的日志行）
    lp1 = """	pr_info("NX659J_AOD_SW: LP1 -> AOD_ON (tp=%s)\\n",
		synaptics_nubia_aod_fp_enable ? "pushed" : "absent");
"""
    lp1_new = lp1 + """	/* NX659J_AOD_FOD: AOD 窗口开始，允许 FP_DOWN/UP 驱动 fod_ui */
	nx659j_aod_panel = panel;
	nx659j_aod_fod_down = false;
	pr_info("NX659J_AOD_FOD: LP1 armed (fod_ui bridge ready)\\n");
"""
    if lp1 not in s:
        raise SystemExit("FAIL dsi_panel.c: LP1 anchor not found (patch21 missing?)")
    s = s.replace(lp1, lp1_new, 1)

    # 5) NOLP：复位并关闭窗口
    nolp = '\tpr_info("NX659J_AOD_SW: NOLP -> AOD_OFF\\n");\n'
    nolp_new = nolp + """	/* NX659J_AOD_FOD: 退出 AOD，强制复位，防止 fod_ui 残留 1 */
	nx659j_aod_fod_down = false;
	if (nx659j_aod_panel)
		dsi_panel_set_fod_ui(nx659j_aod_panel, false);
	nx659j_aod_panel = NULL;
	pr_info("NX659J_AOD_FOD: NOLP disarmed (fod_ui reset)\\n");
"""
    if nolp not in s:
        raise SystemExit("FAIL dsi_panel.c: NOLP anchor not found (patch21 missing?)")
    s = s.replace(nolp, nolp_new, 1)

    write(path, s)
    print("OK  dsi_panel.c: fod_ui bridge + guard + LP1/NOLP (%d marks)" % s.count(MARK))
    return True


def patch_tp(path):
    s = read(path)
    if MARK in s:
        print("SKIP synaptics_dsx_core.c: already patched")
        return False

    # 1) 弱声明，放在补丁21 导出函数之后（前向前已验证该锚点存在）
    anchor = "EXPORT_SYMBOL(synaptics_nubia_aod_fp_enable);\n"
    if anchor not in s:
        raise SystemExit("FAIL tp: patch21 export anchor not found")
    decl = anchor + """
/* NX659J_AOD_FOD: 显示侧的 fod_ui 通知入口，弱符号避免跨子系统强耦合。
 * 只在 AOD 手势态（suspend && enable_fod_gesture）被调用。 */
extern void nx659j_aod_fod_notify(bool down) __attribute__((weak));
"""
    s = s.replace(anchor, decl, 1)

    # 2) FP_DOWN：单次通知（首次按下，复用 fp_down_input_flag 去重）
    down_anchor = """				ts_err("---FP_DOWN_DATA-->[%d] flag[FP_DOWN]\\n",
				rmi4_data->gesture_detection[0]);
"""
    down_new = down_anchor + """				/* NX659J_AOD_FOD: 通知 vendor HAL 采图（内核态，不经过 UDFPS 图层） */
				if (nx659j_aod_fod_notify)
					nx659j_aod_fod_notify(true);
"""
    if down_anchor not in s:
        raise SystemExit("FAIL tp: FP_DOWN anchor not found")
    s = s.replace(down_anchor, down_new, 1)

    # 3) FP_UP：通知抬起
    up_anchor = """			ts_err("---FP_UP_DATA---->[%d] flag[FP_UP]\\n",
			rmi4_data->gesture_detection[0]);
"""
    up_new = up_anchor + """			/* NX659J_AOD_FOD: 通知 vendor HAL 结束采集 */
			if (nx659j_aod_fod_notify)
				nx659j_aod_fod_notify(false);
"""
    if up_anchor not in s:
        raise SystemExit("FAIL tp: FP_UP anchor not found")
    s = s.replace(up_anchor, up_new, 1)

    write(path, s)
    print("OK  synaptics_dsx_core.c: FP_DOWN/UP -> fod_ui (%d marks)" % s.count(MARK))
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
