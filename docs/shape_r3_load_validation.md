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
