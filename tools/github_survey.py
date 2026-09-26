# -*- coding: utf-8 -*-
"""Re-run the GitHub survey behind docs/github_survey.md.

Searches the GitHub repository API, prints a compact table per query, and
optionally lists the HDL file names of a shortlist so a claim like "this repo
has a real NMS + double-threshold pipeline" can be checked instead of trusted.

urllib does not reach api.github.com from this machine (times out) but curl.exe
does, so every request goes through curl.  The results are written to work/gh/,
which is git-ignored.

    python tools\\github_survey.py                 # the searches only
    python tools\\github_survey.py --trees         # + the shortlist file lists
    python tools\\github_survey.py --repo owner/name   # one repo in detail
    python tools\\github_survey.py --file owner/name:path/to/file.v   # read one file
"""

import argparse
import glob
import json
import os
import subprocess
import time
import urllib.parse

CURL = r"C:\Windows\System32\curl.exe"
OUT = os.path.join("work", "gh")

QUERIES = [
    "sobel edge detection fpga language:verilog",
    "canny edge detection verilog fpga",
    "efinix image processing",
    "ti60f225",
    "efinix",
    "histogram equalization fpga language:verilog",
    "otsu verilog",
    "line buffer verilog",
    "median filter verilog fpga",
    "gaussian filter verilog fpga",
    "crazybingo fpga",
    "imx219 fpga",
    # Kept because they come back empty: the point of the doc is that this
    # niche is thin on GitHub, not that the queries were badly chosen.
    "fpga image processing verilog hdmi",
    "otsu adaptive threshold fpga verilog",
    "edge detection ov5640 verilog",
]

# Repos whose actual HDL file list decides whether the entry in the doc is
# worth anybody's afternoon.
TREES = [
    "EricYXZ/ti60f225-image-processing-fpga",
    "DOUDIU/Hardware-Implementation-of-the-Canny-Edge-Detection-Algorithm",
    "Nitcloud/Image_sim",
    "Passionate0424/CLAHE_verilog",
    "AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection",
    "Floatkyun/Ultra-Vision",
    # The two that back the licence section: XAli-SHX hides the Altera
    # University Program Canny quad, BambooWhispering the histeq pair.
    "XAli-SHX/Implementation-of-an-Edge-Detection-Filter-Using-the-Avalon-Interface",
    "BambooWhispering/FPGA-histogram_equalization",
]


def curl(url, dst=None, raw=False, tries=4):
    for _ in range(tries):
        args = [CURL, "-sL", "-m", "30", "-A", "codex-survey",
                "-H", "Accept: application/vnd.github+json"]
        if dst:
            args += ["-o", dst, "-w", "%{http_code}"]
        args.append(url)
        r = subprocess.run(args, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if raw:
            return r.stdout
        if (r.stdout or "").strip() == "200":
            try:
                return json.load(open(dst, encoding="utf-8"))
            except Exception:
                pass
        time.sleep(5)
    return None


def repo(name):
    tag = name.replace("/", "__")
    return curl("https://api.github.com/repos/" + name, os.path.join(OUT, "repo_%s.json" % tag))


def tree(name, branch):
    tag = name.replace("/", "__")
    return curl("https://api.github.com/repos/%s/git/trees/%s?recursive=1" % (name, branch),
                os.path.join(OUT, "tree_%s.json" % tag))


def branches():
    """full_name -> default_branch, harvested from every saved search result."""
    out = {}
    for f in glob.glob(os.path.join(OUT, "*.json")):
        try:
            d = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        for it in (d.get("items") or []):
            out[it["full_name"]] = it.get("default_branch", "main")
    return out


def searches():
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for n, q in enumerate(QUERIES):
        url = ("https://api.github.com/search/repositories?q=" + urllib.parse.quote(q)
               + "&sort=stars&order=desc&per_page=8")
        dst = os.path.join(OUT, "q%02d.json" % n)
        # Unauthenticated search allows ~10 requests a minute, and a burst
        # trips it.  One failed query silently shrinks the row count, so back
        # off and retry the whole query instead of moving on.
        d = None
        for attempt in range(3):
            d = curl(url, dst, tries=2)
            if d is not None:
                break
            print("   (retry %d for %s)" % (attempt + 1, q))
            time.sleep(35)
        if d is None:
            print("FAIL %s" % q)
            continue
        print("\n== %s  (total %d)" % (q, d.get("total_count", 0)))
        for it in d.get("items", []):
            lic = (it.get("license") or {}).get("spdx_id") or "-"
            print("   %-52s %5d %-11s %-11s %s" % (
                it["full_name"], it["stargazers_count"], it.get("language") or "-", lic,
                (it.get("description") or "")[:62]))
            rows.append({"q": q, "full_name": it["full_name"],
                         "stars": it["stargazers_count"], "language": it.get("language"),
                         "license": lic, "pushed": (it.get("pushed_at") or "")[:10],
                         "url": it["html_url"],
                         "desc": (it.get("description") or "")[:200]})
        time.sleep(7)
    json.dump(rows, open(os.path.join("work", "github_survey.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("\nrows=%d -> work/github_survey.json" % len(rows))


def show_tree(name, branch=None):
    b = branch or branches().get(name) or "main"
    d = tree(name, b)
    if d is None:
        print("-- %s : tree fetch failed" % name)
        return
    paths = [t["path"] for t in d.get("tree", []) if t["type"] == "blob"]
    hdl = [p for p in paths if p.lower().endswith((".v", ".sv", ".vhd", ".vh", ".svh"))]
    names = sorted(set(p.split("/")[-1] for p in hdl))
    print("\n-- %s  branch=%s  (%d files, %d HDL, %d distinct names)"
          % (name, b, len(paths), len(hdl), len(names)))
    for n in names:
        print("     %s" % n)


def show_file(spec):
    """owner/name:path -> print it, so a claim about a line can be rechecked."""
    name, _, path = spec.partition(":")
    if not path:
        print("-- usage: --file owner/name:path/to/file.v")
        return
    # Local knowledge first: the search results already carry default_branch,
    # and raw.githubusercontent needs no token, so this stays a single request.
    b = branches().get(name) or "main"
    for cand in (b, "master", "main"):
        url = "https://raw.githubusercontent.com/%s/%s/%s" % (name, cand, path)
        body = curl(url, raw=True)
        if body and not body.startswith("404"):
            print("== %s  branch=%s  %s" % (name, cand, path))
            print(body)
            return
    print("-- %s : %s not found on %s/master/main" % (name, path, b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trees", action="store_true")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--file", default=None, help="owner/name:path")
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    if a.file:
        show_file(a.file)
        return 0
    if a.repo:
        info = repo(a.repo)
        if info:
            print("== %s stars=%d license=%s pushed=%s"
                  % (a.repo, info.get("stargazers_count", 0),
                     (info.get("license") or {}).get("spdx_id") or "-",
                     (info.get("pushed_at") or "")[:10]))
            print("   %s" % (info.get("description") or ""))
        show_tree(a.repo, (info or {}).get("default_branch"))
        return 0
    searches()
    if a.trees:
        for name in TREES:
            show_tree(name)
            time.sleep(2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
