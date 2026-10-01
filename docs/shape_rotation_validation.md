# 三类抗旋转识别：验证记录

## 状态与范围

2026-10-01，用户选择当前对话内实施已确认的设计/计划。工作副本为
`D:\FPGA_Project\imx219_shape` / `shape-detect`，实现起点 `47aa44e`。
只保留圆形/圆环、三角形、矩形；十字拒识，不做OCR，保留类别文字标注。
最佳回退版及冻结实验版不动；不自动JTAG、不写Flash、不自行晋升最佳版。

当前已完成测试驱动、软件模型门禁、摘要与三类定点分类器接入；
审查修复后完整10381例RTL几何对拍及最终产品构建通过。已归档可供板主测试的
`shape_rotation_34e5d39_20261001.bit`，**尚未JTAG或上板肉眼验证**。
旧 `shape_rotation_e74ced2_20261001.bit` 已失效，不得用于本轮验收。
任务1的功能红灯是旧RTL基线，不是现行版本的测试结论。

## 任务1：失败基线与真实退出码

改前快照 `D:\FPGA_Project\_backups\20261001_103516_pre-three-shape-task1`：
295个文件、35个refs、零缺失；验证输出 `RESULT: BACKUP VERIFIED RESTORABLE`。

```powershell
$shapePython = 'C:\Users\HUAWEI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$env:ALG_OSS_BIN = 'C:\iverilog\bin'
$env:PYTHONDONTWRITEBYTECODE = '1'
& $shapePython -m unittest discover -s sim/algo -p test_shape_runner.py -v
& $shapePython sim/algo/model/check_shape.py --rtl tb_shp_rot
```

驱动实现前，7项真实进程测试中6项失败；实现后7项全部通过（退出0）。
覆盖缺失测试台、编译错误、失败断言、打印FAIL却返回0、无成功断言、超时，
及成功断言正常返回0。临时仿真产物在忽略的 `outflow/diagnostics/`。

修正 `tb_shp_rot.v` 的预期后，未改产品RTL时实际退出1、4个错误：

| 帧 | 正确预期 | 旧RTL实际 | 误判框 | FIFO溢出 |
| --- | --- | --- | --- | --- |
| 1 | 圆0/矩形6/三角0/十字0 | 圆0/矩形5/三角0/十字1 | cls4，(733,493)..(847,607)，45°方形 | 0 |
| 2 | 圆2/矩形2/三角0/十字0 | 圆2/矩形1/三角0/十字1 | cls4，(93,493)..(207,607)，40°方形 | 0 |

每帧各有“矩形数少1、十字数多1”两项失败。旧测试把这些误判写成预期，
因此原来的 errors=0 不代表抗旋转识别合格。新测试不依赖旧内部FSM编号。

### 实施裁决

- Task 1 Ruling: 增加 `sim/algo/fixtures/runner/` 的6个小型真实Verilog样本，
  超出计划原4个文件边界，用于不模拟subprocess地验证驱动失败行为。
  若取舍有误，代价是少量测试文件；无产品功能变化。

## 任务2：软件门禁

改前快照 `D:\FPGA_Project\_backups\20261001_104743_pre-three-shape-task2`：
310个文件、35个refs、零遗漏，VERIFIED RESTORABLE。

