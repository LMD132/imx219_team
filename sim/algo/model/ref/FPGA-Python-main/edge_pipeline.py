"""
edge_pipeline.py — 与 FPGA(易灵思 Ti60F225 / 赛题4) 对应的整数图像处理流水线

镜像 RTL 处理顺序(与你们板上 overlay_box 位流一致):
    RGB -> 灰度化 -> (椒盐噪声模拟, 仅调参用) -> (3x3 中值滤波, 可选)
        -> (3x3 高斯 [1,2,1]^2/16, 可选) -> 3x3 Sobel(|Gx|+|Gy|)
        -> 阈值(单阈值 / Canny 式双阈值滞后) -> 分屏显示(左灰度 + 右边缘 + 红框)

全部使用整数运算并显式截位, 尽量贴近 Verilog 的移位实现, 便于把参数直接迁移到 RTL。
"""

import numpy as np
import cv2


def to_gray(bgr):
    """RGB 转灰度, 整数系数 (77,150,29)>>8, 与 RTL 常用系数一致。"""
    b = bgr[:, :, 0].astype(np.int32)
    g = bgr[:, :, 1].astype(np.int32)
    r = bgr[:, :, 2].astype(np.int32)
    y = (77 * r + 150 * g + 29 * b) >> 8
    return np.clip(y, 0, 255).astype(np.uint8)


def median3x3(gray):
    """3x3 中值滤波: 取 9 邻域中值。功能等价于 RTL 的 3x3 排序网络。"""
    p = np.pad(gray, 1, mode="edge").astype(np.int32)
    planes = []
    for i in range(3):
        for j in range(3):
            planes.append(p[i:i + gray.shape[0], j:j + gray.shape[1]])
    s = np.stack(planes, axis=-1)  # H,W,9
    s.sort(axis=-1)
    return s[..., 4].astype(np.uint8)


def gaussian3x3(gray):
    """3x3 高斯低通, 整数核 [1,2,1]x[1,2,1]/16, 对应 RTL 两级 [1,2,1] 低通。
    注意: 高斯是"压白点但磨细节"的来源, 保留它是为了 A/B 对比。"""
    k = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]], dtype=np.float32) / 16.0
    out = cv2.filter2D(gray.astype(np.float32), cv2.CV_32F, k)
    return np.clip(out, 0, 255).astype(np.uint8)


def gaussian5x5(gray):
    """5x5 高斯, 整数核(参考 EricYXZ 同平台 RTL: [32,38,40,38,32;38,45,47,45,38;
    40,47,50,47,40;38,45,47,45,38;32,38,40,38,32], 总和1010, 右移10+四舍五入)。
    比 3x3 更稳: 梯度噪声更小 -> NMS 局部极大值判定不易帧间翻转 -> 线条少闪。"""
    k = np.array([[32, 38, 40, 38, 32],
                  [38, 45, 47, 45, 38],
                  [40, 47, 50, 47, 40],
                  [38, 45, 47, 45, 38],
                  [32, 38, 40, 38, 32]], dtype=np.int32)
    p = np.pad(gray, 2, mode="edge").astype(np.int32)
    h, w = gray.shape
    out = np.zeros((h, w), dtype=np.int32)
    for i in range(5):
        for j in range(5):
            out += k[i, j] * p[i:i + h, j:j + w]
    # 右移10带四舍五入 (等价 RTL 的 sum[17:10]+sum[9])
    out = (out >> 10) + ((out >> 9) & 1)
    return np.clip(out, 0, 255).astype(np.uint8)


def guided_filter(gray, radius=6, eps=400):
    """导向滤波(边缘保持滤波): 压平坦区噪声、不抹边缘。
    局部线性模型, 用盒滤波(Box Filter)实现 O(1)/像素; guide=自身。
    参数: radius=局部窗口半径(5~20), eps=正则化(100~1000, guide=src 时常用 1000 附近)。
    用于替代高斯做 Canny/Sobel 前置滤波, 理论上对"低对比软边"更友好;
    上板代价=盒滤波+线性回归(比固定核高斯重, 需行缓存, 工作量中等)。"""
    g = gray.astype(np.float32)
    k = (radius, radius)
    mean_I = cv2.boxFilter(g, cv2.CV_32F, k)
    mean_II = cv2.boxFilter(g * g, cv2.CV_32F, k)
    var_I = mean_II - mean_I * mean_I
    a = var_I / (var_I + eps)
    b = mean_I - a * mean_I
    mean_a = cv2.boxFilter(a, cv2.CV_32F, k)
    mean_b = cv2.boxFilter(b, cv2.CV_32F, k)
    return np.clip(mean_a * g + mean_b, 0, 255).astype(np.uint8)


