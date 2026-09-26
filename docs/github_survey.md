# GitHub 开源项目调研（2026-09-26）

板子持有人要求："去 GitHub 上找开源项目，能借鉴到这个赛题里的。"

本文是**广度调研**的结论：15 组关键词、67 条结果、8 个候选仓库的真实文件清单。
它与 `reference_survey.md`（板子持有人给的 9 份本地资料）互补，与
`reference_source_review.md` §7（2026-09-25 那次窄搜索，已采纳 DOUDIU 的局部迟滞）不重复。

复现见 §7。

---

## 1. 一句话结论

1. **头号发现**：同平台（Efinix Ti60F225）、同竞赛、**MIT 许可**、113★ 的
   `Floatkyun/Ultra-Vision` —— 2024 全国大学生嵌入式芯片与系统设计竞赛 FPGA 创新设计赛道
   **国一 + 易灵思创新杯**，基于 Ti60F225 的无极缩放。这是本轮唯一"同芯片 + 同工具链 +
   许可干净 + 有竞赛背书"的工程，值得逐模块对照。
2. **没有任何一个仓库能直接搬进我们的算法链**。GitHub 上不存在"Ti60F225 上的完整
   实时边缘检测开源工程"；我们已跑通的链路（MIPI → DDR → 720p HDMI + 中值 + Sobel +
   双阈值迟滞 + 去碎斑 + 彩色叠加 + UART 遥测）是自己拼出来的，不是抄来的。
3. **真正值得动手的只有 2–3 条**，列在 §5。

---

## 2. 方法（可复现）

| 项 | 值 |
|---|---|
| 工具 | `tools/github_survey.py`（新增，含 `--trees` / `--repo` / `--file`） |
| 端点 | GitHub Search API + `git/trees?recursive=1` + `raw.githubusercontent.com` |
| 网络 | 必须走 `curl.exe`：本机 `urllib` 直连 `api.github.com` **超时**，`curl` 直连 200 |
| 关键词 | 15 组（见 §2.1） |
| 结果 | 67 行 → `work/github_survey.json`（`work/` 不入库） |
| 文件清单 | 8 个候选仓库的完整 HDL 文件名 → `work/gh/tree_*.json` |

抓取时间 2026-09-26；GitHub 的 `total_count` 随时间漂移，数字只代表当天。

### 2.1 各组命中数（当天）

| 关键词 | total | 关键词 | total |
|---|---|---|---|
| `sobel edge detection fpga language:verilog` | 57 | `median filter verilog fpga` | 8 |
| `canny edge detection verilog fpga` | 9 | `gaussian filter verilog fpga` | 3 |
| `efinix image processing` | 2 | `crazybingo fpga` | 1 |
| `ti60f225` | 16 | `imx219 fpga` | 7 |
| `efinix` | 82 | `fpga image processing verilog hdmi` | **0** |
| `histogram equalization fpga language:verilog` | 5 | `otsu adaptive threshold fpga verilog` | **0** |
| `otsu verilog` | 1 | `edge detection ov5640 verilog` | **0** |
| `line buffer verilog` | 15 | | |

**三条 0 命中是有意义的**：`fpga image processing verilog hdmi`、`otsu adaptive threshold
fpga verilog`、`edge detection ov5640 verilog` 在 GitHub 上一个仓库都没有。我们这个赛道
（易灵思 + HDMI 环出 + 边缘检测）在开源社区几乎是空白，这解释了为什么本地那 9 份资料
和参照视频才是主要参考来源。

---

## 3. 头号发现：`Floatkyun/Ultra-Vision`（同平台 + 同竞赛 + MIT）

| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/Floatkyun/Ultra-Vision` |
| 许可 | **MIT**（可移植，保留版权声明即可） |
| 热度 | **113★**，最近推送 `2026-08-29` |
| 体量 | 3384 个 blob / **625 个 HDL** / 148 个不重名模块 |
| 器件 | **Ti60F225**（与我们同芯片同工具链 Efinity） |
| 视频输入 | ADV7611（`ADV7611_I2C_Ctrl.v`、`I2C_ADV7611_Config.v`）—— 它是 **HDMI 输入**，不是 MIPI |
| 核心 | 双线性 / 双三次插值缩放（无极缩放） |

**它值得对照的模块**（文件名来自 `work/gh/tree_Floatkyun__Ultra-Vision.json`）：

| 我们的关注点 | 它的文件 | 为什么值得看 |
|---|---|---|
| **HDMI TX 时序** | `rgb2dvi.v`、`tmds_channel.v`、`serdes_4b_10to1.v` | 我们 TX 早期出现过"直连显示器能亮、经分配器/采集卡就不行"的 TMDS 疑问。同芯片、同工具链的这套三件套是最贴近的官方风格对照 |
| 缩放 / 插值 | `BiCubic.v` + `BiCubic_x0..x3.v` / `BiCubic_y0..y3.v`、`bicubic_interpolation.v`、`bilinear_interpolation.v`、`rgb_bicubic.v`、`rgb_biliner.v` | 把双三次拆成"列方向 4 个 × 行方向 4 个"共 8 个子模块，和常规"行缓存 + 一维插值"写法互相对照 |
| DDR 帧缓存 | `DdrCtrl.v`、`ddr3.v`、`ddr3_controller.vh`、`ddr3_device_ID.vh` | 我们都靠 DDR 做帧缓存，可对照 AXI4 读写时序与参数宏 |
| 定点运算原语 | `integer_divider.v`、`divider_ip.v`、`mul_2.v`/`mul_3.v`/`mul_4.v`、`mul_add_1.v`/`mul_add_2.v`、`efx_dsp12.v`/`efx_dsp24.v`/`efx_dsp48.v` | Efinity 上写乘法/除法的现成形状；`efx_*` 系列是厂商原语包装 |
| 时钟 / 复位 | `reset.v`、`asyn_fifo.v`、`data_in_fifo.v`、`axi4_ctrl.v` | 跨时钟域与 FIFO 的标准写法 |
| I2C 寄存器配置 | `i2c_timing_ctrl_reg8_dat8_wronly.v` | 传感器 / 桥片寄存器写入的通用时序器 |

**注意**：它是**缩放**项目，不是边缘检测。可借的是"同芯片上的工程写法与 HDMI/DDR 通路"，
不是算法链。

---

## 4. 准入红线（许可证）

本仓库的纪律不变：**只学思路，RTL 全部自研重写**（同 `reference_survey.md` §3）。
下表是这次调研新增的取舍依据。

### 4.1 无 license → 只读思路，不搬代码

GitHub 上无 LICENSE 文件默认"保留所有权利"，比"需授权"更严。

| 仓库 | ★ | 备注 |
|---|---|---|
| `EricYXZ/ti60f225-image-processing-fpga` | 1 | 同平台；HDMI TX 三件套 + 5×5 加权灰度 + 对比度/白平衡（见 §5.3） |
| `Nitcloud/Image_sim` | 54 | 自称出自 crazybingo，含 `Line_Shift_RAM.v`、`Sort3.v`、`Sobel_Edge_Detector.v` |
| `DOUDIU/Hardware-Implementation-of-the-Canny-...` | 50 | Canny 四件套（见 §5.1）；**其迟滞逻辑已按"重写"采纳**（`reference_source_review.md` §7） |
| `XAli-SHX/...Avalon-Interface` | 7 | Sobel 的 Avalon-ST 接口写法（见 §5.2） |
| `Malinqing-work/FPGA-Image-Acquisition-Edge-Detection` | 4 | 8 方向 Sobel + `LineBuffer_3.v` |
| `BambooWhispering/FPGA-histogram_equalization` | 11 | `histogram_statistics.v` + `histogram_equalization.v` |
| `getlanced/FPGA-Otsu` | 14 | Otsu 自适应阈值 |
| `georgeyhere/FPGA-Video-Processing` | 44 | SystemVerilog，高斯 + Sobel |

### 4.2 许可干净 → 可移植，但要保留版权声明

| 仓库 | ★ | 许可 |
|---|---|---|
| `Floatkyun/Ultra-Vision` | 113 | MIT |
| `AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection` | 75 | MIT |
| `2268977258/binocular-stitching` | 24 | Apache-2.0（Ti60F225 + MT9M001 双目拼接） |
| `Passionate0424/CLAHE_verilog` | 21 | Apache-2.0 |
| `Efinix-Inc/xyloni` | 49 | MIT（官方板级参考） |
| `hdl-modules/hdl-modules` | 219 | BSD-3-Clause |
| `thai-kha/fpga-median-filter-soc-de2` | 1 | MIT |
| `47737/fpga-ti60f225-distortion-calibration` | 4 | MIT（同平台畸变校正） |

### 4.3 厂商 IP → 不可抄，只能当算法参考

`XAli-SHX` 仓库里混着一整套 Altera University Program 的 **Canny 四件套**：
`altera_up_edge_detection_gaussian_smoothing_filter.v`、
`..._sobel_operator.v`、`..._nonmaximum_suppression.v`、`..._hysteresis.v`，
以及 `altera_merlin_*`（互连）、`nios_system_*`（Nios II 系统）。
这些是 Intel 随 Quartus 发布的 IP，**不可移植（Efinity 上也没有对应原语）**。
价值仅在于：它是"Canny 五步怎么拆模块"的一份官方命名参考（见 §5.1）。

---

## 5. 真正值得动手的 2–3 条

### 5.1 Canny 最后一环 NMS：结构对照（不新增代码）

我们离 Canny 五步只差 NMS：高斯 ✅ / 梯度 ✅ / **NMS ❌** / 双阈值 ✅ / 迟滞 ✅
（`tuning_findings.md` §3）。GitHub 上两份可对照的实现：

| 来源 | 文件 | 结构 |
|---|---|---|
| `DOUDIU` | `canny_get_grandient.v` → `canny_nonLocalMaxValue.v` → `canny_doubleThreshold.v` | 三段流水：梯度把**方向量化 2 bit 打包进 `gra_path[15:14]`**，NMS 按该 2 bit 选 4 组邻居比较，再双阈值 |
| Altera UP（`XAli-SHX` 内） | `altera_up_edge_detection_nonmaximum_suppression.v` | 厂商版的同级实现 |

**一处交叉证据**：`DOUDIU` 的 `canny_get_grandient.v:20-21` 是
`THRESHOLD_LOW = 50` / `THRESHOLD_HIGH = 100`，**比例正好 1:2**；而我们
`rtl/edge_display_720p.v:240` 的强阈值是 `{1'b0, active_threshold, 1'b0}`，
也就是 `active_threshold × 2`。两条独立路径都落在 2×，说明这个比例不是拍脑袋。
（复核命令见 §7 的 `--file`。）

**结论：不新增 RTL。** NMS 已离线否决（`tuning_findings.md` §3：像素压到 1/3，
但连通域 431→1175、碎片 6→299，且与去碎斑互斥）。这份对照只用于答辩时说明
"我们知道 NMS 长什么样、为什么暂时不上"。

### 5.2 HDMI TX 交叉检查（值得做，成本低）

动机来自真实经历：TX 直连显示器能显示，中间加分配器 / 采集卡时曾不行。同一颗 Ti60F225
上，`Ultra-Vision`（MIT）与 `EricYXZ` 都用了同一套三件套
`rgb2dvi.v` + `tmds_channel.v` + `serdes_4b_10to1.v`。

**动作**：把它们的 `tmds_channel` / `serdes_4b_10to1` 与我们生成的 TX 逐行对齐
（重点是 OSERDES 位宽、4b/10b 或 10:1 串化、以及 common-mode / 预加重相关配置位）。
这是**只读对照**，不改我们已上板的 TX。

### 5.3 同平台写法对照（按需查阅，非必须）

`EricYXZ/ti60f225-image-processing-fpga`（无 license，只读）虽然只有 1★，但它是同芯片
同工具链的完整工程。文件数看着吓人（628 blob / 407 HDL），但**大部分是 IP 自动生成的
`*_tmpl.v` / `*_tmpl.vhd` 包装**，手写模块其实不多，值得记下名字的有：

| 模块 | 和我们比 |
|---|---|
| `RGB888_to_GRAY8_1280x720.v` | 和我们同样做 **720p** 灰度化 |
| `GRAY5x5_WEIGHTED_INTERNAL_FRAMEAVG_W8R8.v` + `Matrix_Generate_5X5_8Bit.v` | 5×5 加权（注意：`contrast_budget.md` 已量出**窗口放大到 5×5 会杀掉 1 像素线**，所以只对照不采用） |
| `contrast_enhance.v`、`auto_white_balance.v` | 对比度/白平衡——我们选了无帧缓存的 `tone_curve_lut.v` |
| `gaussian_filter_proc.v` | 和我们 `gauss3_720p.v` 同级 |
| `frame_rate_detector.v`、`Row_Line_Counter.v` | 给"无丢帧"补量化证据时可参照的思路 |
| `VIP_Matrix_Generate_3X3_8Bit.v` | **VIP 命名 → 与 CrazyBingo 系同源**，引用时注意（见 `reference_survey_provenance.md`） |

---

## 6. 明确不采用的（及理由）

| 方向 | GitHub 候选 | 不采用的理由 |
|---|---|---|
| CLAHE / 直方图均衡 | `Passionate0424/CLAHE_verilog`（Apache-2.0，16 / 64 tile 并行）、`BambooWhispering` | 需要 tile 内直方图 + 帧缓存，**破坏我们"算法链零帧缓存"的口径**。我们已有无帧缓存的 `tone_curve_lut.v`（`reference_source_review.md` §7.2） |
| Otsu 自适应阈值 | `getlanced/FPGA-Otsu` | 同上，需要整帧直方图；且 `otsu adaptive threshold fpga verilog` 关键词 **total=0** |
| 目标外接框 | `bounding box` 类搜索无可用 RTL | 自研（我们已有 ~1140 FF 的行/列投影方案，未上板验证） |
| 中值滤波 | `thai-kha`(MIT)、`HaNghia005`、`pratikprajapati1310` 等 | 我们已有**更强的证据**：`tools/verify_median_network.py` 在 4⁹ 穷举 + 40 万随机 + 459 万真实窗口上**全 0 失配**（`median_network.md`），这些只能用于交叉验证 |
| 整体替换 | —— | GitHub 上没有"Ti60F225 + 实时边缘检测"的完整开源工程；照抄没有对象 |

---

## 7. 复现

```powershell
# 15 组搜索 + 8 个仓库的 HDL 文件清单（约 2–5 分钟；未认证搜索有 10 次/分限制，
# 脚本自带退避重试）
python tools\github_survey.py --trees

