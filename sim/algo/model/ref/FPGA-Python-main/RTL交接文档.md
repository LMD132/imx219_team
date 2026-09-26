# 赛题4 · FPGA 实时边缘检测 · Python 调参 → RTL 完整交接文档

> **版本**: v2.0 (2026-09-26 定稿)
> **读者**: 板上队友 / 任何 AI 编码助手（本文档按机器可读结构编写，可直接作为 RTL 实现依据）
> **平台**: 易灵思 Efinix Ti60F225（赛题指南指定 VF-Ti60F225，实际板卡 Ti60F225I3 DemoBoard V4 同芯片）
> **工作台目录**: D:\FPGA-Python（纯软件，不需要芯片即可运行）
> **一句话定位**: 在电脑上把"边缘检测算法选型 + 参数区间 + 去噪策略"全部验证定稿，RTL 侧照此蓝图实现；参数按"区间+初值"迁移，上板后微调 2~3 个值。

---

## 1. 赛题要求与交付策略

### 1.1 赛题四要求（原文要点，PDF 第 12–18 页）

| 层级 | 要求 | 说明 |
|---|---|---|
| 基础① | 摄像头采集 ≥640×480 | FIFO/BRAM 缓存，不丢帧 |
| 基础② | 灰度化 | 移位加法实现，禁除法器 |
| 基础③ | 3×3 Sobel Gx/Gy + \|Gx\|+\|Gy\| + 阈值可配 | 行缓存 |
| 基础④ | HDMI 640×480@60 分屏 | 左灰度+右边缘 |
| 基础⑤ | 交付 RTL 源码+约束+演示视频 | 棋盘格/数字纸/人脸轮廓 |
| 高阶① | 3×3 中值滤波 | 并行排序网络 |
| 高阶② | 按键实时调阈值 | 消抖+寄存器 |
| 高阶③ | DDR 帧缓存 | 采集-存储-读取-处理分离，回放/冻结/多帧对比 |
| 高阶④ | 完整 Canny | 高斯→梯度幅值方向→NMS→双阈值→滞后连接 |
| 高阶⑤ | 边缘红/彩色叠加 | RGB 三通道 |
| 高阶⑥ | 简易目标识别 | 圆形/矩形，屏幕显示文字 |

> 底部注明："算法复杂度与视频帧频也是考核维度"——实现要可综合、可实时。

### 1.2 交付策略（核心决策）

**RTL 两个都写：Sobel 作默认档（基础保底） + Canny 作可切换档（高阶加分）。**
理由：基础是必做硬底线；高阶是加分项；两者共享约 80% 硬件（灰度/行缓存/滑动窗口/Gx/Gy 梯度），Canny 只多"高斯+NMS+双阈值滞后"三段，用一个 MODE 寄存器切换，增量成本约 30~40% 逻辑。

---

## 2. Python 工作台（环境与使用）

### 2.1 目录与文件

```
D:\FPGA-Python\
├── edge_pipeline.py        # 核心流水线（整数运算，镜像 RTL 结构）
├── live_tune.py            # 实时调参（滑条+按键，摄像头/图片/视频）
├── batch_sweep.py          # 离线批量预筛（滤波×阈值网格）
├── features_demo.py        # 高阶功能五栏演示（Canny/彩色/识别）
├── config.json             # 最终参数（外部实时控制，--config 加载）
├── README.md               # 使用说明+赛题对照
├── RTL交接文档.md          # 本文档
├── requirements.txt        # numpy + opencv
├── 运行_实时调参.bat / 运行_批量预筛.bat
├── .venv\                  # python3.13 虚拟环境（numpy 2.5.3 + opencv 5.0.0.93）
├── samples\                # 按 s 键保存的调参截图
└── out\                    # batch_sweep / features_demo 输出
```

### 2.2 环境搭建（队友电脑若需复跑）

```bash
cd /d D:\FPGA-Python
python3.13 -m venv .venv
.venv\Scripts\python -m pip install -U pip
.venv\Scripts\python -m pip install -r requirements.txt   # 慢可加 -i https://pypi.tuna.tsinghua.edu.cn/simple
```

**关键坑（必读）**：本机 Microsoft Store 版 Python3.13 装在 WindowsApps（只读、禁 --user），裸 `pip` 不在 PATH，必须 `python3.13 -m pip`；依赖必须装进 `.venv`，否则报 `ModuleNotFoundError: cv2/numpy`。

### 2.3 启动命令

```bash
# 实时调参（推荐：加载定稿参数 + 320×240 提速）
.venv\Scripts\python live_tune.py --config config.json --width 320 --height 240

# 指定摄像头 / 图片 / 视频
.venv\Scripts\python live_tune.py --source 1
.venv\Scripts\python live_tune.py --source 图片.png
.venv\Scripts\python live_tune.py --source 视频.mp4

# 离线批量预筛（给多张图出网格对比+指标报告）
.venv\Scripts\python batch_sweep.py 图1.png 图2.png
```