完整轮廓参考模型与32方向极值点/4行条带整数摘要模型独立分类。
两者输入来自同一确定性栅格边缘；分类函数不接收名称、旋转角度或预期标签。
完整参考使用有序外轮廓拟合；整数模型不调用OpenCV分类，使用整数凸包、
尺度归一化简化、垂直/平行检查、条带凹陷与曲线残差。圆环内孔不当作外凹陷。
官方轮廓接口参考：[OpenCV contour features](https://docs.opencv.org/4.x/dd/d49/tutorial_py_contour_features.html)。

```powershell
& $shapePython -m unittest discover -s sim/algo -p test_shape_model.py -v
& $shapePython sim/algo/model/check_shape.py --model
```

实测9项unittest通过；CLI退出0并输出 `MODEL GATE PASS`。模型初始缺失时
7项失败；第一轮实现正样本失败1374次，而负样本通过。根因是把最短多边形边长
检查误用于曲线细分，以及把内接凸包外侧的采样边缘误当凹陷。
修正这两项实现语义，未放宽配置阈值、未删矩阵或逐角度特判；重跑正样本零错误。

### 标准集结果（每个模型独立）

角度0..355°步进5°；尺寸48/80/160；三个位置、两个相位。

| 输入 | 样本数 | 完整轮廓正确/拒识/误识 | 整数摘要正确/拒识/误识 |
| --- | ---: | --- | --- |
| 圆环 | 1296 | 1296/0/0 | 1296/0/0 |
| 实心圆 | 1296 | 1296/0/0 | 1296/0/0 |
| 等边三角 | 1296 | 1296/0/0 | 1296/0/0 |
| 正方形 | 1296 | 1296/0/0 | 1296/0/0 |
| 矩形宽高比1.5 | 1296 | 1296/0/0 | 1296/0/0 |
| 矩形宽高比2 | 1296 | 1296/0/0 | 1296/0/0 |
| 十字（臂宽0.15/0.3/0.5） | 648 | 0/648/0 | 0/648/0 |
| 直线/五边形/星形 | 648 | 0/648/0 | 0/648/0 |

标准正样本共7776、负样本1296（每模型）。另测镜像/平移、Q8系数、
极值同分按(y,x)字典序、条带边界、空输入及非法游程。

### 诊断边界，不作任意噪声/透视承诺

固定随机种子20261001；66个额外样本，每组6个。
断边为顶部边界水平删除指定宽度、3行高区域；噪点为ROI内随机盐点；
透视为ROI顶部缩进指定比例的最近邻单应变换。其严重度不是实际纸张倾斜角度。

| 变化 | 完整轮廓正确/拒识/误识 | 整数摘要正确/拒识/误识 |
| --- | --- | --- |
| 断边1px | 0/6/0 | 4/2/0 |
| 断边3px | 0/6/0 | 3/3/0 |
| 断边5px | 0/6/0 | 3/3/0 |
| 盐点2个 | 2/4/0 | 2/4/0 |
| 盐点8个 | 0/6/0 | 0/6/0 |
| 盐点16个 | 0/6/0 | 0/6/0 |
| 截断10% | 0/6/0 | 0/6/0 |
| 顶部缩进5% | 0/6/0 | 5/1/0 |
| 顶部缩进15% | 0/6/0 | 3/3/0 |
| 顶部缩进30% | 0/6/0 | 1/5/0 |
| 装饰矩形 | 6/0/0 | 6/0/0 |

轻量摘要不是完整轮廓，不能可靠检测所有小断口；本诊断集无错误类别，
但拒识率和完整模型不同。装饰矩形仍识别为矩形，无法仅凭边缘判断纸面用途。
标准集通过不代表实拍图或任意透视通过，后续板测仍必需。

唯一参数表 `sim/algo/model/shape_params.json` SHA-256：
`91C43D27AEDABCEFB6CFDBAD57782FA4BC4007A57377EDE1E0A35AD1110D54B1`。
依赖实测Python3.12.14、NumPy2.5.2、OpenCV5.0.0。
旧产品RTL未改，旋转测试的4项红灯仍保留。
本任务结束时重跑全部16项Python测试通过；原 `check_chain.py` 与
`check_ebridge.py` 均退出0、RESULT PASS（逐位 mismatch 0）。

## 任务3：流式几何摘要与近期连接证据

`shp_summary` 按槽保存32方向的Q8支撑点和4行条带，命令完成后才允许
读取；清槽、合并、复位和边界坐标均由软件模型生成的黄金向量逐字对拍。
`tb_shp_summary` 的11阶段检查通过。

`shp_recent` 每槽保留至多16个真实的近期游程。仅有近期行、水平间隙
分别不超过4行、6像素时才连接；覆盖仍在4行有效期内的记录时将目标
标记为不可用。查询按单端口RAM逐条扫描，因此必须在任务4验证FIFO吞吐。
`tb_shp_connect` 中两个不接触但历史包围框重叠的嵌套矩形保持分离。
此项测试只验证连接安全，不代表三类旋转分类或整帧吞吐已经通过。

任务4为圆环内外双轮廓和多目标吞吐把近期游程容量调至每槽32条，
并在有序槽中从最新游程反向扫描、遇到过期行提前结束；合并后改为全扫描。
`tb_shp_recent` 已覆盖32条容量和合并语义。下述任务3资源/时序数字
是旧分类器及16条游程版本的历史记录，不代表任务4的最终构建。

Efinity 初次映射在推断多读端口近期游程数组为RAM时报告端口宽度断言
和内部异常。改成并行寄存器后通过映射，却在布局时报70869/60800
逻辑位置超限；逐槽并行版本仍需66213。现在改用单端口顺序扫描RAM，
且 `tb_shp_recent` 验证了扫描、合并、间隙和容量标记。单端口版综合/
打包为42732/60800逻辑位置、245/256 RAM、46/160 DSP。完整构建
map/interface/pnr/pgm 四阶段均PASS；本次时序报告的setup最小0.414ns、
hold最小0.026ns。此时分类器仍是旧逻辑，摘要读取尚未接到分类器，故
任务4接通后的资源、时序和行为必须重新验证。本次生成的bit不是三类
抗旋转候选，不能用来验收新功能。

## 任务4：定点三类分类器与流式接入

改前快照 `D:\FPGA_Project\_backups\20261001_120029_pre-three-shape-task4`：
已验证可恢复。新 `shp_geometry.v` 使用32方向极值、每4行左右轮廓摘要、
整数直线/边长/垂直平行关系及椭圆残差分类；只产生类1/2/3，
十字和不可信轮廓输出 `valid=0`。轮廓内侧同心、同类别、相互包含时，
只保留圆环外侧的一个检测框，避免靠单纯bbox包含误删不同类别。

本轮发现软件摘要模型把光栅化大三角顶点约9px短平边当作第四边，
因此以统一参数 `min_side_pixels=12` 合并恰好一条短边，并重跑软件标准
及负样本全集；未按旋转角度特判。新参数表SHA-256：
`14EE97AE06492D91651DB56E3376A5618FAD34CF6BDF8D644E859FE28820D6F4`。
完整软件门禁仍通过，每模型7776个正样本及1296个负样本零误判/漏判。

`tb_shp_geometry` 对同一10369条黄金向量逐例比较类别/有效位，退出0，
输出 `SHAPE_TEST_PASS tb_shp_geometry 10369 golden cases`。流式测试已确认：
旋转矩形0/8/15/22/30/40/45°、多个圆、倾斜三角形、四个纵向错开的
圆环，以及三类拒识/空帧/关闭再开启。间距扫描2/4px保守拒识，
8/16/32px分离并正确识别；不依赖当前纸张上的固定间距。

在诊断计数修补后，重跑 `tb_shp_summary`、`tb_shp_recent`、
`tb_shp_connect`、`tb_shp_rot`、`tb_shp_detect`、`tb_shp_ring`、
`tb_shp_tilt`、`tb_shp_spacing`、`tb_shp_lifecycle`、
`tb_shp_throughput`，均退出0并打印各自的 `SHAPE_TEST_PASS`。
软件模型门禁再次退出0，10项单元测试通过；全矩阵每模型
7776/7776正样本正确、1296/1296负样本拒识。

端到端测试在720p有效区、1650总列、750总行节拍下验证；六目标标准场景
无FIFO溢出，故意密纹理溢出会使受影响帧无效。另用生命周期测试注入
近期游程摘要异常，先证实旧诊断漏计，再修改为饱和计入 `o_ovf`，
该坏槽不能产出肯定类别。更密集且同一高度的多圆环尚未作为保证范围；
零间距/接触、任意透视和遮挡也不承诺。

诊断计数修补之前的Task4版本曾完成Efinity四阶段PASS，映射估计为
54846/60800逻辑位置、251/256 RAM、154/160 DSP；最终setup最小
0.326ns、hold最小0.023ns。此数字证明当时的主分类链路可布局布线，
**但不是修补后及任务5显示改动后的最终构建结果**。最终构建须在任务6
重新执行，才能归档候选位流。当前不能归档或烧录任务4位流。

## 任务5：三类显示与字库兼容

改前快照 `D:\FPGA_Project\_backups\20261001_133512_pre-three-shape-task5`：
534文件、35 refs、零遗漏，输出 `RESULT: BACKUP VERIFIED RESTORABLE`。

先写测试观察到旧版失败：现有字库及生成器的80..111行仍为十/字，
叠加层仍将class4画成绿色框；调参台的Z字段仍声称新分类使用填充率。
修正后 `test_shape_compat.py` 3项通过，`tb_shp_overlay`退出0并打印
`SHAPE_TEST_PASS`。旧字库只有索引5/6对应的32行被清零，其他224行
拼接SHA-256保持 `7533d4f5207d344410b96143cac84bc70c1a0b2f0a3b76825c9e9fef876c23c7`；
“未”“知”仍在索引7/8。叠加测试覆盖三类颜色、class4拒绝显示、
未知字模、左右半屏、mode1..3和精确两拍延迟。

调参台的S/Y/Z/W/A命令范围、Z→FL及108字节状态行解析保持兼容；
Z现在明确为新几何分类不使用的旧版参数。内部 `o_ovf` 是饱和的识别
处理异常计数，但旧108字节遥测没有OVF字段，因此软件界面不伪造
该字段的读回。未打开或占用实板COM端口。旧 `tb_alg_tel_shp` 原生运行
17项全部PASS，统一驱动最初因缺少 `SHAPE_TEST_PASS` 标记将它判为失败；
任务6已修正该测试台的成功标记，其17项经统一驱动重新通过。
未修改产品遥测协议。

## 任务6：整套回归与最终构建

改前快照 `D:\FPGA_Project\_backups\20261001_134200_pre-three-shape-task6`：
537个文件、35个refs、零遗漏，输出 `RESULT: BACKUP VERIFIED RESTORABLE`。

为 `check_shape.py --all` 增加真实进程失败传播测试：缺失测试台、编译失败、
运行时失败、伪成功、无断言、超时与模型失败均必须使整套门禁非零退出；
旧驱动的8项红灯已复现，修正后10项驱动测试通过。整套门禁运行全部
`test_shape_*.py` 和12个 `tb_shp_*`，几何单元强制跑10369例完整黄金矩阵。

现有 `tb_alg_cfg_uart` 沿用65字节/CRLF的历史预期，现行产品遥测已是
108字节/LF，且该测试台未连接后增的EPF/GF/BRG/SHP输入。对照现有
`tb_alg_tel_shp` 和产品端口后，只修正测试台输入和期望；统一驱动复跑
68项通过。`tb_alg_tel_shp` 的17项也经统一驱动通过。`check_chain.py`、
`check_ebridge.py` 在设置 `ALG_OSS_BIN=C:\iverilog\bin` 后逐位对拍通过，
无不匹配；首次未设置该环境变量的启动失败不是RTL失败。

最终 `check_shape.py --all` 退出0：23项Python形状测试通过，软件门禁
打印 `MODEL GATE PASS`，12个形状RTL台全部打印 `SHAPE_TEST_PASS`，
最后才打印 `ALL PASS`。`tb_shp_geometry` 使用全量10369例；多目标、
间距扫描、吞吐和叠加测试均在本次整套门禁中重新通过。单项
`tb_alg_tel_shp` 17项、`tb_alg_cfg_uart` 68项经统一驱动通过。

构建输入固定为干净的 `e74ced23e9cc758366dd5edbc09d947636c983c1`
（`shape-detect`）。随后运行 `tools/compile.bat`，命令退出0；
`outflow/compile.log` 中 map/interface/pnr/pgm 四阶段全PASS。
Efinity 2026.1.132.4.5 仍打印 `cannot find correct IV value` 警告，
但未阻止最终位流生成。最终 `place.rpt`：XLR 54819/60800，
RAM 251/256，DSP 154/160；RAM和DSP只剩5/6块，后续扩展必须重做
资源预算。`timing.rpt` 的15组时钟关系setup/hold均非负，
最小setup +0.222ns、最小hold +0.026ns；未见unconstrained条目。

`outflow/ti60f225_oob.bit` 于2026-10-01 14:01:16生成，逐字节复制到
`candidate_bitstreams/shape_rotation_e74ced2_20261001.bit`，大小3114330字节，
双方SHA-256均为
`CC906672CC24907D5F87E121DF214B527AE53F54A0F5570E5FAF4D7CA00461DB`。
`candidate_bitstreams/README.md` 记载来源及验证级别。该位流是**候选**：
尚未JTAG、尚未写Flash、尚未获板主肉眼验收，不可晋升最佳回退版。

**后续审查纠正：** `e74ced2` 位流虽通过上述当时门禁，最终审查发现
矩形下一条边索引误用（垂直判定实际为零向量）、关闭后待提交标签残留、
单个帧末请求位合并连续边界，以及四圆环同一高度时处理队列溢出。
因此该旧候选**不可用于本轮验收或烧录**，上方构建数字仅作为历史证据。
审查修复前已验证快照
`D:\FPGA_Project\_backups\20261001_141727_pre-shape-review-fixes`：
540文件、35 refs、零遗漏，结果为 `RESULT: BACKUP VERIFIED RESTORABLE`。
修复按失败测试推进：倾斜平行四边形曾被错判矩形；停用后旧标签曾在
空帧重现；背靠背 VS 边界曾合并为一次提交；同高四圆环曾溢出301次。
修正后的单项测试分别通过：`tb_shp_geometry` 589例、
`tb_shp_lifecycle`、`tb_shp_frame_epoch`（含满队列丢边界）、
`tb_shp_ring`（同高四环、溢出0）。`tb_shp_stream_matrix` 又通过
5类输入×8角度×3尺寸＝120个端到端样本，其中十字全部拒识；
保留的 `tb_shp_no_blank` 无水平消隐压力测试得到6个矩形、溢出0。
这些是软件仿真，不替代重新综合、时序检查和板上肉眼验收。

修复后全量门禁 `python sim/algo/model/check_shape.py --all` 退出0：
23项Python测试、10381例几何黄金对拍、15个RTL测试台均通过，
最终打印 `ALL PASS`。`check_chain.py` 与 `check_ebridge.py`
重新逐位对拍均为 `RESULT: PASS`、mismatch 0；
`tb_alg_tel_shp` 17项、`tb_alg_cfg_uart` 68项通过。
修复版源码、资源时序与位流另见下方构建记录；旧位流不得沿用。

二次只读审查又指出：输入端后一帧的游程溢出不应借用正在退休的
前一帧 `frame_fault`，以及丢失帧边界后不能在源帧中途恢复捕获。
因此停止了 `cd851c0` 的首次构建，**该中断构建不归档**。
修改前独立快照 `D:\FPGA_Project\_backups\20261001_145201_pre-frame-fault-review2`
经544文件、35 refs、零遗漏验证，输出
`RESULT: BACKUP VERIFIED RESTORABLE`。新增失败测试先复现中途恢复；
修正后 `capture_fault` 按源帧持有丢游程故障并随帧边界入队，
`sync_lost` 只在真实VS且旧工作清空后退出，恢复边界本身标为无效。
扩展的 `tb_shp_frame_epoch` 覆盖后一帧B溢出时前一帧A还在退休、
以及丢边界后下一帧中途不能重新捕获，两项均已单测通过。
复审未发现新的控制流问题；最终仍以重新全套回归与完整编译为准。
重新运行 `check_shape.py --all` 已退出0：23项Python、10381例
几何黄金对拍、15个RTL台均通过，最终输出 `ALL PASS`。

### 审查修复版最终构建（当前待上板候选）

从干净的 `shape-detect` 提交
`34e5d39b75654e2a8bb8d1149b2c9cd284750974` 执行 `tools/compile.bat`，
命令退出0，`outflow/compile.log` 中map/interface/pnr/pgm四阶段全部PASS。
`outflow/ti60f225_oob.bit` 于2026-10-01 15:16:33生成，大小3123549字节；
复制至 `candidate_bitstreams/shape_rotation_34e5d39_20261001.bit` 后，
原件和副本的SHA-256相同：
`EC1799C6DAE0B4D554A7E9184905328A833152B44F928220AEFBCB0D4AA8B32F`。
归档仅供板主安排JTAG实测，不覆盖 `known_good/`，未写Flash。

`place.rpt` 报XLR 54488/60800、RAM 251/256、DSP 154/160；
`timing.rpt` 报告的15组时钟关系setup/hold全部非负，最小分别为
+0.385ns / +0.026ns。`cdc.rpt` 没有同步器警告。编译日志仍有
`cannot find correct IV value` 非致命警告；PnR日志还有部分时钟名
`No clocks matched`、相关延迟约束未生效的SDC警告。因此上述时序结论
仅针对报告列出的路径，**不能据此宣称全部路径已获约束签核**；
若本轮需要最终时序签核，须单独核对SDC与被优化的IP端口。

板测建议依次看干净圆环、等边三角、正方形和长方形的0/15/30/45/90°
旋转，三类多目标间距变化、十字拒识、移开纸张后两帧内清框，并记录
类别/框位置/时延/溢出。透视倾斜、遮挡、断边和噪声属于诊断边界，
若失败需保存照片及角度/距离，不用本次干净旋转成绩代替实拍验收。
