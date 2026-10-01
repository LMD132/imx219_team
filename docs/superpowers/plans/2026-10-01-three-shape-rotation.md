# 三类图形抗旋转识别 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有形状候选工程中可靠识别平面内旋转的圆环、三角形和矩形，删除十字类别，不做OCR。

**Architecture:** 先建立完整外轮廓参考模型，再验证32方向极值点＋每4行左右轮廓摘要能否保留必要信息。模型达标后，移植独立摘要存储和定点分类状态机，保留现有视频链路和框表接口；不达标则停在软件阶段修订设计。

**Tech Stack:** Verilog-2005、Icarus Verilog、Python 3.12 / unittest / NumPy / OpenCV / Pillow、Efinity 2026.1、Windows PowerShell、Git。

**Spec:** `D:\FPGA_Project\imx219_shape\docs\superpowers\specs\2026-10-01-three-shape-rotation-design.md`（用户已于2026-10-01确认）。

## Global Constraints

- 继续在 `D:\FPGA_Project\imx219_shape` / `shape-detect` 修改候选版；每轮编辑前备份并取得 `RESULT: BACKUP VERIFIED RESTORABLE`。
- 最佳回退版 `imx219_notemp`、冻结实验版 `imx219_smooth` 均不修改；只有板子持有人实际观察后确认效果好，才可晋升最佳回退版。
- 类别编码保持 `1=圆形, 2=矩形, 3=三角形, 0=未知/无效`；不再产生类别4。
- 用户明确不需要十字／加号识别，也不做文字识别（OCR）。保留类别文字标注。
- 位置、顺序、旋转角度、图形间距不写死，不以当前A4纸布局作为分类模板。
- 本阶段先处理平面内旋转；不承诺任意透视、遮挡或互相接触；无法可靠分类时拒识，`bval=0`。
- 保持原摄像头、DDR、灰度/边缘流水、显示坐标和HDMI时序不变；显示仍保持720p、60Hz。
- 每个候选保存32个等间隔方向极值点，每4个源图像行记录左右轮廓；8槽×180条带×25bit＝36000bit。
- 字库仍用256行、原8位地址和原读延迟；旧“十”“字”位置清零，未知原索引保持不变。
- `S/Y/W/A`控制语义保留；旧 `Z/FL`保留协议位置，调参台明确显示为旧版参数，不静默改成其他含义。
- 空帧或确定拒识替换场景后，旧标签最多再保留2个输入帧；结果按整帧原子更新，目标预算为源帧结束后2帧内更新。
- 新增识别目标预算最多8块RAM，总量硬上限256；当前现存构建243/256 RAM、46/160 DSP。不新增完整1280×720帧缓存或修改DDR仲裁。
- FIFO溢出、摘要容量不足、处理未赶上帧边界时，受影响结果无效并报告诊断，不能用半截轮廓给出肯定类别。
- 0..355°每5°一档、尺寸48/80/160源像素的干净未截断互不接触标准样本必须正确；未知不算正确。
- map/interface/pnr/pgm、资源、吞吐和所有相关时钟setup/hold通过后才可交付可烧录候选。
- 重要源文件、测试、结果和候选位流提交并推送私有仓库；临时 `.vvp/.vcd`、缓存及outflow不入库。
- 未经新指示不自动烧录、不写Flash；软件验证、RTL验证、板主肉眼验收三个状态分开记录。

## Review Focus

1. 内外双轮廓的圆环不能被当作凹形或分成两个目标：任务2模型、任务4端到端测试。
2. 不接触但历史bbox相交的两个目标不能被拼成已知形状：任务3摘要/连接测试、任务4多目标测试。
3. 槽位重用、处理中复位及关闭再开启不能继承旧轮廓或旧标签：任务3清理测试、任务4生命周期测试。
4. 最后一列/行的游程、4行条带边界和跨帧积压不能被悄悄丢掉：任务3端点测试、任务4帧边界测试。
5. 移除字模不能移动“未知”索引或改变叠加延迟；纸面装饰矩形也不能被硬编码位置排除：任务5显示测试、任务2边界报告。

