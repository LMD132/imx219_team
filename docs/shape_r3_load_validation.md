# R3 负载诊断验证记录

本记录属于 `shape-detect` 候选版；代码路径验证、JTAG 下载和当前 COM5 读数均不等于实板肉眼／识别验收。2026-10-02 已经板主同意完成 JTAG 临时下载；未写 Flash，不改变 `known_good/`。

## Task 1：事件计数器

- 改前快照：`D:\FPGA_Project\_backups\20261001_221304_pre-shape-r3-load-task1`；`verify_backup.ps1` 输出 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 红：`python sim/algo/model/check_shape.py --rtl tb_shp_load_counts` 与 `--rtl tb_shp_clutter` 均退出 1；旧 `shp_detect` 缺少 `o_slot_drop_total` 和 `o_fifo_full_total`，Icarus 对每台报告 4 个 elaboration errors。
- 绿：两台在新增端口与逐事件计数后均返回 `SHAPE_TEST_PASS`。`tb_shp_load_counts` 包含 VS/游程同拍但 FIFO 不满、FIFO 满、形状开关与硬件复位；记录 `S=1 Q=45 VS_NONFULL=1 OV=47`，复位后两计数为零。`tb_shp_clutter` 保留原 `R1` 识别断言，记录 `slot_drops=199 fifo_drops=0 reason=1 ovf=199`，并确认新计数相符。
- 当前仅覆盖离线 RTL 仿真；尚未跨时钟、串口、GUI、综合或实板验证。

## Task 2：完整 720p R3 压力场景

- 改前快照：`D:\FPGA_Project\_backups\20261001_222244_pre-shape-r3-load-task2`，已显示 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 红：生产参数 `NB=8,FQ=24`、1280×720 有效区/1650×750 总时序，沿用八噪声场景；监视器给出 `S=199/199 Q=0/0 bad_marker=0/0 lost=0 pending=1 maxQ=23 CNT=0 F=1 R=1 OV=199`，精确 `R3` 门禁报错，退出码 1。
- 绿：仅在测试刺激加入 y=100 的密集交替游程后，同一测试连续两次通过。每次监视器均为 `S=199/199 Q=369/369 bad_marker=1/1 lost=0 pending=1 maxQ=24 CNT=0 F=1 R=3 OV=568`；分子为新 RTL 计数，分母为独立逐拍监视器。最终帧边界被成功入队、读出，且无边界丢弃。该台已纳入 `check_shape.py --all`。
- 总门禁：`python sim/algo/model/check_shape.py --all` 退出码 0，结尾 `ALL PASS`，其中包含 `SHAPE_TEST_PASS tb_shp_r3_pressure exact R3` 与原 `tb_shp_clutter` 的 `R1` 回归。
- 这只证明 `R3` 路径可离线复现，不证明实板 `R3` 由 FIFO 满引起；实板仍须比较连续 `S/Q` 增量。

## Task 3：96 位跨时钟快照

- 改前快照：`D:\FPGA_Project\_backups\20261001_225643_pre-shape-r3-load-task3`，验证结果为 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 红：扩展测试接入四个新端口后，旧 CDC 缺少端口，`tb_shape_diag_cdc` elaboration 报 8 处错误，退出码 1。
- 绿：`tb_shape_diag_cdc` 以 7 ns/11 ns 半周期异相时钟交替输入两组完整 96 位元组；20 次请求、忙时脉冲、两侧空闲及事务中复位均通过，退出码 0、`SHAPE_TEST_PASS`。既有 `tb_shp_load_counts` 与 `tb_shp_r3_pressure` 再跑均通过，后一台仍是 `S=199 Q=369 F1 R3`。
- 本任务只把两个计数接入顶层的像素域与 25 MHz 域；尚未发送 UART 后缀。

## Task 4：148 字节状态行

