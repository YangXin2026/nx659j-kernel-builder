#!/usr/bin/env python3
"""用 Contents API 上传 kernel-builder 到 GitHub 并触发 Phase 0（适配空仓库）。"""
import argparse
import base64
import fnmatch
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _ignore_patterns():
    """读取仓库根 .gitignore，用于跳过 diag/、artifacts/ 等大目录。"""
    patterns = []
    gi = os.path.join(ROOT, ".gitignore")
    if os.path.exists(gi):
        for line in open(gi, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                patterns.append(line.rstrip("/"))
    return patterns


def _ignored(rel, patterns):
    rel = rel.replace("\\", "/")
    for p in patterns:
        if fnmatch.fnmatch(rel, p) or fnmatch.fnmatch(rel, p + "/*"):
            return True
        if rel == p or rel.startswith(p + "/"):
            return True
        if fnmatch.fnmatch(os.path.basename(rel), p):
            return True
    return False


def req(method, path, token, data=None, raw=False, retries=4):
    body = json.dumps(data).encode() if data is not None else None
    last = None
    for attempt in range(retries):
        r = urllib.request.Request(API + path, data=body, method=method)
        r.add_header("Authorization", "Bearer " + token)
        r.add_header("Accept", "application/vnd.github+json")
        r.add_header("X-GitHub-Api-Version", "2022-11-28")
        r.add_header("User-Agent", "nx659j-kernel-builder")
        if body is not None:
            r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r, timeout=90) as resp:
                c = resp.read()
                return c if raw else json.loads(c.decode() or "{}")
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            if e.code in (500, 502, 503, 504) and attempt < retries - 1:
                time.sleep(3 * (attempt + 1)); last = e; continue
            raise RuntimeError(f"{method} {path} -> {e.code}: {detail[:600]}")
        except Exception as e:
            last = e
            if attempt < retries - 1:
                time.sleep(3 * (attempt + 1)); continue
            raise RuntimeError(f"{method} {path} -> {e}")
    raise RuntimeError(str(last))


def collect():
    patterns = _ignore_patterns()
    files = []
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in (".git", "__pycache__")
                  and not _ignored(os.path.relpath(os.path.join(dp, d), ROOT), patterns)]
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, ROOT).replace("\\", "/")
            if _ignored(rel, patterns):
                continue
            files.append((rel, p))
    files.sort()
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="nx659j-kernel-builder")
    ap.add_argument("--phase", default="0")
    ap.add_argument("--stock", default="0", help="1=使用 configs/stock-linux.config")
    ap.add_argument("--minimal", default="0", help="1=minimal")
    ap.add_argument("--localversion", default="kona-ksu-a16fix-oc")
    ap.add_argument("--wait", action="store_true")
    ap.add_argument("--timeout", type=int, default=5400)
    args = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        sys.exit("set GITHUB_TOKEN")

    owner = req("GET", "/user", token)["login"]
    repo_path = f"/repos/{owner}/{args.repo}"
    try:
        repo = req("GET", repo_path, token)
        print("[*] repo exists:", repo["html_url"])
    except RuntimeError:
        repo = req("POST", "/user/repos", token, {"name": args.repo, "private": True, "auto_init": True})
        print("[*] created:", repo["html_url"])
        time.sleep(3)

    files = collect()
    for i, (rel, p) in enumerate(files):
        content = base64.b64encode(open(p, "rb").read()).decode()
        payload = {"message": f"add {rel}", "content": content}
        if i > 0:
            payload["branch"] = "main"
        try:
            req("PUT", f"{repo_path}/contents/{rel}", token, payload)
            print("[+]", rel)
        except RuntimeError as e:
            # 已存在 -> 取 sha 更新
            try:
                cur = req("GET", f"{repo_path}/contents/{rel}?ref=main", token)
                payload["sha"] = cur["sha"]
                req("PUT", f"{repo_path}/contents/{rel}", token, payload)
                print("[~]", rel)
            except Exception as e2:
                print("[!] fail", rel, e)
                raise

    req("POST", f"{repo_path}/actions/workflows/build.yml/dispatches", token,
        {"ref": "main", "inputs": {"phase": args.phase, "stock": args.stock,
                                  "minimal": args.minimal, "localversion": args.localversion}})
    print("[*] workflow dispatched phase", args.phase, "stock", args.stock, "minimal", args.minimal)

    if not args.wait:
        return
    deadline = time.time() + args.timeout
    run = None
    while time.time() < deadline:
        runs = req("GET", f"{repo_path}/actions/runs?per_page=5", token)
        for r in runs.get("workflow_runs", []):
            if r.get("event") == "workflow_dispatch":
                run = r
                break
        if run:
            print("[*] run", run["id"], run["status"], run.get("conclusion"))
            if run["status"] == "completed":
                break
        time.sleep(20)
    if not run or run["status"] != "completed":
        sys.exit("timeout waiting run")
    if run.get("conclusion") != "success":
        sys.exit("build failed: " + run.get("html_url", ""))
    arts = req("GET", f"{repo_path}/actions/runs/{run['id']}/artifacts", token)
    for a in arts.get("artifacts", []):
        data = req("GET", a["archive_download_url"], token, raw=True)
        out = os.path.join(os.getcwd(), a["name"] + ".zip")
        open(out, "wb").write(data)
        print("[+] artifact", out, len(data))


if __name__ == "__main__":
    main()