---

## 文件边界与执行环境

所有相对路径均以 `D:\FPGA_Project\imx219_shape` 为根。新增文件只在下列任务中创建；既有 `rtl/algo/alg_top.v`、`alg_vdisp.v`、顶层引脚/摄像头配置不顺带重构。

- `sim/algo/model/shape_cases.py`：确定性样本生成和源坐标游程。
- `sim/algo/model/shape_geometry.py`：完整有序外轮廓参考分类；不使用待测摘要作为oracle。
- `sim/algo/model/shape_fixed.py`、`shape_params.json`：轻量摘要、整数分类、唯一参数表。
- `sim/algo/test_shape_*.py`：模型、工具和兼容性单元测试；`check_shape.py`：模型↔RTL对拍驱动。
- `rtl/algo/shp_summary.v`：8槽摘要存储、更新/合并/清除；`shp_geometry.v`：串行定点分类。
- `rtl/algo/shp_detect.v`：现有游程/目标管理接入上述组件，保持公开接口；专用测试台在 `sim/algo/`。
- `docs/shape_rotation_validation.md`：红灯基线、软件门禁、资源时序和未上板状态；不把结果仅留在聊天。

以下命令在PowerShell、工程根执行；变量仅为本次任务准备，不改变全局设置：

```powershell
$shapePython = 'C:\Users\HUAWEI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$env:ALG_OSS_BIN = 'C:\iverilog\bin'
$env:PYTHONDONTWRITEBYTECODE = '1'
New-Item -ItemType Directory -Force -Path outflow\diagnostics | Out-Null
```

本机已只读确认NumPy、OpenCV、Pillow可导入；不依赖pytest，不在实现前安装新库。Icarus失败测试用 `$finish_and_return(1)`，成功返回0；新Python测试用unittest断言。仿真临时文件放 `outflow/diagnostics/`，`vvp <file> -none`关闭波形。每任务开始跑备份脚本并使用其返回的**确切快照名**验证，不使用其他目录默认值。

### Task 1: 建立不会假通过的失败基线

**Files:** 修改 `sim/algo/tb_shp_rot.v`；新增 `sim/algo/model/check_shape.py`、`sim/algo/test_shape_runner.py`、`docs/shape_rotation_validation.md`。

**Interfaces:** `run_tb(name: str, extra_sources: list[str] = []) -> subprocess.CompletedProcess[str]`，返回真实编译/仿真状态；CLI `check_shape.py --rtl <tb名>`遇到错误或超时返回非零。旧测试期待修正，其他算法源码暂不变。

- [ ] **Red:** 在 `test_shape_runner.py::RunnerTests`断言缺失测试台、失败断言、进程超时均使CLI返回非零；成功测试返回0，不以“日志含DONE”代替断言。
- [ ] **Run red:** `& $shapePython -m unittest discover -s sim/algo -p test_shape_runner.py -v`；新驱动不存在时失败。
- [ ] **Implement runner:** 实现上述签名；受测源为测试台、`rtl/algo/*.v`、两种RAM原语和按测试需要的UART配置模块，cwd固定工程根，选定测试台为顶层；用Icarus `-g2012`，超时120秒/测试台，临时产物在outflow。
- [ ] **Correct regression:** `tb_shp_rot.v`帧1期待 `circle=0, rect=6, tri=0, cross=0`，帧2期待 `circle=2, rect=2, tri=0, cross=0`；错误退出非零，移除对内部旧FSM编号的必需依赖，保留公开框表检查。
- [ ] **Verify:** runner单元测试通过；`& $shapePython sim/algo/model/check_shape.py --rtl tb_shp_rot`必须在旧算法上失败，确认40°/45°矩形误分类被抓到。将失败退出码、对应框及FIFO计数写入验证文档。这是有意保留的待修功能红灯，不能叫全套通过。
- [ ] **Commit:** 显式暂存本任务4个文件，提交 `test: expose rotated rectangle misclassification`；按全局约束推送 `shape-detect`。

### Task 2: 软件模型与轻量摘要可行性门禁

