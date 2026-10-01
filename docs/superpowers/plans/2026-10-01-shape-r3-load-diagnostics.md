# 形状识别 R3 负载诊断 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在形状候选版分别回读槽位丢弃与 FIFO 满丢段，并以可重复仿真区分 `R1` 与 `R3`，为后续修复提供证据。

**Architecture:** `shp_detect` 新增两只 32 位累计计数器，沿 `alg_top` 和原有 request/ack CDC 与 `CNT/OV/F/R` 同步快照。原 128 字节状态行保留前 127 个可见字节，追加 ` Sxxxxxxxx Qxxxxxxxx` 后成为 148 字节；GUI 兼容旧行并谨慎计算增量。

**Tech Stack:** Verilog-2005、Icarus Verilog、Python/tkinter、Efinity 2026.1、PowerShell、Git。

**Spec:** `D:\FPGA_Project\imx219_shape\docs\superpowers\specs\2026-10-01-shape-r3-load-diagnostics-design.md`（板子持有人已审阅确认）。

## Global Constraints

- 只改 `D:\FPGA_Project\imx219_shape` 的 `shape-detect` 候选版；每个任务首次改文件前运行 `powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup\make_backup.ps1 -Label <任务标签> -Worktree D:\FPGA_Project\imx219_shape`，再运行 `verify_backup.ps1 -Snapshot latest -Worktree D:\FPGA_Project\imx219_shape`，亲眼确认 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 不改分类判据、阈值含义、HDMI/摄像头/DDR/引脚、`NB=8`、`FQ=24`；不动 `imx219_notemp`、`imx219_smooth`、`known_good/`。
- `S` 仅在 `cfg_en && no_slot_drop` 增一；`Q` 仅在 `cfg_en && span_end && f_full` 增一。两者硬件复位清零、形状关闭时保持、按 32 位模计数；`OV` 旧饱和语义、`CNT/F/R` 最近提交帧语义不变。
- 新行总长 148 字节（含唯一 LF），索引 `0..126` 原样不动、`127..146` 为 ` Sxxxxxxxx Qxxxxxxxx`、索引 `147` 为 LF。旧 108/125/128 字节行仍可被 GUI 接受。GUI 只在同一连接、间隔不超过 5 秒、两计数器都未减小时显示差分；其余情况只显示原值。
- 每个任务先观察失败测试，再做最小实现，再运行通过测试；失败、跳过、资源/时序超限必须如实记录，不调整断言来掩盖错误。
- 源码/测试/记录/合格候选位流按用户要求提交并尝试推送私有 `origin/shape-detect`；网络推送失败要记录为“仅本地”。未经板主新指示，不 JTAG、不 Flash、不晋升最佳版。

## Review Focus

1. `span_end` 与 VS 同拍但 FIFO 未满时，`Q` 必须不增；任务 1 的独立碰撞场景锁定此点。
2. 形状关闭/重新开启或硬件复位时，计数器分别应保持/继续或清零，且不能污染旧 `OV/F/R`；任务 1 检查。
3. 96 位 CDC 源值在异相时钟变化或任一侧复位时，目的端不得拼接旧/新元组或保留旧有效位；任务 3 检查。
4. 148 字节状态行在滑块触发连续发送时不得漏字、重发或插入第二个 LF，旧前缀也不能变；任务 4 检查。
5. GUI 读到旧行、残缺新行、`F?`、串口重连、超过 5 秒的样本或原值下降时，不得显示虚假计数增量；任务 5 检查。

---

## 文件边界与执行环境

