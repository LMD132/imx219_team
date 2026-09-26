# 赛题4 · 算法 RTL 化说明（Python → Verilog 逐位移植）

本文回答一个问题：**板上的边缘检测算法到底是不是 GitHub 仓库 `FPGA-Python` 里那套 Python 算法？**
结论：是，逐级逐位一致，且可复现。

- 算法唯一来源：`liuziyaoyao1210-sudo/FPGA-Python` 的 `edge_pipeline.py`（本仓库内有快照，见 §2）。
- 未参考任何其它工程的算法实现；本工程只复用了原相机的 MIPI/DDR/HDMI **链路** RTL。
- `edge_pipeline.py` 依赖 OpenCV（`cv2`）的少数几个操作（放大、轮廓、HSV）在 Verilog 里没有对应库，
  这部分是**按 Python 的语义手写等价 RTL**，并在 §4 逐条列出；其余全部是按 Python 表达式直接改写。

---

## 1. 证据分级（先说清楚哪些做了、哪些没做）

| 等级 | 本项目状态 |
| --- | --- |
| A. RTL 实现 | ✅ 全部算法级 + 显示级模块已实现并入库（`rtl/algo/`） |
| B. 仿真逐位对拍 | ✅ 7 级 × 3 种模式全 0 mismatch；显示对齐 306 像素 0 mismatch |
| C. Python 溯源对拍 | ✅ 仓库原始 `edge_pipeline.py` ≡ RTL 金标准模型（2 图 × 8 级 0 mismatch） |
| D. 编译 / 时序 / 资源 | ✅ Efinity 2026.1 map/interface/pnr/pgm 全 PASS，全设计无负 slack |
| E. JTAG 下载 | ❌ **未做** |
| F. 上板肉眼画面确认 | ❌ **未做**（需板子持有人） |

> 任何"画面效果"的说法都只能等到 F 级证据出现。D 级通过不等于画面正确。

---

## 2. 算法来源与快照

| 项 | 值 |
| --- | --- |
| 上游仓库 | https://github.com/liuziyaoyao1210-sudo/FPGA-Python |
| 唯一算法文件 | `edge_pipeline.py`（未改一行） |
| 仓库内快照 | `sim/algo/model/ref/FPGA-Python-main/` |
| 定稿参数 | 同目录 `config.json` |
| 测试用图 | 同目录 `samples_test.png`（真实照片，320×240 裁剪参与比对） |
| 上游自述文档 | 同目录 `RTL交接文档.md`、`README.md` |

快照的意义：换机器、换线程、离开聊天记录之后，`sim/algo/model/check_py_repo.py`
仍然能就地重跑并复现"逐位一致"的结论，不依赖任何外部路径。

`config.json` 定稿值 → 顶层实例参数（`rtl/ti60f225_oob_top.v`）：

| config.json | 值 | 顶层实例 | 是否一致 |
| --- | --- | --- | --- |
| `algo` | 1（Canny） | `cfg_mode(2'd2)` | ✅ |
| `t_hi` / `t_lo` | 58 / 21 | `cfg_hi(11'd58)` / `cfg_lo(11'd21)` | ✅ |
| `t` | 24 | `cfg_t(11'd24)` | ✅ |
| `median` | 1 | `cfg_median_en(1'b1)` | ✅ |
| `gauss` | 0 | `cfg_gauss_en(1'b0)`（CANNY 档由 `alg_top` 自动置 1） | ✅ 语义一致 |
| `isol` | 1 | `cfg_isol_en(1'b1)` | ✅ |
| `temp` | 50 | — | ⚠️ **未 RTL 化**，见 §11 |
| `color` | 0 | `cfg_ov_color(1'b1)` | ⚠️ 演示取舍：RGB 为 12bit 通道拼接，红边叠彩更直观；置 0 即是同语义的灰度底 |
| `shape` | 0 | — | ❌ 未 RTL 化 |

---

## 3. Python ↔ RTL 逐级映射表

