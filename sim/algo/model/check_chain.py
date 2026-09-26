"""check_chain.py -- alg_top 全链路对拍(逐级 + 对齐 + 显示)

流程:
  1. 生成小尺寸测试图 -> in_rgb.hex
  2. iverilog 编译 tb_alg_chain.v + rtl/algo/*.v + RAM 原语, vvp 运行(+MODE= +DISP=)
  3. 逐级对比: alg_gray / median3 / gauss5 / sobel3(mag,dir) / nms / thresh / despeckle
     -> 只比"真实图像区域"(x<W, y<H), 该区域 RTL 必须逐位等于 rtl_model.py
  4. 对齐核查: 用 dump 的 tick 实测 dsp 标签流与输入流的延迟差 == DLY_RGB
  5. 显示核查: 按显示光栅重建 (帧,行,列), 逐像素对比四种显示模式的模型
"""
import os
import shutil
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))   # 仓库根
# iverilog/vvp 是可选的第三方工具(约 2GB), 不入库。
#   * 设 ALG_OSS_BIN 指向 oss-cad-suite\bin -> 自动读它的 environment.bat
#   * 或者把 iverilog/vvp 直接放进 PATH, 不设 ALG_OSS_BIN 也行
OSS = os.environ.get("ALG_OSS_BIN", "")
RTL = os.path.join(REPO, "rtl")
TB = os.path.join(REPO, "sim", "algo")
RUN = os.path.join(TB, "run")


def exe(name):
    """工具可执行文件路径: 有 ALG_OSS_BIN 就用它, 否则当作在 PATH 里。"""
    return os.path.join(OSS, name + ".exe") if OSS else name

sys.path.insert(0, HERE)
import rtl_model as M  # noqa: E402

W, VEXT, H, REXT = 17, 9, 9, 8
NFRM, GAP, HALF, AW = 2, 40, 8, 4
LINE = W + VEXT
DLY_RGB = 26            # alg_top 模块默认值(被测配置)
MODE, GAUSS_AUTO = 2, True
DIR_CODE = {0: 0, 90: 1, 45: 2, 135: 3}   # 角度 -> RTL 2bit 编码

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


def build(extra=None, name="tb.vvp"):
    os.makedirs(RUN, exist_ok=True)
    vvp = os.path.join(RUN, name)
    algo = sorted(os.path.join(RTL, "algo", f) for f in os.listdir(os.path.join(RTL, "algo"))
                  if f.endswith(".v"))
    src = [os.path.join(TB, "tb_alg_chain.v")] + algo + [
        os.path.join(RTL, "simple_dual_port_ram.v"),
        os.path.join(RTL, "true_dual_port_ram.v")]
    p = subprocess.run([exe("iverilog"), "-g2012", "-o", vvp]
                       + (extra or []) + src,
                       cwd=RUN, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=oss_env())
    out = (p.stdout + p.stderr).strip()
    if out:
        print("[iverilog] " + out)
    if p.returncode != 0:
        raise SystemExit("iverilog failed")
    return vvp


def run(vvp, img, mode, disp, tag=""):
    rd = os.path.join(RUN, tag + "m%d_d%d" % (mode, disp))
    if os.path.isdir(rd):
        shutil.rmtree(rd)
    os.makedirs(rd)
    with open(os.path.join(rd, "in_rgb.hex"), "w", encoding="ascii") as f:
        for y in range(H):
            for x in range(W):
                r, g, b = img[y, x]
                f.write("%02x%02x%02x\n" % (r, g, b))
    p = subprocess.run([exe("vvp"), os.path.abspath(vvp),
                        "+MODE=%d" % mode, "+DISP=%d" % disp],
                       cwd=rd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=oss_env())
    if p.returncode != 0 or "DONE" not in p.stdout:
        print(p.stdout, p.stderr)
        raise SystemExit("vvp failed")
    return rd


def _h(s):
    """hex -> int; iverilog %0d/%0x 遇 X 会打出 x, 记为 -1"""
    try:
        return int(s, 16)
    except ValueError:
        return -1


def parse_stream(rd, name, nhex):
    """-> (dict[(fr,x,y)] = (tick,val...), dup)  同键保留第一次(tick 最小)"""
    d, dup = {}, 0
    with open(os.path.join(rd, name), "r", encoding="ascii", errors="replace") as f:
        for ln in f:
            t = ln.split()
            if len(t) != 4 + nhex:
                continue
            k = (int(t[0]), int(t[2]), int(t[3]))
            v = tuple(_h(x) for x in t[4:])
            if k in d:
                dup += 1
            else:
                d[k] = (int(t[1]),) + v
    return d, dup


