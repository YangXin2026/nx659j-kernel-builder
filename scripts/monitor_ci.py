#!/usr/bin/env python3
"""CI 构建监控：等指定 workflow 的下一次运行完成 -> 打包日志/产物 -> 输出摘要。

用法:
  python scripts/monitor_ci.py --after-id 40082666645 --name "4.19-kona" --dir diag/ci-runs
完成后会打印 CI_READY 摘要，并退出（harness 会通知 agent）。
"""
import argparse
import io
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request
import zipfile

API = "https://api.github.com"


def req_json(url, token, retries=6):
    last = None
    for _ in range(retries):
        try:
            r = urllib.request.Request(url)
            r.add_header("Authorization", "Bearer " + token)
            r.add_header("Accept", "application/vnd.github+json")
            r.add_header("User-Agent", "nx659j-monitor")
            with urllib.request.urlopen(r, timeout=90) as resp:
                return json.loads(resp.read().decode() or "{}")
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(5)
    raise last


def download_redirect(url, token, out_path, retries=6):
    """GitHub logs/artifacts 先 302 到签名 URL，签名 URL 不能再带 Authorization。"""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    last = None
    for _ in range(retries):
        try:
            op = urllib.request.build_opener(NoRedirect)
            try:
                op.open(urllib.request.Request(url, headers={
                    "Authorization": "Bearer " + token,
                    "User-Agent": "nx659j-monitor",
                }), timeout=120)
                loc = url
            except urllib.error.HTTPError as e:
                loc = e.headers.get("Location")
            if not loc:
                raise RuntimeError("no redirect location")
            data = urllib.request.urlopen(loc, timeout=900).read()
            with open(out_path, "wb") as f:
                f.write(data)
            return len(data)
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(5)
    raise last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="YangXin2026/nx659j-kernel-builder")
    ap.add_argument("--after-id", type=int, default=0)
    ap.add_argument("--name", default="", help="workflow 名称过滤（包含匹配）")
    ap.add_argument("--dir", default="diag/ci-runs")
    ap.add_argument("--timeout", type=int, default=7200)
    args = ap.parse_args()
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("set GITHUB_TOKEN")

    end = time.time() + args.timeout
    target = None
    while time.time() < end:
        runs = req_json(f"{API}/repos/{args.repo}/actions/runs?per_page=10", token)
        cands = []
        for r in runs.get("workflow_runs", []):
            if r["id"] <= args.after_id:
                continue
            if args.name and args.name not in r.get("name", ""):
                continue
            cands.append(r)
        if cands:
            cands.sort(key=lambda x: x["id"], reverse=True)
            latest = cands[0]
            if latest["status"] == "completed":
                target = latest
                break
            print(f"waiting run {latest['id']} {latest['status']}", flush=True)
        time.sleep(20)

    if not target:
        sys.exit("monitor timeout")

    rid = target["id"]
    outdir = os.path.join(args.dir, str(rid))
    os.makedirs(outdir, exist_ok=True)

    jobs = req_json(f"{API}/repos/{args.repo}/actions/runs/{rid}/jobs", token)
    steps = []
    for job in jobs.get("jobs", []):
        for s in job.get("steps", []):
            steps.append((s.get("number"), s.get("name"), s.get("conclusion")))

    logs_zip = os.path.join(outdir, "logs.zip")
    try:
        download_redirect(f"{API}/repos/{args.repo}/actions/runs/{rid}/logs", token, logs_zip)
        with zipfile.ZipFile(logs_zip) as z:
            z.extractall(os.path.join(outdir, "logs"))
    except Exception as e:  # noqa: BLE001
        print("logs download failed:", e, flush=True)

    # 产物（成功时）
    artifacts = req_json(f"{API}/repos/{args.repo}/actions/runs/{rid}/artifacts", token)
    for a in artifacts.get("artifacts", []):
        try:
            p = os.path.join(outdir, a["name"] + ".zip")
            download_redirect(a["archive_download_url"], token, p)
            print("artifact", a["name"], os.path.getsize(p), flush=True)
        except Exception as e:  # noqa: BLE001
            print("artifact failed", a["name"], e, flush=True)

    # 从日志里抓错误行
    errs = []
    logroot = os.path.join(outdir, "logs")
    for root, _, files in os.walk(logroot):
        for fn in files:
            fp = os.path.join(root, fn)
            try:
                with open(fp, "r", encoding="utf-8", errors="replace") as f:
                    lines = f.readlines()
            except Exception:
                continue
            for ln in lines[-4000:]:
                low = ln.lower()
                if any(k in low for k in ("error:", "error [", "failed:", "missing and no known rule", "undefined reference", "no such file", "fatal")):
                    errs.append(f"{os.path.relpath(fp, logroot)}: {ln.strip()}")

    summary = [
        f"run={rid}",
        f"name={target.get('name')}",
        f"conclusion={target.get('conclusion')}",
        f"url={target.get('html_url')}",
        "steps:",
    ] + [f"  {n}. {name}: {concl}" for n, name, concl in steps]
    if errs:
        summary.append("errors:")
        summary.extend("  " + e[:300] for e in errs[-25:])
    summary_text = "\n".join(summary)
    with open(os.path.join(outdir, "summary.txt"), "w", encoding="utf-8") as f:
        f.write(summary_text + "\n")
    print("CI_READY dir=" + outdir)
    print(summary_text, flush=True)
    # 失败退出码用 0，避免 harness 把 job 当崩溃；摘要里已有 conclusion
    sys.exit(0)


if __name__ == "__main__":
    main()