`edge_pipeline.py` 是算法定义；`rtl_model.py` 是"用 Python 精确模拟 RTL 定点行为"的金标准模型；
RTL 模块与金标准模型逐位对拍。

| `edge_pipeline.py` 函数 | 语义 | RTL 金标准 `rtl_model.py` | RTL 模块 | 流水线延迟 |
| --- | --- | --- | --- | --- |
| `to_gray()` | `(77R+150G+29B)>>8` | `gray_shift_add()` | `alg_gray.v` | 1 |
| `median3x3()` | 3×3 中值 | `median_3x3_network()` | `alg_median3.v` | 4 |
| `gaussian5x5()` | 5×5 整数高斯，核和 1010 | `gauss5x5_int()` | `alg_gauss5.v` | 5 |
| `gradient()` / `sobel3x3()` | `G=|Gx|+|Gy|` 全量程 | `sobel_full()` | `alg_sobel3.v` | 4 |
| `nms()` 里的方向量化 | `arctan2` 角度 → 0/45/90/135 | `dir_class()` | `alg_sobel3.v`（`out_dir`） | 并入上级 |
| `nms()` | 非极大值抑制 | `nms_rtl()` | `alg_nms.v` | 4 |
| `threshold_hysteresis()` | 双阈值滞后 | `hysteresis_rtl()` | `alg_thresh.v`（mode 1/2） | 4 |
| `threshold_single()` | 单阈值 | `threshold_rtl()` | `alg_thresh.v`（mode 0） | 4 |
| `remove_isolated()` | 去孤立白点 | `isolated_rtl()` | `alg_despeckle.v` | 4 |
| `run_pipeline()` 的整链路 | 组合以上各步 | `rtl_pipeline()` | `alg_top.v` | 26 |
| `split_view()` | 左右分屏 | 硬件换成行缓存方案 | `alg_vdisp.v`（mode 0/2/3） | — |
| `color_edge_overlay()` mode 1 | 红边叠加 | — | `alg_vdisp.v`（mode 1 + `ov_color`） | — |

### 3.1 为什么"自己的代码"只出现在这几处

`edge_pipeline.py` 用到 `cv2` 的地方，Verilog 里没有对应库，必须手写等价实现：

| Python 用到的 cv2 能力 | 用在哪 | RTL 等价实现 | 等价性依据 |
| --- | --- | --- | --- |
| `np.sort` 9 元素取中位 | `median3x3()` | 19 比较器排序网络（3 级） | `rtl_model.median_3x3_network()` 与 `np.sort[...,4]` 0 mismatch |
| `cv2.filter2D` | `gaussian3x3()` | 移位加法 + 定点舍入 | 核/移位与 Python 表达式逐项相同 |
| `cv2.dilate(3×3)` | `threshold_hysteresis()` | `alg_thresh` 内 9 个 strong 位相或 | `rtl_model._dilate3_zero()` 补 0 边界，0 mismatch |
| `np.pad(mode="edge")` | `median3x3/sobel3x3/nms` | `alg_gray` 的扩展光栅流（行尾 VEXT 复制 + 帧尾 REXT 行） | 见 §6 |
| `np.pad(constant=0)` | `remove_isolated()` | `alg_win` 的 `PAD_EDGE=0` | 0 mismatch |
| `np.arctan2` | `gradient()` | 整数交叉相乘判角（`|Gy|*4096 vs |Gx|*1697`） | 见 §5 |
| `cv2.cvtColor(GRAY2BGR)` | `split_view()` | 复制到 RGB 三通道 | 肉眼等价 |
| 行缓存（无 cv2 对应） | 全部窗口算子 | `alg_win.v`（行缓存 + 列移位寄存器） | 见 §7 |

除上表以外，没有再自行引入任何算法。

---

## 4. 逐位对拍结果（可复现）

### 4.1 Python 溯源：仓库原始 `edge_pipeline.py` ≡ RTL 金标准模型

运行：`python sim/algo/model/check_py_repo.py`（从仓库根目录）