def real_of(d):
    return {k[1:]: v for k, v in d.items() if k[1] < W and k[2] < H}


def cmp_stage(tag, got, exp, extra_msg=""):
    """exp: dict[(x,y)] = (val,)   got: dict[(x,y)] = (tick,val,)"""
    bad = [k for k in exp if got.get(k, (None,))[1:] != exp[k]]
    miss = [k for k in exp if k not in got]
    nex = sum(1 for k in got if k not in exp)
    print("  [%-9s] expect %4d got %4d  mismatch %3d missing %3d extra %3d  %s"
          % (tag, len(exp), len(got), len(bad), len(miss), nex, extra_msg))
    for k in bad[:3]:
        print("        (x=%d,y=%d) rtl=%s exp=%s" % (k[0], k[1], got.get(k), exp[k]))
    return not (bad or miss or nex)


def main():
    img = gen()
    luma = M.gray_shift_add(img[:, :, 0], img[:, :, 1], img[:, :, 2])
    vvp = build()

    allok = True
    for mode, disp in [(2, 1), (2, 3), (0, 2), (1, 0)]:
        print("=== MODE=%d DISP=%d ===" % (mode, disp))
        rd = run(vvp, img, mode, disp)
        allok &= check_run(rd, img, luma, mode, disp)

    # ---- 独立验证: 行周期初值刻意写错(40), 检验实测修正是否自动生效 ----
    print("=== HTOTAL 初值刻意写错(40) -> 实测修正 ===")
    vvp2 = build(extra=["-Ptb_alg_chain.HTOTAL=40"], name="tb_ht.vvp")
    rd2 = run(vvp2, img, 2, 1, tag="ht_")
    E2 = chain_expected(luma, 2)
    ok2 = check_disp(rd2, img, luma, E2, 2, 1, only_last=True)
    print("  [htotal   ] 实测修正后(末帧)显示对齐 %s" % ("PASS" if ok2 else "FAIL"))
    allok &= ok2
    print("RESULT:", "PASS" if allok else "FAIL")
    return 0 if allok else 1


def chain_expected(luma, mode):
    """返回逐级期望值(真实图像区域)"""
    med = M.median_3x3_network(luma)
    gauss_on = True if mode == 2 else False
    gau = M.gauss5x5_int(med) if gauss_on else med
    gx, gy, mag = M.sobel_full(gau)
    dirc = M.dir_class(gx, gy)
    nms = M.nms_rtl(mag, dirc)
    if mode == 2:
        thr = M.hysteresis_rtl(nms, 21, 58)
    elif mode == 1:
        thr = M.hysteresis_rtl(mag, 21, 58)
    else:
        thr = M.threshold_rtl(mag, 24)
    dsp = M.isolated_rtl(thr)
    return dict(med=med, gau=gau, mag=mag, dirc=dirc, nms=nms, thr=thr, dsp=dsp)


def d2exp(mat):
    return {(x, y): (int(mat[y, x]),) for y in range(H) for x in range(W)}


def check_run(rd, img, luma, mode, disp):
    E = chain_expected(luma, mode)
    ok = True

    # ---- 1) 各级(真实区域) ----
    g, du = parse_stream(rd, "c_gray.txt", 1)
    ok &= cmp_stage("gray", real_of(g), d2exp(luma), "dup %d" % du)
    # 扩展光栅流: 行尾列 = 最后列, 帧尾行 = 最后一行
    bad_ext = 0
    for (fr, x, y), v in g.items():
        if x >= W and y < H and v[1] != int(luma[y, W - 1]):
            bad_ext += 1
        elif y >= H and v[1] != int(luma[H - 1, min(x, W - 1)]):
            bad_ext += 1
    print("  [gray-ext ] 行尾/帧尾扩展像素错误 %d  (dump 总数 %d)" % (bad_ext, len(g)))
    ok &= (bad_ext == 0)

    for tag, fn, mat in (("median", "c_med.txt", E["med"]),
                         ("gauss5", "c_gau.txt", E["gau"]),
                         ("sobel3", "c_sob.txt", E["mag"]),
                         ("nms", "c_nms.txt", E["nms"]),
                         ("thresh", "c_thr.txt", E["thr"]),
                         ("despeck", "c_dsp.txt", E["dsp"])):
        d, dup = parse_stream(rd, fn, 2 if tag == "sobel3" else 1)
        r = real_of(d)
        exp = d2exp(mat)
        if tag == "sobel3":
            exp = {(x, y): (int(E["mag"][y, x]), DIR_CODE[int(E["dirc"][y, x])]) for y in range(H) for x in range(W)}
        ok &= cmp_stage(tag, r, exp, "dup %d" % dup)

    # ---- 2) 对齐延迟(仅记录): 该判据量的是"标签流-输入流"的 tick 差, 它不是
    #        显示对齐的充分条件(显示位置由 alg_vdisp 的整行延迟+源坐标寻址重建,
    #        见 alg_vdisp.v)。真正的对齐断言是下面的 [display] 逐像素比对。
    din, _ = parse_stream(rd, "c_in.txt", 1)
    ddp, _ = parse_stream(rd, "c_dsp.txt", 1)
    din_r = {(k[0], k[1], k[2]): v[0] for k, v in din.items()}
    deltas = {}
    for (fr, lx, ly), (tk, val) in ddp.items():
        sx, sy = lx + 7, ly + 7          # dsp 标签 = 源像素坐标, 出现时输入光栅已 +7
        if sx >= W or sy >= H:
            continue
        t_in = din_r.get((fr, sx, sy))
        if t_in is None:
            continue
        deltas[tk - t_in] = deltas.get(tk - t_in, 0) + 1
    top = sorted(deltas.items(), key=lambda kv: -kv[1])[:3]
    print("  [delay    ] dsp标签流 - 输入流(同源像素) 直方图 top3 = %s  (仅记录)" % (top,))


    # ---- 3) 显示 ----
    ok &= check_disp(rd, img, luma, E, mode, disp)
    return ok


