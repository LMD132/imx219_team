# `median-experiment` 验证记录

这条分支在已经上板验证的灰度 + Sobel 主线上增加 `rtl/median_filter_3x3_720p.v`。滤波器采用两行缓存构建 3×3 窗口，再用寄存器流水化的 9 轮奇偶比较交换求中值。左侧仍显示未滤波灰度，右侧 Sobel 改为处理中值滤波后的灰度。

- 2026-09-24：在原独立目录 `D:\FPGA_Project\edge_median_720p` 完整编译 PASS，并成功经 JTAG 下载至 ID `0x10660A79` 的 FPGA；尚未收到板上画面的确认反馈。
- 2026-09-24：把同一源码整理进本分支，并在本协作目录重新完整编译，map / interface / pnr / pgm 均 PASS。
- 本目录时序报告 `outflow/ti60f225_oob.timing.rpt`：`hdmi_tx_slow_clk` 自身 setup slack `+7.780 ns`，hold slack `+0.035 ns`。
- 仍需队员观察：左灰度、右边缘是否实时；噪声场景下过滤效果；边界两行/两列是否可接受。上述未完成前不要合入 `main`。

回退时可切回 `main` 编译，或直接 JTAG 下载 `known_good/edge_detect_720p_verified.bit`。JTAG 为易失下载，不要误写 Flash。