- 事件源：`rtl/algo/shp_detect.v` 产生 `o_slot_drop_total[31:0]`、`o_fifo_full_total[31:0]`；`rtl/algo/alg_top.v` 仅透传为 `diag_slot_drop_total`、`diag_fifo_full_total`。
- 跨域：`rtl/alg_shape_diag_cdc.v` 增加同名 `i_*/o_*` 32 位端口，把已有 32 位元组扩为 96 位；`rtl/ti60f225_oob_top.v` 只负责像素域、25 MHz 域和遥测模块接线。
- 串口：`rtl/alg_cfg_telemetry.v` 添加 `i_diag_slot_drop_total`、`i_diag_fifo_full_total` 端口和十六进制后缀；不更改 `rtl/alg_cfg_uart.v` 的任何命令。
- 上位机：`tools/alg_tuner.py` 保持 `parse_shape_diag()` 的四元组返回值，另加 `parse_shape_load(line: str) -> tuple[int, int] | None`，GUI 只读显示 `S/Q`；`tools/smoke_alg_tuner.py` 回归旧/新状态行与断线逻辑。
- 测试与记录：`sim/algo/tb_shp_load_counts.v` 检查事件定义，`tb_shp_r3_pressure.v` 在生产 `FQ=24` 的 720p 节拍复现压力；既有 `tb_shape_diag_cdc.v`、`tb_alg_tel_shp.v`、`tb_alg_cfg_uart.v` 扩展断言；`sim/algo/model/check_shape.py` 把两个新形状台纳入 `--all`；结果记在 `docs/shape_r3_load_validation.md`。

在工程根目录执行。Python 使用当前可用的项目运行时（先以 `python --version` 或既有 bundled runtime 确认），Icarus 可由 `check_shape.py` 默认从 `C:\iverilog\bin` 找到。临时 `.vvp` 和向量放 `outflow/diagnostics/`，不入库。每个任务提交时显式暂存本任务文件并尝试 `git push origin shape-detect`；上轮网络曾失败，推送结果必须实际核对。

### Task 1: 事件计数器及定义测试

**Files:** 修改 `rtl/algo/shp_detect.v`、`rtl/algo/alg_top.v`、`sim/algo/tb_shp_clutter.v`；新增 `sim/algo/tb_shp_load_counts.v`、`docs/shape_r3_load_validation.md`。

**Interfaces:** `shp_detect` 输出 `o_slot_drop_total[31:0]`、`o_fifo_full_total[31:0]`；`alg_top` 输出 `diag_slot_drop_total[31:0]`、`diag_fifo_full_total[31:0]`，仅透传。`F/R/OV` 仍用现有端口。

