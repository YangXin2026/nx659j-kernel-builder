#!/usr/bin/env python3
"""监控最新 workflow_dispatch run，完成后下载 artifacts。"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"


def req(path, token, raw=False):
    last = None
    for _ in range(5):
        try:
            r = urllib.request.Request(API + path)
            r.add_header("Authorization", "Bearer " + token)
            r.add_header("Accept", "application/vnd.github+json")
            r.add_header("User-Agent", "nx659j-watch")
            with urllib.request.urlopen(r, timeout=90) as resp:
                c = resp.read()
                return c if raw else json.loads(c.decode() or "{}")
        except Exception as e:
            last = e
            time.sleep(5)
    raise last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="YangXin2026/nx659j-kernel-builder")
    ap.add_argument("--out", default="artifacts")
    ap.add_argument("--timeout", type=int, default=5400)
    ap.add_argument("--after-id", type=int, default=0)
    args = ap.parse_args()
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("set GITHUB_TOKEN")
    os.makedirs(args.out, exist_ok=True)
    repo = f"/repos/{args.repo}"
    seen = set()
    end = time.time() + args.timeout
    while time.time() < end:
        runs = req(repo + "/actions/runs?per_page=5", token).get("workflow_runs", [])
        for r in runs:
            if r.get("event") != "workflow_dispatch":
                continue
            if r["id"] <= args.after_id:
                continue
            if r["status"] == "completed":
                print("RUN", r["id"], r["status"], r.get("conclusion"), r.get("html_url"))
                arts = req(f"{repo}/actions/runs/{r['id']}/artifacts", token)
                for a in arts.get("artifacts", []):
                    if a["id"] in seen:
                        continue
                    data = req(a["archive_download_url"], token, raw=True)
                    out = os.path.join(args.out, a["name"] + ".zip")
                    open(out, "wb").write(data)
                    seen.add(a["id"])
                    print("ARTIFACT", out, len(data), flush=True)
                return
            print("RUN", r["id"], r["status"], r.get("conclusion"), flush=True)
        time.sleep(20)
    sys.exit("timeout")


if __name__ == "__main__":
    main()
