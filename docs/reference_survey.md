# 外部参考资料盘点与可借鉴清单

记录日期：2026-09-24 ｜ 来源：`D:\FPGA边缘化参考\`（板子持有人提供 9 份资料）

本文只记录**思路**，不转载任何第三方源码。所有拟采用的算法都必须在本仓库
用自研 RTL 重写（见文末「版权红线」）。

---

## 1. 资料清单与一句话价值

| # | 目录 | 平台 | 对本项目的价值 |
|---|---|---|---|
| 1 | `【源码】基于FPGA的灰度直方图均衡算法案例_Saylinx301开发板_Quartusii18.1` | Altera | ★★★ **直方图均衡**逐帧 LUT 重映射，正面解决"暗处轮廓少" |
| 2 | `【源码】基于FPGA的帧差法运动目标检测_DMK301开发板` | Altera | ★★ 帧差二值化 + 外接矩形框 |
| 3 | `【源码】基于FPGA的帧差法运动目标检测_Saylinx301开发板_Quartsuii18.1` | Altera | ★★ 同上，乒乓帧缓存写法 |
| 4 | `【源码】基于易灵思FPGA的火灾检测系统（内含图像缩放源码）` | **Efinity / Ti60F225** | ★★★ 同芯片同工具链：纯 Verilog Avalon-ST scaler、对比度增强、帧长统计 |
| 5 | `【源码】中值滤波和均值滤波` | Altera | ★ 3×3 中值的另一种排序写法（本项目已自研实现） |
| 6 | `【资料】基于VIP_Board Big的FPGA入门进阶及图像处理算法开发教程-V3.X.pdf` | 教程 | ★★ 算法讲解与流水线拆解思路 |
| 7 | `【源码】 Modelsim仿真图像处理算法（Sobel边缘检测）` | — | ⚠ 目录内只有 `.rar`，未解压；价值低，暂不处理 |
| 8 | `【源码】sobel边缘检测` | Altera | ★ 3×3 窗口生成（移位寄存器法） |
| 9 | `【源码】基于FPGA的肤色检测人脸识别_小梅哥AC620开发板` | Altera | ★★ YCbCr 判据 + 1bit 图求外接框 + 数码管显示阈值 |

---

## 2. 可借鉴清单（按优先级）

### P0 — 直方图均衡：治"暗处轮廓少"最治本的一招

**问题**：现版本 Sobel 对暗目标（人）几乎出不来边缘，对高亮目标（手机屏）
边缘很干净。根因是**暗区只占了 8bit 灰度的一小段**，`|Gx|+|Gy|` 的差分值
天然很小，固定阈值一卡就没了。

**参考方案（`hist_equ_top.v` 体系，Avalon-ST 流式，逐帧一 LUT）**：

| 阶段 | 模块 | 做法 |
|---|---|---|
| 统计 | `hist_equ_static` | 逐像素对 256×19bit RAM 自增（19bit 覆盖 640×480=307200） |
| 累加+映射 | `hist_equ_cumulate` | `remap = cumulate * 255 / (W*H)`，乘/除各 4 拍流水 |
| 重映射 | `hist_equ_remap_ram` | 256×8 LUT，读地址 = 当前像素 |
| 掩盖延迟 | `hist_equ_scfifo` + `hist_equ_fifo2st` | **FIFO 扇出掩盖 LUT 流水延迟** |

**关键时序**：统计整帧 → 场消隐期算 LUT → 下一帧才用新 LUT，即**延迟 1 帧**。

**移植注意**：
- 乘法/除法要用移位近似（256 项，可用 `>>8` 的倒数表或分级近似），
  Efinity 上没有免费的 LPM_DIVIDE。
- 本项目若做，建议**只在灰度通路上做均衡**，然后 Sobel 吃均衡后的灰度，
  而不是去改显示亮度。
- 延迟 1 帧与题面"实时"表述的关系，需要先想清楚演示口径（与 DDR 帧缓存同问题）。

### P0 — 数字对比度增强 `vip_contrast.v`（均衡的轻量替代）

`Gout = k * (Gin - Gavr) + Gavr`，`Gavr` = **上一帧**均值，`k` 为 Q5.3 定点系数。

**优点**：只需一个帧均值累加器 + 一个乘法器，远比直方图均衡省资源，
效果上同样能拉开暗部。**适合先做这一版试探观感**，好了再升级到真均衡。

### P1 — 按键调阈值（赛题高阶 ②）

参考 `key_debounce.v` 思路（正点原子版）：
- 32 位递减计数到 20 ms（50 MHz 装 1000000），计满才把 `key` 采样进 `key_value`；
- `delay_cnt == 1` 时输出 `key_flag` 单脉冲；
- 下降沿用两级同步 + `flag = ~r1 & r2`。

本项目引脚（已确认）：KEY1=`GPIOR_22`(P14)、KEY2=`GPIOR_21`(N14)、
KEY3=`GPIOL_03`(A3)；KEY0=`GPIOL_07`(C4) 已被 `i_arstn` 占用，不可用。

**改动点**：`EDGE_THRESHOLD` 目前是 `edge_display_720p.v` 的 parameter，
顶层以 `.EDGE_THRESHOLD(11'd24)` 例化（`rtl/ti60f225_oob_top.v:852`）。
要运行时可调，必须改成**输入端口**，由按键状态机驱动。

### P1 — 目标外接框（赛题高阶 ⑥ 的两条现成思路）

两份参考逻辑几乎一致，都是**逐帧求 1bit 图的外接矩形**：
- `find_box.v`（帧差法）：`edg_up/down/left/right` 在 `vsync` 上升沿复位，
  像素为 1 时更新最值，再叠加画框输出。
- `Face_Posion.v`（肤色检测）：同样的 `x_min/x_max/y_min/y_max` 思路。

**用途**：对 1bit 边缘图求外接框 → 画框输出，即可演示"简易目标识别"。
本项目已有 1bit 边缘图，接一个外接框统计模块成本很低。

### P1 — 3×3 窗口的移位寄存器写法（省资源）

`VIP_Matrix_Generate_3X3_8Bit.v`：`{p11,p12,p13} <= {p12,p13,row1_data}`，
三行移位寄存器同时推进，`matrix_p22` 即窗口中心。

本项目当前是 line buffer + 9 级寄存器；移位寄存器写法更省。**属可选优化，
不影响正确性，暂不动已上板基线。**

### P2 — 腐蚀去噪（治"暗区冒噪点"）

`ViP_Bit_Erosion_Detector.v`：1bit 图 3×3 腐蚀 = 9 输入与；膨胀 = 9 输入或。

若提高阈值后暗区出现零星白点，先腐蚀一个 3×3 即可消掉孤立噪点。

### P2 — 帧长/帧率在线统计（`st_frame_pix_cnt.v`）

统计 `sop..eop` 之间 `valid` 拍数，输出 `pix_cnt_cur/last/min/max`、
`frame_cnt`、`frame_done`，带 `syn_preserve` 便于 Efinity Debugger 抓取。

**用途**：给"无丢帧、无错位"这条基础要求补上**量化证据**（期望 921600/帧）。
这个文件是纯 Verilog、无厂商 IP，思路可直接照搬重写。

### P2 — 灰度直方图 / 测试图发生器

`frame_test_gen.v`、`gray_bar_gen.v`：内部测试图案源（含 `FRAME_SRC_PATTERN`
开关式设计）。**用途**：不接摄像头也能验证 HDMI 通路与算法，
对拍演示视频很有用。

### 参考 — UART 遥测（已完成，无需再抄）

本仓库 `rtl/uart_tx.v` + `rtl/uart_status_tx.v` 已自研完成并上板验证
（COM5 @115200，`TI60 UART OK`）。厂商 demo（`17_Ti60F225_uart_demo`）仅供对照。

---

## 3. 版权红线（必须遵守）

以下代码**只可读、不可复制入库**：

| 来源 | 标记 |
|---|---|
| CrazyBingo 系：`Median_Filter_3X3.v`、`Sort3.v`、`Sorted3.v`、`VIP_Gray_Median_Filter.v`、`VIP_Gray_Mean_Filter.v`、`ViP_Bit_Erosion_Detector.v`、`VIP_Bit_Dilation_Detector.v`、`VIP_Sobel_Edge_Detector.v`、`VIP_Matrix_Generate_3X3_8Bit.v`、`rgb2ycbcr.v` | 文件头 **"CONFIDENTIAL IN CONFIDENCE / 需授权"** |
| 正点原子 `key_debounce.v` | "版权所有 盗版必究" |
| 周立功 / Intel `LPM_MULT`、`LPM_DIVIDE` | 无法移植到 Efinity |
| 火灾检测 `vip_*` | Intel VIP 派生 |

**统一原则：只学思路，自己重写。**

（注：火灾检测项目里的 `vip_scaler.v` / `vip_contrast.v` 文件头是自研说明，
纯 Verilog-2001、不依赖厂商 IP，参考价值较高，但仍按"重写"处理。）

---

## 4. 建议实施顺序

1. **按键实时调阈值 + UART 数字遥测**（赛题高阶 ②，UART 通道已通，
   改动集中在顶层端口 + 一个按键状态机）。
2. **3×3 腐蚀**（治暗区噪点，与 ① 配套验收）。
3. **目标外接框**（赛题高阶 ⑥，成本低、演示效果好）。
4. **对比度增强 `k*(Gin-Gavr)+Gavr`**（先试轻量版，看观感）。
5. **直方图均衡**（若第 4 步观感仍不足再上，资源与时序代价最高）。

## 5. 待补证据（与参考资料无关，但一直挂着）

- 自适应阈值版（`median_adaptive.bit` / 当前板上的 `uart_banner.bit`）的
  **肉眼观感反馈**尚未收集：暗处轮廓回来没有？亮处边缘还清楚吗？暗区有无噪点？
- "无丢帧无错位"缺量化证据 → 用第 2 节的 `st_frame_pix_cnt` 思路补。