**Files:** 新增 `sim/algo/model/{shape_cases.py,shape_geometry.py,shape_fixed.py,shape_params.json}`、`sim/algo/test_shape_model.py`；扩展 `check_shape.py`、更新 `docs/shape_rotation_validation.md`。

**Interfaces:** `ShapeCase(kind, expected_cls, runs, contours, bounds)`；`make_case(kind: str, angle_deg: int, size: int, aspect: float, center: tuple[int,int], phase: tuple[float,float]) -> ShapeCase`。`ShapeResult(cls: int, valid: bool, reason: str)`；`classify_contour(contours: list[np.ndarray], params: dict) -> ShapeResult`；`summarize_runs(runs: list[tuple[int,int,int]], width=1280, height=720) -> ShapeSummary`；`classify_summary(summary: ShapeSummary, params: dict) -> ShapeResult`。`ShapeSummary(support: list[tuple[bool,int,int]], strips: list[tuple[bool,int,int]], bounds: tuple[int,int,int,int], bad: bool)`，support记录(valid,x,y)，strips记录(valid,left,right)，bounds为(x0,y0,x1,y1)。游程顺序为 `(y,x0,x1)`、端点闭区间。

- [ ] **Red:** `ShapeModelTests.test_clean_rotation_matrix`对两种模型分别执行固定矩阵：ring/circle/triangle/square/rectangle(1.5、2)，`range(0,360,5)`、尺寸48/80/160，中心(240,180)/(640,360)/(1000,500)，相位(0,0)/(0.5,0.5)，断言 `valid is True`且`cls == expected_cls`；每个样本未截断。
- [ ] **Red negatives:** `test_cross_rejected_all_angles`测试臂宽/外宽比例0.15/0.3/0.5及全部上述角度/尺寸，断言 `valid is False, cls == 0`；加入直线、正五边形、五角星负样本。同一圆环内外轮廓只有一个有效圆类输出。
- [ ] **Run red:** `& $shapePython -m unittest discover -s sim/algo -p test_shape_model.py -v`；缺失模型/判据时失败。
- [ ] **Implement oracle:** 从同一确定性栅格边缘图提取有序外轮廓，不用理想解析几何替代采样后的轮廓；用轮廓直边/角点、垂直/平行关系及圆/受限椭圆残差做分类。分类函数不接收类名、角度、预期标签或生成器元数据。加入镜像/平移等价检查；装饰矩形按几何识别矩形，不擅自过滤，透视/断裂/噪声另列诊断集。
- [ ] **Implement summary/model:** 32方向系数Q8、signed10bit，按 `round(256*cos/sin(2πk/32))`离线生成并存配置；点坐标12/13bit、投影signed24bit，同分选(y,x)字典序最小点。条带索引 `y//4`，记录valid/left/right；使用全部180条带检验外轮廓偏离，内环不当作外凹陷。所有整数位宽、舍入、角点/拟合阈值存于唯一配置，RTL不得另选一套阈值。
- [ ] **Gate:** 重跑同集，报告每类正确/拒识/误识数量，并测试断边1/3/5px、确定种子20261001的少量噪点、截断和透视样本。参数选择依据完整已入库矩阵，不删除失败样本、不逐角度特判；阈值不预先假定有效。软件模型若不能全过标准正样本/十字负样本，记录失败并停下修订设计，**不开始任务3**。
- [ ] **Verify:** 上述unittest零失败；`& $shapePython sim/algo/model/check_shape.py --model`输出 `MODEL GATE PASS`且退出0；参数配置哈希、依赖版本、样本总数和噪声/透视的实测边界入文档。旧RTL旋转测试仍预期失败，不能隐藏。
- [ ] **Commit:** 显式暂存本任务新增模型/测试和更新文档/驱动，提交 `feat: validate three-shape rotation geometry model`，推送。

### Task 3: 流式摘要与目标连接安全

**Files:** 新增 `rtl/algo/shp_summary.v`、`sim/algo/tb_shp_summary.v`、`tb_shp_connect.v`；修改 `rtl/algo/shp_detect.v`、`ti60f225_oob.xml`、`check_shape.py`、`docs/shape_rotation_validation.md`。

