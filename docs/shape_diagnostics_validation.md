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
