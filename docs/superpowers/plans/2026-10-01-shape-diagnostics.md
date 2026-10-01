# 形状识别串口诊断 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在形状候选版调参界面可靠回读最近帧合格数、累计处理异常数及整帧故障标记，以定位“有边缘、无形状框”。

**Architecture:** `shp_detect` 锁存最近提交帧状态，经 `alg_top` 引出；独立 toggle request/ack 模块把多位诊断值从 HDMI 像素时钟域完整传给 25 MHz 域。现有遥测行只追加 17 字节后缀，GUI 可选解析，旧位流仍可用。

**Tech Stack:** Verilog-2005、Icarus Verilog、Python/tkinter、Efinity 2026.1、Windows PowerShell、Git。

**Spec:** `D:\FPGA_Project\imx219_shape\docs\superpowers\specs\2026-10-01-shape-diagnostics-design.md`（用户已确认）。

## Global Constraints

- 只改 `D:\FPGA_Project\imx219_shape` / `shape-detect` 候选版；每轮编辑前显式传 `-Worktree D:\FPGA_Project\imx219_shape` 做快照并确认 `RESULT: BACKUP VERIFIED RESTORABLE`。备份脚本默认目标是旧工程，不可省略该参数。
- 不改识别判据、HDMI叠加、现有滑块语义、摄像头/DDR/引脚链路；不动 `imx219_notemp` 和 `imx219_smooth`。
- `CNT=000..999` 为最近提交帧的合格数；`OV=0000..FFFF` 为饱和累计异常数；`F=0/1/?` 为最近帧未故障/整帧故障/尚无完整帧。`OV` 不随 GUI `R` 清零。
- 原 108 字节状态行的前 107 个 ASCII 字节不动；后缀精确为 ` CNTddd OVhhhh Ff`，末尾一个 LF，新总长 125 字节。旧状态行必须仍能解析。
- 使用一次只允许一个未完成请求的跨时钟握手；整行使用同一已完成快照，复位、断线和重连不得显示旧会话值。
- 所有源码、测试、验证记录和候选位流默认提交并推送私有远端；构建中间产物不入库。新位流仅为“未上板候选”，不自动 JTAG、Flash 或晋升最佳版。

## Review Focus

1. 视频时钟单独复位而串口时钟不停时，必须丢弃旧快照并重新握手：任务2的独立复位测试。
2. 多位 `OV/CNT` 在异相时钟连续变化时不能撕裂：任务2的交替位型测试。
3. 命令触发状态行连发时，不能拼接两次快照或重发字符：任务3的连续 `i_update` 测试。
4. 旧 108 字节行、半行以及串口重连，GUI 不能把不存在的诊断显示成零：任务4的兼容/重连测试。
5. `OV=FFFF` 后不能显示“本帧新增异常”，`CNT000 F0` 不能被判定为几何算法故障：任务4的饱和/语义测试。

---

## 文件边界与执行环境

- `rtl/algo/shp_detect.v`：提交帧故障/有效位；`rtl/algo/alg_top.v`：只引出四个诊断信号，不碰显示路径。
- `rtl/alg_shape_diag_cdc.v`：唯一的像素域→25 MHz 域捆绑数据握手；`rtl/ti60f225_oob_top.v`：两端接线与复位。
- `rtl/alg_cfg_telemetry.v`：追加 ASCII 后缀及每行快照/请求；不修改 `alg_cfg_uart.v` 的命令协议。
- `tools/alg_tuner.py`：只读显示及兼容解析；`tools/smoke_alg_tuner.py`：离线 GUI 断言。
- `sim/algo/tb_shp_diag.v`、`tb_shape_diag_cdc.v`、`tb_alg_tel_shp.v`：分别验证帧语义、跨域、串口字节；`docs/shape_diagnostics_validation.md`：记录红灯、回归、构建、候选位流哈希与未上板状态。

