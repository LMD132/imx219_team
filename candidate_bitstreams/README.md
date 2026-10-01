# 候选位流归档记录

## 2026-10-01 当前形状识别候选（未通过旋转/倾斜识别验收）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_detect_2cb0932_20261001.bit` |
| 算法源码提交 | `2cb0932a3f93ca6bb57fc385b6ed023ea5486137`，分支 `shape-detect`，目录 `D:\FPGA_Project\imx219_shape` |
| 来源 | 本目录现存 `outflow/ti60f225_oob.bit` 的逐字节副本；本次归档没有重新编译 |
| 现存构建时间 | 2026-10-01 01:00:32（文件时间及现存 `compile.log`） |
| 字节数 | 2794899 |
| SHA-256 | `C9DB772BA8853C1F17FFDEE06C116759F854D7ACAEB8CF0A39BD9B2B76CEFEBD` |
| 编译证据 | 检查现存日志：map / interface / pnr / pgm 均 PASS；日志另有 `cannot find correct IV value` 警告。本轮未重编译，不将旧日志当作新验证 |
| 资源证据 | 现存 `ti60f225_oob.place.rpt`：Memory Blocks 243/256，DSP Blocks 46/160 |
| 上板/效果 | 关联聊天此前记录过此源码版的 JTAG 下载；本轮没有烧录，也不保证当前板内仍运行此版。用户2026-10-01反馈纸张未端正摆放会误识别，**效果验收未通过** |
| 本日诊断 | 复跑 `tb_shp_rot.v`：40°和45°方形被判十字，FIFO溢出0；测试 `errors=0` 不等于形状分类正确 |
| 版本地位 | 仅候选；最佳回退仍是 `imx219_notemp` 中 `known_good/best_epf_guided_99540aa_20260928.bit`。不得因编译或下载成功自动替换 |

以下是早期归档的历史记录；其中“当前版”“板上运行”等措辞仅对应各自记录日期。

规则（见 `AGENTS.md`）：

- 候选位流只放本目录，并记录**来源提交、SHA-256、上板状态**。
- 只有**肉眼验证通过**的恢复位流才能进 `known_good/`；不要用实验位流覆盖已验证基线。
- `outflow/` 被 Git 忽略，**切分支不会切换位流**；下载前必须重新编译，或明确选择本目录里已记录的位流。

烧录命令（本机已封装，含 `PYTHONHOME` / `EFINITY_USER_DIR` 两个环境坑的处理）：

```bat
cd /d D:\FPGA_Project\imx219_pyrtl
tools\flash_candidate.bat candidate_bitstreams\<位流文件>
```

---

## -1. `brg_canny_smooth_78779c7_20260928.bit` —— 断线桥接版 = **冻结"最新版"的位流**（2026-09-28 晚）

| 项 | 值 |
| --- | --- |
| 来源提交 | `78779c7`（分支 `canny-smooth`，基于 `a390a99`） |
| 编译时间 | 2026-09-28 18:29:55（在 `imx219_smooth` 内编译，`outflow/compile.log`：map/interface/pnr/pgm 全 PASS） |
| 字节数 | 2548746 |
| SHA-256 | `09A44591609D17C25A70A32DCAD7BC04136531DA5FF9719E4611A6719ABB642F` |
| **上板状态** | ⚠️ **已烧录，肉眼效果待板主确认**。2026-09-28 19:14 用 `tools\flash_candidate.bat` 烧进板子（JTAG ID `0x10660A79`，日志 `finished with JTAG programming`），串口回读状态行为 `M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 **BRG2** CAM0000=FF`，确认板上跑的就是这一版。**但 BRG 在屏幕上的实际观感还没得到板主回答**，所以只算"最新"，不算"最佳"。 |
| 冻结 | 2026-09-28 晚板主指令：这一版固定为**最新版本**，后续改动一律先备份 + 复制新目录再改；位流**暂不进 `known_good/`**（本目录规矩：只有肉眼验证通过的才进）。一键重烧：`D:\FPGA_Project\烧录最新版.bat` |
| 内容 | 与回退版同链，新增 **断线桥接 `alg_ebridge`**（命令 `B0..B3`，默认 B2）与精确深度行缓存 `alg_ring_ram`；`ROWD` 11→14、`L` 51→55；遥测行 77→82 字节 |
| 时序 | `hdmi_tx_slow_clk` setup **+4.774 ns**；`core_clk`（100 MHz）setup **+4.582 ns**；全设计最小 setup **+0.454 ns**、0 条负 slack |
| 资源 | XLRs 28809/60800 (47.4%)、**Memory Blocks 242/256 (94.5%)**、LUT 16157 / FF 12201、DSP 36/160 |
| 对拍 | `check_ebridge.py` K=0/1/2/3 全 0 mismatch；`check_chain.py` 含 BRG=0/1/3 三档 + 显示逐像素 `RESULT: PASS` |
| 回退 | 效果不满意就直接烧 `rollback_epf_guided_99540aa_20260928.bit`（`tools\flash_best.bat` / `烧录最佳版.bat`），本目录的 `imx219_smooth` 可继续改 |


