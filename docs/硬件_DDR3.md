# 板载 DDR3：有没有、多大、跑多快、在不在通路上

**一句话**：有。2 Gbit（256 MB），16 bit 位宽，单 rank，DDR3-800
（400 MHz / 800 MT/s），而且是**真的在视频通路上工作**的，不是摆设。

## 为什么说它一定存在（不是照抄厂商 demo）

| 证据 | 位置 |
|---|---|
| 顶层实打实例化了 `ddr3_top u_ddr3_top`，DDR 总线全部接到芯片引脚 | `rtl/ti60f225_oob_top.v:666` |
| 引脚约束里有 **47 条 `ddr_*`**，`io_standard` 全是 **`1.5 V SSTL`** —— 这正是 DDR3 的电平标准 | `ti60f225_oob.peri.xml:91` 起 |
| `create_clock -period 2.500 -name sdram_clk` → **400 MHz**，并对 `ddr_addr[*]` 等写了 `set_output_delay` 相对 `sdram_clk` 的 DDR3 时序约束 | `ti60f225_oob.sdc:7`、`:87` 起 |
| 一整套 DDR3 PHY 校准 IP：写调平 / 读调平 / 写校准 / 校准初值 —— 没有真颗料根本不需要这些 | `rtl/ddr3_controller/phy_ctl/ddr_phy_wrlvl.v`、`ddr_phy_rdlvl_dqs.v`、`ddr_phy_wrcal.v`、`ddr_calibration_ini.v` |
| README 把 "IMX219 采集、DDR 帧缓存、720p HDMI 实时显示" 标为**已上板验证** | `README.md:37` |

## 容量与速度（从 `rtl/ddr3_controller/ddr3_parameter.vh` 算）

| 参数 | 值 | 依据 |
|---|---|---|
| 数据位宽 | 16 bit（x8 颗粒 2 颗） | `DQ_WIDTH=16`、`DRAM_WIDTH=8` |
| Bank × 行 × 列 | 8 × 16384 × 1024 | `BANK_WIDTH=3`、`ROW_WIDTH=14`、`COL_WIDTH=10` |
| **容量** | 8 × 16384 × 1024 × 16 bit = 2 Gbit = **256 MB** | 上两行相乘 |
| Rank / CS | 单 rank、单 CS | `CS_WIDTH=1`、`RANKS=1` |
| 速率 | `tCK=2500 ps` → 400 MHz → **DDR3-800（800 MT/s）** | `tCK`、`CL=6`、`CWL=5` |
| ODT / Burst | RTT_NOM 40 Ω、RTT_WR 60 Ω、BL8 | `RTT_NOM`、`RTT_WR`、`BURST_MODE` |

## 它在通路上（这是判定"DDR3 一定好着"的依据）

```
摄像头 MIPI RX ─► frame_buffer ─► 写进 DDR3 ─► 从 DDR3 读回 ─► cvo_axi 转成视频时序
                                                              └─► HDMI 像素流 ─► alg_top ─► 屏幕
```

接线在天花板级别明确，没有旁路：

| 步骤 | 位置 |
|---|---|
| `frame_buffer` 输出 `m_axis_tdata` 等 | `rtl/ti60f225_oob_top.v:579` |
| 送进 `cvo_axi` 的 `s_axis_*` | 同文件 `:646` |
| `cvo_axi` 输出 `{ch0_g, ch0_b}` / `ch0_de` | 同文件 `:659` |
| 进 RGB 通路（`raw_datax4_i` 等） | 同文件 `:786`–`:790` |
| 出来就是 `hdmi_tx_*`，同时喂给 `alg_top` 和 HDMI TX | 同文件 `:807`–`:827`、`:983`、`:1163` |

**所以：屏幕上有正常画面 ⇒ 这颗 DDR3 在场、校准通过、读写都是好的。**
如果它没焊或者坏了，`frame_buffer` 读出来是黑的，屏幕上不会有画面。

帧缓存配置：`FB_NUM=3`（三缓冲）、`MAX_VID_WIDTH=640`、`MAX_VID_HIGHT=720`、
`START_ADDR=32'h00000`（`rtl/ti60f225_oob_top.v:552` 的 `frame_buffer` 参数）。

## 对赛题的意义

`temporal_blend`（时间域帧间平均，压"白点闪 / 人闪"）之前被记为
"需要整帧缓存，而 Memory Blocks 已用 81.25%"（见 `docs/ALGO_RTL.md:324`）。
那个账是把存储算在**片内 BRAM** 上的。片外有 256 MB DDR3，
并且 `frame_buffer` 本来就在存整帧（还开了三缓冲），
所以"存不下两帧"不是 DDR3 的限制 —— 这一项在存储资源上是有余量的。

注意这只是**存储资源**的结论；真要做，还是要按
GitHub 那份 Python 源码 `edge_pipeline.py` 里 `temporal_blend` 的原意一比一移植，
不能自己另写一套平均逻辑。