```
=== samples_test.png(裁剪 320x240)  320x240 ===
  [to_gray       ] (240, 320)  mismatch 0 / 76800
  [median3x3     ] (240, 320)  mismatch 0 / 76800
  [gaussian5x5   ] (240, 320)  mismatch 0 / 76800
  [sobel_mag     ] (240, 320)  mismatch 0 / 76800
  [nms           ] (240, 320)  mismatch 0 / 76800
  [hysteresis    ] (240, 320)  mismatch 0 / 76800
  [single_thr    ] (240, 320)  mismatch 0 / 76800
  [remove_isolated] (240, 320) mismatch 0 / 76800
=== 合成(棋盘+圆+矩形+噪声)  208x160 ===
  ... 同上 8 级, 全部 mismatch 0 / 33280
RESULT: PASS (仓库 Python == RTL 金标准模型, 逐级逐位)
```

该脚本 `import edge_pipeline` 的是**仓库原文件**，没有任何改写或包装。

### 4.2 全链路 RTL 仿真：iverilog 跑真 RTL vs 金标准模型

运行：`python sim/algo/model/check_chain.py`（需 `ALG_OSS_BIN`，见 §12）

每级都在"真实像素区"（`x<W, y<H`）逐像素比对：

```
=== MODE=2 DISP=1 ===  gray/median/gauss5/sobel3/nms/thresh/despeck  各 153 像素 mismatch 0
                       [display] 稳定 306 像素 mismatch 0
=== MODE=2 DISP=3 ===  同上, [display] mismatch 0
=== MODE=0 DISP=2 ===  同上, [display] mismatch 0
=== MODE=1 DISP=0 ===  同上, [display] mismatch 0
=== HTOTAL 初值刻意写错(40) -> 实测修正 ===  [display] mismatch 0, PASS
RESULT: PASS
```

最后一段是**鲁棒性验证**：把 `HTOTAL` 参数初值故意写成错的 40，验证 `alg_vdisp`
能靠运行期实测行周期自动修正（见 §8.4）。

---

## 5. 定点与截位约定（决定桌面/板子差 1~2 的那些细节）

以下每一条都是为了让 RTL 与 Python **逐位**相同；改任何一条都会破坏 §4 的 0 mismatch。

1. **灰度**：`Y = (77R + 150G + 29B) >> 8`，16bit 中间量后取 `[15:8]`。
   系数展开成移位加法（77=64+8+4+1，150=128+16+4+2，29=32-4+1），**无除法器、无乘法器**。
2. **中值**：19 个 2 输入比较器。第 1 级 3 行各自 sort3；第 2 级 `lo=max(行最小)`、
   `hi=min(行最大)`、`md=med3(行中位)`；第 3 级 `median=med3(lo,md,hi)`。
3. **5×5 高斯**：核 `[32,38,40,38,32;38,45,47,45,38;40,47,50,47,40;...]`，总和 1010。
   舍入按 Python `(sum>>10)+((sum>>9)&1)`，不是简单截位。
4. **Sobel 幅值全量程**：`mag=|Gx|+|Gy|` 保留 11bit（0..2040），**NMS 之前不截到 255**。
   Python 注释已说明原因：截位会让大量像素饱和成 255，NMS 邻域比较变成平局，
   "谁留谁删"随机化 → 线条帧间抖动。截位只发生在 NMS 输出和阈值处。
5. **方向量化用整数交叉相乘**（替代 `arctan2`，且与 `np.degrees%180` 的分档一致）：
   - `|Gy|*4096 <= |Gx|*1697` → 0°（左右比较）
   - `|Gx|*4096 <= |Gy|*1697` → 90°（上下比较）
   - 其余：`sign(Gx)==sign(Gy)` → 45°，否则 135°
   - RTL 用 2bit 编码：`0→0, 90→1, 45→2, 135→3`
   （1697/4096 ≈ tan(22.5°)）
