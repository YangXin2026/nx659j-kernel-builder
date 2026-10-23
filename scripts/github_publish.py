#!/usr/bin/env python3
"""用 GitHub API 一键发布 kernel-builder 仓库并触发 Phase 0 构建（无需本地 git）。

用法：
  set GITHUB_TOKEN=ghp_xxx
  python scripts/github_publish.py --repo nx659j-kernel-builder --phase 0 --wait

需要 token：
- 经典 PAT：勾选 repo + workflow
- 细粒度 PAT：Administration(RW, 用于建仓库) + Contents(RW) + Workflows(RW) + Actions(RW)
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def req(method, path, token, data=None, raw=False, accept=None):
    url = API + path
    body = None
    if data is not None:
        body = json.dumps(data).encode()
    r = urllib.request.Request(url, data=body, method=method)
    r.add_header("Authorization", "Bearer " + token)
    r.add_header("Accept", accept or "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    r.add_header("User-Agent", "nx659j-kernel-builder")
    if body is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            content = resp.read()
            if raw:
                return content
            return json.loads(content.decode() or "{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} -> {e.code}: {detail[:500]}")


def collect_files():
    files = []
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in (".git", "__pycache__")]
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, ROOT).replace("\\", "/")
            files.append((rel, p))
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="nx659j-kernel-builder")
    ap.add_argument("--phase", default="0")
    ap.add_argument("--localversion", default="kona-ksu-a16fix-oc")
    ap.add_argument("--wait", action="store_true", help="等待构建完成并下载 artifacts")
    ap.add_argument("--timeout", type=int, default=5400)
    ap.add_argument("--private", action="store_true", default=True)
    args = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        sys.exit("请先设置 GITHUB_TOKEN 环境变量（PAT），或改用手动上传方案。")

    user = req("GET", "/user", token)
    owner = user["login"]
    print(f"[*] 认证用户: {owner}")

    repo_path = f"/repos/{owner}/{args.repo}"
    try:
        repo = req("GET", repo_path, token)
        print(f"[*] 仓库已存在: {repo['html_url']}")
    except RuntimeError:
        repo = req("POST", "/user/repos", token, {
            "name": args.repo,
            "private": args.private,
            "auto_init": False,
            "description": "4.19-kona-ksu-a16fix-oc CI builder",
        })
        print(f"[*] 已创建仓库: {repo['html_url']}")

    # 空仓库检查（有提交就拒绝，避免覆盖）
    try:
        req("GET", f"{repo_path}/commits?per_page=1", token)
        sys.exit("[!] 仓库已有提交，请换一个空仓库名，或手动更新。")
    except RuntimeError:
        pass  # 空仓库：GET commits 会 409/404

    files = collect_files()
    files.sort()
    blobs = []
    for rel, path in files:
        content = base64.b64encode(open(path, "rb").read()).decode()
        b = req("POST", f"{repo_path}/git/blobs", token, {"content": content, "encoding": "base64"})
        blobs.append({"path": rel, "mode": "100644", "type": "blob", "sha": b["sha"]})
        print(f"[*] blob {rel} ({os.path.getsize(path)} B)")

    tree = req("POST", f"{repo_path}/git/trees", token, {"tree": blobs})
    commit = req("POST", f"{repo_path}/git/commits", token, {
        "message": "kernel-builder: 4.19-kona-ksu-a16fix-oc Phase 0",
        "tree": tree["sha"],
        "parents": [],
    })
    req("POST", f"{repo_path}/git/refs", token, {"ref": "refs/heads/main", "sha": commit["sha"]})
    print("[*] 已提交 main 分支")

    req("POST", f"{repo_path}/actions/workflows/build.yml/dispatches", token, {
        "ref": "main",
        "inputs": {"phase": args.phase, "localversion": args.localversion},
    })
    print(f"[*] 已触发 workflow_dispatch phase={args.phase}")

    if not args.wait:
        print("[*] 不等待；稍后用 GitHub Actions 或加 --wait 下载产物。")
        return

    deadline = time.time() + args.timeout
    run = None
    while time.time() < deadline:
        runs = req("GET", f"{repo_path}/actions/runs?per_page=5", token)
        for r in runs.get("workflow_runs", []):
            if r.get("event") == "workflow_dispatch" and r.get("path", "").endswith("build.yml"):
                run = r
                break
        if run:
            print(f"[*] run {run['id']} status={run['status']} conclusion={run.get('conclusion')}")
            if run["status"] == "completed":
                break
        time.sleep(15)

    if not run or run["status"] != "completed":
        sys.exit("[!] 超时或未找到 run，请到 Actions 页面查看。")

    if run.get("conclusion") != "success":
        logs_url = run.get("html_url")
        sys.exit(f"[!] 构建失败: {logs_url}")

    arts = req("GET", f"{repo_path}/actions/runs/{run['id']}/artifacts", token)
    for a in arts.get("artifacts", []):
        print(f"[*] artifact: {a['name']} ({a['size_in_bytes']} B)")
        data = req("GET", a["archive_download_url"], token, raw=True,
                   accept="application/vnd.github+json")
        out = os.path.join(os.getcwd(), a["name"] + ".zip")
        with open(out, "wb") as f:
            f.write(data)
        print(f"[+] 已下载: {out}")


if __name__ == "__main__":
    main()
