#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
补丁30：把努比亚官方 AOD/HBM 显示驱动整块移植进 LineageOS 内核树。

已核实事实（2026-11-08）：
  内核源 = LineageOS/android_kernel_nubia_sm8250 (lineage-23.2)
  LineageOS 删掉了努比亚官方的：
    - techpack/display/msm/nubia_disp_preference.c/.h
      → 它就是 /sys/kernel/lcd_enhance/{hbm_mode, aod_mode} 的提供者
    - dsi_panel.c 里全部 CONFIG_NUBIA_AOD_HBM_MODE 块
      → nubia_dsi_panel_aod() / nubia_dsi_panel_hbm()
    - dsi_defs.h 里 DSI_CMD_SET_AOD_* / DSI_CMD_SET_HBM_FP_* 枚举
  官方树 nubia-development/android_kernel_nubia_sm8250 (nubia_sdm865_q-diff)
  里这些全在，且 DT 里 aod-command-* / hbm-command-* 属性齐备。

  指纹 HAL 屏灭打光写 /sys/kernel/lcd_enhance/hbm_mode
  值域：0=HBM_FP_OFF 1=HBM_FP_ON 23=HBM_OFF 24=HBM_ON

本补丁：
  A. 新增 nubia_disp_preference.c/.h（官方原文，含必要适配）
  B. dsi_defs.h：枚举按官方顺序重排，补 AOD/HBM-FP
  C. dsi_panel.c：prop_map/state_map 同步重排 + nubia_dsi_panel_aod/hbm
  D. dsi_panel.h：补声明
  E. Makefile / Kconfig / nx659j.config

