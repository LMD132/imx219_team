# 形状诊断验证记录

日期：2026-10-01。工作副本：`D:\FPGA_Project\imx219_shape` / `shape-detect`。
此处严格区分仿真、编译、JTAG 和肉眼验收；Task 1–5 完成时尚未烧录，后续板主指示的 JTAG 临时下载记录见文末。

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

## Task 4：调参界面只读诊断

- 改前快照：`D:\FPGA_Project\_backups\20261001_173318_pre-shape-diagnostics-task4`，`RESULT: BACKUP VERIFIED RESTORABLE`。
- RED：扩展 `tools/smoke_alg_tuner.py` 后退出码 1，报 `alg_tuner` 无 `parse_shape_diag`。
- GREEN：同一冒烟测试退出码 0，末尾 `SMOKE OK`；`py_compile` 退出码 0。覆盖新行解析、旧行/半行回退、`F?`、`OVFFFF` 饱和、同连接内 OV 差量、`CNT000 F0` 只是无合格目标、断开/重连后旧队列丢弃，并保留滑块及手动输入原测试。
- 此测试未连接真实串口；`tools/gui_hw_test.py` 本轮不运行，不声称已读到板上诊断。Efinity 编译、JTAG 与上板肉眼验收仍未进行。

## Task 5：完整回归、构建与未上板候选

- 最终源码提交：`3604b66`（`shape-detect`，已推送私有仓库）。此前四个功能提交为 `ff5733e`、`11e7978`、`f6f0147`、`0f35625`。候选位流编译后仅追加了不影响综合的 SDC 注释及测试驱动/GUI 修复；RTL 和有效 SDC 命令未再改变。
- 编辑前可恢复快照：`20261001_173905_pre-shape-diagnostics-task5`、`20261001_180102_pre-shape-diagnostics-sdc-fix`、`20261001_183509_pre-shape-diagnostics-precise-cdc-sdc`、`20261001_190420_pre-shape-diagnostics-test-runner-fix`、`20261001_190835_pre-shape-diagnostics-candidate-archive`，均得到 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 最终 `check_shape.py --all` 退出码 0、`ALL PASS`：23 项 Python、10381 个几何黄金样本、15 个形状 RTL 台。另单跑 `tb_shp_diag`、`tb_shape_diag_cdc`、`tb_alg_tel_shp`、`tb_alg_cfg_uart` 均退出 0，分别覆盖提交帧状态、20 组异步跨域/独立复位、19 项新遥测、68 项完整 UART 协议。通用测试驱动现已包含 CDC 模块，避免单跑时缺模块。
- `check_chain.py`、`check_ebridge.py` 均退出 0 并显示 `RESULT: PASS`；`tools/smoke_alg_tuner.py` 退出 0、`SMOKE OK`；GUI 文件 `py_compile` 退出 0。冒烟测试补充串口 `ERR`/`CLOSED` 后旧队列失效。真实串口 GUI 测试、JTAG、Flash、屏幕肉眼验收均**未做**。
- 早期构建：原 SDC 的 `<USER_PERIOD>` 使 `CLK_25M` 未纳入有效时序检查；改为 40 ns 后发现异步跨域的虚假相位负裕量。一次域级 5 ns 约束构建仅用于诊断，还出现 SDRAM -0.017 ns 裕量，不予归档。最终改为具名握手/持有总线/复位源寄存器的 5 ns 约束并重新完整构建。
- 最终 `tools/compile.bat` 退出码 0；Efinity 2026.1.132.4.5 的 map、interface、pnr、pgm 四阶段均完成。`place.rpt`：XLR 54820/60800、RAM 251/256、DSP 154/160；资源余量很紧。布线后 `timing.rpt` 列出的 setup/hold 最小裕量分别为 +0.228/+0.027 ns，`CLK_25M` 及有关双向跨域关系均出现且非负。新增 SDC 行无目标未匹配警告；仍存在工程原有 JTAG/MIPI 等端口未匹配警告，因此不宣称全设计无条件时序签核。
- SDC 复核：Efinity 对当前 `-from` 源寄存器规则也会约束其同域扇出，例如 `dly_cnt[26]` 到 debayer 复位、`req_toggle` 到 25 MHz 域 CE；这些是额外收紧且本次均通过，不是域级 false path。以后若重构握手，应重新核对端点集合与约束范围。
- 归档：`candidate_bitstreams/shape_diag_3604b66_20261001.bit`，3,118,644 字节，SHA-256 `25F66926F864AC3054ADFBFD5B5622289B9254B7C3F2315ECD2E318B7E468B6C`，与最终 `outflow/ti60f225_oob.bit` 相同。归档时尚未上板；未修改 `known_good/`，也未替换最佳回退位流。

## 板主指示后的 JTAG 临时下载

- 2026-10-01，板主明确要求“现在烧录”。下载前确认候选位流为 3,118,644 字节、SHA-256 与归档一致，Windows 检出板载 FT4232H（VID:PID `0403:6011`）。
- 执行 `tools\flash_candidate.bat candidate_bitstreams\shape_diag_3604b66_20261001.bit`，模式为 `-m jtag`、6 MHz、`Generic Board Profile Using FT4232H`；命令退出码 0。日志显示 `Device ID read from JTAG: 0x10660A79` 及 `... finished with JTAG programming`。
- 这是易失性 JTAG 下载，**未写 Flash**。尚未通过屏幕肉眼或真实串口验证 `CNT/OV/F`；下载成功不等于识别效果已验收。`known_good/` 仍未动。
