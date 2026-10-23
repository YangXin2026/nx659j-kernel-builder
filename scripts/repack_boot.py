#!/usr/bin/env python3
"""本地重打包 boot.img：只替换 kernel，保持原 boot 头字段/ramdisk/dtb 不变。

用法（Windows / Linux 均可）：
  python scripts/repack_boot.py --base D:\\rom-los\\boot.img \\
      --kernel out/arch/arm64/boot/Image.gz --out boot-4.19-kona-ksu-a16fix-oc.img

原理：
  1) 调用 AOSP `unpack_bootimg.py`（已 vendored 在 tools/）解出 kernel/ramdisk/dtb 等，
     并用 `--format=mkbootimg -0` 取得原始 mkbootimg 参数；
  2) 把解出的 kernel 替换为新产品；
  3) 用 `mkbootimg.py` 按原参数重打包，只改 --output。
CI 不执行本脚本（CI 不碰 boot 头字段/AVB）。
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(os.path.dirname(HERE), "tools")
UNPACK = os.path.join(TOOLS, "unpack_bootimg.py")
MKBOOTIMG = os.path.join(TOOLS, "mkbootimg.py")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd):
    print("[cmd]", " ".join(cmd))
    subprocess.check_call(cmd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="原始 boot.img")
    ap.add_argument("--kernel", required=True, help="新内核 Image.gz")
    ap.add_argument("--out", required=True, help="输出 boot.img")
    args = ap.parse_args()

    for p in (UNPACK, MKBOOTIMG):
        if not os.path.isfile(p):
            sys.exit(f"缺少工具: {p}")

    work = tempfile.mkdtemp(prefix="bootrepack-")
    try:
        outdir = os.path.join(work, "unpacked")
        os.makedirs(outdir, exist_ok=True)

        # 取 mkbootimg 参数（NUL 分隔，避免 shell 转义问题）
        cmd = [sys.executable, UNPACK, "--boot_img", args.base,
               "--out", outdir, "--format=mkbootimg", "-0"]
        print("[cmd]", " ".join(cmd))
        raw = subprocess.check_output(cmd)
        parts = raw.split(b"\0")
        if parts and parts[-1] == b"":
            parts = parts[:-1]
        mkboot_args = [p.decode() for p in parts]
        # unpack 可能输出空的 --board 值（空字符串），mkbootimg 的 argparse 会误判，
        # 这里把空值的成对参数剔除。
        cleaned = []
        i = 0
        while i < len(mkboot_args):
            a = mkboot_args[i]
            if a == "":
                i += 1
                continue
            if a == "--board":
                # 空 board 值：连同其空参数一起丢弃
                if i + 1 >= len(mkboot_args) or mkboot_args[i + 1] == "":
                    i += 2
                    continue
            cleaned.append(a)
            i += 1
        mkboot_args = cleaned
        print("[*] 原 boot mkbootimg 参数:", mkboot_args)

        # 替换 kernel
        kernel_in_image = None
        for i, a in enumerate(mkboot_args):
            if a == "--kernel" and i + 1 < len(mkboot_args):
                kernel_in_image = mkboot_args[i + 1]
                break
        if kernel_in_image is None:
            sys.exit("unpack 参数里没有 --kernel")

        # 参数里的 kernel 是相对 outdir 的路径
        target = kernel_in_image
        if not os.path.isabs(target):
            target = os.path.join(outdir, target)
        shutil.copyfile(args.kernel, target)
        print(f"[*] 已替换 kernel -> {target}")

        cmd = [sys.executable, MKBOOTIMG] + mkboot_args + ["--output", args.out]
        run(cmd)

        if not os.path.isfile(args.out):
            sys.exit("重打包失败：输出不存在")
        print("[+] 输出:", args.out)
        print("[+] sha256:", sha256(args.out))
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
