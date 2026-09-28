"""check_inms_rtl.py -- 真 RTL 仿真对拍 alg_nms 的 cfg_inms / cfg_eps 路径。

流程:
  1. Python 生成随机梯度流 in_nms.hex (raster, {dir,gx,gy,mag});
  2. iverilog 编译 sim/algo/tb_alg_nms_inms.v + alg_nms/alg_win/alg_stream_delay
     /true_dual_port_ram, vvp 跑出 out_ref/out_ref3/out_new/out_new3.txt;
  3. 与 rtl_model 的金标准 nms_rtl(eps=0/3) / nms_interp_rtl(eps=0/3) 逐位比对。

iverilog 位置: 环境变量 ALG_IVERILOG 优先, 否则找 D:\\FPGA_Project\\tools\\iverilog
               \\bin\\iverilog.exe, 再退到 PATH。

用法:  python check_inms_rtl.py
"""

import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rtl_model import dir_class, nms_rtl, nms_interp_rtl  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SIM_DIR = os.path.abspath(os.path.join(HERE, ".."))          # sim/algo
PROJ = os.path.abspath(os.path.join(SIM_DIR, "..", ".."))    # 工程根
BUILD = os.path.join(SIM_DIR, "nms_sim")

W, H, VEXT = 32, 12, 8


def find_iverilog():
    env = os.environ.get("ALG_IVERILOG")
    if env and os.path.exists(env):
        return env
    cand = r"D:\FPGA_Project\tools\iverilog\bin\iverilog.exe"
    if os.path.exists(cand):
        return cand
    from shutil import which
    return which("iverilog")


def gen_stream(seed=3):
    """混合用例: 纯随机 / 四根轴 / 主轴与角邻居特意取相等(测严格侧口径)。"""
    rng = np.random.default_rng(seed)
    gx = rng.integers(-1020, 1021, (H, W)).astype(np.int64)
    gy = rng.integers(-1020, 1021, (H, W)).astype(np.int64)
    # 第 1 行: gy=0(水平轴); 第 2 行: gx=0(垂直轴)
    gy[1, :] = 0
    gx[2, :] = 0
    # 第 3 行: |gx|=|gy|(两条对角线轴)
    r = rng.integers(1, 900, W).astype(np.int64)
    gx[3, :] = r
    gy[3, :] = r
    gx[4, :] = r
    gy[4, :] = -r
    # 第 5 行: gx,gy 很小, 专门制造相等/零值
    gx[5, :] = rng.integers(-3, 4, W)
    gy[5, :] = rng.integers(-3, 4, W)
    # 第 6 行: mag 与真正幅值无关(测 mag 与梯度不同源时的行为)
    mag = np.abs(gx) + np.abs(gy)
    mag[6, :] = rng.integers(0, 2041, W)
    mag = np.clip(mag, 0, 2040).astype(np.int64)
    return gx, gy, mag


# dir_class() 返回 0/45/90/135; RTL 的 2bit 编码是 0->0, 90->1, 45->2, 135->3
DIR2RTL = {0: 0, 90: 1, 45: 2, 135: 3}


def main():
    iv = find_iverilog()
    if not iv:
        print("找不到 iverilog, 跳过真 RTL 仿真(可用 ALG_IVERILOG 指定)")
        return 2
    os.makedirs(BUILD, exist_ok=True)

    gx, gy, mag = gen_stream()
    d = dir_class(gx, gy)

    # 喂 H+2 行: 最后两行复制第 H-1 行, 这样窗口中心 y=H-1 也能输出
    # (等价于模型 pad_edge 的下边界), 否则最下一行永远无从对拍。
    with open(os.path.join(BUILD, "in_nms.hex"), "w") as f:
        for src_y in range(H + 2):
            yy = H - 1 if src_y >= H else src_y
            for x in range(W):
                word = ((DIR2RTL[int(d[yy, x])] & 3) << 35) \
                     | ((int(gx[yy, x]) & 0xFFF) << 23) \
                     | ((int(gy[yy, x]) & 0xFFF) << 11) | (int(mag[yy, x]) & 0x7FF)
                f.write("%010x\n" % word)

    srcs = [
        os.path.join(SIM_DIR, "tb_alg_nms_inms.v"),
        os.path.join(PROJ, "rtl", "algo", "alg_nms.v"),
        os.path.join(PROJ, "rtl", "algo", "alg_win.v"),
        os.path.join(PROJ, "rtl", "algo", "alg_stream_delay.v"),
        os.path.join(PROJ, "rtl", "true_dual_port_ram.v"),
    ]
    for s in srcs:
        if not os.path.exists(s):
            print("缺文件:", s)
            return 2

    vvp = os.path.join(os.path.dirname(iv), "vvp.exe")
    r = subprocess.run([iv, "-g2012", "-o", "tb_nms.vvp"] + srcs,
                       cwd=BUILD, capture_output=True, text=True)
    if r.returncode != 0:
        print("iverilog 编译失败:\n" + r.stdout + r.stderr)
        return 2
    r = subprocess.run([vvp, "tb_nms.vvp"], cwd=BUILD, capture_output=True,
                       text=True, timeout=300)
    if "TB NMS DONE" not in r.stdout:
        print("仿真没跑完:\n" + r.stdout + r.stderr)
        return 2

    want = [
        ("out_ref.txt", nms_rtl(mag, d, eps=0)),
        ("out_ref3.txt", nms_rtl(mag, d, eps=3)),
        ("out_new.txt", nms_interp_rtl(mag, gx, gy, eps=0)),
        ("out_new3.txt", nms_interp_rtl(mag, gx, gy, eps=3)),
    ]
    ok = True
    for name, exp in want:
        got = np.zeros((H, W), dtype=np.int32)
        seen = np.zeros((H, W), dtype=bool)
        path = os.path.join(BUILD, name)
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) != 4:
                    continue
                _, x, y, v = p
                x, y = int(x), int(y)
                if 0 <= y < H and 0 <= x < W:
                    got[y, x] = int(v, 16)
                    seen[y, x] = True
        n_missing = int((~seen).sum())
        n_bad = int((got != exp).sum())
        ok = ok and n_missing == 0 and n_bad == 0
        print("  %-14s 缺失 %3d 个像素, 不一致 %3d 个像素 -> %s"
              % (name, n_missing, n_bad, "OK" if (n_missing == 0 and n_bad == 0) else "FAIL"))
        if n_bad:
            bad = np.nonzero(got != exp)
            y0, x0 = bad[0][0], bad[1][0]
            print("      例: (y=%d,x=%d) rtl=%d model=%d gx=%d gy=%d mag=%d dir=%d"
                  % (y0, x0, got[y0, x0], exp[y0, x0], gx[y0, x0], gy[y0, x0],
                     mag[y0, x0], d[y0, x0]))

    print("结论: %s" % ("4 路 RTL 输出全部与金标准逐位一致 OK" if ok else "存在不一致"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