- 改前快照：`D:\FPGA_Project\_backups\20261001_230035_pre-shape-r3-load-task4`，验证结果为 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 红：`tb_alg_tel_shp` 因旧遥测 RTL 缺少 `i_diag_slot_drop_total/i_diag_fifo_full_total` 等报 7 处 elaboration 错误；`tb_alg_cfg_uart` 同理报 4 处，两者均退出码 1。
- 绿：`tb_alg_tel_shp` 21 项检查通过，旧可见前缀保持、`F?` 与 `OVFFFF` 行保留新后缀、发送中变动计数不撕裂，后续行整组变为 `S89ABCDEF Q01234567`；`tb_alg_cfg_uart` 68 项检查通过，旧命令回读和 `S00000000 Q00000000` 后缀正常。两台均退出码 0，输出 `SHAPE_TEST_PASS`。
- 状态行现在固定 148 字节（含索引 147 的唯一 LF）；`0..126` 与旧格式一致，`127..146` 为 ` Sxxxxxxxx Qxxxxxxxx`。

## Task 5：调参界面只读显示

- 改前快照：`D:\FPGA_Project\_backups\20261001_230552_pre-shape-r3-load-task5`，验证结果为 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 红：`python tools/smoke_alg_tuner.py` 在新行 `S/Q` 解析断言处失败，旧正则尚不接受 148 字节行，退出码 1。
- 绿：相同冒烟测试退出码 0，结尾 `SMOKE OK`。验证旧四元组接口、新二元组解析、旧/残缺行与 `F?` 隐藏计数、5 秒内差分、超过 5 秒及计数下降不显示虚假增量、断线重连后不沿用旧基准；原滑块与命令检查保持通过。
- 此项是离线 Tk/假串口测试，**不是** COM5 实机通信或屏幕肉眼验收。

## Task 6：完整回归、构建与归档

- 改前快照：`D:\FPGA_Project\_backups\20261001_231021_pre-shape-r3-load-task6`，已验证 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 构建源码提交：`72380a3e177d7ef3cceaf6ae5cadb08c752e3c8d`；构建前工作区干净。Efinity 只去掉 `ti60f225_oob.xml` 末尾换行，归档前恢复；没有改变有效 RTL、SDC 或工程参数。

| 命令 | 退出码与证据 |
| --- | --- |
| `python sim/algo/model/check_shape.py --all` | 0，`ALL PASS`：23 项 Python、10,381 组几何、17 个形状 RTL 台；含 `tb_shp_clutter` 的 R1 与 `tb_shp_r3_pressure exact R3` |
| `python sim/algo/model/check_chain.py` | 配置 `ALG_OSS_BIN=C:\iverilog\bin` 后退出 0，`RESULT: PASS`，逐级像素对拍无差异 |
| `python sim/algo/model/check_ebridge.py` | 同上工具目录，退出 0，`RESULT: PASS`，全部六组桥接/模式对拍 mismatch 0 |
| `python sim/algo/model/check_shape.py --rtl tb_shape_diag_cdc` | 0，`SHAPE_TEST_PASS`，20 组异步元组与独立复位 |
| `python sim/algo/model/check_shape.py --rtl tb_alg_tel_shp` | 0，`SHAPE_TEST_PASS`，21 项 |
| `python sim/algo/model/check_shape.py --rtl tb_alg_cfg_uart` | 0，`SHAPE_TEST_PASS`，68 项 |
| `python tools/smoke_alg_tuner.py` | 0，`SMOKE OK` |
| `tools\compile.bat` | 0；`outflow/compile.log` 的 map/interface/pnr/pgm 均 PASS |

主链与桥接首次启动时因未配置 `ALG_OSS_BIN`、PATH 中找不到 `iverilog` 而退出 1；指定已有的 `C:\iverilog\bin` 后重跑通过，未因此修改产品代码。