**Interfaces:** `shp_summary`参数W/H/NB保持1280/720/8；命令握手 `cmd_valid/cmd_ready`，`cmd_op[1:0]`编码0清槽、1并入游程、2合并槽；`cmd_slot[2:0]`为目的槽、`cmd_other[2:0]`为源槽，`cmd_x0/x1[11:0], cmd_y[12:0]`。读取接口 `rd_req, rd_slot[2:0], rd_index[7:0] -> rd_valid, rd_data[25:0]`，请求握手后下一拍返回；索引0..31为 `{valid,y[12:0],x[11:0]}`、32..211为零扩展 `{valid,left[11:0],right[11:0]}`。请求仅在摘要命令不忙时受理；每槽 `bad[NB-1:0]`记录不可用状态。

- [ ] **Red:** `tb_shp_summary`逐字比较任务2生成的黄金摘要，覆盖空槽、32方向极值同分、y=3/4/719、x=0/1279、合并交换顺序、释放重用及更新中复位；`tb_shp_connect`输入不接触但历史bbox相交的两个目标，要求不得合并成肯定的已知形状。
- [ ] **Run red:** `& $shapePython sim/algo/model/check_shape.py --rtl tb_shp_summary`及 `--rtl tb_shp_connect`；新模块未实现时失败。
- [ ] **Implement summary:** 按任务2配置和握手实现串行更新/合并；条带RAM使用精确深度，不因深度取整跨RAM预算。命令完成前不能释放/读取旧槽，清槽与合并包含所有摘要；`bad`随合并传播，清槽复位。不把复位写遍大RAM当成必需硬件模式，清理有效位和版本归属可独立实现。
- [ ] **Implement connection guard:** 在现有游程管理中仅把有当前/最近行连接证据的游程相连；使用GAPX=6/GAPY=4作为有界容差，不能只凭历史bbox重叠。没有足够连接信息时标记该目标无效，不生成由多个目标拼成的分类；紧邻目标分离能力另报，不承诺零间距。
- [ ] **Verify:** 两个测试台逐位/断言零失败；新模型在多目标场景与目标管理对照。黄金生成由 `check_shape.py`消费任务2函数，不能用RTL结果反向生成预期。XML仅增算法源条目。
- [ ] **Commit:** 暂存本任务源/测试/工程源条目/驱动/验证记录，提交 `feat: accumulate bounded rotation geometry summaries`，推送；此时分类器旧逻辑尚未替换，不宣称抗旋转完成。

### Task 4: 定点分类接入与两帧时限

**Files:** 新增 `rtl/algo/shp_geometry.v`、`sim/algo/tb_shp_geometry.v`、`tb_shp_lifecycle.v`、`tb_shp_throughput.v`；修改 `shp_detect.v`、`tb_shp_rot.v`、`tb_shp_detect.v`、`tb_shp_ring.v`、`tb_shp_tilt.v`、`ti60f225_oob.xml`、`check_shape.py`、验证文档。

**Interfaces:** `shp_geometry`消费任务3读取接口及任务2参数；`start/start_ready, slot[2:0], bbox_x0/x1[11:0], bbox_y0/y1[12:0], bad`，输出 `done, valid, cls[2:0]`（仅0..3）。读取输出 `rd_req, rd_slot, rd_index`接摘要模块，输入`rd_valid/rd_data`；繁忙期间不受理下一start。`shp_detect`所有公开端口位宽/配置语义不变。

