# 队友的 image_processing 这套 RTL：能不能烧到 Ti60F225 上

结论先说：**接口能接、语法改完能综合过，但按现在的写法放不进 Ti60F225**。
`map` 过了，`pnr` 在 block capacity check 上失败，缺口不是"逻辑多一点"，而是
差 3.8 倍的移位寄存器资源。根因只有一个：`delay_n` 用移位寄存器链来做**行级**
延迟（最长的 8967 拍）。这个可以修，见第 5 节。

来源：`C:\Users\HUAWEI\Desktop\rtl_sources\`（9 个 .v + `README_集成.md`）。
实验分支：`teammate-ip`（从 `uart-bringup` 拉出）。**没有烧板**，`uart-bringup`
和 `main` 都没动，板子上跑的还是 2026-09-26 0:57 烧的那版。

## 1. 这套 IP 是什么

一个纯像素流处理的 IP，不是完整工程：没有顶层、没有 MIPI/DDR/HDMI、没有引脚和
时序约束。输入输出都是 `RGB888 + de/hs/vs`，全部模块每拍都在跑，固定延迟。

| 文件 | 作用 |
| --- | --- |
| `line_buffer.v` | 双口行缓存，输出"上一行同列" |
| `delay_n.v` | 移位寄存器打拍链，N=0 直通 |
| `median3x3.v` | 3x3 中值（21 比较器排序网络） |
| `gaussian5x5.v` | 5x5 高斯整数核，>>10 舍入 |
| `sobel3x3.v` | Sobel，输出 12bit 全量程 mag + 2bit 方向 |
| `canny_nms.v` | 非极大值抑制，输出 8bit |
| `hysteresis.v` | 双阈值滞后（strong 3x3 膨胀 & weak） |
| `remove_isolated.v` | 去掉无邻居孤立点 |
| `image_processing_top.v` | 组装 + 分屏 + 分隔线 + 中心红框 |

顶层参数（按队友 README 第四节定稿值接的常量）：`algo=1`(Canny)、`mode_dual=1`、
`median_en=1`、`isol_en=1`、`color_mode=0`(白边)、`split_en=1`(左灰右边)、
`box_en=1`，`thr/thr_hi/thr_lo = 24/58/21`。

## 2. 接口对得上，插入点很干净

我们顶层的像素流：`rgb_datax2`（每拍 2 像素）经 `vid_cnt` 拆成单像素
`hdmi_tx_rdata/gdata/bdata` + `hdmi_tx_de/hs/vs`，在 `hdmi_tx_slow_clk` 域。
`edge_overlay_720p` 的输出 `ov_*` 直接进 `dvi_encoder_m0`（gamma 已被旁路）。

所以：**输入接 `hdmi_tx_*`，输出和 `ov_*` 二选一送编码器**，同域同协议，不用跨时钟、
不用改时序约束。

## 3. 集成方式（分支 `teammate-ip`）

- 9 个文件放到 `rtl/teammate_ip/`，`ti60f225_oob.xml` 里加了 9 条 `design_file`。
- 顶层例化 `image_processing_top`，输入 `hdmi_tx_*`，参数用上面那组常量。
- 编码器输入加了 mux：`enc_* = ip_sync ? tip_* : ov_*`。
- `uart_cmd.v` 新增 `I<n>`（key `K_I`）：`I0` 用回我们这条已验证的链，`I1` 切到队友这条。
  选择位是**真实信号**而不是常量——常量会让综合器把没选中的一条整链删掉，资源报告就假了。
- 两条链都常驻，所以下面的资源数是"两条链同时在"的真值。

## 4. 编译结果：map PASS，pnr FAIL

```
map : PASS
interface : PASS
pnr : FAIL
```

`outflow/ti60f225_oob.log`：

```
ERROR : Not enough physical locations for Logic blocks : capacity=60800 usage=80871
ERROR : Not enough physical locations for FF cells     : capacity=60800 usage=80871
ERROR : Not enough physical locations for SRL8 cells   : capacity=14720 usage=55351
ERROR : Not enough physical locations for EFM blocks   : capacity=14720 usage=55351
```

| 资源 | 容量 | 需求 | 结果 |
| --- | --- | --- | --- |
| Logic block / FF | 60,800 | 80,871 | 超 33 % |
| SRL8 | 14,720 | 55,351 | **超 3.76 倍** |

对照基线（我们这条链单独编译）：10514 FF、12549 LUT、122/256 存储块、最差 slack +0.479 ns。
也就是说这多出来的 7 万左右 FF/SRL 几乎全是队友 IP 带来的，而且**绝大部分不是算法逻辑，
是打拍器**。

另外：行缓存本身推断结果是好的，综合器认出了存储块并自动补了 write-first bypass
（`"MEM|SYN-0690" : Inserted write-first bypass logic for memory block ... line_buffer.v:33`），
`line_buffer` 不是瓶颈。

## 5. 根因：`delay_n` 拿移位寄存器做行级延迟

`image_processing_top.v` 里所有"对齐"都用 `delay_n`，而 `delay_n` 是逐位寄存的移位链。
延迟是以**行**为单位的，所以位数是"行宽 x 拍数"：

| 实例 | N（拍） | 位宽 | 位 x 拍 |
| --- | --- | --- | --- |
| `u_hc` / `u_vc`（行列计数） | 7*1280+7 = 8967 | 16 | 2 x 143,472 |
| `u_gt`（gray_dtot，左半灰度图） | 8967 | 8 | 71,736 |
| `u_de` / `u_dh` / `u_dv` | 8967 | 1 x 3 | 26,901 |
| `u_gg`（gray_dg） | 3843 | 8 | 30,744 |
| `u_mag`（med 对齐 gauss） | 2562 | 8 | 20,496 |
| `u_gm`（gray_dm） | 1281 | 8 | 10,248 |
| `u_ht`（edge_hys 对齐） | 1281 | 8 | 10,248 |
| 合计 | | | **约 45.7 万位** |

综合器把这些链落成 SRL8（每块 8 深），45.7 万位 / 8 ≈ 5.7 万个 SRL8，器件只有 14,720 个。

**拍数里绝大部分是整行**：8967 = 7 行 + 7 拍；3843 = 3 行 + 3 拍；2562 ≈ 2 行 + 2 拍。
整行延迟用移位寄存器是纯浪费——一行数据本来就必须存在存储器里，行缓存只要一块
`line_buffer` 就能替掉 1280 拍 x 位宽。

## 6. 修法（给队友的具体建议）

把"整行"部分换成行缓存串联，"零头"留在 `delay_n`：

1. `u_hc` / `u_vc`：**根本不需要延迟 8967 拍**。行列计数可以放在输出级，用输出自己的
   `o_de/o_hs/o_vs` 重新计数，天然和像素对齐。这一项就能省下 28.7 万位（最大的两块）。
2. `u_gt`（gray_dtot，8bit x 7 行）：串 7 个 `line_buffer #(.W(8), .DEPTH(HACT))`，再补 7 拍。
   存储代价 7 x 1280 x 8 bit，约 9 个存储块，换掉 71,736 位寄存器。