- 最终 Efinity 时序报告时间 2026-10-01 23:37:45，版本 `2026.1.132.4.5`：19 组 setup 和 19 组 hold 关系均非负，最小分别 `+0.091/+0.028 ns`；全部 342 条报告路径 slack 非负。工具保留 IV 值与组合环计时警告，以上是报告所列路径的结果，不能扩大为全设计无条件签核。
- `outflow/ti60f225_oob.place.rpt` 资源：XLR `54798/60800`（90.13%）、RAM `251/256`（98.05%）、DSP `154/160`（96.25%），均未超容量。
- 本次 `outflow/ti60f225_oob.map.v` 明确包含像素域及 UART 域两个计数器的 bit 31 寄存器，及 `u_shape_diag_cdc/held_tuple[95:0]`，确认完整新计数链进入综合。
- 23:37:50 生成位流，归档为 `candidate_bitstreams/shape_r3_load_72380a3_20261001.bit`，3,116,013 字节；归档与原输出 SHA-256 均为 `C671A57EB3E87502DA1C428ED50C416CB3B9C66902854E18B98AA0D0689C3211`。
- **构建归档当时未上板**：2026-10-01 本轮构建归档未执行 JTAG/Flash，也未做 COM5 实机或画面验收，`known_good/` 与最佳回退版未修改。后续 JTAG 下载记录见下节。

## 2026-10-02 JTAG 临时下载

- 板主明确同意下载 `candidate_bitstreams/shape_r3_load_72380a3_20261001.bit`；归档位流的 SHA-256 核对为 `C671A57EB3E87502DA1C428ED50C416CB3B9C66902854E18B98AA0D0689C3211`。
- 实际运行 `tools/flash_candidate.bat`，命令退出码 0。日志显示 `jtag programming started!`、`Programming 'candidate_bitstreams\shape_r3_load_72380a3_20261001.bit' via JTAG at freq 6.0 MHz`、`Device ID read from JTAG: 0x10660A79`，并以 `finished with JTAG programming` 结束。
- JTAG 后调参界面重新连接 COM5，显示“已连接，板端与滑块一致”。板端读数为负载计数 `S 0000217C (+0)`、`Q 0001AAB7 (+0)`，形状诊断 `CNT 000`、`OV FFFF`、`F0`、`R0`；约 25 秒后复查，`S/Q` 仍为 `+0`，`F0/R0` 未变。该次界面记录的参数为 `M2 T24 L21 H58 E0 P2 F400 N1 G0 I1 B2 D0 C1 S1 Y24 Z875 W4 A50`。
- **未写 Flash，未做屏幕肉眼或形状识别效果验收**。当前摄像头场景未知；这组 COM5 读数不能判定 A4 图形识别，也不能据此认定实拍 `R3` 根因或漏检已修复，或把此候选提升为最佳回退版。

## 后续实板读数的解释

在同一阈值、固定纸张场景下比较连续新状态行，并留出数行等待快照稳定。`S/Q` 是累计模计数，`CNT/F/R` 是最近提交帧，两者不是严格同帧事件统计；界面超过 5 秒、断线重连或计数下降会暂停增量。

- `ΔS>0、ΔQ>0`：支持槽位耗尽与 FIFO 满丢游程同时发生。
- `ΔS>0、ΔQ=0` 且仍为 `R3`：检查 VS 同拍、待处理边界或重同步；不能把 R3 直接等同 FIFO 满。
- 两者增量都为 0：先排除采样滞后，再检查其他坏帧来源。

离线的 `S=199 Q=369 F1 R3` 只证明压力路径可复现，不能替代上述实板连续读数。

## 最终只读审查

2026-10-01 对 `6f0b6f2..cfb817e` 的整轮改动完成独立只读审查：没有 Critical 或 Important 问题。审查者复核了候选位流哈希、342 条报告路径的非负 slack、串口后缀与上位机兼容逻辑。审查后记录本节前创建并验证快照 `D:\FPGA_Project\_backups\20261001_235613_pre-r3-final-review-notes`，结果为 `RESULT: BACKUP VERIFIED RESTORABLE`。