- [ ] **Red:** `tb_shp_geometry`用任务2正负矩阵黄金结果要求逐例同类、同有效位；`tb_shp_lifecycle`要求空帧/拒识场景2帧内无旧框、关闭立即无框、开关/复位后无旧槽数据、输出框表不在帧内撕裂。用 `valid==0`拒识，不用未知框冒充通过。
- [ ] **Red stress:** `tb_shp_throughput`按1280有效像素、1650总列、720有效行、750总行送720p光栅，标准6目标无溢出且源帧结束后≤2帧提交；故意密纹理挤满FQ=24、超过8槽、帧末未完成分类，要求受影响结果无效并增加诊断，不接受残缺形状。保留不含水平消隐的旧压力测试另报。
- [ ] **Run red:** 通过 `check_shape.py --rtl tb_shp_geometry/tb_shp_lifecycle/tb_shp_throughput`分别运行三台；旧旋转测试仍非零证明红灯。
- [ ] **Implement classifier:** 串行整数几何FSM逐位复现任务2：角点＋直边＋矩形垂直/平行、受限圆/椭圆残差、条带外凹陷拒识。删除 `c_cross`和class4，也删除以填充率/最宽行作为类别主判据的兜底；不能简单把旧class4改为class1/3。
- [ ] **Implement integration:** 摘要握手、分类退休、排序/提交按帧绑定；HOLD有效上限2、溢出/超时与坏槽拒识。对圆环内外嵌套轮廓按模型验证的同心/包含几何证据消除内环重复，不能仅凭bbox包含就吞掉其他目标。内部新增诊断以既有 `o_ovf`汇总不可用事件（饱和16bit，文档明确其扩大为识别处理异常计数），不改变UART字段/字节数；若不能定位受影响槽，整帧拒识比假分类优先。保留S/Y/W/A，Z/FL接受但不控制新主分类。
- [ ] **Verify:** 模型/摘要/分类/旋转/圆环/生命周期/吞吐全部通过；完整矩阵在分类模块对拍，端到端流式测试覆盖至少0/15/30/40/45/60/90/135°、每类/每尺寸和多目标，不把单模块对拍当作已经验证连接管理。旧直立/倾斜测试仍输入十字，预期改为负样本而非删输入。多目标间距扫描2/4/8/16/32px记录分离范围，≥16px干净非接触多目标必须正确；更近的容差歧义可拒识并记录，不以固定纸张布局补偿。
- [ ] **Commit:** 显式暂存本任务文件，提交 `feat: classify three rotated shapes with bounded frame lifetime`，推送。

### Task 5: 删除十字显示并保留字体/调参兼容

**Files:** 修改 `rtl/algo/shp_overlay.v`、`tools/gen_font.py`、`shp_font.mem`、`tools/alg_tuner.py`、`sim/algo/tb_shp_overlay.v`；新增 `sim/algo/test_shape_compat.py`；更新验证文档。

**Interfaces:** 叠加端口、原两拍输出延迟、类别1/2/3颜色、32×16标注位置不变；生成脚本CLI不变，GLYPHS索引5/6使用空占位，7/8仍为“未”“知”。非法class4不画框/文字，默认未知字模仍用于class0接口兼容。

- [ ] **Red:** `test_font_slots`断言256行、80..111全零、其他行与改前快照逐位一致；`test_generator_keeps_unknown_indices`生成临时字体到outflow后检查相同规则。`tb_shp_overlay`注入class4/bval1要求 `ov_hit=0`，并校验三类原色、未知字模、mode0左右半幅、mode1..3坐标及两拍延迟。
- [ ] **Run red:** `& $shapePython -m unittest discover -s sim/algo -p test_shape_compat.py -v`及 `check_shape.py --rtl tb_shp_overlay`；旧十字字体/显示路径使测试失败。
- [ ] **Implement:** 删除class4绿色与十字字模选择，对非法class4命中屏蔽；生成器跳过两个空占位，既有字体仅清零5/6槽以避免重新渲染改变其余字。调参台删除四类描述，Z显示为“旧版填充率（新分类不使用）”，OVF描述改为识别处理异常计数而非仅FIFO；串口仍发送/解析原Z/FL范围800..990与旧字段。
- [ ] **Verify:** 两组测试通过；纯软件调参协议测试验证旧108字节状态行与S/Y/Z/W/A命令原语义，不能打开/抢占COM5。检查活跃RTL/tools无OCR入口或class4生成，历史资料和旧位流不删除。
- [ ] **Commit:** 暂存本任务显示/字体/GUI/测试/验证记录，提交 `refactor: remove cross class and preserve shape label compatibility`，推送。