## 0. `rollback_epf_guided_99540aa_20260928.bit` —— 回退版（2026-09-28 晚起为板上运行版本）

> 取代下面第 1 节：TEMP 时域降噪版上板实测不合格后，按板主指示回退到加 TEMP 之前的版本。

| 项 | 值 |
| --- | --- |
| 来源提交 | `99540aa1413c9eadb28f3b74e2f6e1f9fb78cd61`（分支 `epf-guided`，即 `temp-blend` 的父提交） |
| 编译时间 | 2026-09-28 02:15:29（在 `imx219_gf` 内编译，`outflow/compile_gf.log`：map/interface/pnr/pgm 全 PASS） |
| 字节数 | 2540034 |
| SHA-256 | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |
| 显示模式 | 固定 mode 0 = 同视野左右分屏（运行期 `D0..D3` 可切换） |
| **上板状态** | ✅ 2026-09-28 晚 JTAG 重新烧录成功（回退 TEMP 后），JTAG ID `0x10660A79` |
| 内容 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel → NMS → 双阈值 → 去孤点 → 显示；含导向滤波(EPF)参数 P，**不含 TEMP 时域降噪** |
| 背景 | TEMP 版（`temp-blend`，`405701f`/`b4e4dcf`）被判不合格：无效果且更差（拖影）。原因见 imx219_temp 根目录 不合格_已废弃_TEMP时域降噪_20260928.md |


## 1. `algo_uart_tuner_splitonly_20260926_2037.bit` —— **当前版**（算法全链 + 固定左右分屏 + 运行期串口调参）

| 项 | 值 |
| --- | --- |
| 来源提交 | `0cf4f6962760856742bc0eac7cf17a4ea8b2fd26`（分支 `py-algo-rtl`） |
| 编译时间 | 2026-09-26 20:36:52 |
| 字节数 | 2434185 |
| SHA-256 | `4F9D7D387627031A0D8F1AC6F4B0AE5AB1CC94D716D6238D8ADBCB51ECC3EB05` |
| 工具 | Efinity 2026.1.132.4.5 |
| 流程结果 | `map` PASS、`interface` PASS、`pnr` PASS、`pgm` PASS |
| 时序 | `hdmi_tx_slow_clk` setup **+5.360 ns** / hold **+0.026 ns**；全设计无负 slack；最大可分析频率 **123.335 MHz**（约束 74.25 MHz） |
| 资源 | XLRs 22313/60800 (36.70%)、Memory Blocks 208/256 (81.25%)、DSP 4/160 |
| CDC | `No Synchronizer warnings to report` |
| 显示模式 | **固定 mode 0** = 同视野左右分屏。可用串口命令 `D0..D3` 在运行期切换，不需要重新编译 |
| 调参通道 | 板载 UART 115200 8N1（`o_uart_txd`→`GPIOR_28`/R14，`i_uart_rxd`→`GPIOL_02`/R4），PC 端 `tools/alg_tuner.py` |
| **上板状态** | ✅ **JTAG 下载成功**（JTAG ID `0x10660A79`）；✅ **串口通道上板实测 9/9 OK**；✅ **GUI 真板端到端 PASS**；❌ **肉眼画面仍未确认** |
| 内容 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel(幅值+方向) → NMS → 双阈值滞后(58/21) → 去孤点 → 显示 |
| 已验证程度 | RTL + 仿真逐位对拍 + 编译/时序通过 + **JTAG 下载 + 串口链路真板实测**（**不含**肉眼画面） |