有两项非阻断的后续改进：`sim/algo/tb_alg_tel_shp.v` 的 `expect_line` 可允许六次尝试内出现不匹配的完整中间行，今后应逐条验证完整状态行；`tools/alg_tuner.py` 的新行只写 `S/Q`，今后可直接标明它们分别是槽位丢弃和 FIFO 满游程丢弃，`(+n)` 是样本间增量。本轮只记录，不在已完成门禁的候选上追加功能改动。

审查没有替代实板证据：真实摄像头 `R3` 的成因、漏检改善、HDMI 画面、Flash 和最佳回退版升级，均需相应后续测试或板主决定；JTAG 临时下载与 COM5 读数见上节。现有 IV 与组合环计时警告也使最终时序报告不能被称作全设计无条件签核。

## 2026-10-02 局部吞吐优化：摘要记录预取（已 JTAG，待实板效果验收）

### 用户证据与本轮范围

- 后续[用户截图](evidence/shape_r3_sq_user_20261002.png)显示 `CNT000 OVFFFF F1/R3`，`S0034FC15 (+4571)`、`Q017C1D28 (+27734)`。`S/Q` 累计值为十六进制，括号内为相邻有效采样间的十进制增量；不是单帧事件数，也不能证明两个事件在同一帧发生。
- 正增量确认该采样间隔既出现槽位丢弃，也出现 FIFO 满时的游程丢弃。`F1` 会使 `CNT` 归零，不能据此判断分类器把所有形状判错。计数不能单独证明摘要模块是实板唯一或主要瓶颈。
- 板主批准“先测试、再改 RTL、验证构建；不操作调参界面，也不自动烧录”。本轮不改阈值、识别规则、槽位数/FIFO 深度、串口协议、引脚、DDR/摄像头/HDMI 或最佳回退版。
- 改前备份 `D:\FPGA_Project\_backups\20261002_003548_pre-summary-prefetch` 已验证 `RESULT: BACKUP VERIFIED RESTORABLE`：583 个文件、35 个 Git 引用，未覆盖项为 0。

### RTL 与红绿验证

- 源码提交 `12ac41a9afc2f342410d29650305e9419c190738`。`shp_summary` 正常游程先执行一次同步读，随后写当前记录时，用原有读端口预取下一条独立记录；32 条方向极值后更新对应条带。每条游程仍写 33 个记录，不增加 RAM 或端口。合并、清空和外部查询路径保持原样。
- 红：新 `tb_shp_summary` 的 34 拍预算断言在旧 RTL 上退出 1，`phase1 slot0 y3 busy=66 clocks, budget=34`。这是有实际行为依据的性能失败，不是编译错误。
- 绿：同一测试退出 0，`SHAPE_TEST_PASS tb_shp_summary 11 phases 498 spans max_busy=34`。11 阶段仍逐字比较全部 8 槽、每槽 212 字的黄金摘要，包括方向极值、条带边界、合并、清空、复位及非法游程。
- 新 `tb_shp_summary_load` 在完整 1650×750 时序、1280×720 有效区、`NB=8/FQ=24` 下输入六个紧凑排列方形。旧版与新版均识别出六个正确类别/边界，`S=0 Q=0 F0/R0 OV0`，边界入队/出队各 1 次、完整提交 1 帧。队列峰值从旧版 10 降到新版 6。**此台是数据及集成回归，不是旧版过载、新版恢复的证明。**
- `tb_shp_load_counts` 退出 0：`S=1 Q=45 VS_NONFULL=1 OV=47`，硬件复位后 S/Q 为 0；计数语义未改。
- 独立只读审查 `6985f74..12ac41a` 未发现 Critical/Important/Minor 问题。确认当前 720p/8 槽下预取地址不与写地址相同，初读、方向 31 到条带、最后一次写入及命令优先级正确。审查未替代综合映射、时序或实板验证。

这次优化减少摘要更新等待，不保证任意复杂背景都不过载：槽位容量、最近像素查询和分类仍可能构成瓶颈。本轮候选在用户另行授权前不执行 JTAG/Flash。

### 编译与候选归档

