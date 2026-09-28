"""check_inms.py -- 验证"亚像素方向插值 NMS"(alg_nms.v 的 cfg_inms=1 路径)。

三条检查:

  1) 退化性质(正确性): 梯度方向正好落在 0/45/90/135 四根轴上时(即逐像素满足
     min(|gx|,|gy|)=0 或 |gx|=|gy|), 插值版必须与 4 方向量化版逐位一致 ——
     证明新增路径没有改变参考实现的行为, 只在"轴与轴之间"起作用。
     ⚠ 生成用例时必须让 |gx|=|gy| 逐像素成立; 若 gx、gy 各自独立随机, 那是
     "轴间"方向, 两个版本本来就应当不同(那正是插值要修的东西)。

  2) 效果对比(有效性): 合成不同倾角的直线阶跃边缘(+噪声), 用与实际链路同量级
     的预处理(5x5 整数高斯)与滞回(压掉噪底)后统计
        - 平均线宽  (理想 ~1.0 px; >1 说明"一根线变几根")
        - 断续率    (某一行一个保留像素都没有)
        - 抖动率    (相邻两行边缘中心跳变 >1.5 px = 肉眼看到的"流动")
        - 错位率    (边缘中心偏离真实直线 >1.2 px = 上下跳动的另一面)
     对比 nms_rtl(4 方向量化) 与 nms_interp_rtl(插值)。

  3) RTL 转录对拍(兜底): 把 alg_nms.v 里 cfg_inms=1 的表达式按 Verilog 位宽/
     符号语义逐行抄成 Python, 与金标准 nms_interp_rtl 在随机梯度上逐位对拍。
     (真 RTL 对拍见 check_inms_rtl.py; 这一条用来兜住, 这一条用来兜住"抄错索引/抄错符号"这类低级错误。)

用法:  python check_inms.py
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rtl_model import (  # noqa: E402
    pad_edge, sobel_full, dir_class, nms_rtl, nms_interp_rtl, hysteresis_rtl,
)


# ---------------------------------------------------------------------------
# 3) RTL 转录: alg_nms.v 的 cfg_inms=1 路径(每一位宽/符号都照抄)
# ---------------------------------------------------------------------------
def rtl_shape_nms_interp(mag, gx, gy, eps=0):
    m = mag.astype(np.int64)
    h, w = m.shape
    p = pad_edge(m, 1)
    # 与 alg_nms.v 的 m0..m8 一一对应
    m0 = p[0:h, 0:w]
    m1 = p[0:h, 1:w + 1]
    m2 = p[0:h, 2:w + 2]
    m3 = p[1:h + 1, 0:w]
    m4 = m
    m5 = p[1:h + 1, 2:w + 2]
    m6 = p[2:h + 2, 0:w]
    m7 = p[2:h + 2, 1:w + 1]
    m8 = p[2:h + 2, 2:w + 2]

    cgx = gx.astype(np.int64)
    cgy = gy.astype(np.int64)
    # ---- 输入级: i_code = {sgx, strict, hor, w[3:0]} ----
    # wire [11:0] egx = in_gx[11] ? (~in_gx + 12'd1) : in_gx;  (12bit 补码取绝对值)
    egx = np.where(cgx < 0, (~cgx) + 1, cgx) & 0xFFF
    egy = np.where(cgy < 0, (~cgy) + 1, cgy) & 0xFFF
    i_hor = egx >= egy
    i_a = np.where(i_hor, egy, egx)          # min
    i_b = np.where(i_hor, egx, egy)          # max
    i_a15 = (i_a * 15) & 0x3FFF              # wire [13:0] i_a15
    # wire [13:0] i_bk[1:15] = i_b*k;  i_ge[k] = (i_a15 >= i_bk[k])
    w_raw = np.zeros_like(i_b)
    for k in range(1, 16):
        w_raw = w_raw + ((i_a15 >= ((i_b * k) & 0x3FFF))).astype(np.int64)
    cc_w = np.where(i_b == 0, 0, w_raw) & 0xF
    cc_sgx = cgx < 0
    cc_str = (cgy < 0) | ((cgy == 0) & cc_sgx)
    cc_hor = i_hor

    # ---- 窗口中心词解码后做插值比较(与 RTL 的组合逻辑逐句对应) ----
    p_m = np.where(cc_hor, np.where(cc_sgx, m3, m5),
                   np.where(cc_str, m1, m7))
    p_d = np.where(cc_sgx, np.where(cc_str, m0, m6),
                   np.where(cc_str, m2, m8))
    q_m = np.where(cc_hor, np.where(cc_sgx, m5, m3),
                   np.where(cc_str, m7, m1))
    q_d = np.where(cc_sgx, np.where(cc_str, m8, m2),
                   np.where(cc_str, m6, m0))

    wgt_d = cc_w
    wgt_m = 15 - cc_w
    lp = (wgt_m * p_m + wgt_d * p_d) & 0x7FFF
    lq = (wgt_m * q_m + wgt_d * q_d) & 0x7FFF
    # wire [11:0] me = {1'b0,m4} + eps;  wire [14:0] me15 = {3'b0,me};
    # wire [14:0] cent = (me15 << 4) - me15;   (15bit 自决定宽度, 无截位)
    me = (m4 + int(eps)) & 0xFFF
    me15 = me & 0x7FFF
    cent = ((me15 << 4) - me15) & 0x7FFF
    l_strict = np.where(cc_str, lp, lq)
    l_loose = np.where(cc_str, lq, lp)
    keep = (cent > l_strict) & (cent >= l_loose)
    return np.clip(np.where(keep, m4, 0), 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# 2) 合成图与指标
# ---------------------------------------------------------------------------
def _blur1d(a, k, axis):
    """沿 axis 做 1D 卷积, 边界按 edge 复制(而不是 np.convolve 的补 0) --
    否则图像四边会凭空多出一圈假边缘, 把指标污染掉。"""
    pad = len(k) // 2
    if axis == 0:
        ap = np.pad(a, ((pad, pad), (0, 0)), mode="edge")
    else:
        ap = np.pad(a, ((0, 0), (pad, pad)), mode="edge")
    return np.apply_along_axis(lambda v: np.convolve(v, k, mode="valid"), axis, ap)


def make_slant(theta_deg, size=256, noise=2.0, seed=1):
    """合成一条倾角 theta(相对竖直线) 的直线阶跃边缘: 返回 (gray, 每行真实边缘 x)。"""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    cy = (size - 1) / 2.0
    t = np.tan(np.deg2rad(theta_deg))
    x_line = 0.5 * size + t * (yy - cy)
    gray = np.where(xx > x_line, 235.0, 20.0)
    gray = gray + rng.normal(0.0, noise, gray.shape)
    # 5x5 整数高斯 [1 4 6 4 1]/16 可分离, 与实际链路同量级
    k = np.array([1, 4, 6, 4, 1], dtype=np.float64) / 16.0
    gray = _blur1d(_blur1d(gray, k, 0), k, 1)
    return np.clip(gray, 0, 255).astype(np.uint8), x_line[:, 0]


def measure(edge, x_line, thr=25, band=6):
    """edge: 8bit NMS 输出; thr 取在噪底之上、边缘脊之内(合成图阶跃 215 灰阶,
    脊峰被截到 255, 0.6 灰阶的残余噪声经 Sobel 后 <20)。

    只统计真边 ±band 像素内的保留点(带外保留点单独算成"带外误检率")。

    返回 (平均线宽, 断续率, 抖动率, 带外误检率, 平均|位置误差|)

    抖动率用"误差序列相邻行的跳变"衡量(|Δ(pos-真值)| > 1px), 而不是直接用
    Δpos —— 否则斜线本身的斜率(tan θ)会被算成抖动。
    """
    e = edge >= thr
    h, w = e.shape
    xs_all = e.sum()
    pos = np.full(h, np.nan)
    width = np.zeros(h)
    in_band = 0
    for y in range(h):
        a = int(max(0, x_line[y] - band))
        b = int(min(w, x_line[y] + band + 1))
        xs = np.nonzero(e[y, a:b])[0]
        in_band += int(xs.size)
        if xs.size:
            pos[y] = a + xs.mean()
            width[y] = xs.size
    fp_rate = 0.0 if xs_all == 0 else float(1.0 - in_band / float(xs_all))
    rows = np.isfinite(pos)
    if rows.sum() < 4:
        return 0.0, 1.0, 1.0, fp_rate, 0.0
    avg_w = float(width[rows].mean())
    gap_rate = float(1.0 - rows.mean())
    e = pos[rows] - x_line[rows]
    jitter = float((np.abs(np.diff(e)) > 1.0).mean())
    return avg_w, gap_rate, jitter, fp_rate, float(np.abs(e).mean())


def run_case(theta, noise, seed=1):
    size = 256
    gray, x_line = make_slant(theta, noise=noise, seed=seed, size=size)
    gx, gy, mag = sobel_full(gray)
    dirs = dir_class(gx, gy)
    e_ref = nms_rtl(mag, dirs)
    e_new = nms_interp_rtl(mag, gx, gy)
    if theta <= 45:
        return measure(e_ref, x_line), measure(e_new, x_line)
    # 陡角(>45°, 线更接近水平) 按"每列"统计: 转置后同一套指标仍然成立
    cy = (size - 1) / 2.0
    xs = np.arange(size, dtype=np.float64)
    y_line = cy + (xs - 0.5 * size) / np.tan(np.deg2rad(theta))
    return measure(e_ref.T, y_line), measure(e_new.T, y_line)


def main():
    print("=" * 92)
    print("[1] 退化性质: 方向正好落在四根轴上(min(|gx|,|gy|)=0 或 |gx|=|gy|)时,")
    print("    插值版必须与 4 方向量化版逐位一致")
    print("=" * 92)
    rng = np.random.default_rng(7)
    z = np.zeros((64, 64), dtype=np.int64)
    rp = rng.integers(1, 900, (64, 64)).astype(np.int64)
    rn = -rng.integers(1, 900, (64, 64)).astype(np.int64)
    rg = rng.integers(-900, 900, (64, 64)).astype(np.int64)
    cases = [
        ("gy=0 (dir 0)", rg, z),
        ("gx=0 (dir 90)", z, rg),
        ("gx=gy>0 (dir 45)", rp, rp.copy()),
        ("gx=gy<0 (dir 45)", rn, rn.copy()),
        ("gx=-gy (dir 135)", rp, -rp.copy()),
        ("gx=-gy (dir 135)", rn, -rn.copy()),
    ]
    ok = True
    for name, gx, gy in cases:
        mag = (np.abs(gx) + np.abs(gy)).astype(np.int32)
        a = nms_rtl(mag, dir_class(gx, gy))
        b = nms_interp_rtl(mag, gx, gy)
        same = bool(np.array_equal(a, b))
        ok = ok and same
        print("  %-18s -> %s" % (name, "逐位一致 OK" if same else "不一致 !!"))
    print("  结论: %s" % ("四条轴全部退化 OK" if ok else "存在不一致, RTL 需要改"))

    print()
    print("=" * 92)
    print("[2] 效果对比   ref = 4 方向量化    new = 亚像素插值   (滞回 LO/HI = 5/20, 噪声 sigma=2)")
    print("=" * 92)
    print("  倾角 |   ref 线宽 断续% 抖动% 带外% 位置误差 |   new 线宽 断续% 抖动% 带外% 位置误差")
    print("  " + "-" * 88)
    for theta in (15, 20, 25, 30, 35, 40, 45, 50, 65, 70, 75):
        (w0, g0, j0, m0, e0), (w1, g1, j1, m1, e1) = run_case(theta, 2.0)
        print("  %4d |  %6.2f %5.1f %5.1f %5.1f %8.3f |  %6.2f %5.1f %5.1f %5.1f %8.3f"
              % (theta, w0, g0 * 100, j0 * 100, m0 * 100, e0,
                 w1, g1 * 100, j1 * 100, m1 * 100, e1))
    print("  说明: 倾角=22.5/67.5 是方向量化的归轴边界, 4 方向版在这里最差;")
    print("        45 度两版本应当完全一样(a=b 的退化情形), 可当自检。")

    print()
    print("=" * 92)
    print("[3] RTL 转录对拍: rtl_shape_nms_interp(照抄 alg_nms.v 的 16 档权重版) vs 金标准 nms_interp_rtl")
    print("=" * 92)
    ok3 = True
    rng = np.random.default_rng(11)
    for trial in range(6):
        gx = rng.integers(-1020, 1021, (48, 48)).astype(np.int64)
        gy = rng.integers(-1020, 1021, (48, 48)).astype(np.int64)
        mag = (np.abs(gx) + np.abs(gy)).astype(np.int32)
        for eps in (0, 3):
            a = rtl_shape_nms_interp(mag, gx, gy, eps)
            b = nms_interp_rtl(mag, gx, gy, eps)
            same = bool(np.array_equal(a, b))
            ok3 = ok3 and same
            if not same:
                bad = np.nonzero(a != b)
                print("  第 %d 组 eps=%d -> 不一致 %d 个像素, 例: (y=%d, x=%d) rtl=%d std=%d gx=%d gy=%d mag=%d"
                      % (trial, eps, int((a != b).sum()), bad[0][0], bad[1][0],
                         a[bad][0], b[bad][0], gx[bad][0, 0], gy[bad][0, 0], mag[bad][0, 0]))
    print("  结论: %s" % ("6 组 x 2 档 eps 全部逐位一致 OK" if ok3 else "存在不一致!"))


if __name__ == "__main__":
    main()
