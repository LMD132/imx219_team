# 三类抗旋转识别：验证记录

## 状态与范围

2026-10-01，用户选择当前对话内实施已确认的设计/计划。工作副本为
`D:\FPGA_Project\imx219_shape` / `shape-detect`，实现起点 `47aa44e`。
只保留圆形/圆环、三角形、矩形；十字拒识，不做OCR，保留类别文字标注。
最佳回退版及冻结实验版不动；不自动JTAG、不写Flash、不自行晋升最佳版。

当前完成测试驱动，**软件模型、产品RTL、编译及上板验证尚未完成**。
功能红灯是待修问题，不是全套测试通过。

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

## 任务2：软件门禁（待执行）

先对完整轮廓参考模型及32方向极值点/4行条带整数摘要模型独立测试。
标准集必须正确，十字必须拒识；不达标则停在软件阶段修订设计，不直接写RTL。
官方轮廓接口参考：[OpenCV contour features](https://docs.opencv.org/4.x/dd/d49/tutorial_py_contour_features.html)。
