"""check_ebridge.py -- alg_ebridge(边缘断线桥接) 单元对拍

流程:
  1. 生成"带断线的二值边缘图"测试向量(短线/长线/随机空洞/噪声点) -> in_edge.hex
  2. iverilog 编译 tb_alg_ebridge.v + rtl/algo/*.v, vvp 运行 (+K= +MODE=)
  3. 真实图像区域(x<W, y<H)输出必须逐位等于 rtl_model.bridge_rtl()
  4. 档位: K=0/1/2/3, MODE=2(CANNY) 与 MODE=0(单阈值旁路)

用法: python check_ebridge.py            (需要 ALG_OSS_BIN 或 PATH 里有 iverilog)
"""
import os
import shutil
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OSS = os.environ.get("ALG_OSS_BIN", "")
RTL = os.path.join(REPO, "rtl")
TB = os.path.join(REPO, "sim", "algo")
RUN = os.path.join(TB, "run_brg")

W, VEXT, H = 17, 12, 9


def exe(name):
    return os.path.join(OSS, name + ".exe") if OSS else name


sys.path.insert(0, HERE)
import rtl_model as M  # noqa: E402

_ENV = None


def oss_env():
    global _ENV
    if _ENV is None:
        env = dict(os.environ)
        if OSS:
            bat = os.path.join(os.path.dirname(OSS.rstrip("\\")), "environment.bat")
            if os.path.exists(bat):
                p = subprocess.run(["cmd", "/c", "call %s >nul 2>&1 && set" % bat],
                                   capture_output=True, text=True,
                                   encoding="utf-8", errors="replace")
                for ln in p.stdout.splitlines():
                    if "=" in ln:
                        k, v = ln.split("=", 1)
                        env[k] = v
        _ENV = env
    return _ENV


def gen():
    """带断线的边缘图: 直线/斜线上撒随机 1~3px 空洞 + 孤立噪声点"""
    rng = np.random.default_rng(20260928)
    e = np.zeros((H, W), dtype=np.uint8)
    # 水平两条(不同行)
    for y in (2, 6):
        e[y, 2:W - 2] = 1
    # 垂直两条
    for x in (3, 13):
        e[1:H - 1, x] = 1
    # 对角线(斜率 1)一条
    for t in range(min(H, W) - 3):
        e[1 + t, 4 + t] = 1
    # 打洞: 每行/列随机去掉 1~3 px
    for y in (2, 6):
        for x0 in range(3, W - 4, 5):
            g = int(rng.integers(1, 4))
            e[y, x0:x0 + g] = 0
    for x in (3, 13):
        for y0 in range(2, H - 3, 4):
            g = int(rng.integers(1, 4))
            e[y0:y0 + g, x] = 0
    for t in range(0, min(H, W) - 3, 4):
        g = int(rng.integers(1, 3))
        for d in range(g):
            yy, xx = 1 + t + d, 4 + t + d
            if yy < H and xx < W:
                e[yy, xx] = 0
    # 随机噪声点(孤立)与一对明显的孤立短线
    for _ in range(12):
        e[int(rng.integers(0, H)), int(rng.integers(0, W))] = 1
    return (e * 255).astype(np.uint8)


def build():
    os.makedirs(RUN, exist_ok=True)
    vvp = os.path.join(RUN, "tb_brg.vvp")
    algo = sorted(os.path.join(RTL, "algo", f)
                  for f in os.listdir(os.path.join(RTL, "algo"))
                  if f.endswith(".v"))
    src = [os.path.join(TB, "tb_alg_ebridge.v")] + algo + [
        os.path.join(RTL, "simple_dual_port_ram.v"),
        os.path.join(RTL, "true_dual_port_ram.v")]
    p = subprocess.run([exe("iverilog"), "-g2012", "-o", vvp] + src,
                       cwd=RUN, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=oss_env())
    out = (p.stdout + p.stderr).strip()
    if out:
        print("[iverilog] " + out)
    if p.returncode != 0:
        raise SystemExit("iverilog failed")
    return vvp


def run(vvp, img, k, mode, tag=""):
    rd = os.path.join(RUN, tag + "k%d_m%d" % (k, mode))
    if os.path.isdir(rd):
        shutil.rmtree(rd)
    os.makedirs(rd)
    with open(os.path.join(rd, "in_edge.hex"), "w", encoding="ascii") as f:
        for y in range(H):
            for x in range(W):
                f.write("%02x\n" % img[y, x])
    p = subprocess.run([exe("vvp"), os.path.abspath(vvp),
                        "+K=%d" % k, "+MODE=%d" % mode],
                       cwd=rd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=oss_env())
    if p.returncode != 0 or "DONE" not in p.stdout:
        print(p.stdout, p.stderr)
        raise SystemExit("vvp failed")
    return rd


def _h(s):
    try:
        return int(s, 16)
    except ValueError:
        return -1


def parse_out(rd):
    d = {}
    with open(os.path.join(rd, "e_out.txt"), "r", encoding="ascii",
              errors="replace") as f:
        for ln in f:
            t = ln.split()
            if len(t) != 5:
                continue
            fr, tk, x, y, v = int(t[0]), int(t[1]), int(t[2]), int(t[3]), _h(t[4])
            if 0 <= x < W and 0 <= y < H:
                d.setdefault((fr, x, y), v)
    return d


def main():
    img = gen()
    vvp = build()
    allok = True
    for mode, k in ((2, 0), (2, 1), (2, 2), (2, 3), (0, 2), (1, 2)):
        rd = run(vvp, img, k, mode)
        exp = M.bridge_rtl(img, k, mode)
        got = parse_out(rd)
        bad = 0
        for fr in range(3):
            for y in range(H):
                for x in range(W):
                    if got.get((fr, x, y)) != int(exp[y, x]):
                        bad += 1
                        if bad <= 3:
                            print("    (f=%d x=%d y=%d) rtl=%s exp=%s"
                                  % (fr, x, y, got.get((fr, x, y)), exp[y, x]))
        added = int(((exp > 0) != (img > 0)).sum())
        print("  [K=%d MODE=%d] 3 帧 x %d px   mismatch %d  (桥接新增像素 %d)"
              % (k, mode, W * H, bad, added))
        allok &= (bad == 0)
    print("RESULT:", "PASS" if allok else "FAIL")
    return 0 if allok else 1


if __name__ == "__main__":
    raise SystemExit(main())