幂等：MARK 判定。
"""
import os
import sys

MARK = "NX659J_OFFICIAL_AODHBM"
M = "techpack/display/msm"
DSI = M + "/dsi"

F_PREF_C = M + "/nubia_disp_preference.c"
F_PREF_H = M + "/nubia_disp_preference.h"
F_DEFS = DSI + "/dsi_defs.h"
F_PANEL_C = DSI + "/dsi_panel.c"
F_PANEL_H = DSI + "/dsi_panel.h"
F_DISP_C = DSI + "/dsi_display.c"
F_MK = M + "/Makefile"
F_KCONF = "drivers/gpu/drm/msm/Kconfig"
F_CFG = "arch/arm64/configs/vendor/nx659j.config"


def read(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(p, s):
    d = os.path.dirname(p)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
        f.write(s)


def sub_once(s, old, new, what):
    if old not in s:
        raise SystemExit("FAIL %s: anchor not found" % what)
    return s.replace(old, new, 1)


# ============================================================ A. 新增两个文件

PREF_H = r'''/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * nubia_disp_preference.h
 *
 * NX659J_OFFICIAL_AODHBM: 原样移植自努比亚官方
 *   nubia-development/android_kernel_nubia_sm8250 (nubia_sdm865_q-diff)
 *   techpack/display/msm/nubia_disp_preference.h
 */
#ifndef _NUBIA_DISP_PREFERENCE_H_
#define _NUBIA_DISP_PREFERENCE_H_

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/device.h>
#include <linux/types.h>

#define NUBIA_DISP_INFO(fmt, arg...)	pr_info("[NUBIA_DISP]" fmt, ##arg)
#define NUBIA_DISP_ERROR(fmt, arg...)	pr_err("[NUBIA_DISP]" fmt, ##arg)

enum {
	CABC_OFF = 23,
	CABC_LEVEL1,
	CABC_LEVEL2,
	CABC_LEVEL3
};

enum {
	AOD_OFF = 23,
	AOD_ON
};

enum {
	HBM_FP_OFF = 0,
	HBM_FP_ON,
	HBM_OFF = 23,
	HBM_ON
};

struct nubia_disp_type {
	int en_cabc;
	unsigned int cabc;
#ifdef CONFIG_NUBIA_AOD_HBM_MODE
	int en_aod_mode;
	unsigned int aod_mode;
	int en_hbm_mode;
	unsigned int hbm_mode;
#endif
};

void nubia_set_dsi_ctrl(struct dsi_display *display);

#endif /* _NUBIA_DISP_PREFERENCE_H_ */
'''

PREF_C = r'''// SPDX-License-Identifier: GPL-2.0-only
/*
 * nubia_disp_preference.c - nubia lcd display color enhancement
 *
 * NX659J_OFFICIAL_AODHBM: 移植自努比亚官方
 *   nubia-development/android_kernel_nubia_sm8250 (nubia_sdm865_q-diff)
 *   techpack/display/msm/nubia_disp_preference.c
 *
 * 只保留 AOD / HBM / CABC 三条链路；DFPS / DEBUG_LCD_REG / SWITCH_LCD
 * 三组依赖的宏在本内核里未开启，相关代码按官方 #ifdef 自然排除。
 */
#include "dsi_panel.h"
#include "dsi_display.h"
#include "nubia_disp_preference.h"
#include <linux/delay.h>

extern bool is_66451_panel;

static struct dsi_display *nubia_display = NULL;
static struct kobject *enhance_kobj = NULL;

struct nubia_disp_type nubia_disp_val = {
	.en_cabc = 1,
	.cabc = CABC_OFF,
#ifdef CONFIG_NUBIA_AOD_HBM_MODE
	.en_aod_mode = 1,
	.aod_mode = AOD_OFF,
	.en_hbm_mode = 1,
	.hbm_mode = HBM_OFF,
#endif
};

/* ---------------------------------------------------------------- CABC */
static ssize_t cabc_show(struct kobject *kobj, struct kobj_attribute *attr,
			 char *buf)
{
	if (nubia_disp_val.en_cabc)
		return snprintf(buf, PAGE_SIZE, "%d\n", nubia_disp_val.cabc);
	return snprintf(buf, PAGE_SIZE, "no cabc\n");
}

static ssize_t cabc_store(struct kobject *kobj, struct kobj_attribute *attr,
			  const char *buf, size_t size)
{
	unsigned int val = 0;
	int ret = 0;

	if (!nubia_disp_val.en_cabc) {
		NUBIA_DISP_ERROR("no cabc\n");
		return size;
	}
	if (sscanf(buf, "%d", &val) != 1) {
		NUBIA_DISP_ERROR("invalid cabc val\n");
		return size;
	}
	if (val < CABC_OFF || val > CABC_LEVEL3) {
		NUBIA_DISP_ERROR("invalid cabc val = %d\n", val);
		return size;
	}
	NUBIA_DISP_INFO("cabc value = %d\n", val);
	if (!nubia_display || !nubia_display->panel) {
		NUBIA_DISP_ERROR("no display\n");
		return size;
	}
	ret = nubia_dsi_panel_cabc(nubia_display->panel, val);
	if (ret == 0) {
		nubia_disp_val.cabc = val;
		NUBIA_DISP_INFO("success to set cabc as = %d\n", val);
	}
	return size;
}

#ifdef CONFIG_NUBIA_AOD_HBM_MODE
/* ------------------------------------------------------------- AOD MODE */
static ssize_t aod_show(struct kobject *kobj, struct kobj_attribute *attr,
			char *buf)
{
	if (nubia_disp_val.en_aod_mode)
		return snprintf(buf, PAGE_SIZE, "%d\n", nubia_disp_val.aod_mode);
	return snprintf(buf, PAGE_SIZE, "no aod_mode\n");
}

static ssize_t aod_store(struct kobject *kobj, struct kobj_attribute *attr,
			 const char *buf, size_t size)
{
	unsigned int val = 0;
	int ret = 0;

	if (!nubia_disp_val.en_aod_mode) {
		NUBIA_DISP_ERROR("no aod_mode\n");
		return size;
	}
	if (sscanf(buf, "%d", &val) != 1)
		return size;
	if ((val != AOD_OFF) && (val != AOD_ON)) {
		NUBIA_DISP_ERROR("invalid aod_mode val = %d\n", val);
		return size;
	}
	NUBIA_DISP_INFO("aod_mode value = %d\n", val);
	if (!nubia_display || !nubia_display->panel) {
		NUBIA_DISP_ERROR("no display\n");
		return size;
	}
	ret = nubia_dsi_panel_aod(nubia_display->panel, val);
	if (ret == 0) {
		nubia_disp_val.aod_mode = val;
		NUBIA_DISP_INFO("success to set aod_mode as = %d\n", val);
	}
	return size;
}

/* ------------------------------------------------------------- HBM MODE */
static ssize_t hbm_show(struct kobject *kobj, struct kobj_attribute *attr,
			char *buf)
{
	if (nubia_disp_val.en_hbm_mode)
		return snprintf(buf, PAGE_SIZE, "%d\n", nubia_disp_val.hbm_mode);
	return snprintf(buf, PAGE_SIZE, "no hbm_mode\n");
}

static ssize_t hbm_store(struct kobject *kobj, struct kobj_attribute *attr,
			 const char *buf, size_t size)
{
	uint32_t val = 0;
	int ret = 0;

	if (!nubia_disp_val.en_hbm_mode) {
		NUBIA_DISP_ERROR("no hbm_mode\n");
		return size;
	}
	if (!nubia_display || !nubia_display->panel) {
		NUBIA_DISP_ERROR("no hbm_mode\n");
		return size;
	}
	if (sscanf(buf, "%d", &val) != 1)
		return size;
	if ((val != HBM_OFF) && (val != HBM_ON) &&
	    (val != HBM_FP_OFF) && (val != HBM_FP_ON)) {
		NUBIA_DISP_ERROR("invalid hbm_mode val = %d\n", val);
		return size;
	}
	if (!is_66451_panel) {
		NUBIA_DISP_INFO("r66455 un-support hbm mode\n");
		return size;
	}
	NUBIA_DISP_INFO("hbm_mode value = %d\n", val);
	ret = nubia_dsi_panel_hbm(nubia_display->panel, val);
	if (ret == 0) {
		nubia_disp_val.hbm_mode = val;
		NUBIA_DISP_INFO("success to set hbm_mode as = %d\n", val);
	}
	return size;
}
#endif /* CONFIG_NUBIA_AOD_HBM_MODE */

/* ------------------------------------------------------------ attrs 表 */
static struct kobj_attribute lcd_disp_attrs[] = {
	__ATTR(cabc, 0664, cabc_show, cabc_store),
#ifdef CONFIG_NUBIA_AOD_HBM_MODE
	__ATTR(aod_mode, 0664, aod_show, aod_store),
	__ATTR(hbm_mode, 0664, hbm_show, hbm_store),
#endif
};

void nubia_set_dsi_ctrl(struct dsi_display *display)
{
	NUBIA_DISP_INFO("start\n");
	nubia_display = display;
}
EXPORT_SYMBOL(nubia_set_dsi_ctrl);

static int __init nubia_disp_preference_init(void)
{
	int retval = 0;
	int attr_count = 0;

	NUBIA_DISP_INFO("start\n");

	enhance_kobj = kobject_create_and_add("lcd_enhance", kernel_kobj);
	if (!enhance_kobj) {
		NUBIA_DISP_ERROR("failed to create and add kobject\n");
		return -ENOMEM;
	}

	for (attr_count = 0; attr_count < ARRAY_SIZE(lcd_disp_attrs);
	     attr_count++) {
		retval = sysfs_create_file(enhance_kobj,
					   &lcd_disp_attrs[attr_count].attr);
		if (retval < 0) {
			NUBIA_DISP_ERROR("failed to create sysfs attributes\n");
			goto err_sys_creat;
		}
	}
	NUBIA_DISP_INFO("success\n");
	return retval;

err_sys_creat:
	for (--attr_count; attr_count >= 0; attr_count--)
		sysfs_remove_file(enhance_kobj,
				  &lcd_disp_attrs[attr_count].attr);
	kobject_put(enhance_kobj);
	return retval;
}

static void __exit nubia_disp_preference_exit(void)
{
	int attr_count = 0;

	for (attr_count = 0; attr_count < ARRAY_SIZE(lcd_disp_attrs);
	     attr_count++)
		sysfs_remove_file(enhance_kobj,
				  &lcd_disp_attrs[attr_count].attr);
	kobject_put(enhance_kobj);
}

MODULE_AUTHOR("NUBIA LCD Driver Team Software");
MODULE_DESCRIPTION("NUBIA LCD DISPLAY Color Saturation and Temperature Setting");
MODULE_LICENSE("GPL");
module_init(nubia_disp_preference_init);
module_exit(nubia_disp_preference_exit);
'''

# ============================================================ B. 枚举
OLD_ENUM = """	DSI_CMD_SET_QSYNC_ON,
	DSI_CMD_SET_QSYNC_OFF,
	DSI_CMD_SET_HBM_ON,
	DSI_CMD_SET_HBM_OFF,
	DSI_CMD_SET_CABC_OFF,
	DSI_CMD_SET_CABC_LEVEL1,
	DSI_CMD_SET_CABC_LEVEL2,
	DSI_CMD_SET_CABC_LEVEL3,
	DSI_CMD_SET_MAX