6. **NMS 非对称比较**（打破平局，把粗边细化为单像素；与 OpenCV 一致）：
   `0°: (m>L)&(m>=R)`；`90°: (m>U)&(m>=D)`；`45°: (m>UL)&(m>=DR)`；`135°: (m>UR)&(m>=DL)`。
7. **滞后**：`strong = mag>=hi`；`weak = mag>=lo`；`edge = weak & dilate3x3(strong)`。
   膨胀的视场外补 **0**（等价 `cv2.dilate` 默认边界）。`lo>hi` 时自动交换。
8. **去孤点**：Python 判据是"3×3 内白邻居数 ≥ 1"；RTL 等价写成"自身为白且 3×3 计数 ≥ 2"。
   边界补 0。
9. **NMS 输出**：`clip(m, 0, 255)`；阈值级输入是 8bit 的 NMS 结果。
10. **开关不改变延迟**：中值/高斯/去孤点关掉时输出"窗口中心像素"，但流水线延迟保持不变
    （4/5/4 拍）。这样运行时切换开关画面位置不跳。

---

## 6. 边界处理：扩展光栅流

Python 用 `np.pad` 在图像四周造虚拟像素；RTL 是流式的，没有"整幅图"这个概念，
所以把边界扩展做进流里（`alg_gray.v`）：

```
行内：x = 0..W-1      真实像素
      x = W..W+VEXT-1 行尾扩展（PAD_EDGE=1: 复制本行最后一个像素）
帧尾：y = H..H+REXT-1 复制最后一行
```

于是每一级窗口模块都能拿到"不存在的未来行/列"的合法近似，用于：

- `PAD_EDGE=1` → 等价 `np.pad(mode="edge")`：中值、高斯、Sobel、NMS。
- `PAD_EDGE=0` → 等价补 0：阈值膨胀、去孤点。

**代价**：整幅画面最外 7 行/列需要"未来的行/列"，流式下拿不到真值，
该处 `de=0`、边缘显示为 0（图像边界 7 像素）。这是流式架构的固有边界，
已在 §4.2 的比对中限定在真实像素区，并与 Python 的差异如实记录。

---

## 7. 流水线延迟表与 `ROWD`

| 级 | 模块 | 窗口半径 H2 | 该级延迟 |
| --- | --- | --- | --- |
| 1 | `alg_gray` | — | 1 |
| 2 | `alg_median3` | 1 | 4 |
| 3 | `alg_gauss5` | 2 | 5 |
| 4 | `alg_sobel3` | 1 | 4 |
| 5 | `alg_nms` | 1 | 4 |
| 6 | `alg_thresh` | 1 | 4 |
| 7 | `alg_despeckle` | 1 | 4 |
| — | **合计** | **7** | **26** |

两条关键结论：

1. `L = 26` 拍：dsp 级在时钟 `t` 输出的边缘值，对应顶层输入在 `t-26` 时刻的像素。
2. `ROWD = 7`：dsp 输出的 `(x,y)` 标签 = **源像素坐标**，比屏幕坐标小 7。
   即**标签是元数据，不是屏幕位置**。

> 曾经踩过的坑：以为"边缘整体延迟 26 拍，那就把彩色也延迟 26 拍再叠加"，
> 结果边缘整体右下移 7 行 7 列（306 个显示像素里错 80 个）。原因是边缘值到达显示侧时，
> 彩色光栅已经跑到了 `(x+7, y+7)`，而标签仍然标着源坐标。修法见 §8。

SOBEL 档（mode 0/1）走 NMS 旁路，但 `alg_stream_delay` 依然补足 4 拍，所以两种档位
末端延迟都收敛到 26 拍，换档不跳（§4.2 中 MODE=0/1 的 `[display]` 亦为 0 mismatch）。

---

## 8. 显示对齐 `alg_vdisp`（本项目最容易写错的地方）

### 8.1 问题

算法主链是 6 级级联窗口。边缘值算出来时，输入光栅已经流过去了 7 行 7 列。
彩色和边缘虽然指向同一个源像素，但在**时间上**差约 7 行。直接同拍叠加 → 错位。