def sobel3x3(gray):
    """3x3 Sobel, 输出 G=|Gx|+|Gy| (赛题4要求), 截位到 0..255。"""
    p = np.pad(gray, 1, mode="edge").astype(np.int32)
    a00, a01, a02 = p[0:-2, 0:-2], p[0:-2, 1:-1], p[0:-2, 2:]
    a10, a11, a12 = p[1:-1, 0:-2], p[1:-1, 1:-1], p[1:-1, 2:]
    a20, a21, a22 = p[2:, 0:-2], p[2:, 1:-1], p[2:, 2:]
    gx = (a02 + 2 * a12 + a22) - (a00 + 2 * a10 + a20)
    gy = (a20 + 2 * a21 + a22) - (a00 + 2 * a01 + a02)
    mag = np.abs(gx) + np.abs(gy)
    return np.clip(mag, 0, 255).astype(np.uint8)


def threshold_single(mag, t):
    """单阈值: 梯度 >= t 判为边缘(白)。阈值低=白点多闪, 高=细节丢。"""
    return (mag >= t).astype(np.uint8) * 255


def threshold_hysteresis(mag, t_lo, t_hi):
    """Canny 式双阈值滞后: 高阈值起强边, 低阈值续弱边(弱边邻域有强边才保留)。
    用于破解"低阈值闪白点 / 高阈值丢眼镜"的矛盾。
    防呆: 若 t_lo > t_hi(滑条调反), 自动交换, 避免逻辑退化成单高阈值。"""
    if t_lo > t_hi:
        t_lo, t_hi = t_hi, t_lo
    strong = (mag >= t_hi).astype(np.uint8)
    weak = (mag >= t_lo).astype(np.uint8)
    strong_d = cv2.dilate(strong, np.ones((3, 3), np.uint8))
    edge = (weak & strong_d).astype(np.uint8) * 255
    return edge


def add_salt_pepper(gray, amount=0.0, seed=None):
    """模拟传感器/传输椒盐噪声(帧间白点闪烁的来源之一)。amount=0 时原样返回。"""
    if amount <= 0:
        return gray
    rng = np.random.default_rng(seed)
    out = gray.copy()
    black = rng.random(gray.shape) < amount
    out[black] = 0
    white = rng.random(gray.shape) < amount
    out[white] = 255
    return out