### 2.4 滑条与按键速查（窗口不支持中文，英文缩写）

| 滑条 | 含义 | 定稿值 |
|---|---|---|
| MODE(0=S,1=D) | 0=单阈值 1=双阈值滞后 | 1 |
| ALGO(0=S,1=C) | 0=Sobel 1=Canny(手写含NMS) 2=OpenCV原生(对照标尺) | 1 |
| THR | 单阈值门限 | 24 |
| THR_HI | 双阈值高门限（起强边） | 58 |
| THR_LO | 双阈值低门限（续弱边） | 21 |
| MEDIAN | 3×3 中值 0/1 | 1 |
| EPF(0/1/2) | 0=关 1=高斯3x3 2=导向滤波 | 0 |
| NOISE(0.001x) | 椒盐噪声模拟强度 0~60（×0.001） | 0 |
| COLOR(0=B,1=R,2=H) | 彩色叠加 0=黑白 1=红边 2=方向色 | 0 |
| SHAPE(0/1) | 矩形/圆形识别 | 0 |
| TRACK(0=F,1=T) | 红框 0=固定 1=跟随质心 | 0 |
| TEMP(0-90) | 时间域帧间平均强度（alpha=1-temp/100） | 50 |
| ISOL(0/1) | 孤立单像素点消除 | 1 |
| BOX(%) | 红框大小 | 50 |

按键：`q`退出 `s`存图 `t`切单/双阈值 `o`Otsu自动阈值 `m`切显示 `n`红框开关。

### 2.5 config.json 说明

`--config` 加载后**每帧重读文件**，外部改文件实时生效（便于队友远程/脚本调参）。键名：mode_dual/algo/t/t_hi/t_lo/median/gauss/noise/color/shape/track/temp/isol/box。

---

## 3. 最终参数组合（2026-09-26 定稿，实测 flicker=1638@fps19）

| 参数 | 定稿值 | 作用 | 迁移到 RTL 的对应寄存器 |
|---|---|---|---|
| 算法 | Canny (ALGO=1) | 高阶④，与 OpenCV 逐像素零差异 | MODE=1 分支 |
| THR_HI | **58** | 起强边；压"线条闪"只调它（一次+5） | high_thr[8:0] |
| THR_LO | **21** | 续弱边；丢细节(眼镜/键帽)只调它（一次-4） | low_thr[8:0] |
| MEDIAN | 1 | 压椒盐白点第一招（实测闪变 23498→27px） | median_en |
| EPF | 0 | **2=导向滤波禁用**（丢细节且不治闪，见 §5.5） | — |
| TEMP | **50** | 时间域平均（alpha=0.5），治线条呼吸感闪 | frame_avg_en + alpha 查表 |
| ISOL | **1** | 只删"无白邻居"的孤立单像素，1px 线保留 | isol_en |
| NOISE | 0 | 实拍不模拟噪声 | — |
| 分辨率 | 320×240(调参) / 640×480(上板) | fps 太低画面断续=观感闪 | 上板固定 640×480@60 |

**调参口诀（上板微调用）**：
1. 闪白点/闪线 → 只抬 THR_HI（一次 +5），别动 THR_LO。
2. 丢细节 → 只降 THR_LO（一次 -4）。
3. 人闪打印不闪 → 物理极限（微动+软边），上板固定曝光后好转，别死磕参数。
4. 高低阈值写反 → 自动交换防呆（Python 已实现，RTL 建议同样处理）。

---

## 4. 算法实现细节（Python ↔ RTL 迁移，整数运算）

> 全部整数运算+显式截位，与 Verilog 移位实现对应，**结构层 100% 可迁移**，数值 ±1~2 截断偏差。

### 4.1 灰度化 to_gray()
- 公式: `Y = (77*R + 150*G + 29*B) >> 8`（移位加法，无除法器）
- RTL 参考: EricYXZ/ti60f225-image-processing-fpga `RGB888_to_GRAY8_1280x720.v`（系数逐位一致，已核对）
- 位宽: 输入 8bit×3，系数和 256 → 输出 8bit

### 4.2 3×3 中值 median3x3()
- 9 邻域排序取中值；RTL=3 级并行排序网络
- 实测: 椒盐噪声下边缘闪变 23498px(无滤波)→27px(中值开)

### 4.3 高斯（3×3 与 5×5）
- 3×3: `[1,2,1]×[1,2,1]/16`，RTL=两级低通
- **5×5（Canny 分支强制使用）**: 整数核
  `[32,38,40,38,32; 38,45,47,45,38; 40,47,50,47,40; 38,45,47,45,38; 32,38,40,38,32]`
  总和 1010，`sum >> 10 + ((sum >> 9) & 1)`（四舍五入）
  RTL 参考: EricYXZ `gaussian_filter_proc.v`（5×5 高斯 + 两级加合 18bit + sum[17:10]+sum[9]）
