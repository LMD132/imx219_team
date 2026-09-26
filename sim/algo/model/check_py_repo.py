"""check_py_repo.py -- 直接对拍: 仓库原始 edge_pipeline.py  vs  RTL 金标准模型 rtl_model.py
用途: 证明"RTL 逐级等于仓库 Python 算法", 而不是只等于我们自己写的模型。
输入: 仓库自带 samples_test.png (真实照片) + 合成图案。
"""
import os, sys, numpy as np, cv2

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "ref", "FPGA-Python-main")   # 算法参考源快照
MODEL = HERE
sys.path.insert(0, REPO)
sys.path.insert(0, MODEL)
import edge_pipeline as EP   # 仓库原文件, 未改一行
import rtl_model as M        # RTL 金标准

def cmp(tag, a, b):
    a = np.asarray(a); b = np.asarray(b)
    if a.shape != b.shape:
        print("  [%-14s] SHAPE %s vs %s  FAIL" % (tag, a.shape, b.shape)); return 1
    d = (a.astype(np.int64) != b.astype(np.int64))
    n = int(d.sum())
    print("  [%-14s] %s  mismatch %d / %d %s" % (tag, a.shape, n, a.size,
          "" if n == 0 else "<-- maxdiff %d" % int(np.abs(a.astype(np.int64)-b.astype(np.int64)).max())))
    return n

def check_image(name, bgr, tl=21, th=58, t=24):
    H, W = bgr.shape[:2]
    print("=== %s  %dx%d ===" % (name, W, H))
    bad = 0
    b = bgr[:, :, 0]; g = bgr[:, :, 1]; r = bgr[:, :, 2]
    g1 = EP.to_gray(bgr);                                   bad += cmp("to_gray", g1, M.gray_shift_add(r, g, b))
    m1 = EP.median3x3(g1);                                  bad += cmp("median3x3", m1, M.median_3x3_network(g1))
    ga1 = EP.gaussian5x5(m1);                               bad += cmp("gaussian5x5", ga1, M.gauss5x5_int(m1))
    mag1, ang1 = EP.gradient(ga1)
    gx, gy, mag2 = M.sobel_full(ga1);                       bad += cmp("sobel_mag", mag1, mag2)
    n1 = EP.nms(mag1, ang1); n2 = M.nms_rtl(mag2, M.dir_class(gx, gy))
    bad += cmp("nms", n1, n2)
    e1 = EP.threshold_hysteresis(n1, tl, th); e2 = M.hysteresis_rtl(n2, tl, th)
    bad += cmp("hysteresis", e1, e2)
    s1 = EP.threshold_single(mag2, t); s2 = M.threshold_rtl(mag2, t)
    bad += cmp("single_thr", s1, s2)
    d1 = EP.remove_isolated(e1); d2 = M.isolated_rtl(e2)
    bad += cmp("remove_isolated", d1, d2)
    return bad

total = 0
p = os.path.join(REPO, "samples_test.png")
if os.path.exists(p):
    im = cv2.imread(p, cv2.IMREAD_COLOR)
    total += check_image("samples_test.png(裁剪 320x240)", im[:240, :320].copy())
else:
    print("samples_test.png 缺失")

# 合成测试: 棋盘格 + 圆 + 矩形 + 噪声 (更接近"边缘检测演示"的场景)
rng = np.random.default_rng(7)
sy = np.full((160, 208, 3), 40, np.uint8)
for i in range(0, 160, 20):
    for j in range(0, 208, 20):
        if ((i // 20) + (j // 20)) % 2 == 0:
            sy[i:i+20, j:j+20] = 235
cv2.circle(sy, (60, 120), 34, (200, 60, 60), -1)
cv2.rectangle(sy, (120, 30), (190, 100), (30, 220, 240), -1)
sy = np.clip(sy.astype(np.int16) + rng.integers(-25, 26, sy.shape), 0, 255).astype(np.uint8)
total += check_image("合成(棋盘+圆+矩形+噪声)", sy)

text = "同步" 
print("RESULT:", "PASS (仓库 Python == RTL 金标准模型, 逐级逐位)" if total == 0 else "FAIL")