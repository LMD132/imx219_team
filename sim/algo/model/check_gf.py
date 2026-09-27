"""check_gf.py -- alg_gf(EPF 前置滤波)单元对拍: RTL vs rtl_model 定点模型

流程:
  1. 生成小尺寸随机彩色图 -> in_rgb.hex
  2. iverilog 编译 tb_alg_gf.v + rtl/algo/*.v + RAM 原语, vvp 运行(+EPF= +GFEPS=)
  3. 真实图像区域(x<W, y<H)逐位对比:
       EPF=0 -> luma(直通)   EPF=1 -> gauss3x3_int   EPF=2 -> guided_filter_int(eps)

用法: python check_gf.py            # 跑 EPF=0/1/2 三档
      CHAIN_EPS / GFEPS 环境变量可覆盖导向滤波 eps
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
RUN = os.path.join(TB, "run_gf")

W, VEXT, H, REXT = 17, 9, 9, 8
GFEPS = int(os.environ.get("GFEPS", "400"))


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
    rng = np.random.default_rng(20260926)
    return rng.integers(0, 256, size=(H, W, 3), dtype=np.uint8)


def build():
    os.makedirs(RUN, exist_ok=True)
    vvp = os.path.join(RUN, "tb_gf.vvp")
    algo = sorted(os.path.join(RTL, "algo", f) for f in os.listdir(os.path.join(RTL, "algo"))
                  if f.endswith(".v"))
    src = [os.path.join(TB, "tb_alg_gf.v")] + algo + [
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


def run(vvp, img, epf, gfeps):
    rd = os.path.join(RUN, "epf%d_e%d" % (epf, gfeps))
    if os.path.isdir(rd):
        shutil.rmtree(rd)
    os.makedirs(rd)
    with open(os.path.join(rd, "in_rgb.hex"), "w", encoding="ascii") as f:
        for y in range(H):
            for x in range(W):
                r, g, b = img[y, x]
                f.write("%02x%02x%02x\n" % (r, g, b))
    p = subprocess.run([exe("vvp"), os.path.abspath(vvp),
                        "+EPF=%d" % epf, "+GFEPS=%d" % gfeps],
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


def parse_stream(rd, name, nhex):
    d, dup = {}, 0
    with open(os.path.join(rd, name), "r", encoding="ascii", errors="replace") as f:
        for ln in f:
            t = ln.split()
            if len(t) != 4 + nhex:              # frame tick x y data
                continue
            k = (int(t[2]), int(t[3]))          # (x, y)
            v = tuple(_h(x) for x in t[4:])
            if k in d:
                dup += 1
            else:
                d[k] = (int(t[1]),) + v         # (tick, val...)
    return d, dup


def real_of(d):
    return {k: v for k, v in d.items() if k[0] < W and k[1] < H}


def check(rd, luma, epf, gfeps):
    got, dup = parse_stream(rd, "c_gf.txt", 1)
    g = real_of(got)
    if epf == 0:
        exp = luma
    elif epf == 1:
        exp = M.gauss3x3_int(luma)
    else:
        exp = M.guided_filter_int(luma, gfeps)
    expd = {(x, y): (int(exp[y, x]),) for y in range(H) for x in range(W)}
    bad = [k for k in expd if g.get(k, (None,))[1:] != expd[k]]
    miss = [k for k in expd if k not in g]
    nex = sum(1 for k in g if k not in expd)
    print("  [gf epf=%d eps=%d] expect %4d got %4d  mismatch %3d missing %3d extra %3d dup %d"
          % (epf, gfeps, len(expd), len(g), len(bad), len(miss), nex, dup))
    for k in bad[:5]:
        print("        (x=%d,y=%d) rtl=%s exp=%s" % (k[0], k[1], g.get(k), expd[k]))
    # 输入->输出 标签延迟实测(仅记录)
    gin, _ = parse_stream(rd, "c_gray.txt", 1)
    gd = real_of(gin)
    deltas = {}
    for (x, y), (tk, _v) in g.items():
        ti = gd.get((x, y))
        if ti is None:
            continue
        deltas[tk - ti[0]] = deltas.get(tk - ti[0], 0) + 1
    print("        延迟直方图 top3 = %s"
          % sorted(deltas.items(), key=lambda kv: -kv[1])[:3])
    return not (bad or miss or nex)


def main():
    img = gen()
    luma = M.gray_shift_add(img[:, :, 0], img[:, :, 1], img[:, :, 2])
    vvp = build()
    ok = True
    for epf in (0, 1, 2):
        rd = run(vvp, img, epf, GFEPS)
        ok &= check(rd, luma, epf, GFEPS)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
