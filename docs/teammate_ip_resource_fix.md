# 修复说明（资源 / pnr 失败）

## 1. 原问题
`map PASS / pnr FAIL`：
```
Not enough physical locations for SRL8 cells : capacity=14720 usage=55351
Not enough physical locations for Logic/FF   : capacity=60800 usage=80871
```
根因：`delay_n` 是逐位寄存的移位链，被用来做**行级**对齐延迟（最长 7·HACT+7=8967 拍），
综合成 SRL8 后超 3.76 倍。

## 2. 本次修改（在"2_修改后文件"内，沿用队友命名 tip_line_buffer / strong_p / weak_p / weak_c）
1. **新增 `line_delay_n.v`**：把 N 拍延迟拆成 `N/DEPTH` 个整行（用 `tip_line_buffer` 级联，进 BRAM）
   + `N%DEPTH` 拍零头（`delay_n`，仅 1..7 拍，不爆 SRL）；带 `we` 使能，消隐期不写。
2. **6 个算法模块内**所有 `delay_n #(.N(OUT_DELAY 行级))` 全部替换为 `line_delay_n`（`we=i_de`）：
   median / gaussian5x5 / sobel3x3 / canny_nms / hysteresis / remove_isolated。
3. **顶层 `image_processing_top`**：
   - gray 的三级对齐、med 对齐、mag8 对齐、single 对齐、edge_hys 对齐全部改用 `line_delay_n`（BRAM）；
   - `de/hs/vs` 合并为 **3bit 一条** BRAM 链（`u_sync`），不再三条独立；
   - **行列计数 hc/vc 改为输出级实时计数**（用延迟后的 fde/fhs/fvs），消除最大的两块
     16bit×8967 移位链（约 28.7 万位）。

## 3. 资源估算（以队友 Efinity 编译为准）
- 新增对齐用 BRAM：约 18 条 8bit 行 + 7 条 3bit 行 ≈ 206 Kbit，粗估 **~50 个存储块**；
  基线已用 122/256，空闲约 134，**够用**。
- SRL8：仅剩 1..7 拍零头，需求由 55,351 降到数千量级，**远低于 14,720**。
- FF：对齐寄存器大量转入 BRAM，预计两链合计 ~25–30K，**低于 60,800**。

## 4. 队友需做
1. 把新增的 `line_delay_n.v` 一并加入 Efinity 工程 `design_file`（其余 9 个文件已在）；
2. 重新跑 `map → interface → pnr`，确认 block capacity check 不再报错即可烧板；
3. 若 BRAM 仍偏紧：把 gray 的 u_gm/u_gg/u_gt 三条独立链改成"一条 7 级链 + 抽头"
   （可再省约 4 行 = 十余块），需要时反馈。

## 5. 未变 / 未实现
- 算法逻辑、参数（thr=24 / thr_hi=58 / thr_lo=21、Canny、中值、孤立消除、分屏、红框）不变；
- temporal_blend（DDR 上一帧）、形状识别+文字、Otsu、GRAY/EDGE 文字标签仍未实现（见原集成文档）。
