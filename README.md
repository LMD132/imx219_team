# Ti60F225 + IMX219 720p 边缘检测协作工程

这是供两名队员和各自 AI 助手协作的 Git 工程，私有远端为 [LMD132/imx219_team](https://github.com/LMD132/imx219_team)。主线从已在板上验证的灰度 + Sobel 版本整理而来；原始工程 `D:\FPGA_Project\imx219_hdmi_720p`、`D:\FPGA_Project\edge_detect_720p`、`D:\FPGA_Project\edge_median_720p` 未被修改。

## 硬件与当前验证状态

- 开发板：Ti60F225I3 DemoBoard V4；摄像头：IMX219，2-lane MIPI CSI；输出：HDMI 1280×720。
- 工具：Efinity 2026.1；板载 FT4232H 调试器，JTAG ID 实测 `0x10660A79`。
- **已在板上确认**：`known_good/edge_detect_720p_verified.bit` 可显示左半边灰度、右半边黑白 Sobel 边缘，两边随摄像头实时变化。此版本也是当前 `main` 源码。
- **中值滤波待调**：`median-experiment` 分支已通过编译/时序检查并 JTAG 下载。队员观察到右侧不少边缘消失，因此不能把它标记为画面验收通过，也不能合入 `main`。
- 现有分屏把完整 1280 像素画面的左半区显示为灰度、右半区显示为边缘；两半是各自的空间裁切，**不是同一完整视野缩放后并排**。这个展示细节仍可按赛题完善。
- **算法全链移植（`py-algo-rtl` 分支，2026-09-26）**：把 GitHub 仓库
  [liuziyaoyao1210-sudo/FPGA-Python](https://github.com/liuziyaoyao1210-sudo/FPGA-Python)
  的 `edge_pipeline.py`（灰度 → 中值 → 5×5 高斯 → Sobel → NMS → 双阈值滞后 → 去孤点）
  完整改写成 Verilog，放在 `rtl/algo/`。已通过 **逐位对拍**（仿真 7 级 × 3 种模式
  0 mismatch；与仓库原始 Python 逐级 0 mismatch）和 **Efinity 全流程编译**
  （`map/interface/pnr/pgm` PASS，无负 slack）。**尚未 JTAG 下载、尚未上板肉眼确认。**
  该分支同时修正了上面那条分屏口径问题（mode 0 = 同一完整视野 2:1 抽取）。
  算法的来源、逐级映射、延迟表与对齐原理见 [`docs/ALGO_RTL.md`](docs/ALGO_RTL.md)。

## 赛题对照与待办

赛题原件：`C:\Users\HUAWEI\Desktop\2026 FPGA竞赛赛题指南 -8.22(更正版).pdf`，相关内容在第 23–26 页。给队友时须另外确认资料包、赛题 PDF 和厂商代码的分享权限；不要上传公开仓库。

**逐条细则的对照见 [`CONTEST_CHECKLIST.md`](CONTEST_CHECKLIST.md)**（基础 12 条细则 + 高阶 6 项，含证据与缺口）；下表是摘要。

| 项目 | 状态 |
| --- | --- |
| IMX219 采集、DDR 帧缓存、720p HDMI 实时显示 | 已上板验证 |

`main` / `median-experiment`（旧，已上板验证过一部分）：

| 项目 | 状态 |
| --- | --- |
| 无除法器灰度化、两行缓存、3×3 Sobel、参数化阈值、左右分屏 | 已上板验证（`main`） |
| 3×3 中值滤波后再 Sobel | `median-experiment` 已编译/JTAG；画面右侧丢失不少边缘，待调优 |

`py-algo-rtl`（算法全链移植，**仿真/编译通过，未上板**）：

| 项目 | 状态 |
| --- | --- |
| 无除法器灰度化、行缓存 3×3 窗口、3×3 Sobel + \|Gx\|+\|Gy\|、运行期可配阈值 | ✅ RTL + 逐位对拍 |
| 高阶① 3×3 中值（19 比较器排序网络） | ✅ RTL + 逐位对拍 |
| 高阶④ 完整 Canny（5×5 高斯 → 幅值+方向 → NMS → 双阈值滞后 → 去孤点） | ✅ RTL + 逐位对拍 |
| 高阶⑤ 边缘红边叠加彩色输出 | ✅ RTL（mode 1） |
| 赛题④ 同一完整视野的灰度/边缘并排显示 | ✅ RTL（mode 0，逐位对拍 306 像素 0 mismatch） |
| 按键实时调阈值（含消抖） | 🔄 阈值已是运行期寄存器；按键硬件接入与消抖未做 |
| 高阶③ DDR 帧缓存的回放/冻结/多帧对比 | 🔄 整帧经 DDR 中介成立；扩展功能未做 |
| 高阶⑥ 圆/矩形识别 + 屏幕文字 | ❌ 未做 |
| 时间域平均 `temporal_blend`（压帧间白点闪烁） | ❌ 未 RTL 化（下一步优先级最高） |
| JTAG 下载、上板画面确认、演示视频 | ❌ 未做 |

## 关键文件

- `ti60f225_oob.xml`：Efinity 工程；顶层为 `rtl/ti60f225_oob_top.v`。
- `ti60f225_oob.peri.xml`、`ti60f225_oob.sdc`：引脚/接口与时序约束；改引脚前必须核对开发板资料。
- `piv2_720p_7M_2L_reg.mem`：IMX219 的 720p 摄像头配置。
- `rtl/edge_display_720p.v`：灰度、Sobel、阈值及分屏。主线阈值在顶层实例中设为 `180`。
- `known_good/edge_detect_720p_verified.bit`：恢复画面的已验证 JTAG 位流；不要覆盖。
  SHA-256：`146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355`。

`py-algo-rtl` 分支新增：

- `rtl/algo/`：算法全链 RTL（`alg_gray` `alg_win` `alg_median3` `alg_gauss5` `alg_sobel3`
  `alg_nms` `alg_stream_delay` `alg_thresh` `alg_despeckle` `alg_vdisp` `alg_top`）。
  其中 `alg_align.v`、`alg_disp.v` 是早期版本，**未被例化**，保留备查。
  在 `py-algo-rtl` 分支上，顶层用 `alg_top` 取代了 `edge_display_720p` 实例
  （`edge_display_720p.v` 文件仍在，供 `main` 回退用）。
- `docs/ALGO_RTL.md`：**算法溯源、Python↔RTL 逐级映射、延迟表、显示对齐原理、
  资源/时序实测、未 RTL 化清单**。看算法先看这份。
- `sim/algo/tb_alg_chain.v`：全链路测试台。
- `sim/algo/model/`：逐位对拍工具（`rtl_model.py` 金标准模型、`check_chain.py` RTL 全链路对拍、
  `check_py_repo.py` 仓库 Python 对拍）和算法参考源快照 `ref/FPGA-Python-main/`。
  `check_py_repo.py` 只依赖 numpy + opencv，可直接重跑；RTL 仿真需要 iverilog，用
  `ALG_OSS_BIN` 指到 oss-cad-suite（约 2GB，不入库）。
- `candidate_bitstreams/`：候选位流 + 来源提交、SHA-256、上板状态记录。见该目录 `README.md`。

## 编译与下载（Windows CMD）

先在本工程目录打开 CMD，按实际安装位置调整 Efinity 路径：

```bat
call C:\Efinity\2026.1\bin\setup.bat
C:\Efinity\2026.1\python311\bin\python.exe C:\Efinity\2026.1\scripts\efx_run.py ti60f225_oob.xml --flow compile
```

编译成功应看到 map、interface、pnr、pgm 全部 `PASS`，并检查 `outflow/ti60f225_oob.timing.rpt` 中相关时钟 setup/hold slack 为正。下载前先核对所选 `.bit` 路径和连接的 FPGA：

```bat
call C:\Efinity\2026.1\bin\setup.bat
call C:\Efinity\2026.1\pgm\bin\ftdi_pgm.bat known_good\edge_detect_720p_verified.bit -m jtag -b "Generic Board Profile Using FT4232H" --jtag_clock_freq 6000000
```

JTAG 下载是**易失**的：断电后需重新下载；按 CRESET_N 可能重新加载 Flash 中的旧设计。硬件测试前先确认屏幕 HDMI 输入、线材接触、摄像头小板指示灯。

## 双人协作规则

1. `main` 只放已在板上验证的版本；每个新功能从独立分支开发。`median-experiment`、`py-algo-rtl`
   都属于待验证分支（`py-algo-rtl` 已过编译与逐位对拍，但未上板）。
   `outflow/` 是被 Git 忽略的构建目录，切换分支**不会**切换里面的位流；下载前须重新编译当前分支，或明确选择 `known_good/` 的恢复位流。
2. 同学可独立负责 RTL、仿真、赛题对照或报告；开发板烧录由板子持有人统一安排，避免把软件编译通过误判成硬件成功。
3. 提交新功能时写明：改动文件、编译/时序结果、板上观察、回退用的已验证位流。合并前由另一名队员复核。
4. 不提交 `.codex/sessions`、账号/API 密钥、个人资料、完整工具生成目录。厂商源码和赛题附件在确认许可前仅限本地/获授权的私有共享。
5. 后续有价值的新源码、仿真/测试、配置、验证记录和必要的候选位流统一放在本仓库并提交到对应分支、推送到现有**私有**远端，便于双人备份。候选位流放在 `candidate_bitstreams/`，附上来源提交、SHA-256 和实际板上状态；只有经过画面验证的位流才可进入 `known_good/`。`outflow/`、缓存、临时日志/波形不入库，必要结论写入跟踪的 Markdown 文件。推送前检查差异，避免泄露密钥、个人会话及未经许可的资料。