"""

# 说明：不做 #ifdef 条件编译，直接无条件展开成官方完整顺序。
# 理由 —— 三张表（enum / prop_map / state_map）必须长度严格一致，
# 任何一边带 #ifdef 而另一边漏掉就是数组错位、命令发错寄存器，
# 表现为花屏/黑屏，且极难排查。这里由 Kconfig 强制依赖保证：
#   NUBIA_AOD_HBM_MODE depends on NUBIA_DISP_PREFERENCE
# 
# 官方顺序（nubia_sdm865_q-diff dsi_defs.h L313-333）：
#   ... QSYNC_ON, QSYNC_OFF,
#   CABC_OFF, CABC_L1..L3,
#   AOD_OFF, AOD_ON, HBM_FP_OFF, HBM_FP_ON, HBM_OFF, HBM_ON,
#   MAX
NEW_ENUM = """	DSI_CMD_SET_QSYNC_ON,
	DSI_CMD_SET_QSYNC_OFF,
	/* %s: 官方顺序，与 prop_map/state_map 严格配对 */
	DSI_CMD_SET_CABC_OFF,
	DSI_CMD_SET_CABC_LEVEL1,
	DSI_CMD_SET_CABC_LEVEL2,
	DSI_CMD_SET_CABC_LEVEL3,
	DSI_CMD_SET_AOD_OFF,
	DSI_CMD_SET_AOD_ON,
	DSI_CMD_SET_HBM_FP_OFF,
	DSI_CMD_SET_HBM_FP_ON,
	DSI_CMD_SET_HBM_OFF,
	DSI_CMD_SET_HBM_ON,
	DSI_CMD_SET_MAX