3. `u_gg`（3 行）、`u_mag`（2 行）、`u_gm`（1 行）、`u_ht`（1 行）、`u_de/u_dh/u_dv`（7 行）
   同样处理；1bit 的那几个用 `line_buffer #(.W(1))` 最省。
4. 顺带一提：`line_buffer` 的读口是异步的（`assign dout = mem[raddr_q]`），综合器这次
   接受了，但改成"读地址打一拍 + 输出寄存器"的同步读更稳，代价是各条链统一 +1 拍，
   `image_processing_top.v` 的延迟常量跟着调。
5. 改完再编译一次，只要 `pnr` 的 block capacity check 不再报错，就能烧板试了。

## 7. 顺手修掉的三个真缺陷（在仓库副本里改的，队友桌面上的原文件没动）

1. **`strong` / `weak` 撞 SystemVerilog-2009 保留字**。工程用 `verilog_mode=sv_09`，
   `hysteresis.v` 里的 `wire strong = ...` / `wire weak = ...` 直接语法错
   （`VERI-1137 / VERI-2344`）。改名 `strong_p` / `weak_p`（8 处 + 6 处）。
   注意 `small` / `medium` / `large` / `highz` 也是同类保留字。
2. **`weak_center` 未声明**：`hysteresis.v` 第 70 行用了 `weak_center`，但第 77 行声明的是
   `weak_c`（`u_wk` 的输出也接的 `weak_c`）。这是拼写不一致，不是保留字问题，
   按 `weak_c` 统一了。**这条即使不改保留字也编译不过，队友自己跑一次 Efinity 就会看到。**