### 8.2 做法（只在显示侧做，算法一行不改）

1. **显示光栅** = 输入光栅整体延迟 `TDLY = ROWS × 行周期`（整行数）。
   行内相位不变，显示器拿到的仍是一路合法光栅，只是整帧晚 8 行（人眼不可见）。
2. **彩色行缓存** 8 行 × W × 24bit，地址 `(行号 mod 8)*W + 列`：
   写 = 输入光栅，读 = 显示光栅。同一地址每隔 8 行被写一次、也被读一次，
   读正好落在"上一次写"上 → 彩色与显示位置逐像素严格对齐。
3. **边缘行缓存** 8 行 × W × 8bit，同一套地址，但**写地址用 dsp 标签** `(ed_x, ed_y)`
   （即源像素坐标）→ 边缘值自动落回它所属的屏幕位置。
4. 读地址计数器由"提前 2 拍"的显示光栅驱动，抵消行缓存的 2 拍读延迟，
   地址算术里不需要额外的 `+2` 补偿。
5. 灰度不另存，由延迟后的彩色现算 `(77R+150G+29B)>>8`（与 `alg_gray` 逐位一致）。

### 8.3 行缓存安全性

- 读一行比写晚 `ROWS` 行；同一 bank 要再过 `ROWS` 行才会被下一行覆盖
  → 读总是落在"本 bank 上一次写"上，余量 1~2 拍。
- 依赖 `simple_dual_port_ram` 的 **2 拍读延迟** 与 **同址同拍读旧值（READ_FIRST）** 语义。
- 边缘写地址门控 `ed_y < H`，把帧尾复现行（`alg_gray` 的 REXT 行）排除。
- `ROWS = ROWD+1 必须是 2 的幂`；`TDLY < 2^14`（时延 RAM 深度）。

### 8.4 运行期行周期实测（本工程必需）

本工程的显示光栅来自相机链路（MIPI RX → 去马赛克），**行周期不是综合期常量**。
若用死常数，`TDLY` 就不是行周期的整数倍 → 画面水平错位/撕裂。

`alg_vdisp` 因此用"输入光栅连续 3 次相同的行首间距"自动测出 `lper`，
`TDLY = lper × ROWS` 用**运行时值**；参数 `HTOTAL` 只作上电初值。
此机制由 §4.2 最后一段（初值故意写错）验证。

### 8.5 四种显示模式

| mode | 显示 | 说明 |
| --- | --- | --- |
| 0 | 同视野左右分屏（2:1 水平抽取） | 左半 = 灰度全画幅，右半 = 边缘全画幅 |
| 1 | 彩色原图 + 红边叠加 | `ov_color=0` 时底色改用灰度（对应 `color_edge_overlay` mode 1） |
| 2 | 左右 1:1 分区 | 左半 = 画面左半灰度，右半 = 画面右半边缘 |
| 3 | 全屏二值边缘 | — |

> 赛题基础④要求"分屏显示"，mode 0 正是"同一完整视野"的灰度/边缘并排，
> 修正了旧版"两个半边各显示自己的空间裁切"的问题。

---

## 9. 顶层集成

`rtl/ti60f225_oob_top.v` 中 `u_alg_top`：

| 项 | 值 |
| --- | --- |
| 时钟域 | `hdmi_tx_slow_clk`（74.25MHz） |
| 复位 | `vid_rst_n` |
| 输入 | `hdmi_tx_vs/hs/de` + `hdmi_tx_rdata/gdata/bdata`（已过 DDR 的 RGB 光栅） |
| 输出 | `edge_vs/hs/de/x/y/r/g/b` → `dvi_encoder dvi_encoder_m0` |
| 参数 | `W=1280 VEXT=16 H=720 REXT=8 HTOTAL=1650 HALF=640 ROWD=7` |

相机 / MIPI / DDR / HDMI 链路 RTL **完全未改动**。