""" % MARK

# ============================================================ C. 数组
OLD_PROP = """	"qcom,mdss-dsi-qsync-on-commands",
	"qcom,mdss-dsi-qsync-off-commands",
	"nubia,mdss-dsi-hbm-command-on",
	"nubia,mdss-dsi-hbm-command-off",
	"nubia,mdss-dsi-cabc-command-off",
	"nubia,mdss-dsi-cabc-command-level1",
	"nubia,mdss-dsi-cabc-command-level2",
	"nubia,mdss-dsi-cabc-command-level3",
};
"""

NEW_PROP = """	"qcom,mdss-dsi-qsync-on-commands",
	"qcom,mdss-dsi-qsync-off-commands",
	/* %s */
	"nubia,mdss-dsi-cabc-command-off",
	"nubia,mdss-dsi-cabc-command-level1",
	"nubia,mdss-dsi-cabc-command-level2",
	"nubia,mdss-dsi-cabc-command-level3",
	"nubia,mdss-dsi-aod-command-off",
	"nubia,mdss-dsi-aod-command-on",
	"nubia,mdss-dsi-hbm-fp-command-off",
	"nubia,mdss-dsi-hbm-fp-command-on",
	"nubia,mdss-dsi-hbm-command-off",
	"nubia,mdss-dsi-hbm-command-on",
};
""" % MARK

OLD_STATE = """	"qcom,mdss-dsi-qsync-on-commands-state",
	"qcom,mdss-dsi-qsync-off-commands-state",
	"nubia,mdss-dsi-hbm-command-on-state",
	"nubia,mdss-dsi-hbm-command-off-state",
	"nubia,mdss-dsi-cabc-command-off-state",
	"nubia,mdss-dsi-cabc-command-level1-state",
	"nubia,mdss-dsi-cabc-command-level2-state",
	"nubia,mdss-dsi-cabc-command-level3-state",
};
"""

NEW_STATE = """	"qcom,mdss-dsi-qsync-on-commands-state",
	"qcom,mdss-dsi-qsync-off-commands-state",
	/* %s */
	"nubia,mdss-dsi-cabc-command-off-state",
	"nubia,mdss-dsi-cabc-command-level1-state",
	"nubia,mdss-dsi-cabc-command-level2-state",
	"nubia,mdss-dsi-cabc-command-level3-state",
	"nubia,mdss-dsi-aod-command-off-state",
	"nubia,mdss-dsi-aod-command-on-state",
	"nubia,mdss-dsi-hbm-fp-command-off-state",
	"nubia,mdss-dsi-hbm-fp-command-on-state",
	"nubia,mdss-dsi-hbm-command-off-state",
	"nubia,mdss-dsi-hbm-command-on-state",
};
""" % MARK

# ============================================================ D. 函数
AODHBM_FUNCS = r"""
/* NX659J_OFFICIAL_AODHBM: 以下两个函数原样照抄努比亚官方
 * nubia-development/android_kernel_nubia_sm8250 (nubia_sdm865_q-diff)
 * techpack/display/msm/dsi/dsi_panel.c
 * LineageOS 删掉了整块，导致指纹 HAL 屏灭打光拿不到 HBM/AOD 通道。 */
