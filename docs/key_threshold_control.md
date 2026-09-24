# 按键实时调阈值 + UART 数字遥测

赛题高阶第 ② 项「按键实时调节阈值」。对应位流
`candidate_bitstreams/keys_threshold.bit`（分支 `uart-bringup`）。

## 1. 按键映射

板卡四个按键都是**低有效**（外部上拉，按下接地）。引脚来自厂商 key demo 的
`outflow/LED_8bit_Test.pinout.csv`，不是猜的。

| 板上丝印 | 信号 | `gpio_def` | 封装脚 | Bank | 用途 |
|---|---|---|---|---|---|
| KEY0 | `i_arstn` | `GPIOL_07` | C4 | TL | **已被复位占用**，未复用 |
| KEY1 | `i_key_thr_up` | `GPIOR_22` | P14 | BR | 噪声门限 +(step=8) |
| KEY2 | `i_key_thr_dn` | `GPIOR_21` | N14 | BR | 噪声门限 −(step=8) |
| KEY3 | `i_key_mode` | `GPIOL_03` | A3 | TL | 循环自适应档位 |

KEY0 与 `i_arstn` 同脚——按它就是复位，所以只引出 3 个可编程键。

## 2. 两个旋钮的物理含义

Sobel 判决式（`rtl/edge_display_720p.v`）：

```
active_threshold = max(center >> shift, floor)
edge_pixel       = valid && (|Gx| + |Gy|) >= active_threshold
```

- `floor` = 噪声门限，范围裁到 **0..255**，按键步进 8。
  > 255 没有意义：自适应项最大也只有 255（8bit 中心灰度全权重）。
- `shift` = 自适应项权重，KEY3 循环 `{8, 3, 2, 1, 0}`：

| 档位 | shift | 含义 |
|---|---|---|
| 0 | 8 | 自适应项清零 → **纯固定阈值**（老行为） |
| 1 | 3 | center/8 |
| 2 | 2 | center/4 |
| 3 | 1 | center/2（**上电默认**，与前一位流一致） |
| 4 | 0 | center，全权重自适应 |

## 3. 消抖

`rtl/key_debounce.v`：两级同步 → 与「已确认电平」比较 → 不一致才启动 20 ms
计数器（25 MHz × 20 ms = 500000 拍）→ 计满才采纳新电平。

- 抖动只会不断重置计数器，不影响已确认电平。
- 输出是**单拍脉冲**（下降沿），所以按住不放不会连续步进。
- 复位后 `stable` 初值为 1（按键空闲高），避免上电瞬间误判成一次按下。

## 4. UART 遥测

`rtl/uart_telemetry.v`，115200 8N1，与 `uart_banner.bit` 同一个引脚
`o_uart_txd → GPIOR_28`（R14）。

| 时机 | 报文（14 字节） |
|---|---|
| 复位后第一条（仅一次） | `TI60 UART OK\r\n` |
| 之后每 500 ms，或任一按键被按下 | `THR=nnn SH=n\r\n` |

保留开机横幅是故意的：`tools/uart_listen.ps1` 不用改就能确认通道仍然活着，
也保留了前一位流的 bring-up 证据。

⚠️ 节奏器仍然是 `S_GAP → S_LOAD → S_START → S_SEND` 四态。`uart_tx.o_busy`
是寄存器，从递交字节到 `busy=1` 有 2 拍，两态节奏器会在这个窗口重复触发、
隔一个字节丢一个。**不要简化回两态。**

监听：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA_Project\imx219_team\tools\uart_listen.ps1 -Ports COM5 -Seconds 5
```

## 5. 时钟域

按键消抖、阈值状态机、UART 全部跑在 `CLK_25M`（同一个域，无跨域问题）。
`w_edge_threshold` / `w_edge_shift` 被 2 级触发器重新采样进
`hdmi_tx_slow_clk`（HDMI 像素时钟）后才送进 `edge_display_720p`。
值只在按键时变化，最坏情况也就是一帧用旧值。

## 6. 上板验证记录（2026-09-24）

位流 `keys_threshold.bit`，SHA256
`92F2E33DC0DFD2DF173F0E9E43876A6A5E6491652188D904754DE96E32534DFC`

证据等级：**JTAG 下载 + 串口观测**（画面观感尚未收集）。

90 秒监听 `COM5` 收到 2590 字节 = **28.8 B/s**，与 14 字节/行 × 2 行/秒
（500 ms 周期）完全吻合，说明节拍精确。实测按键轨迹：

| 操作 | COM5 输出 | 判定 |
|---|---|---|
| 复位后 | `THR=024 SH=1` | 默认值正确（与前一位流一致） |
| KEY1 ×1 | `THR=032` | +8 ✅ |
| KEY2 ×2 | `THR=024`、`THR=016` | −8，无连跳 ✅ |
| KEY1 ×1 | `THR=024` | +8 ✅ |
| KEY3 ×2 | `SH=0`、`SH=8` | 1→0→8，循环正确 ✅ |
| KEY2/KEY1 交替 | `THR=016/024/032` | 继续正确 ✅ |

**每次按下正好走一步**，没有丢按键、没有重复步进 → 20 ms 消抖有效。

## 8. 后续变化（`overlay_box.bit`）

本文档描述的是 `keys_threshold.bit` 的行为，位流本身没有改动，所以上面所有
记录仍然有效。之后的 `overlay_box.bit` 在此基础上改了两点：

- KEY3 变成**短按 / 长按两用**：短按（松开时 <1 s）切自适应档，按住 >=1 s
  切去噪档 `{3,5,0,2}`。这样在不增加按键的前提下，去噪也能实时演示。
- UART 报文从 `THR=nnn SH=n\r\n`（14 字节）变成
  `THR=nnn SH=n DS=k PIX=nnnnnn\r\n`（30 字节），多出的 `DS` 是去噪档位，
  `PIX` 是上一帧的有效像素计数（干净 720p 恒为 921600，用来证明整帧无丢
  像素）。

细节见 `docs/edge_overlay.md`。