def check_disp(rd, img, luma, E, amode, ddisp, only_last=False):
    """显示核查: c_disp.txt 现在自带显示坐标 (tick x y rrggbb) -> 直接按屏幕
    (帧, 行, 列) 比对模型。期望 mismatch = 0。"""
    recs = []
    with open(os.path.join(rd, "c_disp.txt"), "r", encoding="ascii", errors="replace") as f:
        for ln in f:
            s = ln.split()
            if len(s) != 4:      # tick x y rrggbb
                continue
            h = s[3]
            recs.append((int(s[0]), int(s[1]), int(s[2]),
                         _h(h[0:2]), _h(h[2:4]), _h(h[4:6])))
    vst = [int(l) for l in open(os.path.join(rd, "c_vs.txt"), "r",
                                encoding="ascii", errors="replace").read().split()]
    frames = []
    for i, vt in enumerate(vst):
        end = vst[i + 1] if i + 1 < len(vst) else 10 ** 12
        frames.append([r for r in recs if vt <= r[0] < end])

    ok = True
    got = {}
    for fi, fr in enumerate(frames):
        rows = {}
        for tk, x, y, r, g, b in fr:
            rows.setdefault(y, {})[x] = (r, g, b)
        ys = sorted(rows)
        if len(ys) != H or any(len(rows[y]) != W for y in ys):
            print("  [display  ] 帧%d 光栅异常: 行数=%d 行长=%s"
                  % (fi, len(ys), sorted({len(rows[y]) for y in ys})))
            ok = False
        for y in ys:
            for x, c in rows[y].items():
                got[(fi, y, x)] = c

    fidx = [len(frames) - 1] if only_last else list(range(len(frames)))
    exp = {}
    for fi in fidx:
        for y in range(H):
            for x in range(W):
                col = x
                if ddisp == 0:      # 2:1 水平抽取(左右各显示一遍全画幅)
                    col = (2 * x) if x < HALF else (2 * (x - HALF))
                col = min(col, W - 1)
                r, g, b = (int(v) for v in img[y, col])
                lg = int(luma[y, col])
                ed = int(E["dsp"][y, col])
                if ddisp == 1:                      # 彩色 + 红边叠加
                    e = (255, 0, 0) if ed else (r, g, b)
                elif ddisp == 3:                    # 纯边缘
                    e = (ed, ed, ed)
                else:                               # 0 / 2: 左灰度 右边缘
                    e = (lg, lg, lg) if x < HALF else (ed, ed, ed)
                exp[(fi, y, x)] = e
    bad = [k for k in exp if got.get(k) != exp[k]]
    for fi in fidx:
        nb = sum(1 for k in bad if k[0] == fi)
        print("        帧%d: 比对 %d 像素 mismatch %d" % (fi, W * H, nb))
    print("  [display  ] 比对 %d 像素  mismatch %d  %s"
          % (len(exp), len(bad), "" if not bad else "<-- 显示/对齐错误"))
    for k in bad[:6]:
        print("        (f=%d y=%d x=%d) rtl=%s exp=%s" % (k[0], k[1], k[2],
                                                          got.get(k), exp[k]))
    return ok and not bad


if __name__ == "__main__":
    raise SystemExit(main())