#ifdef CONFIG_NUBIA_AOD_HBM_MODE
int nubia_dsi_panel_aod(struct dsi_panel *panel, uint32_t aod_modes)
{
	int rc = 0;

	if (!panel) {
		pr_err("invalid params\n");
		return -EINVAL;
	}

	mutex_lock(&panel->panel_lock);

	if (panel->panel_initialized == false) {
		pr_err("panel[%s] not ready\n", panel->name);
		rc = -EINVAL;
		goto exit;
	}

	switch (aod_modes) {
	case AOD_OFF:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_AOD_OFF);
		if (rc)
			pr_err("[%s] failed to send DSI_CMD_SET_AOD_OFF cmds, rc=%d\n",
			       panel->name, rc);
		break;
	case AOD_ON:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_AOD_ON);
		if (rc)
			pr_err("[%s] failed to send DSI_CMD_SET_AOD_ON cmds, rc=%d\n",
			       panel->name, rc);
		break;
	default:
		break;
	}
exit:
	mutex_unlock(&panel->panel_lock);
	return rc;
}
EXPORT_SYMBOL(nubia_dsi_panel_aod);

int nubia_dsi_panel_hbm(struct dsi_panel *panel, uint32_t hbm_modes)
{
	int rc = 0;

	if (!panel) {
		pr_err("invalid params\n");
		return -EINVAL;
	}

	mutex_lock(&panel->panel_lock);

	if (panel->panel_initialized == false) {
		pr_err("panel[%s] not ready\n", panel->name);
		rc = -EINVAL;
		goto exit;
	}

	switch (hbm_modes) {
	case HBM_FP_OFF:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_HBM_FP_OFF);
		if (rc)
			pr_err("[%s] failed to send DSI_CMD_SET_HBM_FP_OFF cmds, rc=%d\n",
			       panel->name, rc);
		break;
	case HBM_FP_ON:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_HBM_FP_ON);
		if (rc)
			pr_err("[%s] failed to send DSI_CMD_SET_HBM_FP_ON cmds, rc=%d\n",
			       panel->name, rc);
		break;
	case HBM_OFF:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_HBM_OFF);
		if (rc)
			pr_err("[%s] failed to send DSI_CMD_SET_HBM_OFF cmds, rc=%d\n",
			       panel->name, rc);
		break;
	case HBM_ON:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_HBM_ON);
		if (rc)
			pr_err("[%s] failed to send DSI_CMD_SET_HBM_ON cmds, rc=%d\n",
			       panel->name, rc);
		break;
	default:
		break;
	}
exit:
	mutex_unlock(&panel->panel_lock);
	return rc;
}
EXPORT_SYMBOL(nubia_dsi_panel_hbm);
#endif /* CONFIG_NUBIA_AOD_HBM_MODE */