工程根执行；先设置 `$shapePython = 'C:\Users\HUAWEI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'`，并用 `New-Item -ItemType Directory -Force outflow\diagnostics` 建临时目录。Icarus 路径为 `C:\iverilog\bin`，临时 `.vvp` 放 `outflow\diagnostics\`。Python 检查驱动为 `sim\algo\model\check_shape.py`，整套 Efinity 编译入口为 `tools\compile.bat`。每个任务结束独立提交、推送；下个任务编辑前重新备份并验证。若一个测试或构建失败，先定位原因，不把失败写成通过。

### Task 1: 锁存最近提交帧语义

**Files:** 修改 `rtl/algo/shp_detect.v`、`rtl/algo/alg_top.v`；新增 `sim/algo/tb_shp_diag.v`、`docs/shape_diagnostics_validation.md`。

**Interfaces:** `shp_detect` 新增 `output reg o_last_fault, o_frame_valid`；`alg_top` 新增 `output wire [9:0] diag_cnt`, `output wire [15:0] diag_ovf`, `output wire diag_last_fault, diag_frame_valid`，直接连到检测器输出。

- [ ] **Red:** `tb_shp_diag.v` 断言复位后 `diag_frame_valid=0`，正常提交后 `diag_frame_valid=1, diag_last_fault=0`，注入故障并提交后 `diag_last_fault=1, o_cnt=0`，下一次正常提交清回 `0`；故障路径必须同时检查无有效框。使用 `$finish_and_return(1)` 使失败返回非零。
- [ ] **Run red:** `& $shapePython sim/algo/model/check_shape.py --rtl tb_shp_diag`；预期新端口缺失或断言失败，记录退出码。
- [ ] **Implement:** 仅在 `S_COMMIT` 锁存 `frame_fault` 并置有效；复位时清两位，关闭/重启形状检测的行为沿用现有状态机；`alg_top` 只透传诊断。
- [ ] **Verify:** 同一命令退出 0，现有 `& $shapePython sim/algo/model/check_shape.py --all` 退出 0；把结果写入验证文档。
- [ ] **Commit:** `git add rtl/algo/shp_detect.v rtl/algo/alg_top.v sim/algo/tb_shp_diag.v docs/shape_diagnostics_validation.md`，提交 `feat: expose committed shape frame status` 并推送。

### Task 2: 跨时钟完整快照

**Files:** 新增 `rtl/alg_shape_diag_cdc.v`、`sim/algo/tb_shape_diag_cdc.v`；修改 `rtl/ti60f225_oob_top.v`；更新验证文档。

**Interfaces:** 模块端口 `clk_src,rst_src_n,i_cnt[9:0],i_ovf[15:0],i_fault,i_frame_valid,clk_dst,rst_dst_n,i_req`；目的端输出 `o_cnt[9:0],o_ovf[15:0],o_fault,o_frame_valid,o_sample_valid,o_busy`。`i_req` 是目的域单拍脉冲，忙时不接新请求；`o_sample_valid` 仅在一次完整应答后置位。顶层接 `clk_src=hdmi_tx_slow_clk`、`clk_dst=CLK_25M`；模块内部让任一复位异步清除目的域有效位，复位释放在相应时钟域同步完成，避免视频域单独复位时留存旧样本。

- [ ] **Red:** 测试台用异相源/目的时钟，将 `{CNT,OV,F,valid}` 在 `155/5555` 与 `844/AAAA` 间交替；每次有效输出必须整体等于某一次源端元组，不能混值。再单独拉低两个复位各一次，断言 `o_sample_valid=0`、忙状态可恢复；连续 `i_req` 忙时无第二个交叠事务。
- [ ] **Run red:** `C:\iverilog\bin\iverilog.exe -g2005 -s tb_shape_diag_cdc -o outflow\diagnostics\tb_shape_diag_cdc.vvp sim\algo\tb_shape_diag_cdc.v rtl\alg_shape_diag_cdc.v`；预期找不到新模块或断言失败。
- [ ] **Implement:** 目的域 request toggle → 源域两级同步、捕获并保持总线 → ack toggle 两级同步回目的域 → 目的域锁存完整总线。重置握手相位和有效位；保持总线直至下一次请求，跨域寄存器加适合 Efinity 的同步器属性/约束检查，不用逐位双触发器冒充总线快照。
- [ ] **Verify:** 编译后 `C:\iverilog\bin\vvp.exe outflow\diagnostics\tb_shape_diag_cdc.vvp` 退出 0，综合可见 CDC 模块且无锁存器；记录复位与异相测试结果。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: transfer shape diagnostics across clock domains` 并推送。

### Task 3: 扩展状态行并完成顶层接线

**Files:** 修改 `rtl/alg_cfg_telemetry.v`、`rtl/ti60f225_oob_top.v`、`sim/algo/tb_alg_tel_shp.v`；更新验证文档。

**Interfaces:** 遥测模块新增 `input [9:0] i_diag_cnt`, `input [15:0] i_diag_ovf`, `input i_diag_fault, i_diag_frame_valid, i_diag_sample_valid, i_diag_busy`，以及 `output reg o_diag_req` 单拍请求。每次准备一行时，若 `!i_diag_busy` 则请求下一份快照；当前行只使用开始发送前锁定的上次完整值。未有有效样本或帧时发 `F?`。

