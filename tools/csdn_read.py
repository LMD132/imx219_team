# -*- coding: utf-8 -*-
"""Read a CSDN article's text body without a browser.

CSDN serves the article HTML server-side, so a plain curl fetch is enough to
read public articles and copy them into the repo as notes.  Python's urllib
times out on this network (same as api.github.com), so the fetch goes through
C:\\Windows\\System32\\curl.exe, which is what works here.

    python tools\\csdn_read.py <url-or-article-id> [--chars 6000] [--out FILE]
    python tools\\csdn_read.py 149813034

Exit codes: 0 ok, 2 fetch failed, 3 the page has no article body (login wall,
deleted post, or a paywall stub).
"""

import argparse
import html
import os
import re
import subprocess
import sys

CURL = r"C:\Windows\System32\curl.exe"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
WORK = os.path.join("work", "csdn")

BLOCK_END = re.compile(r"(?i)</(p|div|li|h[1-6]|tr|pre|blockquote|section)>")
BREAK = re.compile(r"(?i)<(br|hr)\s*/?>")
TAG = re.compile(r"(?s)<[^>]+>")
H1 = re.compile(r'(?s)<h1[^>]*class="[^"]*title-article[^"]*"[^>]*>(.*?)</h1>')
TITLE = re.compile(r"(?s)<title>(.*?)</title>")
BODY_START = re.compile(r'(?s)<div[^>]*id="content_views"[^>]*>')
BODY_END = re.compile(r'(?s)<(div[^>]*id="treeSkill"'
                      r'|div[^>]*class="[^"]*(?:hide-article|article-copyright)|'
                      r'div[^>]*id="blogExtensionBox")')
NUMERIC = re.compile(r"^\d{4,}$")


def url_of(ref):
    if ref.startswith("http://") or ref.startswith("https://"):
        return ref
    if NUMERIC.match(ref):
        return "https://blog.csdn.net/nav/advanced-technology/" + ref  # marker, unused
    raise SystemExit("not a URL or a bare article id: %s" % ref)


def fetch(url, outdir=WORK):
    os.makedirs(outdir, exist_ok=True)
    tmp = os.path.join(outdir, "_last.html")
    cmd = [CURL, "-s", "-L", "--max-time", "40", "-A", UA,
           "-H", "Accept-Language: zh-CN,zh;q=0.9", "-o", tmp, "-w", "%{http_code}", url]
    p = subprocess.run(cmd, capture_output=True, text=True)
    code = (p.stdout or "").strip()
    if p.returncode != 0 or code != "200":
        print("fetch failed: rc=%s http=%s %s" % (p.returncode, code,
                                                  (p.stderr or "").strip()[:200]))
        return None
    with open(tmp, "rb") as fh:
        return fh.read().decode("utf-8", "replace")


def to_text(frag):
    s = BREAK.sub("\n", frag)
    s = BLOCK_END.sub("\n", s)
    s = TAG.sub("", s)
    s = html.unescape(s)
    s = s.replace("\u200b", "").replace("\xa0", " ")
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in s.split("\n")]
    out = []
    for ln in lines:
        if ln or (out and out[-1]):
            out.append(ln)
    return "\n".join(out).strip()


def parse(page, url):
    title = ""
    m = H1.search(page) or TITLE.search(page)
    if m:
        title = to_text(m.group(1))
        title = re.sub(r"\s*[-_]\s*(CSDN博客|CSDN).*$", "", title).strip()
    m = BODY_START.search(page)
    body = ""
    if m:
        rest = page[m.end():]
        e = BODY_END.search(rest)
        body = to_text(rest[:e.start()] if e else rest)
    return title, body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref", help="article URL")
    ap.add_argument("--chars", type=int, default=8000,
                    help="how many body characters to print (0 = all)")
    ap.add_argument("--out", default=None, help="also write title+body here")
    a = ap.parse_args()

    url = url_of(a.ref)
    page = fetch(url)
    if page is None:
        return 2
    title, body = parse(page, url)
    if not title and not body:
        print("no article body found (login wall / deleted / paywall stub)")
        return 3

    print("url    : %s" % url)
    print("title  : %s" % title)
    print("chars  : %d" % len(body))
    print("---")
    shown = body if a.chars == 0 else body[:a.chars]
    print(shown)
    if a.chars and len(body) > a.chars:
        print("\n[truncated at %d of %d chars]" % (a.chars, len(body)))

    if a.out:
        os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
        with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# %s\n\n%s\n\nsource: %s\n" % (title, body, url))
        print("\nwrote %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