#ifdef CONFIG_NUBIA_DISP_PREFERENCE
int nubia_dsi_panel_cabc(struct dsi_panel *panel, uint32_t cabc_modes)
{
	int rc = 0;

	if (!panel)
		return -EINVAL;

	mutex_lock(&panel->panel_lock);
	if (!panel->panel_initialized) {
		rc = -EINVAL;
		goto exit;
	}
	switch (cabc_modes) {
	case CABC_OFF:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_CABC_OFF);
		break;
	case CABC_LEVEL1:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_CABC_LEVEL1);
		break;
	case CABC_LEVEL2:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_CABC_LEVEL2);
		break;
	case CABC_LEVEL3:
		rc = dsi_panel_tx_cmd_set(panel, DSI_CMD_SET_CABC_LEVEL3);
		break;
	default:
		break;
	}
exit:
	mutex_unlock(&panel->panel_lock);
	return rc;
}
#endif /* CONFIG_NUBIA_DISP_PREFERENCE */
"""

DECL = """
#ifdef CONFIG_NUBIA_AOD_HBM_MODE
int nubia_dsi_panel_aod(struct dsi_panel *panel, uint32_t aod_modes);
int nubia_dsi_panel_hbm(struct dsi_panel *panel, uint32_t hbm_modes);
#endif
#ifdef CONFIG_NUBIA_DISP_PREFERENCE
int nubia_dsi_panel_cabc(struct dsi_panel *panel, uint32_t cabc_modes);
#endif
"""


def do_display_c(p):
    """把 display 句柄交给 nubia_disp_preference。

    官方做法（nubia_sdm865_q-diff teckpack/display/msm/dsi/dsi_display.c L5442-5450）：
        if (!strcmp(boot_disp->name, "...r66451_1080p_amoled_new_cmd"))
                nubia_set_dsi_ctrl(display);
    插在 LineageOS 的 boot_disp_en 分支里，panel_node 建立之前。
    """
    s = read(p)
    if MARK in s:
        print("SKIP dsi_display.c")
        return
    old = """		if (!mdp_node) {
			DSI_ERR("mdp_node not found\\n");
			rc = -ENODEV;
			goto end;
		}

		/* The panel name should be same as UEFI name index */
		panel_node = of_find_node_by_name(mdp_node, boot_disp->name);
"""
    new = """		if (!mdp_node) {
			DSI_ERR("mdp_node not found\\n");
			rc = -ENODEV;
			goto end;
		}

#ifdef CONFIG_NUBIA_DISP_PREFERENCE
		/* %s: 把 display 交给 nubia_disp_preference，
		 * 让 /sys/kernel/lcd_enhance/{hbm_mode,aod_mode} 拿到 panel。 */
		if (!strcmp(boot_disp->name, "qcom,nubia_dsi_r66455_1080p_amoled_cmd") ||
		    !strcmp(boot_disp->name, "qcom,nubia_dsi_r66451_1080p_amoled_cmd") ||
		    !strcmp(boot_disp->name, "qcom,nubia_dsi_r66451_1080p_amoled_new_cmd"))
			nubia_set_dsi_ctrl(display);
#endif
		/* The panel name should be same as UEFI name index */
		panel_node = of_find_node_by_name(mdp_node, boot_disp->name);
