#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NX659J GSI 熄屏指纹：按下瞬间走 backlight framework 打光（内核层，补丁24）

=== 补丁23 为什么失败（2026-11-07 真机实测）===
补丁23 在 FP_DOWN 的 work 里调 dsi_panel_set_backlight(panel, 2334)，
日志证明 work 每次都执行：
  NX659J_AOD_LIGHT: FP_DOWN -> bl 2047->2334 (alpha refreshed), fod_ui=1
  NX659J_AOD_LIGHT: FP_UP   -> bl 2047 restored, fod_ui=0
但 [GF_HAL] 每次都是 image_quality=0 / valid_area=0 /
GF_ERROR_PREPROCESS_FAILED(1011) —— 采到的仍是全黑图。

源码核查：dsi_panel_set_backlight() 在本树里只被 set_nolp() 用来清零，
它按 bl->type 直接发 MIPI DCS / PWM 亮度命令；AOD/LP1 面板处于自刷新态，
这些命令不生效。它并不是 framework/sysfs 调光走的那条路径。

=== 真正生效的路径（上次手动打光已实证）===
/sys/class/backlight/panel0-backlight/brightness 写入 255
  -> backlight framework store
  -> sde_backlight_device_update_status(bd)
  -> c_conn->ops.set_backlight(..., bl_lvl)   // 真正驱动面板
实测：image_quality 0 -> 42、valid_area 0 -> 78、onAuthenticated、
      accept 1->2、Waking up from Dozing (WAKE_REASON_BIOMETRIC)。

=== 本补丁做什么 ===
补丁22 的 notify 已改为「只置状态 + schedule_work()」；
补丁24 把 work 里的打光动作换成 backlight framework 的等价内核调用：
  bd = backlight_device_get_by_type(BACKLIGHT_RAW)   // 即 panel0-backlight
  saved = bd->props.brightness                       // AOD 下是 1
  bd->props.brightness = bd->props.max_brightness    // 255 -> 内核 4095
  backlight_update_status(bd)                        // 真正发光
  然后才 dsi_panel_set_fod_ui(panel, true) 通知 HAL 采图
FP_UP 立刻 fod_ui=0 + 恢复 saved + backlight_update_status(bd)，抬手就灭。
LP1/NOLP 成对管理，NOLP 强制收光并 cancel_work_sync。

=== 刻意不做（补丁20 的教训）===
- 不调 dsi_panel_set_hbm()：LP1 态发 HBM DSI 命令 = 整屏高亮常亮风险
- 不再调 dsi_panel_set_backlight()：死路径，且会与 framework 亮度竞争
- 不用任何用户态守护 / Magisk / KSU 模块，不改 framework / vendor / dtbo
- 不做 delayed debounce、不做 300ms 延迟关断

=== 上下文安全 ===
nx659j_aod_fod_notify() 来自触摸 IC 的 FP_DOWN/UP 上报路径，可能处于原子上下文；
backlight_update_status() 可睡眠，因此只置状态位并 schedule_work()，
实际打光在进程上下文串行完成，顺序保证「先发光、再通知 HAL」。

