# 候选位流归档记录

规则（见 `AGENTS.md`）：

- 候选位流只放本目录，并记录**来源提交、SHA-256、上板状态**。
- 只有**肉眼验证通过**的恢复位流才能进 `known_good/`；不要用实验位流覆盖已验证基线。
- `outflow/` 被 Git 忽略，**切分支不会切换位流**；下载前必须重新编译，或明确选择本目录里已记录的位流。

---

## 1. `algo_canny_full_20260926_1954.bit` —— 赛题4 算法全链（Canny）

| 项 | 值 |
| --- | --- |
| 来源提交 | `4fcc6dbef0bce2090ab934cc1ab13f63c84f6c51`（分支 `py-algo-rtl`） |
| 编译时间 | 2026-09-26 19:54:52 |
| 字节数 | 2422623 |
| SHA-256 | `0B1354A8C08C544B40801815378BCD93DB604210A1BC1CC805BE2592CC0AED89` |
| 工具 | Efinity 2026.1.132.4.5 |
| 流程结果 | `map` PASS、`interface` PASS、`pnr` PASS、`pgm` PASS |
| 时序 | `hdmi_tx_slow_clk` setup **+5.316 ns** / hold **+0.031 ns**；全设计无负 slack；该时钟最大可分析频率 122.669 MHz（约束 74.25 MHz） |
| 资源 | XLRs 21593/60800 (35.51%)、Memory Blocks 208/256 (81.25%)、DSP 4/160 |
| **上板状态** | ❌ **未下载、未上板、未肉眼确认** |
| 内容 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel(幅值+方向) → NMS → 双阈值滞后(58/21) → 去孤点 → 显示；显示模式每 128 帧轮换 0/1/2/3 |
| 已验证程度 | RTL 实现 + 仿真逐位对拍 + 编译/时序通过（**不含** JTAG 与画面） |

算法来源、逐级映射与对拍数据见 `docs/ALGO_RTL.md`。

## 2. `pre_algo_edge_display_720p_20260926_1728.bit` —— 移植前的旧基线

| 项 | 值 |
| --- | --- |
| 用途 | 算法移植**之前**的 `edge_display_720p`（灰度 + Sobel）位流，作为对照/回退参考 |
| 编译时间 | 2026-09-26 17:28:52 |
| 字节数 | 2333919 |
| **上板状态** | ❌ 未下载、未上板确认 |

> 它与 `known_good/edge_detect_720p_verified.bit` 同源思路但**不是**同一份文件，
> 请勿与已验证恢复位流混淆。

## 3. `known_good/edge_detect_720p_verified.bit`（不在本目录，仅列出以便对照）

| 项 | 值 |
| --- | --- |
| 状态 | ✅ **已在板上肉眼验证**（左半灰度 / 右半 Sobel 黑白边缘，实时变化） |
| 字节数 | 2333919 |
| SHA-256 | `146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355` |

任何时候需要"至少能看到画面"，用这一份。

---

## 哈希校验

在仓库根目录执行：

```powershell
Get-ChildItem candidate_bitstreams,known_good -Filter *.bit -Recurse |
  ForEach-Object { "{0}  {1}  {2}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Length, $_.FullName }
```

期望值（2026-09-26 实测）：

| 文件 | SHA-256 |
| --- | --- |
| `candidate_bitstreams/algo_canny_full_20260926_1954.bit` | `0B1354A8C08C544B40801815378BCD93DB604210A1BC1CC805BE2592CC0AED89` |
| `candidate_bitstreams/pre_algo_edge_display_720p_20260926_1728.bit` | `140E575936B2222E8AAC808A7E7827CED124638A19106A38B3E0260C1A1B2F6A` |
| `known_good/edge_detect_720p_verified.bit` | `146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355` |

## 归档说明

- 2026-09-26 19:49 曾归档过一份同名候选位流（`..._1949.bit`），随后修正了
  `alg_top.v` / `alg_stream_delay.v` 的**注释**（旧的 `alg_disp`/`DLY_RGB` 描述）并重编译。
  综合结果与时序/资源完全相同（注释不影响网表），但为了让"入库源码"与"归档位流"
  严格一一对应，已删除 1949 那份，改为归档 1954 这份。
- 归档位流对应的源码提交必须能在 `git log` 里找到；提交信息里注明证据等级。
