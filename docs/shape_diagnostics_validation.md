# 形状诊断验证记录

日期：2026-10-01。工作副本：`D:\FPGA_Project\imx219_shape` / `shape-detect`。
此处严格区分仿真、编译、JTAG 和肉眼验收；本轮尚未烧录。

## 修改前基线

- `check_shape.py --all`：退出码 0，23 项软件测试、10381 项 RTL 几何样本及其余形状测试台均通过，末尾 `ALL PASS`。
- `tools/smoke_alg_tuner.py`：退出码 0，末尾 `SMOKE OK`。
- 改前快照：`D:\FPGA_Project\_backups\20261001_164302_pre-shape-diagnostics-task1`，`RESULT: BACKUP VERIFIED RESTORABLE`。

## Task 1：最近提交帧状态

- RED：新增 `tb_shp_diag.v` 后，`check_shape.py --rtl tb_shp_diag` 退出码 1，报 `o_last_fault`、`o_frame_valid` 不是检测器端口；这是预期的缺功能失败。
- GREEN：增加两位寄存输出并经 `alg_top` 引出后，同命令退出码 0，输出 `SHAPE_TEST_PASS tb_shp_diag committed fault and count`。
- 测试覆盖无完整帧、正常提交、故障提交清零框/计数、下一次正常提交及硬件复位。
- 完整回归：`check_shape.py --all` 退出码 0，23 项软件测试、10381 项 RTL 几何样本及其余形状测试台均通过，末尾 `ALL PASS`。
- 本项尚未做 Efinity 编译、JTAG 或上板肉眼验收。

## Task 2：跨时钟完整快照

- 改前快照：`D:\FPGA_Project\_backups\20261001_171025_pre-shape-diagnostics-task2`，`RESULT: BACKUP VERIFIED RESTORABLE`。
- RED：新增测试台后编译退出码 1，报 `rtl\alg_shape_diag_cdc.v: No such file or directory`；这是预期的缺模块失败。
- GREEN：`iverilog -g2005 -s tb_shape_diag_cdc` 编译退出码 0，`vvp` 退出码 0，输出 `SHAPE_TEST_PASS tb_shape_diag_cdc 20 async tuples and independent resets`。
- 覆盖 20 次异相时钟采样、忙时请求拒绝、源域与目的域分别复位后旧样本失效及重新握手。工程 XML 已列入新模块。顶层端口将在 Task 3 与遥测请求端一起完整接通，避免此阶段留悬空请求。
- 此项尚未做 Efinity 编译、JTAG 或上板肉眼验收。

## Task 3：125 字节状态行与顶层接线

- 改前快照：`D:\FPGA_Project\_backups\20261001_171537_pre-shape-diagnostics-task3`，`RESULT: BACKUP VERIFIED RESTORABLE`。
- RED：测试台先新增 `CNT/OV/F` 端口与 125 字节期望，编译退出码 1，报这 7 个端口尚不存在。
- GREEN：`tb_alg_tel_shp` 编译退出码 0、`vvp` 退出码 0，输出 `SHAPE_TEST_PASS tb_alg_tel_shp 19 checks`。测试独立解码 UART，逐字节核验旧 107 字节前缀、固定后缀、唯一 LF；覆盖 `CNT005 OV000A F1`、`CNT000 OVFFFF F?`、连续更新请求和形状参数极值。
- 桥接回归 `check_ebridge.py` 退出码 0，`RESULT: PASS`；主流水 `check_chain.py` 退出码 0，`RESULT: PASS`。两项初跑因测试进程没有 `ALG_OSS_BIN` 找不到已安装的 `iverilog.exe`，设置为 `C:\iverilog\bin` 后重跑通过，未改产品源码。
- `check_shape.py --all` 退出码 0，23 项软件测试、10381 个 RTL 几何样本和全部 15 个既有形状 RTL 台通过，末尾 `ALL PASS`；新增 `tb_shp_diag` 单项复跑亦退出码 0。
- Efinity 编译、JTAG 与上板肉眼验收仍未进行。