- **实测结论: 高斯治不了椒盐，反而更糟（37570px）；Canny 内的高斯用 5×5 更好（两近帧线条闪变 30→0）**

### 4.4 Sobel 梯度
- `Gx = (p02+2*p12+p22) - (p00+2*p10+p20)`；`Gy = (p20+2*p21+p22) - (p00+2*p01+p02)`
- 幅值: `|Gx|+|Gy|`（L1，避免开方；赛题明确要求）
- 单侧最大值 1020 → Gx/Gy 10bit，|Gx|+|Gy| ≤ 2040 → 11bit
- **关键修复: gradient() 的 mag 不做 0..255 截位（全量程 int32）**——截位会让强边饱和成 255，NMS 邻域全平局 → 线条抖动。截位只在显示/阈值处做
- RTL 参考: AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection `sobel_convolution.v`（6 双口 Block RAM + pixel_counter 状态机 + 三级移位寄存器滑动窗口）

### 4.5 NMS 非极大值抑制（Canny 增量①）
- 梯度方向量化 0/45/90/135 四方向（arctan 查表）
- 沿梯度方向保留局部极大；**与 OpenCV 一致的非对称比较 `m > n0 & m >= n1`**（打破平局、细化为单像素）
- 方向约定: 0°=左右比较(垂直边)、90°=上下比较(水平边)、45°=主对角线、135°=副对角线
- 修复前后: 非对称比较后手写 Canny 与 cv2.Canny 同参数**逐像素差异 2408→0（600 vs 600）**

### 4.6 双阈值滞后 threshold_hysteresis()
- strong = mag≥THR_HI；weak = mag≥THR_LO；edge = weak & dilate(strong)
- 防呆: t_lo>t_hi 自动交换
- 破解"低阈值闪白点 / 高阈值丢眼镜"矛盾的核心

### 4.7 时间域平均 temporal_blend()（TEMP）
- `out = alpha*cur + (1-alpha)*prev`；alpha = 1 - TEMP/100
- RTL 参考: EricYXZ `GRAY5x5_WEIGHTED_INTERNAL_FRAMEAVG_W8R8.v`（帧间平均模块）；Cornell ECE5760 Time Averager
- **治"线条呼吸感闪"的主要手段，定稿 TEMP=50**

### 4.8 孤立点消除 remove_isolated()（ISOL）
- 3×3 窗口内白邻居数 < min_neighbors(=1) 的白像素清除
- **已修两个 bug**: ①窗口统计累加目标偏移写错(应为固定 0:H,0:W)→错位判死整条线全黑；②邻居数减的是 0/1 布尔而统计是 255×个数→单位混用根本删不掉
- 修后: 只删无邻居单像素点，1px 线(含端点)完整保留（线段 11/11、孤立点 0 残留）
- **勿用 min_neighbors=2**（Canny 细线端点被误杀→画面全空）

### 4.9 Otsu 自动阈值 otsu_threshold()
- 非零梯度像素上最大化类间方差；结果≤0 回落 40；输入先 clip 0..255 再算（因 mag 全量程）

### 4.10 彩色叠加 color_edge_overlay()
- mode=1: 边缘染红 (0,0,255)；mode=2: 按梯度方向 HSV 着色

### 4.11 形状识别 detect_shapes()/draw_shapes()
- 轮廓逼近(approxPolyDP)+圆度(circ=4πA/P²>0.78)；矩形=绿框+RECT、圆形=蓝框+CIRCLE
- 合成测试图验证通过: RECT@(57,77,167,227)、CIRCLE@(400,190)r93
- 注意: 文字笔画易成小闭合圈被误判小圆，需 min_area 过滤；窗口不支持中文故标签用英文，板上可换字库

---

## 5. 关键实验结论（哪些有效/无效——避免 RTL 侧重复踩坑）

### 5.1 中值 vs 高斯（同图+椒盐噪声，边缘闪变像素）
| 滤波 | 闪变px | 结论 |
|---|---|---|
| 无滤波 | 23498 | 基线 |
| 3×3 中值 | **27** | 压白点第一招 ✅ |
| 高斯 | 37570 | 治不了椒盐还更糟 ❌ |

### 5.2 双阈值 vs 单阈值
- 单阈值低→白点闪；高→丢眼镜/键帽。双阈值(强边起、弱边续)同时压噪保细节 ✅（THR_HI=58/THR_LO=21）

### 5.3 Canny 与 OpenCV 对齐
- 去掉梯度截位 + 非对称 NMS 后，手写 Canny 与 cv2.Canny 同参数逐像素**零差异** → 算法实现=标准答案，线闪不再来自实现差距