def split_view(gray, edge, box=True, box_ratio=0.5, label=True, right=None, box_rect=None):
    """分屏: 左=灰度, 右=边缘(可传自定义右面板 right=BGR), 中间黄色分隔线, 可叠加红框。
    红框位置: 传 box_rect=(x0,y0,x1,y1) 则用该矩形(用于目标跟随);
    不传则固定在画面中心(对应板上 overlay_box 的固定红框)。"""
    h, w = gray.shape
    g3 = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    if right is None:
        e3 = cv2.cvtColor(edge, cv2.COLOR_GRAY2BGR)
    else:
        e3 = right
        if e3.shape[:2] != (h, w):
            e3 = cv2.resize(e3, (w, h))
    if box:
        if box_rect is not None:
            x0, y0, x1, y1 = box_rect
        else:
            half = int(min(h, w) * box_ratio / 2)
            cx, cy = w // 2, h // 2
            x0, y0, x1, y1 = cx - half, cy - half, cx + half, cy + half
        cv2.rectangle(g3, (x0, y0), (x1, y1), (0, 0, 255), 3)
        cv2.rectangle(e3, (x0, y0), (x1, y1), (0, 0, 255), 3)
    if label:
        cv2.putText(g3, "GRAY", (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 1)
        cv2.putText(e3, "EDGE", (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 1)
    sep = np.full((h, 2, 3), (0, 255, 255), np.uint8)
    return np.hstack([g3, sep, e3])


def run_pipeline(bgr, t=24, t_lo=16, t_hi=40, use_median=True, use_gauss=False,
                 noise=0.0, seed=None, dual=False):
    """一条完整链路, 供 live_tune / batch_sweep 复用。返回 (分屏BGR, 灰度, 边缘, 梯度幅值)。"""
    gray = to_gray(bgr)
    gray_n = add_salt_pepper(gray, noise, seed)  # 模拟传感器噪声
    if use_median:
        gray_f = median3x3(gray_n)
    else:
        gray_f = gray_n
    if use_gauss:
        gray_f = gaussian3x3(gray_f)
    mag = sobel3x3(gray_f)
    edge = threshold_hysteresis(mag, t_lo, t_hi) if dual else threshold_single(mag, t)
    view = split_view(gray_f, edge)
    return view, gray_f, edge, mag


# ---------------------------------------------------------------------------
# 高阶④ 完整 Canny(梯度方向 + 非极大值抑制 NMS + 双阈值滞后)
# ---------------------------------------------------------------------------

def gradient(gray):
    """3x3 Sobel 梯度: 返回 (mag=|Gx|+|Gy| 全量程 int32, angle=梯度方向弧度)。
    注意: mag 不做 0..255 截位 —— 强边缘幅值可达 1000+, 截位会让大量像素饱和成 255,
    NMS 邻域比较全是平局, 谁留谁删随机化 -> 线条帧间抖动。截位只在显示/阈值处做。"""
    p = np.pad(gray, 1, mode="edge").astype(np.int32)
    a00, a01, a02 = p[0:-2, 0:-2], p[0:-2, 1:-1], p[0:-2, 2:]
    a10, a11, a12 = p[1:-1, 0:-2], p[1:-1, 1:-1], p[1:-1, 2:]
    a20, a21, a22 = p[2:, 0:-2], p[2:, 1:-1], p[2:, 2:]
    gx = (a02 + 2 * a12 + a22) - (a00 + 2 * a10 + a20)
    gy = (a20 + 2 * a21 + a22) - (a00 + 2 * a01 + a02)
    mag = np.abs(gx) + np.abs(gy)
    angle = np.arctan2(gy.astype(np.float64), gx.astype(np.float64))
    return mag, angle


def nms(mag, angle):
    """非极大值抑制: 把梯度方向量化到 0/45/90/135 四方向,
    只保留沿梯度方向上是局部最大值的像素, 输出被抑制后的梯度幅值。
    方向约定: 0°=左右比较(垂直边), 90°=上下比较(水平边),
             45°=主对角线, 135°=副对角线。"""
    m = mag.astype(np.int32)
    deg = np.degrees(angle) % 180
    q = np.zeros(deg.shape, np.uint8)
    q[(deg < 22.5) | (deg >= 157.5)] = 0
    q[(deg >= 22.5) & (deg < 67.5)] = 45
    q[(deg >= 67.5) & (deg < 112.5)] = 90
    q[(deg >= 112.5) & (deg < 157.5)] = 135
    mp = np.pad(m, 1, mode="edge")
    n0, n1 = mp[1:-1, 0:-2], mp[1:-1, 2:]     # 左右
    n2, n3 = mp[0:-2, 1:-1], mp[2:, 1:-1]     # 上下
    n4, n7 = mp[0:-2, 0:-2], mp[2:, 2:]       # 主对角线
    n5, n6 = mp[0:-2, 2:], mp[2:, 0:-2]       # 副对角线
    # 与 OpenCV 一致的非对称比较(一侧严格 >, 另一侧 >=): 打破平局、把粗边细化为单像素
    keep = np.where(
        q == 0, (m > n0) & (m >= n1),
        np.where(
            q == 45, (m > n4) & (m >= n7),
            np.where(
                q == 90, (m > n2) & (m >= n3),
                (m > n5) & (m >= n6)
            )
        )
    )
    return np.where(keep, m, 0).clip(0, 255).astype(np.uint8)


def canny(gray, t_lo=16, t_hi=40, use_median=True, use_gauss=True):
    """完整 Canny 链: (中值) -> 高斯 -> 梯度 -> NMS -> 双阈值滞后。
    返回 (边缘0/255, NMS后梯度幅值)。"""
    if use_median:
        gray = median3x3(gray)
    if use_gauss:
        gray = gaussian3x3(gray)
    mag, angle = gradient(gray)
    mag_nms = nms(mag, angle)
    edge = threshold_hysteresis(mag_nms, t_lo, t_hi)
    return edge, mag_nms


# ---------------------------------------------------------------------------
# 高阶⑤ 边缘彩色叠加: mode=1 红边叠加灰度, mode=2 按梯度方向 HSV 着色
# ---------------------------------------------------------------------------

def color_edge_overlay(gray, edge, angle=None, mode=1):
    """把边缘彩色叠加到灰度图上。mode=1: 边缘染红色; mode=2: 按梯度方向着色(需 angle)。"""
    out = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    if mode == 1:
        out[edge > 0] = (0, 0, 255)  # BGR 红色
    elif mode == 2 and angle is not None:
        hsv = np.zeros((gray.shape[0], gray.shape[1], 3), np.uint8)
        hsv[..., 0] = (np.degrees(angle) % 180).astype(np.uint8)
        hsv[..., 1] = 255
        hsv[..., 2] = np.where(edge > 0, 255, 0).astype(np.uint8)
        colored = cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)
        out[edge > 0] = colored[edge > 0]
    return out


# ---------------------------------------------------------------------------
# 高阶⑥ 圆形/矩形识别 + 显示文字(OpenCV 窗口不支持中文, 标签用英文, 板上可换字库)
# ---------------------------------------------------------------------------

def detect_shapes(edge, min_area=400, min_side=12):
    """在二值边缘图上识别矩形与圆形(基于轮廓逼近+圆度)。
    返回 [{"type":"RECT","box":(x,y,w,h),"center":(...)}, {"type":"CIRCLE","center":...,"radius":...}]"""
    results = []
    contours, _ = cv2.findContours(edge, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    for c in contours:
        area = cv2.contourArea(c)
        if area < min_area:
            continue
        peri = cv2.arcLength(c, True)
        if peri <= 0:
            continue
        approx = cv2.approxPolyDP(c, 0.02 * peri, True)
        if len(approx) == 4 and cv2.isContourConvex(approx):
            x, y, w, h = cv2.boundingRect(approx)
            if w >= min_side and h >= min_side and 0.3 < w / h < 3.3:
                results.append({"type": "RECT", "box": (x, y, w, h),
                                "center": (x + w // 2, y + h // 2)})
        circ = 4.0 * np.pi * area / (peri * peri)
        if circ > 0.78:
            (cx, cy), r = cv2.minEnclosingCircle(c)
            if r >= min_side / 2:
                results.append({"type": "CIRCLE", "center": (int(cx), int(cy)),
                                "radius": int(r)})
    return results


def draw_shapes(img_bgr, results):
    """把识别结果画到 BGR 图上: 矩形=绿色框+RECT, 圆形=蓝色框+CIRCLE。"""
    for r in results:
        if r["type"] == "RECT":
            x, y, w, h = r["box"]
            cv2.rectangle(img_bgr, (x, y), (x + w, y + h), (0, 255, 0), 2)
            cv2.putText(img_bgr, "RECT", (x, max(y - 6, 12)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
        else:
            cv2.circle(img_bgr, r["center"], r["radius"], (255, 0, 0), 2)
            cv2.putText(img_bgr, "CIRCLE", (max(r["center"][0] - 30, 4),
                                            max(r["center"][1] - r["radius"] - 6, 12)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 0, 0), 2)
    return img_bgr


# ---------------------------------------------------------------------------
# 参考成熟工程后的增强(2026-09-26):
#   - remove_isolated: 孤立点消除(杀单像素白点, 参考红外技术论文腐蚀去孤立点)
#   - otsu_threshold:  自适应阈值(参考 Otsu 边缘检测论文)
#   - temporal_blend:  时间域帧间平均(参考 EricYXZ 同平台工程的帧平均去噪)
# ---------------------------------------------------------------------------

def remove_isolated(edge, min_neighbors=1):
    """孤立点消除: 3x3 窗口内白色邻居数 < min_neighbors 的白像素被清除。
    默认 min_neighbors=1: 只删除"周围一个白邻居都没有"的孤立单点(闪烁白点),
    1px 边缘线完整保留(线端点有 1 个邻居, 也不删)。
    注意: 别用 min_neighbors=2 —— Canny 的 1px 细线端点/短段会被误杀, 画面会空。"""
    p = np.pad(edge, 1, mode="constant", constant_values=0).astype(np.int32)
    win_sum = np.zeros((edge.shape[0] + 2, edge.shape[1] + 2), dtype=np.int32)
    for i in range(3):
        for j in range(3):
            # 累加目标固定在 [0:H,0:W], 源取 p[i:i+H, j:j+W]:
            # 这样 win_sum[r,c] 统计的是 (r,c) 周围 3x3 窗口(含自身)的白像素数。
            win_sum[:edge.shape[0], :edge.shape[1]] += \
                p[i:i + edge.shape[0], j:j + edge.shape[1]]
    n_neigh = win_sum[:edge.shape[0], :edge.shape[1]] - edge.astype(np.int32)
    keep = (edge > 0) & (n_neigh >= min_neighbors)
    return np.where(keep, 255, 0).astype(np.uint8)


def otsu_threshold(mag, fallback=40):
    """Otsu 自动阈值: 最大化类间方差, 自动确定 0..255 阈值。
    只在非零梯度像素上计算(全零/近零画面会误算成 0); 结果<=0 时回落 fallback。
    输入可能是全量程 int32(未截位), 先钳到 0..255 再做 Otsu。"""
    m8 = np.clip(mag, 0, 255).astype(np.uint8)
    nz = m8[m8 > 0]
    if nz.size < max(100, m8.size // 200):
        return fallback
    thr, _ = cv2.threshold(nz, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    t = int(thr)
    return t if t > 0 else fallback


def temporal_blend(prev, cur, alpha):
    """时间域滤波(帧间平均): out = alpha*cur + (1-alpha)*prev。
    alpha 越接近 1 保留当前帧越多; 0.7~0.9 可明显压帧间白点闪烁。"""
    if prev is None or alpha <= 0:
        return cur
    return np.clip(
        alpha * cur.astype(np.float32) + (1 - alpha) * prev.astype(np.float32),
        0, 255).astype(np.uint8)