幂等：以 NX659J_AOD_LIGHT 为标记，重复执行自动跳过。
"""
import os
import sys

MARK = "NX659J_AOD_LIGHT"
PANEL = "techpack/display/msm/dsi/dsi_panel.c"


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
    if "NX659J_AOD_FOD" not in s:
        raise SystemExit("FAIL dsi_panel.c: patch22 missing")

    # 1) 工作者 + 状态，插在补丁22 的全局变量之后
    anchor = "static bool nx659j_aod_fod_down;\n"
    if anchor not in s:
        raise SystemExit("FAIL dsi_panel.c: patch22 globals anchor not found")

    light = r'''
/* NX659J_AOD_LIGHT: 补丁24 —— 走真正生效的 backlight framework 路径。
 * 补丁23 的 dsi_panel_set_backlight() 只发 MIPI DCS，AOD/LP1 自刷新态不生效，
 * 实测 image_quality 仍为 0。这里复现 sysfs brightness=255 的内核等价路径：
 * sde_backlight_device_update_status() -> c_conn->ops.set_backlight()。 */
static struct backlight_device *nx659j_aod_bd;
static int nx659j_aod_bd_saved;
static bool nx659j_aod_light_on;

/* dsi_panel_set_fod_ui() 定义在本文件稍后，显式声明避免隐式声明告警 */
void dsi_panel_set_fod_ui(struct dsi_panel *panel, bool status);

static void nx659j_aod_light_restore(void)
{
	if (!nx659j_aod_bd)
		return;
	nx659j_aod_bd->props.brightness = nx659j_aod_bd_saved;
	backlight_update_status(nx659j_aod_bd);
}

static void nx659j_aod_light_fn(struct work_struct *work)
{
	struct dsi_panel *panel = nx659j_aod_panel;
	bool down = nx659j_aod_fod_down;
	int peak;

	if (!panel)
		return;

	if (down && !nx659j_aod_light_on) {
		if (!nx659j_aod_bd)
			nx659j_aod_bd = backlight_device_get_by_type(BACKLIGHT_RAW);
		if (nx659j_aod_bd) {
			nx659j_aod_bd_saved = nx659j_aod_bd->props.brightness;
			peak = nx659j_aod_bd->props.max_brightness;
			nx659j_aod_bd->props.brightness = peak;
			backlight_update_status(nx659j_aod_bd);  /* 真正发光 */
		} else {
			peak = -1;
		}
		nx659j_aod_light_on = true;
		dsi_panel_set_fod_ui(panel, true);  /* 光到位后才通知 HAL 采图 */
		pr_info("NX659J_AOD_LIGHT: FP_DOWN -> bd %d->%d (framework path), fod_ui=1\n",
			nx659j_aod_bd_saved, peak);
	} else if (!down && nx659j_aod_light_on) {
		dsi_panel_set_fod_ui(panel, false);
		nx659j_aod_light_restore();
		nx659j_aod_light_on = false;
		pr_info("NX659J_AOD_LIGHT: FP_UP -> bd %d restored, fod_ui=0\n",
			nx659j_aod_bd_saved);
	}
}
static DECLARE_WORK(nx659j_aod_light_work, nx659j_aod_light_fn);
'''
    s = s.replace(anchor, anchor + light, 1)

    # 2) 需要的头（重复包含无害）
    inc = "#include <linux/export.h> /* NX659J_AOD_FOD */\n"
    if inc not in s:
        raise SystemExit("FAIL dsi_panel.c: patch22 include anchor not found")
    s = s.replace(inc, inc +
        "#include <linux/workqueue.h> /* NX659J_AOD_LIGHT */\n"
        "#include <linux/backlight.h> /* NX659J_AOD_LIGHT */\n", 1)

    # 3) notify：改为只置状态 + 调度 work，打光在进程上下文做
    old_notify = r'''void nx659j_aod_fod_notify(bool down)
{
	struct dsi_panel *panel = nx659j_aod_panel;

	if (!panel) {
		pr_debug("NX659J_AOD_FOD: not in AOD, FP_%s ignored\n",
			down ? "DOWN" : "UP");
		return;
	}

	/* 先改保护位：down 时启用、up 时放行 set_fod_ui(false) */
	nx659j_aod_fod_down = down;
	dsi_panel_set_fod_ui(panel, down);
	pr_info("NX659J_AOD_FOD: FP_%s -> fod_ui=%d (HAL cmd %s)\n",
		down ? "DOWN" : "UP", down ? 1 : 0,
		down ? "1536" : "1537");
}
'''
    new_notify = r'''void nx659j_aod_fod_notify(bool down)
{
	struct dsi_panel *panel = nx659j_aod_panel;

	if (!panel) {
		pr_debug("NX659J_AOD_FOD: not in AOD, FP_%s ignored\n",
			down ? "DOWN" : "UP");
		return;
	}

	/* 先改保护位：down 时启用、up 时放行 set_fod_ui(false) */
	nx659j_aod_fod_down = down;
	/* NX659J_AOD_LIGHT: backlight_update_status() 可睡眠，不能在 TP 上报路径
	 * 直接发；交给 work 串行完成「先打光、再置 fod_ui」的顺序。 */
	schedule_work(&nx659j_aod_light_work);
	pr_info("NX659J_AOD_FOD: FP_%s -> light work queued (HAL cmd %s)\n",
		down ? "DOWN" : "UP", down ? "1536" : "1537");
}
'''
    if old_notify not in s:
        raise SystemExit("FAIL dsi_panel.c: patch22 notify body not found")
    s = s.replace(old_notify, new_notify, 1)

    # 4) LP1：进入 AOD 窗口时清打光状态
    lp1 = '\tnx659j_aod_fod_down = false;\n\tpr_info("NX659J_AOD_FOD: LP1 armed (fod_ui bridge ready)\\n");\n'
    lp1_new = '\tnx659j_aod_fod_down = false;\n\tnx659j_aod_light_on = false; /* NX659J_AOD_LIGHT */\n\tpr_info("NX659J_AOD_FOD: LP1 armed (fod_ui bridge ready)\\n");\n'
    if lp1 not in s:
        raise SystemExit("FAIL dsi_panel.c: patch22 LP1 anchor not found")
    s = s.replace(lp1, lp1_new, 1)

    # 5) NOLP：退出 AOD 前强制收光、取消 work，防亮度残留
    nolp = '''	nx659j_aod_fod_down = false;
	if (nx659j_aod_panel)
		dsi_panel_set_fod_ui(nx659j_aod_panel, false);
	nx659j_aod_panel = NULL;
'''
    nolp_new = '''	nx659j_aod_fod_down = false;
	if (nx659j_aod_panel)
		dsi_panel_set_fod_ui(nx659j_aod_panel, false);
	/* NX659J_AOD_LIGHT: 退出 AOD 前收回打光，防止亮度残留 */
	if (nx659j_aod_light_on) {
		nx659j_aod_light_restore();
		nx659j_aod_light_on = false;
		pr_info("NX659J_AOD_LIGHT: NOLP bd restored to %d\\n",
			nx659j_aod_bd_saved);
	}
	cancel_work_sync(&nx659j_aod_light_work);
	nx659j_aod_panel = NULL;
'''
    if nolp not in s:
        raise SystemExit("FAIL dsi_panel.c: patch22 NOLP anchor not found")
    s = s.replace(nolp, nolp_new, 1)

    write(path, s)
    print("OK  dsi_panel.c: backlight framework path (%d marks)" % s.count(MARK))
    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    p = os.path.join(root, PANEL)
    if not os.path.isfile(p):
        print("WARN missing %s (skip)" % p)
        return
    patch_panel(p)


if __name__ == "__main__":
    main()
