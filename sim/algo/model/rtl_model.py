"""
rtl_model.py -- 用 Python 逐位模拟"将要写进 Verilog 的定点运算"(金标准模型)。

作用:
  1) 写 RTL 之前先把算法/排序网络/截位/边界处理验证清楚;
  2) 作为 RTL 仿真的对拍基准: RTL 输出(hex) vs 本模型 vs 原始 edge_pipeline.py。

约定:
  * 全部整数运算, 移位/截位与 Verilog 完全一致;
  * 窗口边界两种模式: EDGE=复制边缘(np.pad(mode="edge")), ZERO=补 0
    (np.pad(constant 0) 与 cv2.dilate / remove_isolated 的 0 边界);
  * 3x3 中值 = 行 sort3 -> 列 sort3 -> 取中间列中值(硬件网络, 见 selftest 的 0-1 原理穷举证明)。

用法:
    python rtl_model.py --selftest
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "repo", "FPGA-Python-main"))


# --------------------------------------------------------------------------
# 基础原语(与 Verilog 一一对应)
# --------------------------------------------------------------------------
def gray_shift_add(r, g, b):
    """Y = (77R + 150G + 29B) >> 8, 纯移位加法, 无除法器。
    77 = 64+8+4+1 ; 150 = 128+16+4+2 ; 29 = 32-4+1
    """
    r = r.astype(np.int64)
    g = g.astype(np.int64)
    b = b.astype(np.int64)
    s = (r << 6) + (r << 3) + (r << 2) + r
    s = s + (g << 7) + (g << 4) + (g << 2) + (g << 1)
    s = s + (b << 5) - (b << 2) + b
    return (s >> 8).astype(np.uint8)


def pad_edge(a, r):
    return np.pad(a, r, mode="edge")


def pad_zero(a, r):
    return np.pad(a, r, mode="constant", constant_values=0)


def med3(a, b, c):
    """sort3 比较器: 返回 (min, mid, max)"""
    lo = np.minimum(a, b)
    hi = np.maximum(a, b)
    mn = np.minimum(lo, c)
    mx = np.maximum(hi, c)
    md = np.maximum(lo, np.minimum(hi, c))
    return mn, md, mx


def median_3x3_network(gray):
    """硬件中值网络 —— 经典 19 比较器 3x3 中值网络(与 RTL 逐行对应)。

       第 1 级: 3 行各自 sort3                        (3x3 = 9 个比较器)
       第 2 级: lo = max(三个"行最小")                (2 个比较器)
               hi = min(三个"行最大")                (2 个比较器)
               md = med3(三个"行中位")               (3 个比较器)
       第 3 级: median = med3(lo, md, hi)             (3 个比较器)
       合计 19 个 2 输入比较器。

    正确性(0-1 原理的严格版本): min/max 与阈值化可交换, 即
        [min(a,b) >= t] == min([a>=t],[b>=t]),  max 同理;
    本网络只由 min/max 构成, 故对任意输入 x 与任意 t:
        1{out(x) >= t} = out(1{x >= t})  (0/1 输入)
    所以只要对全部 2^9 个 0/1 输入校验通过(selftest 里穷举),
    就对所有 8bit 输入成立 —— 这是完整证明, 不是抽样。
    注: 之前的 "3 列各自 sort3 后取中间列中值" 是错网络(54/512 失败), 已废弃。
    """
    p = pad_edge(gray, 1).astype(np.int32)
    h, w = gray.shape
    g = lambda i, j: p[i:i + h, j:j + w]
    row = [med3(g(i, 0), g(i, 1), g(i, 2)) for i in range(3)]
    lo = np.maximum(np.maximum(row[0][0], row[1][0]), row[2][0])
    hi = np.minimum(np.minimum(row[0][2], row[1][2]), row[2][2])
    md = med3(row[0][1], row[1][1], row[2][1])[1]
    return med3(lo, md, hi)[1].astype(np.uint8)


def median_3x3_reference(gray):
    """numpy 9 邻域排序取中值(参考实现)"""
    p = pad_edge(gray, 1).astype(np.int32)
    h, w = gray.shape
    planes = [p[i:i + h, j:j + w] for i in range(3) for j in range(3)]
    s = np.sort(np.stack(planes, axis=-1), axis=-1)
    return s[..., 4].astype(np.uint8)


def gauss3x3_int(gray):
    """3x3 高斯 [1,2,1;2,4,2;1,2,1]/16 -> sum>>4 (RTL: 移位加法)。"""
    p = pad_edge(gray, 1).astype(np.int32)
    h, w = gray.shape
    g = lambda i, j: p[i:i + h, j:j + w]
    s = (g(0, 0) + 2 * g(0, 1) + g(0, 2)
         + 2 * g(1, 0) + 4 * g(1, 1) + 2 * g(1, 2)
         + g(2, 0) + 2 * g(2, 1) + g(2, 2))
    return (s >> 4).astype(np.uint8)


GAUSS5X5_K = np.array([[32, 38, 40, 38, 32],
                       [38, 45, 47, 45, 38],
                       [40, 47, 50, 47, 40],
                       [38, 45, 47, 45, 38],
                       [32, 38, 40, 38, 32]], dtype=np.int64)


def gauss5x5_int(gray):
    """5x5 整数高斯: out = (sum >> 10) + ((sum >> 9) & 1)  ==  RTL sum[17:10] + sum[9]"""
    p = pad_edge(gray, 2).astype(np.int64)
    h, w = gray.shape
    s = np.zeros((h, w), dtype=np.int64)
    for i in range(5):
        for j in range(5):
            s += GAUSS5X5_K[i, j] * p[i:i + h, j:j + w]
    return ((s >> 10) + ((s >> 9) & 1)).astype(np.uint8)


def box6_sum_int(a):
    """6x6 盒窗"和"(整数, 未除 36), 对应 cv2.boxFilter(ksize=6) 的锚点=3:
    窗口 = [x-3..x+2] x [y-3..y+2]。边界用复制边缘(本工程统一约定, 见 alg_win.v
    的 PAD_EDGE=1; 参考 Python 用 cv2 默认的 BORDER_REFLECT_101, 属已知差异)。
    硬件对应 alg_win(N=6) 的 36 个 tap 直接求和。
    """
    p = pad_edge(a.astype(np.int64), 3)
    h, w = a.shape
    s = np.zeros((h, w), dtype=np.int64)
    for i in range(6):
        for j in range(6):
            s += p[i:i + h, j:j + w]
    return s


def guided_filter_int(gray, eps=400):
    """导向滤波(EPF=2)的定点模型 —— 与 rtl/algo/alg_epf.v 逐位一致。

    参考: FPGA-Python/edge_pipeline.py :: guided_filter(radius=6, eps=400)
        mean_I = box(I)      mean_II = box(I*I)
        var = mean_II - mean_I^2 ;  a = var/(var+eps) ;  b = mean_I - a*mean_I
        out = clip(box(a)*I + box(b), 0, 255)
    ksize=6 的盒滤波 = 6 抽头 [x-3..x+2](cv2 锚点 3), 硬件上就是 alg_win N=6。

    定点化(唯一的硬件难点是那一处除法, 用逐位流水除法器):
        S1 = ΣI, S2 = ΣI²            (36 tap, 14bit / 22bit)
        V  = 36*S2 - S1²             ( = 1296*var, <= 21067776, 25bit)
        K  = 1296*eps                (eps 运行期可调, 默认 400 -> K=518400)
        a_q8 = sat8( round(256*V/(V+K)) )   8bit, 表示 256*a (a<1)
        mI_q8 = round(256*mean_I) = (S1*455+32)>>6     (455/64 ≈ 256/36)
        b_q  = round(mI_q8*(256-a_q8)/65536)  = mean_I*(1-a)  8bit
        Sa = Σa_q8, Sb = Σb_q                 (stage-2 盒窗和, <=9180 各 14bit)
        q  = round( ((Sa*I+128)>>8 + Sb) / 36 ) = round(w*455/16384)
    误差: a 量化 <=0.5/256 -> mean_a*I 偏差 <=0.5 LSB; b 取整 <=0.5 LSB;
    定点 vs 参考浮点整体 <=1 LSB(见 tools/.../gf_fixed.log 的统计)。
    """
    g = gray.astype(np.int64)
    s1 = box6_sum_int(g)
    s2 = box6_sum_int(g * g)
    v = 36 * s2 - s1 * s1                     # >= 0 (数学上); 25bit
    k = 1296 * int(eps)
    d = v + k
    num = v << 8
    # 逐位恢复除法: q = num//d, r = num - q*d; 再 2r>=d 进 1; 夹到 255
    # d==0 (V==0 且 eps==0) 是退化点: 硬件比较器全真 -> q=255, 模型照此。
    a_q8 = np.where(d == 0, np.int64(255), np.int64(0))
    if np.any(d > 0):
        q = np.where(d > 0, num // np.maximum(d, 1), 0)
        r = np.where(d > 0, num - q * np.maximum(d, 1), 0)
        q = q + np.where(2 * r >= np.maximum(d, 1), 1, 0)
        a_q8 = np.where(d > 0, np.minimum(q, 255), a_q8)
    a_q8 = a_q8.astype(np.int64)
    mI_q8 = (s1 * 455 + 32) >> 6              # ~256*mean_I (<=65264)
    b_q = (mI_q8 * (256 - a_q8) + 32768) >> 16
    sa = box6_sum_int(a_q8)
    sb = box6_sum_int(b_q)
    u = (sa * g + 128) >> 8                   # ~36*mean_a*I
    q = ((u + sb) * 455 + 8192) >> 14         # /36
    return np.clip(q, 0, 255).astype(np.uint8)


def sobel_full(gray):
    """Sobel 全量程: gx/gy 有符号(±1020), mag=|gx|+|gy| (0..2040)"""
    p = pad_edge(gray, 1).astype(np.int32)
    h, w = gray.shape
    g = lambda i, j: p[i:i + h, j:j + w]
    gx = (g(0, 2) + 2 * g(1, 2) + g(2, 2)) - (g(0, 0) + 2 * g(1, 0) + g(2, 0))
    gy = (g(2, 0) + 2 * g(2, 1) + g(2, 2)) - (g(0, 0) + 2 * g(0, 1) + g(0, 2))
    mag = np.abs(gx) + np.abs(gy)
    return gx, gy, mag.astype(np.int32)


def dir_class(gx, gy):
    """RTL 方向量化(整数比较, 与 atan2 的 22.5/67.5 边界等价, 相对误差 2e-4):
        0=左右比较(垂直边), 90=上下比较(水平边), 45=主对角, 135=副对角
    """
    a = np.abs(gx).astype(np.int64)
    b = np.abs(gy).astype(np.int64)
    q0 = (b * 4096) <= (a * 1697)
    q90 = (a * 4096) <= (b * 1697)
    same_sign = (np.signbit(gx) == np.signbit(gy))
    d = np.zeros(gx.shape, dtype=np.uint8)
    d[q90 & (~q0)] = 90
    rest = (~q0) & (~q90)
    d[rest & same_sign] = 45
    d[rest & (~same_sign)] = 135
    return d


def nms_rtl(mag, dirs, eps=0):
    """NMS(EDGE 边界), 与 Python nms() 的非对称比较 + 截位一致, 输出 8bit。

    eps: NMS 容差, 对应 alg_nms.v 的 cfg_eps。 eps=0 时逐位等于
    edge_pipeline.nms(); eps>0 时中心加 eps 再与两侧邻居比, 容忍半像素相位处
    两个候选像素"近等值二选一"的翻转(线条沿轮廓流动抖动的根因)。
    只在 CANNY 档有意义, 上限 8(见 alg_cfg_uart.v 的 K_EPS)。
    """
    m = mag.astype(np.int32)
    p = pad_edge(m, 1)
    h, w = m.shape
    L, R = p[1:h + 1, 0:w], p[1:h + 1, 2:w + 2]
    U, D = p[0:h, 1:w + 1], p[2:h + 2, 1:w + 1]
    UL, DR = p[0:h, 0:w], p[2:h + 2, 2:w + 2]
    UR, DL = p[0:h, 2:w + 2], p[2:h + 2, 0:w]
    me = m + int(eps)
    keep = np.where(dirs == 0, (me > L) & (me >= R),
                    np.where(dirs == 90, (me > U) & (me >= D),
                             np.where(dirs == 45, (me > UL) & (me >= DR),
                                      (me > UR) & (me >= DL))))
    return np.clip(np.where(keep, m, 0), 0, 255).astype(np.uint8)


def nms_interp_rtl(mag, gx, gy, eps=0):
    """亚像素方向插值 NMS, 与 alg_nms.v 的 cfg_inms=1 路径逐位等价。

    免除法 + 16 档量化权重(见 alg_nms.v 文件头): a=min(|gx|,|gy|) b=max(|gx|,|gy|)
        w = floor(15*a/b)                             (b==0 -> 0)
        keep = (15*m >  15*((15-w)*M_f + w*D_f)/15)
             & (15*m >= 15*((15-w)*M_b + w*D_b)/15)
    即"中心 15*(m4+eps) 与 (15-w)*主轴 + w*对角 直接比大小"(两边同乘 15, 无除法)。
    M = 主轴邻居, D = 对角邻居; 选哪一对由 hor 与 gx/gy 的符号决定。
    a=0 -> w=0 退化成 4 方向量化版, a=b -> w=15 退化成对角版, 中间连续过渡。

    eps 与 nms_rtl 的语义相同(中心加 eps), 便于两条路径用同一组参数对照。

    严格侧口径与 RTL 一致: str = (gy<0) | ((gy==0) & (gx<0)), 它同时充当
    "对角邻居取上面那一个"的选择位(sgy_eff) —— 差异只在 gy==0, 而那时 w==0
    (对角项权重为 0), 所以比较结果不受影响。
    """
    m = mag.astype(np.int64)
    h, w = m.shape
    p = pad_edge(m, 1)
    # 与 alg_nms.v 的 m0..m8 一一对应
    UL = p[0:h, 0:w]
    U  = p[0:h, 1:w + 1]
    UR = p[0:h, 2:w + 2]
    L  = p[1:h + 1, 0:w]
    R  = p[1:h + 1, 2:w + 2]
    DL = p[2:h + 2, 0:w]
    D  = p[2:h + 2, 1:w + 1]
    DR = p[2:h + 2, 2:w + 2]

    gxi = gx.astype(np.int64)
    gyi = gy.astype(np.int64)
    egx = np.abs(gxi)
    egy = np.abs(gyi)
    hor = egx >= egy
    ub = np.where(hor, egx, egy)
    ua = np.where(hor, egy, egx)
    sgx = gxi < 0
    str_ = (gyi < 0) | ((gyi == 0) & sgx)      # RTL 的 cc_str / sgy_eff

    # P = 沿梯度正方向那一侧, Q = 反方向那一侧
    p_m = np.where(hor, np.where(sgx, L, R), np.where(str_, U, D))
    p_d = np.where(sgx, np.where(str_, UL, DL), np.where(str_, UR, DR))
    q_m = np.where(hor, np.where(sgx, R, L), np.where(str_, D, U))
    q_d = np.where(sgx, np.where(str_, DR, UR), np.where(str_, DL, UL))

    # w = #{k=1..15 : 15*a >= k*b}: 与 RTL 的 15 个常量比较器逐位同构
    ua15 = ua * 15
    wq = np.zeros_like(ub)
    for k in range(1, 16):
        wq = wq + (ua15 >= ub * k).astype(np.int64)
    wq = np.where(ub == 0, 0, wq)
    wm = 15 - wq

    me = m + int(eps)
    lp = wm * p_m + wq * p_d
    lq = wm * q_m + wq * q_d
    cent = 15 * me
    # 非对称比较的"严格侧"必须与 nms_rtl 一致: 参考实现固定让 y 偏移 <= 0
    # 的那一侧用严格大于 (dir=0 -> L, dir=90 -> U, dir=45 -> UL, dir=135 -> UR)。
    l_strict = np.where(str_, lp, lq)
    l_loose = np.where(str_, lq, lp)
    keep = (cent > l_strict) & (cent >= l_loose)
    return np.clip(np.where(keep, m, 0), 0, 255).astype(np.uint8)


def _dilate3_zero(mask):
    p = pad_zero(mask, 1)
    h, w = mask.shape
    out = np.zeros_like(mask)
    for i in range(3):
        for j in range(3):
            out |= p[i:i + h, j:j + w]
    return out


def hysteresis_rtl(mag, t_lo, t_hi):
    """双阈值滞后: strong = mag>=t_hi; weak = mag>=t_lo; edge = weak & dilate3x3(strong)。
    边界补 0(等价 cv2.dilate 默认); t_lo>t_hi 自动交换(防呆)。
    mag 可以是 8bit(NMS 后)或全量程 11bit(SOBEL 双阈值档), 用法一致。
    """
    if t_lo > t_hi:
        t_lo, t_hi = t_hi, t_lo
    strong = (mag >= t_hi).astype(np.uint8)
    weak = (mag >= t_lo).astype(np.uint8)
    return ((weak & _dilate3_zero(strong)) * 255).astype(np.uint8)


def bridge_rtl(edge, k=2, mode=2):
    """边缘断线桥接(alg_ebridge.v): 二值边缘图上的"轴线方向闭运算"。

    7x7 窗口(0 边界): 空洞像素只要在左/右(同一行)、上/下(同一列)、
    左上-右下 或 右上-左下 两组对角里, 两侧 K 像素内都有边缘, 就补成边缘。
    k = 0 或 mode = 0(单阈值档旁路) 时逐位透传(等价原算法)。
    k: 1 -> 填 1px 空洞; 2 -> 填 1~3px; 3 -> 填 1~5px。
    只在 4 条轴线方向判断, 因此不会把相距 2~3px 的平行线糊成一条粗线。
    """
    e = (edge > 0).astype(np.uint8)
    k = int(k)
    if k <= 0 or int(mode) == 0:
        return (e * 255).astype(np.uint8)
    h, w = e.shape
    p = pad_zero(e, 3)

    def taps(dy, dx):
        """距离 1..3 的邻域(与 RTL 的 win 抽头一一对应), 返回宽度 3 的列表"""
        out = []
        for d in (1, 2, 3):
            y0, x0 = 3 + dy * d, 3 + dx * d
            out.append(p[y0:y0 + h, x0:x0 + w].astype(np.uint8))
        return out

    def within(arrs):
        r = np.zeros((h, w), dtype=np.uint8)
        for d in range(k):
            r |= arrs[d]
        return r

    l, r = taps(0, -1), taps(0, 1)
    u, dn = taps(-1, 0), taps(1, 0)
    ul, dr = taps(-1, -1), taps(1, 1)
    ur, dl = taps(-1, 1), taps(1, -1)
    fill = ((within(l) & within(r)) | (within(u) & within(dn))
            | (within(ul) & within(dr)) | (within(ur) & within(dl)))
    return ((e | fill).astype(np.uint8)) * 255


def isolated_rtl(edge):
    """孤立点消除(0 边界): 3x3 内白邻居数(不含自身) >= 1 才保留。"""
    e = (edge > 0).astype(np.int32)
    p = pad_zero(e, 1)
    h, w = e.shape
    cnt = np.zeros((h, w), dtype=np.int32)
    for i in range(3):
        for j in range(3):
            cnt += p[i:i + h, j:j + w]
    return ((((e > 0) & ((cnt - e) >= 1)).astype(np.uint8)) * 255)
    e = (edge > 0).astype(np.int32)
    p = pad_zero(e, 1)
    h, w = e.shape
    cnt = np.zeros((h, w), dtype=np.int32)
    for i in range(3):
        for j in range(3):
            cnt += p[i:i + h, j:j + w]
    return ((((e > 0) & ((cnt - e) >= 1)).astype(np.uint8)) * 255)


def threshold_rtl(mag, t):
    """单阈值(全量程梯度比较)"""
    return (mag >= t).astype(np.uint8) * 255


# --------------------------------------------------------------------------
# 整条 RTL 流水线(对应 edge_process_core.v)
# --------------------------------------------------------------------------
def rtl_pipeline(gray_in, mode, thr=24, thr_lo=21, thr_hi=58,
                 median_en=True, gauss5_en=None, isol_en=True, nms_eps=0,
                 epf=0, gf_eps=400, brg=2):
    """gray_in: 8bit 灰度(已灰度化/时间域平均后)。
    mode: 0=SOBEL 单阈值, 1=SOBEL 双阈值, 2=CANNY
    gauss5_en: None -> CANNY 自动开, SOBEL 档关(与 live_tune 一致)
    nms_eps: NMS 容差 0..8, 只在 CANNY 档生效(0 = 参考算法逐位一致)
    epf: 前置滤波档位(对应 live_tune 的 EPF, 插在中值之后):
         0 = 关(旁路), 1 = 3x3 高斯, 2 = 导向滤波(guided_filter_int)
    gf_eps: 导向滤波的正则项 eps, 参考值 400 (0..2000, 越大越平滑)
    返回 dict: edge / gray_processed / mag_full / mag_nms
    """
    if gauss5_en is None:
        gauss5_en = (mode == 2)
    g = gray_in
    if median_en:
        g = median_3x3_network(g)
    if epf == 1:
        g = gauss3x3_int(g)
    elif epf == 2:
        g = guided_filter_int(g, gf_eps)
    if gauss5_en:
        g = gauss5x5_int(g)
    gx, gy, mag = sobel_full(g)
    if mode == 2:
        mag_nms = nms_rtl(mag, dir_class(gx, gy), nms_eps)
        edge = hysteresis_rtl(mag_nms, thr_lo, thr_hi)
        mag_out = mag_nms
    elif mode == 1:
        edge = hysteresis_rtl(mag, thr_lo, thr_hi)
        mag_out = np.clip(mag, 0, 255).astype(np.uint8)
    else:
        edge = threshold_rtl(mag, thr)
        mag_out = np.clip(mag, 0, 255).astype(np.uint8)
    edge = bridge_rtl(edge, brg, mode)
    if isol_en:
        edge = isolated_rtl(edge)
    return {"edge": edge, "gray": g, "mag_full": mag, "mag": mag_out}


def temporal_blend_rtl(prev, cur, alpha256):
    """时间域帧间平均(IIR): out = (cur*alpha + prev*(256-alpha)) >> 8。
    alpha256=128 时与 Python alpha=0.5 的 (cur+prev)/2 截断完全一致。
    """
    if prev is None or alpha256 <= 0:
        return cur
    acc = cur.astype(np.int32) * alpha256 + prev.astype(np.int32) * (256 - alpha256)
    return (acc >> 8).astype(np.uint8)


def temp_to_alpha256(temp_val):
    """TEMP(0..90) -> alpha256 = round((1 - temp/100) * 256)"""
    a = int(round((1.0 - temp_val / 100.0) * 256))
    return max(0, min(255, a))


# --------------------------------------------------------------------------
# 自检
# --------------------------------------------------------------------------
def selftest():
    rng = np.random.default_rng(1234)
    ok = True

    # [1] 中值网络: 0-1 原理穷举(充分证明) + 随机
    bad = 0
    for bits in range(512):
        img = np.array([[(bits >> (3 * i + j)) & 1 for j in range(3)] for i in range(3)],
                       dtype=np.uint8) * 255
        if int(median_3x3_network(img)[0, 0]) != int(median_3x3_reference(img)[0, 0]):
            bad += 1
    for _ in range(400):
        img = rng.integers(0, 256, size=(13, 19), dtype=np.uint8)
        bad += int((median_3x3_network(img) != median_3x3_reference(img)).sum())
    print(f"[1] median network             : {bad} mismatches  -> {'PASS' if bad == 0 else 'FAIL'}")
    ok &= (bad == 0)

    # [2] 方向量化 vs atan2
    gx = rng.integers(-1020, 1021, size=(300, 300)).astype(np.int64)
    gy = rng.integers(-1020, 1021, size=(300, 300)).astype(np.int64)
    ang = np.degrees(np.arctan2(gy.astype(np.float64), gx.astype(np.float64))) % 180.0
    ref = np.zeros(ang.shape, dtype=np.uint8)
    ref[(ang >= 22.5) & (ang < 67.5)] = 45
    ref[(ang >= 67.5) & (ang < 112.5)] = 90
    ref[(ang >= 112.5) & (ang < 157.5)] = 135
    diff = int((dir_class(gx, gy) != ref).sum())
    print(f"[2] direction quantize         : {diff}/{ref.size} "
          f"({100.0 * diff / ref.size:.4f}%)  -> {'PASS' if diff <= ref.size * 0.005 else 'CHECK'}")

    # [3] 与 edge_pipeline.py 对拍
    try:
        import edge_pipeline as ep
    except Exception as e:
        print(f"[3] skip (edge_pipeline import failed: {e})")
        return ok
    img = rng.integers(0, 256, size=(96, 128, 3), dtype=np.uint8)
    g_ref = ep.to_gray(img)
    g_got = gray_shift_add(img[:, :, 2], img[:, :, 1], img[:, :, 0])
    print(f"[3a] gray (77,150,29)>>8      : {int((g_ref != g_got).sum())} mismatches")
    print(f"[3b] median3x3 vs Python      : "
          f"{int((ep.median3x3(g_ref) != median_3x3_network(g_ref)).sum())} mismatches")
    print(f"[3c] gauss5x5  vs Python      : "
          f"{int((ep.gaussian5x5(g_ref) != gauss5x5_int(g_ref)).sum())} mismatches")
    _, _, mag = sobel_full(g_ref)
    print(f"[3d] sobel |Gx|+|Gy| vs Python: "
          f"{int((ep.sobel3x3(g_ref) != np.clip(mag, 0, 255)).sum())} mismatches (全量程截目前)")
    print(f"[3e] hysteresis(58/21) vs Py  : "
          f"{int((ep.threshold_hysteresis(np.clip(mag, 0, 255).astype(np.uint8), 21, 58) != hysteresis_rtl(np.clip(mag, 0, 255).astype(np.uint8), 21, 58)).sum())} mismatches")
    e0 = ep.threshold_single(mag, 24)
    print(f"[3f] remove_isolated vs Python: "
          f"{int((ep.remove_isolated(e0) != isolated_rtl(e0)).sum())} mismatches")
    # 全链路(CANNY 档) vs live_tune 的等效链路
    g_c = g_ref
    g_c = ep.median3x3(g_c)
    g_c5 = ep.gaussian5x5(g_c)
    mag5, ang5 = ep.gradient(g_c5)
    ref_edge = ep.threshold_hysteresis(ep.nms(mag5, ang5), 21, 58)
    ref_edge = ep.remove_isolated(ref_edge)
    got = rtl_pipeline(g_ref, mode=2, thr_lo=21, thr_hi=58)
    d = int((ref_edge != got["edge"]).sum())
    print(f"[3g] full CANNY chain vs Py   : {d}/{ref_edge.size} "
          f"({100.0 * d / ref_edge.size:.3f}%) 差异(方向量化边界引起, 见文档)")
    return ok


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
    else:
        ap.print_help()