- [ ] **Red:** 修改 `tb_alg_tel_shp.v` 的期望行：原 107 个可见字节逐字节相同，后接 ` CNT005 OV000A F1`、唯一 LF、`LEN=125`；再测 `CNT000 OVFFFF F?` 和连续 `i_update`，检查没有漏字/重复字及行中字段变化。
- [ ] **Run red:** 使用测试台顶部给出的 `iverilog` 命令，产物改放 `outflow\diagnostics\tb_tel_shp.vvp`；`vvp` 应因长度/字段不符而失败。
- [ ] **Implement:** `MSG_LEN=125`，后缀固定索引 107..123、LF 在 124；BCD 转换器增加 `CNT` 一组且维持原字段输出，`OV` 按四个 nibble 转大写 hex，`F` 按有效位选 `?`/`0`/`1`。顶层把任务1/2的端口接至遥测，保持原 UART 命令和旧字段坐标。
- [ ] **Verify:** `vvp` 退出 0；`& $shapePython sim/algo/model/check_shape.py --all` 与 `& $shapePython sim/algo/model/check_chain.py`、`& $shapePython sim/algo/model/check_ebridge.py` 均退出 0；记录结果。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: append coherent shape diagnostics to telemetry` 并推送。

### Task 4: 调参界面只读诊断

**Files:** 修改 `tools/alg_tuner.py`、`tools/smoke_alg_tuner.py`；更新验证文档。

**Interfaces:** `parse_shape_diag(line: str) -> tuple[int, int, str] | None` 只接受行尾完整 `CNTddd OVhhhh Ff`；`Tuner.diag_labels` 包含 `cnt/ov/fault` 只读标签，`Tuner._prev_diag_ov` 仅在同一次串口连接内有效。

- [ ] **Red:** 冒烟测试断言新行解析 `(5,10,'1')`，旧行/半行返回 `None` 并显示 `--`；`F?` 显示等待完整帧；`OV=FFFF` 显示饱和而不报新增；断开/重连清零比较基准；`CNT000 F0` 不被标记为确定的分类错误。
- [ ] **Run red:** `& $shapePython tools/smoke_alg_tuner.py`；预期缺少函数/标签或断言失败。
- [ ] **Implement:** 解析扩展放在现有状态解析之后；GUI 加简短只读栏，保持滑块和命令原行为；连接断开与新连接都清诊断状态，不用旧位流缺字段时伪造数值。
- [ ] **Verify:** 冒烟测试退出 0；`tools/gui_hw_test.py` 必须连接真实串口，本轮不运行并明确标记“未做硬件GUI测试”；不得声称已经读到板上诊断。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: display shape diagnostics in tuner` 并推送。

### Task 5: 构建与未上板候选归档

**Files:** 更新 `docs/shape_diagnostics_validation.md`、`candidate_bitstreams/README.md`；若四阶段通过，新增 `candidate_bitstreams/shape_diag_<构建时短提交号>_20261001.bit`。

**Interfaces:** 不更改产品接口；交付物为测试/资源/时序证据、候选位流 SHA-256、来源提交和“未上板”标签。

- [ ] **Verify tests:** 重跑任务1–4的全部测试、`& $shapePython sim/algo/model/check_shape.py --all`、`check_chain.py`、`check_ebridge.py`、`& $shapePython tools/smoke_alg_tuner.py`，每项退出 0；保留失败或跳过的原始状态。
- [ ] **Build:** `tools\compile.bat` 退出 0，`outflow\compile.log` 显示 map/interface/pnr/pgm 全 PASS；核对 `timing.rpt` 所有相关时钟 setup/hold 非负、资源未越界、顶层新 CDC 确实入网表。未过则停止，不归档成可烧录候选。
- [ ] **Archive:** 仅在通过后复制本轮 bit 到 `candidate_bitstreams/`，用 `Get-FileHash -Algorithm SHA256` 记录完整哈希、源码提交、四阶段结果与“未上板”；不覆盖 `known_good/`。
- [ ] **Final verification/commit:** `git diff --check`、检查敏感数据和位流大小、`git status`；显式暂存本任务交付物，提交 `build: archive unflashed shape diagnostics candidate` 并推送私有 `shape-detect`。最终只报告软件/RTL/构建事实，等板主另行指示 JTAG 和屏幕验收。