""" % MARK
    s = sub_once(s, old, new, "dsi_display.c boot_disp hook")

    # include
    inc_old = '#include "dsi_display.h"\n'
    inc_new = '#include "dsi_display.h"\n#ifdef CONFIG_NUBIA_DISP_PREFERENCE\n#include "nubia_disp_preference.h"\n#endif\n'
    if inc_old in s:
        s = s.replace(inc_old, inc_new, 1)
    write(p, s)
    print("OK  dsi_display.c: nubia_set_dsi_ctrl(display) 挂钩")


def do_defs(p):
    s = read(p)
    if MARK in s:
        print("SKIP dsi_defs.h")
        return
    s = sub_once(s, OLD_ENUM, NEW_ENUM, "dsi_defs.h enum")
    write(p, s)
    print("OK  dsi_defs.h: enum 重排 + AOD/HBM-FP")


def do_panel_c(p):
    s = read(p)
    if MARK in s:
        print("SKIP dsi_panel.c")
        return
    s = sub_once(s, OLD_PROP, NEW_PROP, "dsi_panel.c prop_map")
    s = sub_once(s, OLD_STATE, NEW_STATE, "dsi_panel.c state_map")
    s = s.rstrip("\n") + "\n" + AODHBM_FUNCS
    write(p, s)
    print("OK  dsi_panel.c: prop_map/state_map + nubia_dsi_panel_{aod,hbm,cabc}")


def do_panel_h(p):
    s = read(p)
    if MARK in s:
        print("SKIP dsi_panel.h")
        return
    idx = s.rfind("#endif")
    if idx < 0:
        raise SystemExit("FAIL dsi_panel.h: no trailing #endif")
    s = s[:idx] + "/* %s */\n" % MARK + DECL + "\n" + s[idx:]
    write(p, s)
    print("OK  dsi_panel.h: 声明")


def do_pref(pc, ph):
    made = False
    if os.path.isfile(pc) and MARK not in read(pc):
        write(pc, PREF_C)
        print("OK  nubia_disp_preference.c 写入")
        made = True
    elif not os.path.isfile(pc):
        write(pc, PREF_C)
        print("OK  nubia_disp_preference.c 新建")
        made = True
    else:
        print("SKIP nubia_disp_preference.c")
    if os.path.isfile(ph) and MARK not in read(ph):
        write(ph, PREF_H)
        print("OK  nubia_disp_preference.h 写入")
    elif not os.path.isfile(ph):
        write(ph, PREF_H)
        print("OK  nubia_disp_preference.h 新建")
    else:
        print("SKIP nubia_disp_preference.h")


def do_makefile(p):
    s = read(p)
    if MARK in s:
        print("SKIP Makefile")
        return
    old = None
    for cand in ("\tdp/nubia_dp_preference.o\\", "\tdp/nubia_dp_preference.o \\",
                 "dp/nubia_dp_preference.o"):
        if cand in s:
            old = cand
            break
    if old is None:
        raise SystemExit("FAIL Makefile: nubia_dp_preference anchor not found")
    new = old + "\nobj-$(CONFIG_NUBIA_DISP_PREFERENCE) += nubia_disp_preference.o"
    s = s.replace(old, new, 1)
    s = s.rstrip("\n") + "\n\n# %s\n" % MARK
    write(p, s)
    print("OK  Makefile: += nubia_disp_preference.o")


def do_kconfig(p):
    s = read(p)
    if MARK in s:
        print("SKIP Kconfig")
        return
    add = (
        "\n# %s\n"
        "config NUBIA_DISP_PREFERENCE\n"
        '\tbool "nubia lcd disp preference includes color enhancement and temperature"\n'
        "\tdefault n\n"
        "\n"
        "config NUBIA_AOD_HBM_MODE\n"
        '\tbool "nubia aod and hbm config"\n'
        "\tdepends on NUBIA_DISP_PREFERENCE\n"
        "\tdefault n\n" % MARK
    )
    s = s.rstrip("\n") + "\n" + add
    write(p, s)
    print("OK  Kconfig: NUBIA_DISP_PREFERENCE / NUBIA_AOD_HBM_MODE")


def do_cfg(p):
    if not os.path.isfile(p):
        print("WARN %s missing, skip" % p)
        return
    s = read(p)
    if MARK in s:
        print("SKIP nx659j.config")
        return
    add = "\n# %s\nCONFIG_NUBIA_DISP_PREFERENCE=y\nCONFIG_NUBIA_AOD_HBM_MODE=y\n" % MARK
    s = s.rstrip("\n") + "\n" + add
    write(p, s)
    print("OK  nx659j.config: CONFIG_NUBIA_DISP_PREFERENCE=y CONFIG_NUBIA_AOD_HBM_MODE=y")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    j = lambda rel: os.path.join(root, rel)

    for rel in (F_PANEL_C, F_DEFS, F_PANEL_H, F_DISP_C, F_MK, F_KCONF):
        if not os.path.isfile(j(rel)):
            raise SystemExit("FAIL required file missing: %s" % rel)

    do_pref(j(F_PREF_C), j(F_PREF_H))
    do_defs(j(F_DEFS))
    do_panel_c(j(F_PANEL_C))
    do_panel_h(j(F_PANEL_H))
    do_display_c(j(F_DISP_C))
    do_makefile(j(F_MK))
    do_kconfig(j(F_KCONF))
    do_cfg(j(F_CFG))

    print("[%s] done" % MARK)


if __name__ == "__main__":
    main()
