# R3 负载诊断验证记录

本记录属于 `shape-detect` 候选版；代码路径验证不等于实板验收。本轮不烧录 JTAG 或 Flash，不改变 `known_good/`。

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
- **未上板**：本轮未执行 JTAG/Flash，也未做 COM5 实机或画面验收，`known_good/` 与最佳回退版未修改。

## 后续实板读数的解释

在同一阈值、固定纸张场景下比较连续新状态行，并留出数行等待快照稳定。`S/Q` 是累计模计数，`CNT/F/R` 是最近提交帧，两者不是严格同帧事件统计；界面超过 5 秒、断线重连或计数下降会暂停增量。

- `ΔS>0、ΔQ>0`：支持槽位耗尽与 FIFO 满丢游程同时发生。
- `ΔS>0、ΔQ=0` 且仍为 `R3`：检查 VS 同拍、待处理边界或重同步；不能把 R3 直接等同 FIFO 满。
- 两者增量都为 0：先排除采样滞后，再检查其他坏帧来源。

离线的 `S=199 Q=369 F1 R3` 只证明压力路径可复现，不能替代上述实板连续读数。