- [ ] **Red test:** `tb_shp_load_counts` 在小 `FQ` 下分别产生队列满、VS/游程同拍但队列不满、形状关闭/重新开启、硬件复位；断言 `Q` 只对满队列游程每拍加一，`S` 只对 `no_slot_drop` 加一，旧 `F/R/OV` 值仍符合相同场景的原预期。既有 `tb_shp_clutter` 的八噪声 `R1` 场景追加 `S>0,Q=0`，不改变其原识别断言。
- [ ] **Run red:** `python sim/algo/model/check_shape.py --rtl tb_shp_load_counts` 和 `--rtl tb_shp_clutter`；新端口/计数断言在当前 RTL 下必须失败，记下原始输出。
- [ ] **Implement:** 仅在现有像素时钟逻辑添加两个 32 位寄存器和端口；复位清零、`!cfg_en` 保持，事件按本计划 Global Constraints 增一；`alg_top` 只连线，不触及视频通路。
- [ ] **Verify:** 两个 RTL 台输出 `SHAPE_TEST_PASS` 且退出码 0；`git diff --check` 无错误，并把红/绿输出记入验证文档。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: count separate shape slot and FIFO-full events`，尝试推送并核对结果。

### Task 2: 可重复的 R3 压力场景

**Files:** 新增 `sim/algo/tb_shp_r3_pressure.v`；修改 `sim/algo/model/check_shape.py`、`docs/shape_r3_load_validation.md`。

**Interfaces:** 消费任务 1 的两个输出；不修改产品 RTL。测试台保留内部 `no_slot_drop`、`span_end && f_full`、坏标记入/出队和 `pending_edges` 的独立监视器。

- [ ] **Red test:** 新台先复用既有八噪声刺激（已知 `R1,Q=0`），但断言目标是精确 `F1 R3,S>0,Q>0`，证明门禁确实会拒绝旧现象。使用生产 `NB=8,FQ=24`、完整 1280×720 有效像素/1650×750 时序，结束后送真实 VS 并排空；加明确仿真超时保护。
- [ ] **Run red:** `python sim/algo/model/check_shape.py --rtl tb_shp_r3_pressure`；当前刺激应因精确 `R3` 或 `S/Q` 断言不满足而失败，保存原始监视器输出。
- [ ] **Tune stimulus:** 只增加密集游程、并发小轮廓或调整**测试刺激的负载/帧间隔**，直至精确 `R3,S>0,Q>0` 可重复；`R7/RB` 或单纯 `R1` 不算达标。若可靠刺激无法找到，停止任务并报告，不能修改产品 RTL 或放宽期望。
- [ ] **Verify:** 同一台重复运行至少两次均退出码 0 且输出 `SHAPE_TEST_PASS`；加入 `ALL_RTL` 后 `python sim/algo/model/check_shape.py --all` 退出 0，并记录 `S/Q/R/F` 与监视器值。
- [ ] **Commit:** 显式暂存本任务文件，提交 `test: reproduce shape R3 load path`，尝试推送并核对结果。

### Task 3: 96 位跨时钟快照

**Files:** 修改 `rtl/alg_shape_diag_cdc.v`、`rtl/ti60f225_oob_top.v`、`sim/algo/tb_shape_diag_cdc.v`、`docs/shape_r3_load_validation.md`。

**Interfaces:** `alg_shape_diag_cdc` 新增 `i_slot_drop_total[31:0]`、`i_fifo_full_total[31:0]` 及对应 `o_*`；顶层像素域接任务 1 输出，25 MHz 域留下两个新 `w_shape_*_uart`，供任务 4 使用。

- [ ] **Red test:** 在现有异相时钟测试台，把两组交替输入元组分别设为 `{CNT155,OV5555,F0,R1,S13579BDF,Q2468ACE0}` 与 `{CNT844,OVAAAA,F1,R8,S02468ACE,QFDB97531}`；每次应答只能完整等于其中一组。源/目的域分别在空闲和事务中复位，`o_sample_valid` 立即无效；忙时请求不能排队。
- [ ] **Run red:** `python sim/algo/model/check_shape.py --rtl tb_shape_diag_cdc` 必须因新端口或元组断言失败。
- [ ] **Implement:** 扩充现有保持寄存器/输出锁存为 96 位，request/ack 和复位相位保持原协议；顶层接到 CDC 输出，不先改串口格式。
- [ ] **Verify:** 同一测试退出 0、输出 `SHAPE_TEST_PASS`；运行任务 1–2 两台，确认端口扩展不影响形状路径，结果写入验证文档。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: snapshot shape load counters across clocks`，尝试推送并核对结果。

### Task 4: 148 字节状态行

**Files:** 修改 `rtl/alg_cfg_telemetry.v`、`rtl/ti60f225_oob_top.v`、`sim/algo/tb_alg_tel_shp.v`、`sim/algo/tb_alg_cfg_uart.v`、`docs/shape_r3_load_validation.md`。

**Interfaces:** `alg_cfg_telemetry` 新增 `i_diag_slot_drop_total[31:0]`、`i_diag_fifo_full_total[31:0]`；从任务 3 的 25 MHz 域快照输入。旧 `CNT/OV/F/R` 输入与命令协议不变。

