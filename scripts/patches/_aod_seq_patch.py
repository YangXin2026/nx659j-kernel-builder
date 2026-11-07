#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NX659J GSI 熄屏指纹：补「打光 → 等光生效 → 才通知采图」时序（内核层，补丁25）

=== 为什么需要它（资料库早年配方 + 本次真机 A/B）===
2026-10-18 早年修锁屏指纹的 make_fod_bridge.sh / service_v6.sh 是四段握手：
    echo 1 > hbm_mode ; echo 4095 > brightness ; echo 1 > fp_mode
    send 13                 # FINGER_DOWN
    sleep 0.15              # 等 HBM 真正生效
    send 14                 # FINGER_UI_READY  ←「识别到手指之后的下一步操作」
    抬指: send 15 ; sleep 0.20 ; 逆序关 fp_mode / hbm / 恢复背光

99-归档/资料/SIMILAR-CASES.md 对 Phh 同类 goodix 的结论：
    AuthService.java 监听 /sys/class/drm/ghbm_on_achieved，变 1 才发
    sendCommand(200002) = "UI ready"；
    「先 DOWN，等 HBM/亮圈就绪，再 UI_READY」是实测顺序，不是臆造。

本次真机 A/B 正好验证「等光生效」的价值：
  - 手动 brightness=255 提前写好并保持数分钟 -> image_quality=42 /
    valid_area=78 / match_score=51 / onAuthenticated  （光已稳定）
  - 同一亮度但在按下瞬间才写、0.5ms 后立刻 fod_ui=1 -> image_quality=17 /
    valid_area=44 / match_score=-31 / onAcquired(5)「请用力按住传感器」
  => 光「有没有」和光「稳没稳」是两件事。

=== 本补丁做什么 ===
在补丁24 的 nx659j_aod_light_fn() 里补两段等待：
  FP_DOWN: backlight_update_status() 之后 msleep(150) 才 fod_ui=1
  FP_UP  : fod_ui=0 之后 msleep(200) 才收光
work 是进程上下文、串行执行，msleep 合法；抬手后仍会亮 200ms，
与早年脚本 sleep 0.20 的逆序复原一致，不是常亮。

=== 刻意不做 ===
- 不引入用户态守护 / Magisk 模块 / IFAA 命令（早年那套是用户态，这里全部下沉内核）
- 不改 HBM、不改 dtbo、不碰 framework/vendor
- 不做 debounce 延迟关断（补丁20 的教训）

幂等：以 NX659J_AOD_SEQ 为标记，重复执行自动跳过。
"""
import os
import sys

MARK = "NX659J_AOD_SEQ"
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
    if "backlight_update_status(nx659j_aod_bd)" not in s:
        raise SystemExit("FAIL dsi_panel.c: patch24 missing")

    old_down = '''		nx659j_aod_light_on = true;
		dsi_panel_set_fod_ui(panel, true);  /* 光到位后才通知 HAL 采图 */
'''
    new_down = '''		nx659j_aod_light_on = true;
		/* NX659J_AOD_SEQ: 早年 make_fod_bridge.sh 打光后 sleep 0.15 才发
		 * FINGER_UI_READY；面板刷新 + 光稳定需要时间，立刻翻 fod_ui 会让
		 * HAL 采到半亮图（实测 image_quality 17 vs 光稳定后的 42）。 */
		msleep(150);
		dsi_panel_set_fod_ui(panel, true);  /* 光稳定后才通知 HAL 采图 */
'''
    if old_down not in s:
        raise SystemExit("FAIL dsi_panel.c: patch24 FP_DOWN anchor not found")
    s = s.replace(old_down, new_down, 1)

    old_up = '''		dsi_panel_set_fod_ui(panel, false);
		nx659j_aod_light_restore();
'''
    new_up = '''		dsi_panel_set_fod_ui(panel, false);
		/* NX659J_AOD_SEQ: 抬指先通知 HAL，再等 200ms 才收光，与早年
		 * 逆序复原 sleep 0.20 一致，避免采图尾帧被掐暗。 */
		msleep(200);
		nx659j_aod_light_restore();
'''
    if old_up not in s:
        raise SystemExit("FAIL dsi_panel.c: patch24 FP_UP anchor not found")
    s = s.replace(old_up, new_up, 1)

    # 日志标明时序版本，便于真机区分
    s = s.replace(
        'pr_info("NX659J_AOD_LIGHT: FP_DOWN -> bd %d->%d (framework path), fod_ui=1\\n",',
        'pr_info("NX659J_AOD_SEQ: FP_DOWN -> bd %d->%d, +150ms, fod_ui=1\\n",', 1)
    s = s.replace(
        'pr_info("NX659J_AOD_LIGHT: FP_UP -> bd %d restored, fod_ui=0\\n",',
        'pr_info("NX659J_AOD_SEQ: FP_UP -> fod_ui=0, +200ms, bd %d restored\\n",', 1)

    write(path, s)
    print("OK  dsi_panel.c: DOWN/HBM-ready/UP sequence (%d marks)" % s.count(MARK))
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
