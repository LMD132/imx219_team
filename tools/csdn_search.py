# -*- coding: utf-8 -*-
"""Search CSDN from the command line through its JSON search API.

so.csdn.net is a JS app, but the endpoint it calls is a plain JSON API, so a
curl fetch is enough - no browser, no scraping of rendered HTML.  Each hit
carries price / vip_view_auth, which is how we tell member-only posts from
public ones.

    python tools\\csdn_search.py "FPGA adaptive threshold"
    python tools\\csdn_search.py "FPGA canny" --pages 2 --only-vip

Same curl caveat as tools\\csdn_read.py: urllib times out on this network.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

CURL = r"C:\Windows\System32\curl.exe"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
WORK = os.path.join("work", "csdn")
API = "https://so.csdn.net/api/v3/search"
TAG = re.compile(r"</?em>")


def search(query, page=1, timeout=25):
    q = urllib.parse.quote(query)
    url = ("%s?q=%s&t=blog&p=%d&s=0&tm=0&lv=-1&ft=0&l=&u=&ct=-1&pnt=-1&ry=-1"
           "&dct=-1&vco=-1&cc=-1&sc=-1&akt=-1&art=-1&ca=-1&prs=&pre=&ecc=-1"
           "&ebc=-1&urw=&ia=1&dId=&cl=-1&scl=-1&tcl=-1&platform=pc" % (API, q, page))
    os.makedirs(WORK, exist_ok=True)
    tmp = os.path.join(WORK, "_search.json")
    cmd = [CURL, "-s", "-L", "--max-time", str(timeout), "-A", UA,
           "-H", "Accept: application/json", "-o", tmp, "-w", "%{http_code}", url]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if (p.stdout or "").strip() != "200":
        return None, (p.stdout or "").strip()
    with open(tmp, "rb") as fh:
        raw = fh.read().decode("utf-8", "replace")
    try:
        return json.loads(raw), "200"
    except ValueError:
        return None, "bad-json"


def clean(s):
    return TAG.sub("", s or "").strip()


def price_of(it):
    try:
        return float(it.get("price") or 0)
    except (TypeError, ValueError):
        return 0.0


def is_vip(it):
    if price_of(it) > 0:
        return True
    if str(it.get("vip_view_auth") or "").strip() not in ("", "0", "None"):
        return True
    return "VIP" in clean(it.get("title")) or "VIP" in clean(it.get("body"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("query")
    ap.add_argument("--pages", type=int, default=1)
    ap.add_argument("--only-vip", action="store_true")
    ap.add_argument("--only-free", action="store_true")
    ap.add_argument("--limit", type=int, default=12, help="max hits printed")
    ap.add_argument("--out", default=None, help="write the JSON hits here")
    a = ap.parse_args()

    hits, seen = [], set()
    total = None
    for page in range(1, a.pages + 1):
        data, code = search(a.query, page)
        if data is None:
            print("search failed on page %d (%s)" % (page, code))
            break
        if total is None:
            total = data.get("total")
        for it in data.get("result_vos", []):
            url = (it.get("url") or "").split("?")[0]
            if not url or url in seen:
                continue
            seen.add(url)
            hits.append({
                "title": clean(it.get("title")),
                "url": url,
                "vip": is_vip(it),
                "view": it.get("view"),
                "digg": it.get("digg"),
                "author": it.get("author") or it.get("nickname"),
                "date": (it.get("create_time_str") or "")[:10],
                "digest": clean(it.get("body"))[:110],
            })
        time.sleep(0.4)

    if a.only_vip:
        hits = [h for h in hits if h["vip"]]
    if a.only_free:
        hits = [h for h in hits if not h["vip"]]

    print("query : %s   total=%s  hits=%d" % (a.query, total, len(hits)))
    for i, h in enumerate(hits[:a.limit], 1):
        print("%2d. [%s] %s  (%s, %s views, %s)"
              % (i, "VIP" if h["vip"] else "free", h["title"],
                 h["author"], h["view"], h["date"]))
        print("    %s" % h["url"])
        print("    %s" % h["digest"])
    if len(hits) > a.limit:
        print("... %d more" % (len(hits) - a.limit))

    if a.out:
        os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
        with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(hits, fh, ensure_ascii=False, indent=1)
        print("wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