### Task 6: 完整回归、资源时序和可追溯交付

**Files:** 更新 `check_shape.py`、`docs/shape_rotation_validation.md`、`HANDOFF.md`、`AGENTS.md`、`candidate_bitstreams/README.md`；通过门禁才新增 `candidate_bitstreams/shape_rotation_<源码短提交>_20261001.bit`（实际日期变化则用实际日期）。

**Interfaces:** CLI `check_shape.py --all`运行模型和全部形状测试、失败非零；文档区分原有配置测试失败、本轮新增失败、编译和板测状态。只在通过构建门禁后归档位流。

- [ ] **Red gate:** 驱动遇到任一模型/RTL断言失败、无结果、超时都不输出ALL PASS；将任务1的失败传播测试补到全部测试路径，不用缺文件skip作通过。
- [ ] **Verify shape:** `& $shapePython -m unittest discover -s sim/algo -p 'test_shape_*.py' -v`；`& $shapePython sim/algo/model/check_shape.py --all`必须零失败、零未解释标准样本拒识。
- [ ] **Verify existing chain:** `& $shapePython sim/algo/model/check_chain.py`、`check_ebridge.py`；`check_shape.py --rtl tb_alg_tel_shp`和 `--rtl tb_alg_cfg_uart`。已有cfg_uart的65字节测试窗/现108字节协议不符需复现、记录；只更新确证失效的测试预期并重跑，若仍失败明确列阻塞，不写“全套通过”。
- [ ] **Build:** `& .\tools\compile.bat`退出0；检查 `outflow/compile.log`四阶段PASS、`ti60f225_oob.hier_util.rpt`与 `ti60f225_oob.timing.rpt`。新增RAM≤8、总RAM≤256、DSP≤160、所有相关时钟setup/hold无负slack且没有新增未约束路径；不通过则不提供可烧录候选，不改时钟来掩盖问题。
- [ ] **Archive:** 先提交所有构建输入并记录确切源码提交及干净状态；确认位流来自这些输入后，用原生Copy-Item归档到上述候选路径，记录大小/SHA-256/软件与RTL成绩/资源时序/尚未JTAG及肉眼验收。不得覆盖known_good或最佳烧录脚本。
- [ ] **Commit/push:** 显式暂存归档位流、验证文档、候选README与交接状态，提交 `docs: archive three-shape rotation candidate and validation`；`git -c 'http.https://github.com.proxy=socks5://127.0.0.1:10808' push origin shape-detect`，再以同参数 `ls-remote origin refs/heads/shape-detect`核对远端SHA=本地HEAD；每任务推送使用相同只对该命令生效的代理。
- [ ] **Hand off:** 给板主候选路径/哈希、JTAG操作建议、旋转三类与十字拒识/空帧清框的观察清单；等待用户另行授权烧录及实测反馈。未上板不晋升最佳版。

## 本次计划状态及自审

- 用户已确认具体设计；本实施计划待审阅和选择执行方式，目前所有任务均未执行。
- 已逐节检查设计§1..§7：范围/保护→全局约束，模型/摘要→任务2/3，分类/期限→任务4，移除十字→任务5，回归/交付→任务1/6；五项Review Focus各有归属测试。
- 唯一参数配置由任务2通过软件门禁后固定，后续任务消费同名接口和数据编码；不是允许RTL实现者自行调一套参数。门禁失败须回到设计讨论。
- 建议当前对话直接实施（Native）：6任务共享模型/摘要/RTL接口，用户此前关注额度；不为每个小任务重复开新上下文。另一选项为分任务子代理实现并逐项独立评审（Subagent-driven），更细致但成本较高。
- 本轮改前快照：`D:\FPGA_Project\_backups\20261001_102433_pre-three-shape-rotation-plan`；已验证294文件、35refs、0遗漏，可恢复。恢复目标以快照STATUS.txt为准。
- 本文件不表示算法、十字移除或新位流已完成；按writing-plans技能要求，等待计划审阅及执行方式确认后才实现。