3. **`line_buffer` 模块重名**：工程原厂 debayer 里已经有 `rtl/debayer/line_buffer.v`，
   同名会 `VERI-1206 overwriting previous definition`。队友那份重命名为 `tip_line_buffer`
   （模块名 + 16 处例化，注释没动）。

队友 README 里说"语法已用解析器全量校验通过"——从上面第 1、2 条看，那个校验器大概
不是 Efinity、也不按 SV-2009，所以关键字和未声明标识符这两类它都放过去了。

## 8. 下一步的选项

- **A（已完成，见第 9 节）**：按第 6 节把行级延迟改成行缓存，改到 `pnr` 过，再上板看效果
  （这样 `I0/I1` 可以直接 A/B 对比两条链）。
- **B**：只在文档层面把这个结论反馈给队友，让他自己改。
- **C**：先不动，我们这条已验证的链继续往下做赛题（红边叠加的对齐、floor 上板验证等）。

不管选哪个，`I<n>` 这个开关和 `rtl/teammate_ip/` 的脚手架都已经在 `teammate-ip` 分支上，
不会影响 `uart-bringup` 和 `main`。
## 9. 队友的修复版：`pnr` 已经过了（2026-09-26）

队友按第 6 节的思路出了修复版（10 个 .v，新增 `line_delay_n.v`）。取进来重新编译：

```
map : PASS    interface : PASS    pnr : PASS    pgm : PASS
```

资源（Ti60F225，I3 时序模型）：

| 资源 | 用了 | 容量 | 说明 |
| --- | --- | --- | --- |
| EFX_FF | 13168 | 60800 | 21.7% |
| EFX_SRL8 | 1866 | 14720 | 12.7%，原版是 55351 |
| EFX_ADD | 4181 | — | |
| EFX_LUT4 | 15969 | — | |
| EFX_RAM10 + DPRAM10 | 211 + 8 = 219 | 256 | **85.5%，只剩 37 块** |
| EFX_DSP48 / DSP24 | 4 / 20 | — | |

最差 setup slack `+0.297 ns`（我们基线 `+0.479 ns`），为正，时序收敛。
bit 归档：`candidate_bitstreams/teammate_canny.bit`（这版是**两条链同时综合**的，
上板后 `I0` / `I1` 可以直接切着对比）。

他做了什么（正好对上第 6 节的建议）：

1. 新增 `line_delay_n.v`：N 拍延迟 = N/DEPTH 个整行（`tip_line_buffer` 级联，进 BRAM）
   + N%DEPTH 拍零头（`delay_n`，最多 7 拍）。
2. 6 个算法模块里的行级 `delay_n` 全换成 `line_delay_n`（`we=i_de`）。
3. 顶层行列计数 `hc`/`vc` 改成输出级实时计数，干掉两块 16bit×8967 的移位链（约 28.7 万位）。
4. `de/hs/vs` 合并成 3bit 一条 BRAM 链（`u_sync`）。

代价：BRAM 从 122/256 涨到 219/256。后面队友链要再加东西（比如 temporal blend 要 DDR
帧缓存、或者 `delay_n` 之外再加对齐）之前，先看余量。

引入修复版时我方只做了一件事：`ti60f225_oob.xml` 补一条
`rtl/teammate_ip/line_delay_n.v` 的 `design_file`（队友 README 第 4 节也提醒了）。
其余 9 个文件沿用他给的内容，未再改动。