- `tools\compile.bat` 于 2026-10-02 本轮重新执行，退出 0；map/interface/pnr/pgm 全 PASS。构建前已提交源码；构建后恢复 Efinity 删掉的 `ti60f225_oob.xml` 尾换行，有效 RTL、SDC、工程和引脚文件与 `12ac41a` 无差异。
- 00:50:42 最终时序报告（Efinity 2026.1.132.4.5）列出 19 组 setup/hold 关系，最小分别 `+0.142/+0.026 ns`；全部 342 条报告路径 slack 非负。工具仍有 IV、未匹配 SDC 和组合环计时警告，故不扩大为全设计无条件签核。
- 资源为 XLR `55188/60800`（较上一候选增加 390）、RAM `251/256`、DSP `154/160`。存储和 DSP 数量未增，均未超容量。
- 00:50:54 生成的位流归档为 `candidate_bitstreams/shape_summary_prefetch_12ac41a_20261002.bit`，3,131,484 字节；原输出和归档 SHA-256 均为 `6F49DD8542A26D7AC068294716254892DDA939A72F601FE19F82D41A2336BBE7`。
- [原始构建证据](evidence/summary_prefetch_12ac41a_20261002/)包含 `compile.txt`、`place.rpt`、`place.txt`、`route.txt` 和最终 `timing.rpt`，保留警告上下文，不依赖下次编译会覆盖的 `outflow/`。
- `check_chain.py`、`check_ebridge.py` 均退出 0、`RESULT: PASS`，主视频流水与六组桥接对拍无像素差异。编译归档阶段没有运行或控制真实调参界面、COM 口、JTAG 或 Flash，也未晋升最佳回退版；后续经授权的 JTAG 下载见下节。

### 完整形状回归结论

`ALG_OSS_BIN=C:\iverilog\bin` 下执行 `python sim/algo/model/check_shape.py --all`，退出码 0，最终 `ALL PASS`：23 项 Python 测试、10,381 组几何黄金对拍、18 个形状 RTL 测试台全部通过，其中含 120 个流式旋转/尺寸样本、间距 2/4/8/16/32、连续/丢失帧边界、生命周期、无消隐、多目标和覆盖层回归。[最终 stdout 分块](evidence/summary_prefetch_12ac41a_20261002/regression_final_stdout.txt)已归档。

原 `tb_shp_clutter` 与 `tb_shp_r3_pressure` 的过载拒识断言保持不变并通过；后者仍验证刻意过载时 F1/R3，**不是要求过载变成正常帧**。仿真、编译和独立代码审查通过，只说明此候选可进入下一步板测；不能宣称实拍 F1/R3、漏检、纸张透视或复杂背景已修复。

### 2026-10-02 摘要预取候选 JTAG 下载

- 板主在候选交付后明确要求“烧录”。下载前再次核验归档 SHA-256 为 `6F49DD8542A26D7AC068294716254892DDA939A72F601FE19F82D41A2336BBE7`，与本节构建记录一致；使用的是归档位流，不是可被后续编译覆盖的 `outflow/` 文件。
- 运行 `tools\flash_candidate.bat candidate_bitstreams\shape_summary_prefetch_12ac41a_20261002.bit`，退出码 0；板载 FT4232H、6.0 MHz JTAG，器件 ID `0x10660A79`，日志以 `... finished with JTAG programming` 结束。[下载日志](evidence/summary_prefetch_12ac41a_20261002/jtag_20261002.txt)已保存。
- **未写 Flash，未关闭/操作调参界面，未发送参数或读取 COM5，未做画面和形状识别验收。** 烧录会重新配置 FPGA；如板端参数回到默认值，由板主持有的界面手动恢复先前测试参数，再比较同一场景下的 F/R 与 S/Q 增量。尚不能认定实拍 R3 已修复，不晋升最佳回退版。
- 更新本下载记录前，已创建并验证快照 `D:\FPGA_Project\_backups\20261002_005645_pre-prefetch-jtag-record`，592 个文件、35 个引用，未覆盖项 0，结果 `BACKUP VERIFIED RESTORABLE`。