与上一版（`..._2019.bit`）的**唯一**差别是参数来源：这一版 `alg_top` 的 `cfg_*`
由 UART 寄存器组驱动，上一版接的是常量。算法 RTL 一行未改，**每个默认值都等于它
替换掉的那个常量**，所以不插串口线时画面与上一版逐位一致。

协议表、GUI 用法与实测记录见 [`../docs/运行期调参.md`](../docs/运行期调参.md)。

## 2. `algo_canny_splitonly_20260926_2019.bit` —— 上一版（固定左右分屏，**已被上面那份取代**）

| 项 | 值 |
| --- | --- |
| 来源提交 | `56867bb43c75c094fa14dd37612a64f82174a14b`（分支 `py-algo-rtl`） |
| 编译时间 | 2026-09-26 20:19:14 |
| 字节数 | 2420499 |
| SHA-256 | `A7234BB845C8E067BA2ABADBE45BF832B3A6BF580D77ECDC938CFC1317A7B1B7` |
| 工具 | Efinity 2026.1.132.4.5 |
| 流程结果 | `map` PASS、`interface` PASS、`pnr` PASS、`pgm` PASS |
| 时序 | `hdmi_tx_slow_clk` setup **+4.843 ns** / hold **+0.031 ns**；全设计无负 slack；该时钟最大可分析频率 115.942 MHz（约束 74.25 MHz） |
| 资源 | XLRs 21351/60800 (35.12%)、Memory Blocks 208/256 (81.25%)、DSP 4/160 |
| 显示模式 | **固定 mode 0** = 同视野左右分屏（左半屏灰度全画幅 / 右半屏边缘全画幅，2:1 水平抽取）。**不再轮换** |
| **上板状态** | ✅ JTAG 下载成功（2026-09-26 20:2x，JTAG ID `0x10660A79`）；❌ 肉眼画面未确认。**已被上面 `..._2037.bit` 取代** |
| 内容 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel(幅值+方向) → NMS → 双阈值滞后(58/21) → 去孤点 → 显示 |
| 已验证程度 | RTL 实现 + 仿真逐位对拍 + 编译/时序通过 + **JTAG 下载**（**不含**肉眼画面） |

算法来源、逐级映射与对拍数据见 `docs/ALGO_RTL.md`。

## 3. `algo_canny_full_20260926_1954.bit` —— 更早（含模式轮换，已被取代）

| 项 | 值 |
| --- | --- |
| 来源提交 | `4fcc6dbef0bce2090ab934cc1ab13f63c84f6c51` |
| 编译时间 | 2026-09-26 19:54:52 |
| 字节数 | 2422623 |
| SHA-256 | `0B1354A8C08C544B40801815378BCD93DB604210A1BC1CC805BE2592CC0AED89` |
| 时序 | `hdmi_tx_slow_clk` setup +5.316 ns / hold +0.031 ns |
| 资源 | XLRs 21593/60800 (35.51%)、Memory Blocks 208/256、DSP 4/160 |
| 显示模式 | 每 128 帧轮换 0/1/2/3（**已按需求移除**） |
| **上板状态** | ✅ JTAG 下载成功（2026-09-26 19:5x）；❌ 肉眼画面未确认 |

与当前版的唯一差别就是显示模式：算法链、参数、链路完全相同。
保留它是因为"JTAG 下载成功"这条证据最早记在它身上，便于对照。

## 4. `pre_algo_edge_display_720p_20260926_1728.bit` —— 移植前的旧基线