**演示用模式轮换**：本板顶层没有任何按键输入（`GPIOL_07` 已被 `i_arstn` 复位占用），
所以加了 `demo_cnt` 在 `pos_vs` 上计数，`demo_disp = demo_cnt[8:7]`，
**每 128 帧轮换一次显示模式 0/1/2/3**，用于演示时展示四种显示效果。
（这不属于算法；有按键后应替换为真实按键输入。）

---

## 10. 编译、时序、资源实测

命令见 §12。`map / interface / pnr / pgm` 全部 `PASS`。

| 指标 | 旧基线（`edge_display_720p`，灰度+Sobel） | 现在（全算法链） |
| --- | --- | --- |
| XLRs | 17256 / 60800 | **21593 / 60800 (35.51%)** |
| Memory Blocks | 110 / 256 | **208 / 256 (81.25%)** |
| DSP Blocks | 4 / 160 | 4 / 160 (2.50%) |
| `hdmi_tx_slow_clk` setup slack | +0.467 ns | **+5.316 ns** |
| `hdmi_tx_slow_clk` hold slack | — | **+0.031 ns** |
| 全设计负 slack 数 | — | **0** |
| `hdmi_tx_slow_clk` 最大可分析频率 | — | 122.669 MHz（约束 74.25 MHz） |

内存构成：`EFX_RAM10` 200 + `EFX_DPRAM10` 8。其中 `u_alg_top` 独占 102 块
（`u_vdisp` 74 块：彩色 8 行 × 1280 × 24bit + 边缘 8 行 × 1280 × 8bit + 时延 RAM）。

> ⚠️ **Memory Blocks 已到 81.25%**，是继续加功能（时间域平均、DDR 回放等）时的首要瓶颈。
> 出口：行缓存深度按需缩小、复用行缓存、或把彩色 24bit 改 16bit。

`u_alg_top` 内部资源（`hier_util.rpt`）：XLR 4893、mem 102、`xlr_lut4` 1609、
`xlr_adder` 1485、`xlr_ff` 742。

---

## 11. 尚未 RTL 化的仓库算法（如实列出）

| 仓库函数 | 状态 | 原因 |
| --- | --- | --- |
| `temporal_blend()` | ❌ 未做 | 时间域帧间平均，需整帧缓存；`config.json` 的 `temp=50` 未生效。**这是"人闪/白点闪"最直接的解法，优先级最高** |
| `otsu_threshold()` | ❌ 未做 | 需直方图统计 + 除法/比较树，代价中等 |
| `guided_filter()` | ❌ 未做 | 仓库自述已排除（EPF=2，实测丢细节） |
| `detect_shapes()` / `draw_shapes()` | ❌ 未做 | 轮廓+凸性判定+中文字库，工作量大 |
| `color_edge_overlay()` mode 2 | ❌ 未做 | HSV 按梯度方向着色，需 HSV→RGB 变换 |
| `gaussian3x3()` | ❌ 未做 | 仓库注明仅作 A/B 对比 |
| `add_salt_pepper()` | ❌ 未做 | 仅 Python 侧噪声模拟，板上无意义 |
| `run_pipeline()` 的红框 / `split_view()` 文字标签 | ❌ 未做 | Python 侧重屏辅助（红框 + "GRAY"/"EDGE" 字样） |

> 上表是**功能缺口**，不是"没实现对"。已 RTL 化的部分与 Python 逐位一致，见 §4。

---

## 12. 复现方法

### 12.1 逐位对拍（只需 Python + numpy + opencv）

```bat
cd /d D:\FPGA_Project\imx219_pyrtl
python sim\algo\model\check_py_repo.py
python sim\algo\model\rtl_model.py --selftest
```

### 12.2 全链路 RTL 仿真（需要 iverilog/vvp）

iverilog 用 oss-cad-suite（约 2GB，不入库），用环境变量指过去：

```bat
cd /d D:\FPGA_Project\imx219_pyrtl
set ALG_OSS_BIN=<你的路径>\oss-cad-suite\bin
python sim\algo\model\check_chain.py
```