# 单仓库详情：stars / 许可 / 默认分支 / 全部 HDL 模块名
python tools\github_survey.py --repo Floatkyun/Ultra-Vision

# 复核本文的具体断言（例如 DOUDIU 的双阈值比例）
python tools\github_survey.py --file "DOUDIU/Hardware-Implementation-of-the-Canny-Edge-Detection-Algorithm:1.RTL/source/canny_get_grandient.v"
```

中间产物全部落在 `work/gh/` 与 `work/github_survey.json`（`work/` 被 gitignore，不入库）。

---

## 8. 一条附带结论：参照视频的源码不在 GitHub

板子持有人给的参照视频（B 站 `BV1HYtg6BERZ`，UP：晓马哥FPGA，标题自称"开源"）
用的是 Ti60F225 + OV5640。我查了它的来源：

* `api.bilibili.com/x/web-interface/view?bvid=BV1HYtg6BERZ` 的简介**只有一句**：
  "加南极动物群：573664534 群文件下载"（QQ 群分发，不是公开仓库）；
* GitHub 用户搜索 `xiaomage fpga` **total=0**；
* `edge detection ov5640 verilog` 关键词 **total=0**。

所以**参照视频对应的源码无法通过公开仓库获得**，只能靠我们自己的量化分析
（`reference_video_analysis.md`）。这也正是本轮 GitHub 调研的价值所在：
能借的是同平台的工程写法，借不到"目标效果的那份实现"。
