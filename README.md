# Ti60F225 + IMX219 720p 边缘检测协作工程

这是供两名队员和各自 AI 助手协作的**本地 Git 工程**。主线从已在板上验证的灰度 + Sobel 版本整理而来；原始工程 `D:\FPGA_Project\imx219_hdmi_720p`、`D:\FPGA_Project\edge_detect_720p`、`D:\FPGA_Project\edge_median_720p` 未被修改。私有远端 `https://github.com/LMD132/imx219_team`（队友 `James-luo-haoran` 的邀请仍待接受）。

## 硬件与当前验证状态

- 开发板：Ti60F225I3 DemoBoard V4；摄像头：IMX219，2-lane MIPI CSI；输出：HDMI 1280×720。
- 工具：Efinity 2026.1；板载 FT4232H 调试器，JTAG ID 实测 `0x10660A79`。
- **已在板上确认**：`known_good/edge_detect_720p_verified.bit` 可显示左半边灰度、右半边黑白 Sobel 边缘，两边随摄像头实时变化。此版本也是当前 `main` 源码。
- **尚未确认**：`median-experiment` 分支加入 3×3 中值滤波后，已通过编译/时序检查并 JTAG 下载，但还没有队员反馈实际屏幕效果。不要把它标记成硬件验证通过。
- **已上板验证（数值层面）**：`uart-bringup` 分支的按键实时调阈值 + UART 遥测，以及 3×3 邻域计数去噪 + 目标外接框 + 帧像素计数（`candidate_bitstreams/overlay_box.bit`）。串口报文能证明设计在跑、按键动作逐次命中，且每帧 `PIX=921600`（= 1280 x 720，帧级无丢/无多像素）。
- **已上板验证（2026-09-26，P 旋钮版）**：`uart-bringup` 的彩色底图 + 红边叠加版已 JTAG 烧录（JTAG ID `0x10660A79`，板级串口 `COM5`），空载回读 `THR=024 SH=8 DS=3 EN=2 SRC=U PIX=921600 CV=1 HY=1 PD=08`；`PIX=921600` 证明帧级无丢像素，`P` 旋钮实测可调（`P40`->`PD=40`，`P8`->`PD=08`）。红边与彩图的水平/行对齐**未确认**（HDMI 采集卡当时不在位）。报 `No USB target detected` 时先跑 `tools\board_probe.ps1`。见 `docs/tuning_findings.md` 第 8、9 节。
- **已知不一致（2026-09-26）**：文档此前写的"上电 floor 16"在板上不成立——顶层两处把 `THRESHOLD_INIT` 显式覆盖成 24，板上空载是 `THR=024`；要真的上电即 16 得改 `rtl/ti60f225_oob_top.v` 第 422/472 行再重编译。见 `docs/tuning_findings.md` 第 9.2 节。
- **已肉眼确认（2026-09-24）**：默认参数下**红框能框住目标**。仍待确认：去噪档切换的可见程度、暗目标轮廓够不够用（这两点决定要不要上对比度增强）。见 `docs/key_threshold_control.md`、`docs/edge_overlay.md`、`docs/contest_status.md`。
- 现有分屏把完整 1280 像素画面的左半区显示为灰度、右半区显示为边缘；两半是各自的空间裁切，**不是同一完整视野缩放后并排**。这个展示细节仍可按赛题完善。

## 赛题对照与待办

赛题原件：`C:\Users\HUAWEI\Desktop\2026 FPGA竞赛赛题指南 -8.22(更正版).pdf`，相关内容在第 23–26 页。给队友时须另外确认资料包、赛题 PDF 和厂商代码的分享权限；不要上传公开仓库。

| 项目 | 状态 |
| --- | --- |
| IMX219 采集、DDR 帧缓存、720p HDMI 实时显示 | 已上板验证 |
| 无除法器灰度化、两行缓存、3×3 Sobel、参数化阈值、左右分屏 | 已上板验证 |
| 3×3 中值滤波后再 Sobel | `median-experiment` 已编译/JTAG，待屏幕验证 |
| 按键调节阈值及消抖 | **已上板验证**：KEY1/KEY2 调梯度门限、KEY3 短按切自适应档、长按切去噪档；串口逐次记录，无丢键无连跳 |
| 3×3 邻域计数去噪 + 目标外接框 + 帧像素计数（赛题高阶 ⑥） | `overlay_box.bit` 已编译/下载，每帧 `PIX=921600` 证明帧级无丢像素；**红框已肉眼确认能框住目标**；去噪可见度与暗目标轮廓待确认；框的适用局限见 `docs/edge_overlay.md` |
| 彩色底图 + 红色边缘叠加（同一视野） | 位流已上板并在跑（2026-09-26，`PIX=921600`）；红边与彩图的重合度待采集卡测量，见 `docs/tuning_findings.md` 第 8、9 节 |
| 同一视野的灰度/边缘并排、叠加、测延迟、演示视频及交付检查 | 未完成 |

## 关键文件

- `ti60f225_oob.xml`：Efinity 工程；顶层为 `rtl/ti60f225_oob_top.v`。
- `ti60f225_oob.peri.xml`、`ti60f225_oob.sdc`：引脚/接口与时序约束；改引脚前必须核对开发板资料。
- `piv2_720p_7M_2L_reg.mem`：IMX219 的 720p 摄像头配置。
- `rtl/edge_display_720p.v`：灰度、Sobel、阈值及分屏。主线阈值在顶层实例中设为 `180`。
- `tools/uart_listen.ps1`：监听板载串口（COM5）读遥测报文。
- `tools/board_probe.ps1`：烧录前判断板子是否真的在场（枚举 FTDI/串口）。报 `No USB target detected` 时先跑它，别反复重试 `program.bat`。
- `tools/capture_hdmi.py`、`tools/analyze_capture.py`：HDMI 采集卡录屏 + 在 PC 上复算板内整数流水线，把"画面好不好"变成数字。见 `docs/capture_and_quantify.md`。
- `known_good/edge_detect_720p_verified.bit`：恢复画面的已验证 JTAG 位流；不要覆盖。
  SHA-256：`146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355`。

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

下载前先跑 `tools\board_probe.ps1` 确认板子在场（退出码 1 = 板子没上电/线没插好/用了充电线）：
JTAG 下载是**易失**的：断电后需重新下载；按 CRESET_N 可能重新加载 Flash 中的旧设计。硬件测试前先确认屏幕 HDMI 输入、线材接触、摄像头小板指示灯。

## 双人协作规则

1. `main` 只放已在板上验证的版本；每个新功能从独立分支开发。`median-experiment` 属于待验证分支。
   `outflow/` 是被 Git 忽略的构建目录，切换分支**不会**切换里面的位流；下载前须重新编译当前分支，或明确选择 `known_good/` 的恢复位流。
2. 同学可独立负责 RTL、仿真、赛题对照或报告；开发板烧录由板子持有人统一安排，避免把软件编译通过误判成硬件成功。
3. 提交新功能时写明：改动文件、编译/时序结果、板上观察、回退用的已验证位流。合并前由另一名队员复核。
4. 不提交 `.codex/sessions`、账号/API 密钥、个人资料、完整工具生成目录。厂商源码和赛题附件在确认许可前仅限本地/获授权的私有共享。
