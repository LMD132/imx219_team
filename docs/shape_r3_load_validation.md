# R3 负载诊断验证记录

本记录属于 `shape-detect` 候选版；代码路径验证不等于实板验收。本轮不烧录 JTAG 或 Flash，不改变 `known_good/`。

## Task 1：事件计数器

- 改前快照：`D:\FPGA_Project\_backups\20261001_221304_pre-shape-r3-load-task1`；`verify_backup.ps1` 输出 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 红：`python sim/algo/model/check_shape.py --rtl tb_shp_load_counts` 与 `--rtl tb_shp_clutter` 均退出 1；旧 `shp_detect` 缺少 `o_slot_drop_total` 和 `o_fifo_full_total`，Icarus 对每台报告 4 个 elaboration errors。
- 绿：两台在新增端口与逐事件计数后均返回 `SHAPE_TEST_PASS`。`tb_shp_load_counts` 包含 VS/游程同拍但 FIFO 不满、FIFO 满、形状开关与硬件复位；记录 `S=1 Q=45 VS_NONFULL=1 OV=47`，复位后两计数为零。`tb_shp_clutter` 保留原 `R1` 识别断言，记录 `slot_drops=199 fifo_drops=0 reason=1 ovf=199`，并确认新计数相符。
- 当前仅覆盖离线 RTL 仿真；尚未跨时钟、串口、GUI、综合或实板验证。