（若 `iverilog`/`vvp` 已在 `PATH` 里，可以不设 `ALG_OSS_BIN`。）
仿真产物写在 `sim/algo/run/`（已被 `.gitignore` 忽略）。

### 12.3 编译

```bat
cd /d D:\FPGA_Project\imx219_pyrtl
call C:\Efinity\2026.1\bin\setup.bat
C:\Efinity\2026.1\bin\efx_run.bat ti60f225_oob.xml --flow compile
```

应看到 `map : PASS`、`interface : PASS`、`pnr : PASS`、`pgm : PASS`，
并在 `outflow/ti60f225_oob.timing.rpt` 确认无负 slack。

### 12.4 下载（**需要板子持有人确认后再做**）

见 `README.md` 的 JTAG 命令。注意：`outflow/` 被 Git 忽略，切分支**不会**切换位流，
下载前必须重新编译当前分支，或明确选用 `candidate_bitstreams/` 中已记录的位流。

---

## 13. 工程坑（写 RTL 时反复遇到的）

1. **不能用 reg 数组做 1280+ 深行缓存**：Efinity 不会推断成 BRAM，会炸成巨量 LUT。
   必须用 `simple_dual_port_ram` / `true_dual_port_ram` 且显式给 `.RAM_INIT_FILE("")`。
2. **行缓存读延迟是 2 拍**，且同址同拍读旧值（READ_FIRST）。地址相位要提前 2 拍。
3. **`LINE = W + VEXT`**：窗口模块的行缓存深度按行内总长算，不是 `W`。
4. **`H2` 累计会把标签减掉**：窗口模块输出标签 = 输入标签 − H2（行、列都减）。
   所以"另开一条 `alg_stream_delay` 支路对齐标签"是错的——两条支路坐标永远差一行，
   阈值级曾因此产生 68/153 个错误像素。正解是让 `weak/single` 与窗口中心**同拍**取窗口中心 tap。
5. **仿真里 `%0d`/`%0x` 遇 X 会打印 `x`**，Python 解析要容错（本项目 `_h()` 返回 −1）。
6. `hier_util.rpt` 的第二列是**复用数**不是容量；容量看 `place.rpt` 的 Resource Summary。
7. `outflow/` 是构建目录且被忽略；**切分支不切位流**，下载前必须重编译。

---

## 14. 相关文件

| 路径 | 作用 |
| --- | --- |
| `rtl/algo/alg_gray.v` | 灰度化 + 扩展光栅流 |
| `rtl/algo/alg_win.v` | N×N 滑动窗口（行缓存 Line Buffer） |
| `rtl/algo/alg_median3.v` | 3×3 中值（19 比较器） |
| `rtl/algo/alg_gauss5.v` | 5×5 整数高斯 |
| `rtl/algo/alg_sobel3.v` | Sobel 梯度 + 方向量化 |
| `rtl/algo/alg_nms.v` | 非极大值抑制 |
| `rtl/algo/alg_thresh.v` | 单阈值 / 双阈值滞后 |
| `rtl/algo/alg_despeckle.v` | 孤立点消除 |
| `rtl/algo/alg_stream_delay.v` | 视频流对齐延迟 |
| `rtl/algo/alg_vdisp.v` | 显示对齐（行缓存）+ 4 种显示合成 |
| `rtl/algo/alg_top.v` | 算法链顶层 |
| `rtl/algo/alg_align.v`、`alg_disp.v` | 早期版本，**未被例化**，保留备查 |
| `sim/algo/tb_alg_chain.v` | 全链路测试台 |
| `sim/algo/model/rtl_model.py` | RTL 金标准模型（`--selftest`） |
| `sim/algo/model/check_chain.py` | RTL 全链路逐级对拍 |
| `sim/algo/model/check_py_repo.py` | 仓库 Python ↔ 金标准模型对拍 |
| `sim/algo/model/ref/FPGA-Python-main/` | 算法参考源快照（未改一行） |
| `candidate_bitstreams/` | 候选位流 + SHA-256 + 上板状态 |