| 项 | 值 |
| --- | --- |
| 用途 | 算法移植**之前**的 `edge_display_720p`（灰度 + Sobel）位流，作为对照/回退参考 |
| 编译时间 | 2026-09-26 17:28:52 |
| 字节数 | 2333919 |
| SHA-256 | `140E575936B2222E8AAC808A7E7827CED124638A19106A38B3E0260C1A1B2F6A` |
| **上板状态** | ❌ 未下载、未上板确认 |

> 它与 `known_good/edge_detect_720p_verified.bit` 同源思路但**不是**同一份文件，
> 请勿与已验证恢复位流混淆。

## 5. `known_good/edge_detect_720p_verified.bit`（不在本目录，仅列出以便对照）

| 项 | 值 |
| --- | --- |
| 状态 | ✅ **已在板上肉眼验证**（左半灰度 / 右半 Sobel 黑白边缘，实时变化） |
| 字节数 | 2333919 |
| SHA-256 | `146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355` |

任何时候需要"至少能看到画面"，用这一份。

---

## 6. `known_good/best_epf_guided_99540aa_20260928.bit` —— 当前最佳版（回退基线）

| 项 | 值 |
| --- | --- |
| 位流 | 与第 0 节 `rollback_epf_guided_99540aa_20260928.bit` 同一份文件（SHA-256 相同），复制进 `known_good/` 便于需要回退时直接取用 |
| 来源提交 | `99540aa`（分支 `epf-guided`，即 `no-temp` 的基线提交） |
| 字节数 | 2540034 |
| SHA-256 | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |
| **状态** | ✅ 板主 2026-09-28 认定：**当前最佳版本**，作为后续改动的回退基线；板上正在运行的就是这一份 |
| 回退用法 | `tools\flash_best.bat`（等价于 `tools\flash_candidate.bat known_good\best_epf_guided_99540aa_20260928.bit`），烧录前先关掉调参界面 |


## 哈希校验

在仓库根目录执行：

```powershell
Get-ChildItem candidate_bitstreams,known_good -Filter *.bit -Recurse |
  ForEach-Object { "{0}  {1}  {2}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Length, $_.FullName }
```

期望值（2026-09-26 实测）：

| 文件 | SHA-256 |
| --- | --- |
| `candidate_bitstreams/algo_uart_tuner_splitonly_20260926_2037.bit` | `4F9D7D387627031A0D8F1AC6F4B0AE5AB1CC94D716D6238D8ADBCB51ECC3EB05` |
| `candidate_bitstreams/algo_canny_splitonly_20260926_2019.bit` | `A7234BB845C8E067BA2ABADBE45BF832B3A6BF580D77ECDC938CFC1317A7B1B7` |
| `candidate_bitstreams/algo_canny_full_20260926_1954.bit` | `0B1354A8C08C544B40801815378BCD93DB604210A1BC1CC805BE2592CC0AED89` |
| `candidate_bitstreams/pre_algo_edge_display_720p_20260926_1728.bit` | `140E575936B2222E8AAC808A7E7827CED124638A19106A38B3E0260C1A1B2F6A` |
| `known_good/edge_detect_720p_verified.bit` | `146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355` |
| `candidate_bitstreams/rollback_epf_guided_99540aa_20260928.bit` | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |
| `known_good/best_epf_guided_99540aa_20260928.bit` | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |

## 归档说明

- 2026-09-26 19:49 曾归档过一份候选位流（`..._1949.bit`），随后修正了
  `alg_top.v` / `alg_stream_delay.v` 的**注释**（旧的 `alg_disp`/`DLY_RGB` 描述）并重编译。
  综合结果与时序/资源完全相同（注释不影响网表），但为了让"入库源码"与"归档位流"
  严格一一对应，已删除 1949 那份，改为归档 1954 那份。
- 归档位流对应的源码提交必须能在 `git log` 里找到；提交信息里注明证据等级。
- **每次改动 RTL 后都要重新编译并归档**，因为位流与源码必须一一对应；
  同时旧位流要标明是否已被取代。