- [ ] **Red test:** `tb_alg_tel_shp` 设 `S=0x13579BDF,Q=0x2468ACE0`，断言原 `0..126` 字节逐字节不变、后缀恰为 ` S13579BDF Q2468ACE0`、总长 148、仅末尾一个 LF；在 `F?`、`OVFFFF`、两计数器变化及连续 `i_update` 时整行使用同一快照。`tb_alg_cfg_uart` 把期望行长同步改为 148、接入新端口的常数零、断言旧命令回读和 ` S00000000 Q00000000` 后缀。
- [ ] **Run red:** 分别运行 `python sim/algo/model/check_shape.py --rtl tb_alg_tel_shp` 与 `python sim/algo/model/check_shape.py --rtl tb_alg_cfg_uart`；新行长度/后缀测试在旧遥测 RTL 下均应失败。
- [ ] **Implement:** `MSG_LEN=148`，`char_idx` 和 `msg_byte.idx` 为 8 位；状态行开始时锁存两个 32 位值，索引 `127..146` 输出固定十六进制字符，147 为 LF。顶层把任务 3 的线接入遥测，保留每行前原有快照/请求节奏。
- [ ] **Verify:** 两台测试均退出 0 且有 `SHAPE_TEST_PASS`；旧前缀与连续行断言全过，结果写入验证文档。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: append shape load counters to UART status`，尝试推送并核对结果。

### Task 5: 调参界面只读计数

**Files:** 修改 `tools/alg_tuner.py`、`tools/smoke_alg_tuner.py`、`docs/shape_r3_load_validation.md`。

**Interfaces:** `parse_shape_diag(line)` 仍返回 `(cnt, ov, fault, reason)`；新增 `parse_shape_load(line: str) -> tuple[int, int] | None`，仅完整 ` S[0-9A-F]{8} Q[0-9A-F]{8}` 后缀返回计数。`Tuner.diag_labels` 增加 `slot`、`queue`，`_prev_diag_load` 只保存本次连接的 `(monotonic_time, S, Q)`。

- [ ] **Red test:** `smoke_alg_tuner.py` 先断言新行能同时解析旧四元组和新二元组，旧行/残缺后缀或 `F?` 时 `slot/queue` 为 `--`；用可替换的 `time.monotonic()` 模拟连续有效行显示增量，并断言重连、下降/回卷、间隔大于 5 秒时只显示原值而无增量；原滑块/命令断言保持。
- [ ] **Run red:** `python tools/smoke_alg_tuner.py` 必须在缺新解析/标签时失败。
- [ ] **Implement:** 给现有完整行正则增加可选的成对 `S/Q` 后缀，旧四元组接口不变；单独解析新两值并在诊断第二行只读显示，避免原横排标签挤出窗口。`_reset_diag()` 清旧差分基准，`_on_line()` 在 `F?` 或无新字段时显示 `S/Q --` 并清 `_prev_diag_load`；增量只在同一连接、间隔 `<=5.0` 秒且两个原值均未下降时计算。
- [ ] **Verify:** 冒烟测试退出 0 并输出 `SMOKE OK`；结果写入验证文档，不将离线 Tk 测试写成真实 COM5/硬件通过。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: display separate shape load diagnostics`，尝试推送并核对结果。

### Task 6: 整套回归、构建及候选归档

**Files:** 修改 `docs/shape_r3_load_validation.md`、`candidate_bitstreams/README.md`；通过全部门禁后新增 `candidate_bitstreams/shape_r3_load_<源码短提交号>_20261001.bit`。

**Interfaces:** 不新增产品接口；交付的是可追溯的离线候选及来源哈希，不是已上板结论。

- [ ] **Run regressions:** `python sim/algo/model/check_shape.py --all`、`python sim/algo/model/check_chain.py`、`python sim/algo/model/check_ebridge.py`、`python tools/smoke_alg_tuner.py`，以及 `--rtl tb_shape_diag_cdc`、`--rtl tb_alg_tel_shp`、`--rtl tb_alg_cfg_uart`；逐项记录命令、退出码和 `PASS` 标记，任何一项失败即停。
- [ ] **Build:** 记录构建前 `git rev-parse --short HEAD`，运行 `tools\compile.bat`；核对 `outflow/compile.log` 中 map/interface/pnr/pgm 四阶段均 PASS，`outflow/ti60f225_oob.timing.rpt` 的所有相关 setup/hold 非负，资源未超器件上限，且新计数链在综合结果中存在。若任一条件不满足，记录失败，不复制位流。
- [ ] **Archive:** 门禁全过后复制 `outflow/ti60f225_oob.bit` 到上述候选路径；用 `Get-FileHash -Algorithm SHA256` 记录完整哈希、字节数、构建来源提交、测试/时序结果及“未上板”；不能覆盖旧候选或 `known_good/`。
- [ ] **Final checks:** `git diff --check`、敏感数据与文件大小检查、`git status`；验证候选位流来源提交、SHA-256 和“未上板”文案一致。
- [ ] **Commit:** 只暂存本任务产物并提交 `build: archive unflashed R3 load diagnostics candidate`，尝试推送私有仓库并核对远端；总结严格区分 RTL 仿真、Efinity 构建、JTAG、肉眼验收四个等级。
