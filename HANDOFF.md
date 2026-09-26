# 给队友及其 AI 助手的交接说明

请先读本目录的 `README.md`、`AGENTS.md` 和赛题 PDF 第 23–26 页，再修改 RTL。不要只凭聊天记录推测当前硬件状态。

## 一句话状态

Ti60F225I3 DemoBoard V4 + IMX219 2-lane MIPI → DDR → 720p HDMI 已出图。`main` 的灰度 + 3×3 Sobel 左右分屏经板上确认实时有效；`median-experiment` 中值滤波版只确认编译、时序和 JTAG 下载，**尚缺画面确认**。

分支 `py-algo-rtl`（2026-09-26）把赛题4 的边缘检测算法**完整移植**了 GitHub 仓库
[liuziyaoyao1210-sudo/FPGA-Python](https://github.com/liuziyaoyao1210-sudo/FPGA-Python)
的 Python 算法，并已通过编译与逐位对拍、JTAG 下载成功，**但肉眼画面仍未确认**。
该分支现在还提供**运行期调参**：PC 上跑 `tools/alg_tuner.py` 拖滑块，画面立即变化，
**不需要重新编译或烧录**（见 `docs/运行期调参.md`）。

## 分支 `py-algo-rtl` 当前状态（2026-09-26）

| 维度 | 状态 |
| --- | --- |
| 算法来源 | 仓库 `edge_pipeline.py`（快照在 `sim/algo/model/ref/`），未参考其它工程算法 |
| 算法链 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel(幅值+方向) → NMS → 双阈值滞后 → 去孤点 |
| RTL 模块 | `rtl/algo/` 11 个（`alg_gray/win/median3/gauss5/sobel3/nms/thresh/despeckle/stream_delay/vdisp/top`） |
| 逐位对拍 | ✅ 7 级 × 3 种模式全 0 mismatch；显示对齐 306 像素 0 mismatch |
| Python 溯源 | ✅ 仓库原 `edge_pipeline.py` ≡ 金标准模型，2 图 × 8 级 0 mismatch |
| 编译 | ✅ Efinity `map/interface/pnr/pgm` 全 PASS，全设计无负 slack，CDC 无警告 |
| 资源 | XLRs 22313/60800 (36.70%)，Memory Blocks **208/256 (81.25%)**（含串口通道后未增），DSP 4/160 |
| JTAG 下载 | ✅ **已完成**（2026-09-26，当前板内为 `algo_uart_tuner_splitonly_20260926_2037.bit`，来源提交 `0cf4f69`；JTAG ID `0x10660A79`；日志见 `docs/上板记录_2026-09-26.md`） |
| 运行期调参通道 | ✅ **真板实测**：串口命令 9/9 OK、GUI 端到端 PASS（`D0..D3` 等 9 个参数实时生效，无需重新烧录）。见 `docs/运行期调参.md` |
| 接口 | 复用板载 UART 115200 8N1：`o_uart_txd`=`GPIOR_28`/R14，`i_uart_rxd`=`GPIOL_02`/R4；主机端口 **COM5**（FT4232H ch.C） |
| 上板肉眼画面 | ❌ **未确认**（需看屏幕；观察清单见上板记录 §5） |

详细推导、延迟表、对齐原理、未 RTL 化清单见 `docs/ALGO_RTL.md`。

**未 RTL 化**（如实列出）：`temporal_blend`(TEMP，压帧间闪烁，优先级最高)、
`otsu_threshold`、`guided_filter`、`detect_shapes`/`draw_shapes`、
`color_edge_overlay` mode 2（按梯度方向着色）、`gaussian3x3`、`add_salt_pepper`。

**显示模式**：上电默认 **同视野左右分屏**（左半屏 = 灰度全画幅，
右半屏 = 边缘全画幅，2:1 水平抽取）。原先"每 128 帧轮换 0/1/2/3"的演示计数
已在 2026-09-26 按需求移除。`alg_vdisp` 里另外三种模式仍然保留，
现在**用串口发 `D0`..`D3` 就能切换**，不需要改代码重编译。

**调参链路**：`PC(tools/alg_tuner.py)` → USB 串口 → `uart_rx` → `alg_cfg_uart`
（寄存器组，CLK_25M 域）→ `alg_cfg_sync`（跨到像素时钟域）→ `alg_top` 的 `cfg_*`。
算法 RTL（`rtl/algo/*.v`）**一行未改**，只是参数来源从常量变成寄存器；
每个默认值都等于它替换掉的旧常量，**不插串口线时画面与旧版逐位一致**。

## 交接时最容易误解的点

- JTAG 日志 `finished with JTAG programming` 只表示下载成功，不证明图像处理正确。
- 已验证恢复位流：`known_good/edge_detect_720p_verified.bit`。原始 camera→HDMI 工程仍在板子持有人电脑的 `D:\FPGA_Project\imx219_hdmi_720p`。
- 当前左右分屏不是同一视野缩放并排，后续若要完善展示需明确像素重映射/缓存方案。
- 板上 `i_arstn` 对应复位；不能直接拿现有 SW0/复位键做实时阈值调整。
- **串口调参 9/9 OK 证明的是"参数确实进了 FPGA 并回读一致"，不等于"画面按预期变化"。**
  画面效果仍属肉眼观测项（`docs/上板记录_2026-09-26.md` §5）。
- 题面"实时阈值调节"字面要的是**板上按键 ± 含消抖**；当前是 PC 串口界面，
  功能等价但形式不同，严格评审可能仍算缺口。
- 摄像头小板 LED 与 HDMI 有图只能证明部分链路正常，算法效果需看屏幕或采集画面。
- 编译工具、USB 调试器、赛题 PDF 和厂商资料需在队友电脑另行配置；本仓库不包含工具安装包。

## 推荐任务划分

- 队员 A（有开发板）：保管已验证位流，负责硬件联调、实拍、最终合并与烧录。
- 队员 B：独立分支做算法 RTL/测试台/赛题证据表，提交变更和可重复的测试结果，由 A 上板验证。

## 可以直接给 AI 的启动提示

> 这是 Ti60F225I3 + IMX219 的 FPGA 赛题4 工程。先读取 README.md、HANDOFF.md、
> AGENTS.md、CONTEST_CHECKLIST.md、docs/ALGO_RTL.md 和赛题 PDF 相关页。
> `main` 已在板上验证灰度 + Sobel 左右分屏；`median-experiment` 只编译/JTAG 成功、
> 未做屏幕确认；`py-algo-rtl` 把 GitHub 仓库 FPGA-Python 的算法（含完整 Canny）
> 移植成 RTL 并完成逐位对拍与编译，JTAG 已下载，但**肉眼画面还没确认**。
> 参数可以在运行期用 `tools/alg_tuner.py` 通过板载 UART 调整（`docs/运行期调参.md`），
> 不需要重新编译或烧录。
> 算法唯一来源是 `edge_pipeline.py`，不要自行引入别的算法；opencv 里没有 Verilog 等价物的
> 操作才允许手写等价实现，并且必须在 `docs/ALGO_RTL.md` 里登记。
> 请先说明你准备处理的一个具体赛题条目，并在独立分支改动；不要覆盖 known_good 位流，
> 不要声称未观察到的硬件效果，不要自动烧录或上传公开仓库。
> 给出构建/时序/板上验证证据和回退方法。