### 5.4 TEMP / ISOL 有效性
- 定稿实测: TEMP=50+ISOL=1 后 flicker 2808→1638（同画面），fps 需 ≥15 否则画面断续观感=闪

### 5.5 EPF=2 导向滤波（已排除）
- 实测: 丢大量细节（眼镜/键帽消失）且仍闪；合成测试闪变 556 vs 高斯 572 无差异
- 依据: SIGGRAPH2011 Domain Transform / 导向滤波本质=边缘保持平滑，"磨小细节、保大边"是设计目标，且是空间滤波不处理帧间时间噪声 → **不用于边缘检测前置**

### 5.6 "人闪打印不闪"= 物理极限（非代码问题）
1. 人微动 0.5~1px → 1px 细线跳格
2. 人脸低对比软边梯度落在双阈值临界区 → 帧间临界翻转
3. 曲线多方向+纹理 → NMS 四方向量化阶梯抖动+弱边碎片
4. 光照/自动曝光帧间漂移
- 对策: 上板固定 IMX219 曝光/增益（最大一招）；演示按场景选参数（打印物低阈值、人脸高阈值+TEMP）

---

## 6. RTL 迁移蓝图

### 6.1 共享流水线（Sobel 档 = 直接输出）

```
Camera(MIPI IMX219) → 灰度化(77,150,29)>>8 → 3行缓存 → 3×3滑动窗口
   → Gx/Gy梯度(10bit) → |Gx|+|Gy|(11bit) → 阈值比较 → HDMI分屏输出
```

### 6.2 Canny 档（MODE=1 增量）

```
MODE 寄存器(0=Sobel, 1=Canny)
   └─ 5×5高斯(整数核,sum>>10+四舍五入)
       → 梯度方向量化(0/45/90/135 查表)
       → NMS(非对称比较 m>n0 & m>=n1)
       → 双阈值滞后(strong≥58, weak≥21, weak&dilate(strong))
```

### 6.3 待办 RTL 优先级

| 优先级 | 任务 | 预计 | 参考 |
|---|---|---|---|
| P0 | Sobel 档收尾+分屏+阈值可配 | 已跑通，补齐 | overlay_box.bit 基线 |
| P1 | Canny 档(高斯+NMS+双阈值) | 增量30~40% | §4.5/4.6 Python 实现 + EricYXZ gaussian_filter_proc.v |
| P2 | 中值滤波、彩色叠加 | 小增量 | §4.2/4.10 |
| P3 | DDR 帧缓存、形状识别 | 大工程，量力而行 | Python §4.11 参考 |

---

## 7. 上板验证清单（按顺序）

1. **锁曝光**: IMX219 寄存器固定曝光/增益(关自动曝光/AE) —— 治"人闪"最大一招
2. 固定测试场景: 棋盘格(对比度)/数字纸(细节)/人脸(轮廓)
3. 先验证 Sobel 档: 单阈值 24~26 → 打印物稳定、白墙无噪点
4. 切 Canny 档: 58/21 + 中值开 + TEMP/ISOL 等效电路 → 人脸轮廓连贯、呼吸感可接受
5. UART/按键微调: 每次只改一个值，用口诀
6. 录演示视频: 一镜到底、切 MODE 展示两档、画面叠加参数 OSD

---

## 8. 参考工程清单

| 工程 | 用途 |
|---|---|
| EricYXZ/ti60f225-image-processing-fpga | **同平台**；灰度系数逐位一致、5×5高斯 RTL、帧平均、UART、参数寄存器 |
| AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection | Sobel 行缓存+FSM RTL 骨架 |
| Floatkyun/Ultra-Vision (113⭐) | 同平台，Algorithm/rtl + FPGA 双架构 |
| Cornell ECE5760 课程项目 | Time Averager（治闪 RTL 参考）、Sobel 实时 demo |
| IAENG IJCS 53_6_33 | 自适应中值(3×3/5×5)+八方向 Sobel+局部自适应阈值（改进方向参考） |

---

## 9. FAQ

- **Q: 为什么电脑上调好上板还要调？** A: USB 摄像头(自动曝光) vs IMX219(需固定) 传感器不同，最优阈值区间整体平移但宽度不变；±1~2 截断偏差。
- **Q: 静态图看不到闪？** A: 闪是时域现象，工作台用"椒盐噪声+帧间异或"近似模拟；最终必须上板确认。
- **Q: Canny 一定比 Sobel 好吗？** A: 不一定。Sobel 硬朗清晰、速度快；Canny 连续但低对比场景更易抖。演示时切档展示两者（各有用武之地）。
- **Q: 上板 fps 不够怎么办？** A: 640×480@60 是赛题硬要求，流水线逐像素处理每时钟 1 像素即达标；TEMP/ISOL/5×5 高斯都是流水线可综合的。
