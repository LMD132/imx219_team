//=============================================================================
// shp_detect.v -- 赛题4 创意拓展⑥: 边缘图上的形状识别(特征匹配法)
//
// 赛题原文: "在边缘检测的基础上, 识别画面中的特定形状(如圆形、矩形);
//            可采用特征匹配法: 在边缘图像中检测轮廓, 计算几何特征;
//            将识别结果显示在屏幕上(如'检测到圆形')"
//
// 本文档按"特征匹配法"实现, 全部在像素流上完成, 不需要整帧缓存:
//
//  1) 游程(Run-Length)连通域: 二值边缘流里每一行会出来若干段"连续白点"。
//     每段结束时, 拿它的 [x0,x1] 与"还在活动的 blob 表"比较:
//       有重叠且行号接近 -> 并进同一个 blob;  完全对不上 -> 开一个新 blob;
//     一行的左右两段(比如圆的左弧和右弧)会先后落进同一个 blob 的 x 范围内,
//     于是被正确并到一起。表里最多 NB=8 个并发 blob(够画面上 8 个图形)。
//
//  2) 每个 blob 用 11 个累加量描述: bbox(x0,x1,y0,y1) + 边缘像素数 cnt
//     + 行跨度累加 sum(每行的 x1-x0+1 累加, 当"填充面积"的估计)
//     + 当前行暂存(rmn,rmx,rs)。表很小, 全用寄存器, 不占 BRAM。
//
//  3) 一个 blob "退休"(行尾超时/帧末)时算几何特征并分类:
//        r   = sum / (w*h)                   -- 填充率(千分比)
//        lsp = 最后一行的跨度(≈底边宽度)
//        矩形:   r >= fill_th                (方形框/矩形框 r≈1000)
//        圆形:   600 <= r < fill_th 且 bbox 近正方 (圆/空心圆环 r≈785)
//        三角:   r < 600 且 lsp >= w/2       (三角 r≈500, 底边占满全宽)
//        十字:   r < 600 且 lsp <  w/2       (加号 r≈420, 底边只有臂宽)
//        (直线段/数字 r<300 记无效; 圆是空心还是实心不影响上述边缘特征)
//     阈值比较全部用乘加比较(和 fill_th 比用一次乘法), 无除法器。
//
//  4) 每帧末把"面积估计最大"的前 NBX=6 个图形提交给显示叠加(shp_overlay),
//     显示端按 1 帧的滞后画框 + 中文标签; 若本帧一个都没检出, 框可以再保持
//     HOLD 帧(防单帧漏检导致闪一下)。
//
// 资源: 全寄存器逻辑(blob 表 8x~130bit + top 表 6x~70bit + 乘法器 1 个),
//       无 BRAM, 无 DSP(9600 以下的常数乘全部改成移位加)。
//
// 时序: 段结束事件进一个深度 FQ=24 的 FIFO, 主状态机平均 4 拍处理一段。
//       满屏混乱纹理(每行几百段)时 FIFO 可能溢出, 溢出计数报告给 telemetry;
//       规则图形(圆/方/三角/数字)每行只有几段, 余量很大。
//
// 边界: 只处理 x<W, y<H 的有效像素, 与显示坐标同一空间(1:1 对准)。
//=============================================================================

module shp_detect #(
    parameter integer W    = 1280,
    parameter integer H    = 720,
    parameter integer NB   = 8,      // 并发 blob 槽位数
    parameter integer NBX  = 6,      // 提交给显示的最大框数
    parameter integer GAPX = 6,      // 水平合并容差(px)
    parameter integer GAPY = 4,      // 垂直容忍(行): 断线不超过 4 行仍算同一形状
    parameter integer FQ   = 24,     // 游程 FIFO 深度
    parameter integer HOLD = 15      // 本帧没检出时, 旧框再保持多少帧
)(
    input  wire        clk,
    input  wire        rst_n,

    // 运行期参数(alg_cfg_sync 送过来; 全部有内部限幅)
    input  wire        cfg_en,          // 0 = 关闭形状识别(直通, 不画任何框)
    input  wire [7:0]  cfg_min_size,    // bbox 最小边长(px), 8..255, 默认 24
    input  wire [2:0]  cfg_max_boxes,   // 显示框数上限 1..6, 默认 4
    input  wire [9:0]  cfg_fill_th,     // 圆/矩形 填充率分界(千分比), 默认 875
    input  wire [6:0]  cfg_max_area,    // 最大 bbox 面积百分比(占全屏), 默认 50

    // 边缘流(dsp 级, 与 alg_vdisp 的 ed_* 同一根线)
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [12:0] in_y,
    input  wire [7:0]  in_d,

    // 输出: NBX 个框(打包成向量, 位段 i = [i*WDT +: WDT])
    output reg  [NBX*12-1:0] o_bx0,
    output reg  [NBX*12-1:0] o_bx1,
    output reg  [NBX*13-1:0] o_by0,
    output reg  [NBX*13-1:0] o_by1,
    output reg  [NBX*3-1:0]  o_bcls,     // 1=圆 2=矩 3=三角 4=十字 0=无效
    output reg  [NBX-1:0]    o_bval,

    output reg  [9:0]  o_cnt,            // 本帧提交的合格图形数(0..999)
    output reg  [15:0] o_ovf             // 游程 FIFO 溢出计数(诊断)
);

    // FQ/HOLD 是 integer 参数, 转定宽 localparam 再比较/做下标,
    // 避免个别综合器对 integer 位选支持不好
    localparam [4:0] FQ5   = FQ;
    localparam [4:0] HOLD5 = HOLD;

    // ---------------------------------------------------------------- 限幅
    wire [7:0]  min_sz  = (cfg_min_size  <  8'd8)   ?  8'd8   : cfg_min_size;
    wire [2:0]  nbox    = (cfg_max_boxes == 3'd0)   ?  3'd1   : cfg_max_boxes;
    // 下限 800: 保证圆的区间 [600, fill_th) 一定包含实测圆心值 ≈785
    wire [9:0]  fil_th  = (cfg_fill_th   < 10'd800) ? 10'd800 :
                          ((cfg_fill_th  > 10'd990) ? 10'd990 : cfg_fill_th);
    wire [6:0]  max_pct = (cfg_max_area  <  7'd5)   ?  7'd5   : cfg_max_area;

    // 全屏面积 x 百分比 = 百分之一面积(W*H/100 = 9216) x pct
    //   9216 = 8192 + 1024 -> 两个移位相加, 无乘法器
    wire [26:0] area_max = ({20'd0, max_pct} << 13) + ({20'd0, max_pct} << 10);

    // ------------------------------------------------------------ 游程提取
    wire        pix = in_de & (in_x < W) & (in_y < H) & (in_d != 8'd0);
    reg         pix_r;
    reg  [11:0] x_r;
    reg  [12:0] y_r;
    reg  [11:0] sx0;                       // 当前游程起点

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_r <= 1'b0; x_r <= 12'd0; y_r <= 13'd0; sx0 <= 12'd0;
        end else begin
            pix_r <= pix;
            x_r   <= in_x;
            y_r   <= in_y;
            if (pix & ~pix_r) sx0 <= in_x;      // 游程起点
        end
    end

    wire span_end = ~pix & pix_r;    // 结束于 (x_r,y_r), 起点 = sx0

    // ------------------------------------------------------------ 游程 FIFO
    reg  [36:0] fifo [0:FQ-1];
    reg  [4:0]  f_wp, f_rp, f_cnt;
    wire        f_empty = (f_cnt == 5'd0);
    wire        f_full  = (f_cnt == FQ5);
    reg         f_pop;                       // 主状态机 1 拍脉冲
    wire [36:0] f_dout  = fifo[f_rp];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_wp <= 5'd0; f_rp <= 5'd0; f_cnt <= 5'd0; o_ovf <= 16'd0;
        end else if (!cfg_en) begin
            f_wp <= 5'd0; f_rp <= 5'd0; f_cnt <= 5'd0;   // 关闭时清空
        end else begin
            if (span_end) begin
                if (!f_full) begin
                    fifo[f_wp] <= {y_r, x_r, sx0};
                    f_wp <= (f_wp == (FQ5 - 5'd1)) ? 5'd0 : (f_wp + 5'd1);
                end else if (o_ovf != 16'hFFFF) begin
                    o_ovf <= o_ovf + 16'd1;
                end
            end
            if (f_pop) f_rp <= (f_rp == (FQ5 - 5'd1)) ? 5'd0 : (f_rp + 5'd1);
            case ({span_end & ~f_full, f_pop})
                2'b10:   f_cnt <= f_cnt + 5'd1;
                2'b01:   f_cnt <= f_cnt - 5'd1;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------- blob 表
    reg            b_act [0:NB-1];
    reg  [11:0]    b_x0  [0:NB-1];
    reg  [11:0]    b_x1  [0:NB-1];
    reg  [12:0]    b_y0  [0:NB-1];
    reg  [12:0]    b_y1  [0:NB-1];
    reg  [12:0]    b_lr  [0:NB-1];      // 最近一次被触碰的行号
    reg  [19:0]    b_cnt [0:NB-1];      // 边缘像素数
    reg  [19:0]    b_sum [0:NB-1];      // 行跨度累加(填充面积估计)
    reg  [11:0]    b_rmn [0:NB-1];      // 当前行的跨度
    reg  [11:0]    b_rmx [0:NB-1];
    reg            b_rs  [0:NB-1];      // 当前行已开始

    // ------------------------------------------------------- top 列表(NBX)
    reg            l_val [0:NBX-1];
    reg  [11:0]    l_x0  [0:NBX-1];
    reg  [11:0]    l_x1  [0:NBX-1];
    reg  [12:0]    l_y0  [0:NBX-1];
    reg  [12:0]    l_y1  [0:NBX-1];
    reg  [2:0]     l_cls [0:NBX-1];
    reg  [19:0]    l_sc  [0:NBX-1];

    // ------------------------------------------------------------ 主状态机
    localparam S_IDLE   = 5'd0,
               S_MATCH  = 5'd1,     // 组合匹配 -> 寄存掩码
               S_MPRI   = 5'd2,     // 优先级 + 合并值
               S_APPLY  = 5'd3,     // 写回 blob 表
               S_PREP   = 5'd4,     // 退休准备(冲行 + 装乘法器)
               S_MULS0  = 5'd5,     // area = w*h: 发启动脉冲
               S_MULW0  = 5'd6,     // area = w*h: 等完成
               S_MULS1  = 5'd7,     // a_th = area*fil_th: 发启动脉冲
               S_MULW1  = 5'd8,     // a_th = area*fil_th: 等完成
               S_CLS    = 5'd9,     // 分类 + 找插入位置
               S_PUSH   = 5'd10,    // 写 top 列表
               S_CLR    = 5'd11,    // 释放槽位
               S_FEND   = 5'd12,    // 帧末逐个退休
               S_COMMIT = 5'd13;    // 提交输出 + hold

    reg  [4:0]  state;
    reg         fend_req;
    reg         fend_mode;
    reg  [3:0]  ret_slot;
    reg  [NB-1:0] alloc_oh;
    reg  [NB-1:0] m_mask;                // 本段命中的槽(寄存)
    reg  [NB-1:0] c_free;                // 空闲槽掩码
    reg  [NB-1:0] c_exp;                 // 过期槽掩码
    reg  [3:0]  m0;                      // 命中槽里最小的一个
    reg  [11:0] s_x0, s_x1;
    reg  [12:0] s_y;
    reg  [12:0] s_len;

    // 合并结果(组合算出, S_MPRI 拍寄存)
    reg  [11:0] mg_x0, mg_x1;
    reg  [12:0] mg_y0, mg_y1;
    reg  [19:0] mg_cnt, mg_sum;
    reg  [11:0] mg_rmn, mg_rmx;

    // 退休统计
    reg  [11:0] ret_w, ret_h;
    reg  [11:0] ret_lsp;                 // 最后一行(底边)跨度
    reg  [19:0] ret_fill, ret_area;
    reg  [9:0]  f_cnt_cur;               // 本帧已提交的合格图形数

    integer i;
    reg [3:0]  t_idx;
    reg        t_found;
    reg [19:0] t_min;

    // vs 上升沿 -> 帧末请求(锁存, 等 FIFO 排空后处理)
    reg vs_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_r <= 1'b0; fend_req <= 1'b0;
        end else begin
            vs_r <= in_vs;
            if (in_vs & ~vs_r) fend_req <= 1'b1;
            else if ((state == S_IDLE) && fend_req && f_empty && cfg_en)
                fend_req <= 1'b0;
        end
    end

    // en 关闭时清表(en 上升沿重新开始)
    reg en_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) en_r <= 1'b0;
        else        en_r <= cfg_en;
    end
    wire clr_all = cfg_en & ~en_r;      // en 刚打开: 清干净

    // ------------------------------------------------- 匹配/优先级(组合)
    reg  [NB-1:0] c_match;
    always @* begin
        for (i = 0; i < NB; i = i + 1) begin
            c_match[i] = b_act[i]
                       & (s_y >= b_lr[i]) & ((s_y - b_lr[i]) <= GAPY)
                       & (s_x0 <= (b_x1[i] + GAPX))
                       & ((s_x1 + GAPX) >= b_x0[i]);
        end
    end

    // 掩码里最小的置位下标(从高往低扫, 后写的胜)
    function [3:0] low_idx;
        input [NB-1:0] m;
        integer k;
        begin
            low_idx = 4'd0;
            for (k = NB-1; k >= 0; k = k - 1)
                if (m[k]) low_idx = k[3:0];
        end
    endfunction

    // 合并值(仅在 S_MPRI 拍组合计算, 用寄存的 m_mask)
    always @* begin
        mg_x0 = s_x0;  mg_x1 = s_x1;
        mg_y0 = s_y;   mg_y1 = s_y;
        mg_cnt = {7'd0, s_len};
        mg_sum = 20'd0;
        mg_rmn = s_x0; mg_rmx = s_x1;
        for (i = 0; i < NB; i = i + 1) begin
            if (m_mask[i]) begin
                if (b_x0[i] < mg_x0) mg_x0 = b_x0[i];
                if (b_x1[i] > mg_x1) mg_x1 = b_x1[i];
                if (b_y0[i] < mg_y0) mg_y0 = b_y0[i];
                if (b_y1[i] > mg_y1) mg_y1 = b_y1[i];
                mg_cnt = mg_cnt + b_cnt[i];
                if (s_y == b_lr[i]) begin         // 同一行的另一段: 合并行跨度
                    if (b_rmn[i] < mg_rmn) mg_rmn = b_rmn[i];
                    if (b_rmx[i] > mg_rmx) mg_rmx = b_rmx[i];
                end else if (b_rs[i]) begin       // 换行: 把上一行的跨度冲进 sum
                    mg_sum = mg_sum + {8'd0, (b_rmx[i] - b_rmn[i] + 12'd1)};
                end
            end
        end
    end

    // ------------------------------------------------------------ 乘法器
    // 11 步移位加: m_res = m_a x m_b (m_b 低 11 位有效)。
    // 显式 start/忙/完成脉冲握手。旧版用 mul_run/mul_clr + (m_cnt>=11) 判完成,
    // 换状态那一拍 m_cnt 还是上一笔的 11 -> 立刻"完成"并读到脏 m_res,
    // 导致第 2/3 个乘积全是上一次的值(ret_area/r_a_th 被污染)。这里脉冲握手不会读脏。
    reg  [31:0] m_acc, m_a, m_res;
    reg  [10:0] m_b;
    reg  [4:0]  m_cnt;
    reg         m_busy;
    reg         mul_start;                 // FSM: 1 拍启动脉冲
    reg         mul_done_p;                // 乘法器: 1 拍完成脉冲

    wire [31:0] m_next = m_acc + (m_b[m_cnt[3:0]] ? (m_a << m_cnt) : 32'd0);
    wire [31:0] m_last = m_acc + (m_b[10] ? (m_a << 10) : 32'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_acc <= 32'd0; m_res <= 32'd0; m_cnt <= 5'd0;
            m_busy <= 1'b0; mul_done_p <= 1'b0;
        end else begin
            mul_done_p <= 1'b0;
            if (mul_start) begin
                m_busy <= 1'b1;
                m_cnt  <= 5'd0;
                m_acc  <= 32'd0;
            end else if (m_busy) begin
                if (m_cnt == 5'd10) begin
                    m_res <= m_last;                  // 第 10 位收尾
                    m_cnt <= 5'd11;
                end else if (m_cnt == 5'd11) begin
                    m_busy     <= 1'b0;
                    mul_done_p <= 1'b1;               // 完成脉冲
                end else begin
                    m_acc <= m_next;
                    m_cnt <= m_cnt + 5'd1;
                end
            end
        end
    end

    // 分类(退休时用): fill x 1000 = <<10 - <<4 - <<3 (1000=1024-16-8), 无乘法;
    //   a_th = area x fil_th 由乘法器算, 比较 fill*1000 >= a_th 等价于
    //   fill/area >= fil_th/1000
    reg [31:0] r_a_th;

    wire [31:0] fill1000 = ({12'd0, ret_fill} << 10)
                         - ({12'd0, ret_fill} << 4)
                         - ({12'd0, ret_fill} << 3);
    wire [31:0] area600 = ({12'd0, ret_area} << 9) + ({12'd0, ret_area} << 6)
                        + ({12'd0, ret_area} << 4) + ({12'd0, ret_area} << 3);
                                                                        // x600
    wire [31:0] area300 = ({12'd0, ret_area} << 8) + ({12'd0, ret_area} << 5)
                        + ({12'd0, ret_area} << 3) + ({12'd0, ret_area} << 2);
                                                                        // x300
    wire [13:0] w7  = ({2'b0, ret_w} << 3) - {2'b0, ret_w};             // 7w
    wire [13:0] w10 = ({2'b0, ret_w} << 3) + ({2'b0, ret_w} << 1);      // 10w
    wire [13:0] h7  = ({2'b0, ret_h} << 3) - {2'b0, ret_h};             // 7h
    wire [13:0] h10 = ({2'b0, ret_h} << 3) + ({2'b0, ret_h} << 1);      // 10h
    wire [13:0] lsp2 = {2'b0, ret_lsp} << 1;                            // 2*lsp

    wire ok_size = (ret_w >= {4'd0, min_sz}) & (ret_h >= {4'd0, min_sz});
    wire ok_area = ({7'd0, ret_area} <= area_max);
    wire aspect_round = (w10 >= h7) & (h10 >= w7);    // 0.7 <= w/h <= 1.43

    wire c_rect   = (fill1000 >= r_a_th);                            // >=fill_th
    wire c_circle = (fill1000 >= area600) & (fill1000 < r_a_th) & aspect_round;
    wire c_low    = (fill1000 >= area300) & (fill1000 < area600);
    wire c_tri    = c_low & (lsp2 >= {2'b0, ret_w});   // 底边占满 => 三角
    wire c_cross  = c_low & ~(lsp2 >= {2'b0, ret_w});  // 底边只中段 => 十字
    wire qualified = ok_size & ok_area & (c_circle | c_rect | c_tri | c_cross);
    wire [2:0] cls_now = c_circle ? 3'd1 : c_rect ? 3'd2 :
                         c_tri ? 3'd3 : c_cross ? 3'd4 : 3'd0;

    // top 列表插入位置(组合, S_CLS 拍)
    reg  [2:0]  ins_idx;
    reg         ins_en;
    reg  [2:0]  free_i;
    reg         free_found;
    reg  [19:0] min_s;
    reg  [2:0]  min_i;
    always @* begin
        free_i = 3'd0; free_found = 1'b0;
        for (i = NBX-1; i >= 0; i = i - 1)
            if (!l_val[i]) begin free_i = i[2:0]; free_found = 1'b1; end
        min_s = 20'hFFFFF; min_i = 3'd0;
        for (i = 0; i < NBX; i = i + 1)
            if (l_val[i] & (l_sc[i] < min_s)) begin min_s = l_sc[i]; min_i = i[2:0]; end
        if (free_found)          begin ins_idx = free_i;  ins_en = qualified; end
        else if (ret_fill > min_s) begin ins_idx = min_i; ins_en = qualified; end
        else                     begin ins_idx = 3'd0;    ins_en = 1'b0; end
    end

    // ------------------------------------------------------------ 槽位写回
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NB; i = i + 1) begin
                b_act[i] <= 1'b0; b_x0[i] <= 12'd0; b_x1[i] <= 12'd0;
                b_y0[i] <= 13'd0; b_y1[i] <= 13'd0; b_lr[i] <= 13'd0;
                b_cnt[i] <= 20'd0; b_sum[i] <= 20'd0;
                b_rmn[i] <= 12'd0; b_rmx[i] <= 12'd0; b_rs[i] <= 1'b0;
            end
        end else begin
            if (clr_all) begin
                for (i = 0; i < NB; i = i + 1) begin
                    b_act[i] <= 1'b0; b_cnt[i] <= 20'd0; b_sum[i] <= 20'd0;
                    b_rs[i] <= 1'b0; b_rmn[i] <= 12'd0; b_rmx[i] <= 12'd0;
                end
            end
            if ((state == S_APPLY) && ~clr_all) begin
                for (i = 0; i < NB; i = i + 1) begin
                    if (m_mask[i] & (i[3:0] != m0) & b_act[i])
                        b_act[i] <= 1'b0;                      // 并进 m0
                    if (m_mask[i] & (i[3:0] == m0)) begin
                        b_act[i] <= 1'b1;
                        b_x0[i] <= mg_x0;  b_x1[i] <= mg_x1;
                        b_y0[i] <= mg_y0;  b_y1[i] <= mg_y1;
                        b_lr[i] <= s_y;
                        b_cnt[i] <= mg_cnt;
                        // 累加: mg_sum 只带"上一次换行时冲掉的整行跨度",
                        // 旧版写成 b_sum <= mg_sum(覆盖) -> 填充面积只剩最后一行
                        b_sum[i] <= b_sum[i] + mg_sum;
                        b_rmn[i] <= mg_rmn; b_rmx[i] <= mg_rmx;
                        b_rs[i]  <= 1'b1;
                    end
                    if (alloc_oh[i]) begin                     // 新 blob
                        b_act[i] <= 1'b1;
                        b_x0[i] <= s_x0;   b_x1[i] <= s_x1;
                        b_y0[i] <= s_y;    b_y1[i] <= s_y;
                        b_lr[i] <= s_y;
                        b_cnt[i] <= {7'd0, s_len};
                        b_sum[i] <= 20'd0;
                        b_rmn[i] <= s_x0;  b_rmx[i] <= s_x1;
                        b_rs[i]  <= 1'b1;
                    end
                end
            end
            if (state == S_CLR) b_act[ret_slot] <= 1'b0;       // 释放
        end
    end

    // ------------------------------------------------------------ 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            f_pop    <= 1'b0;
            fend_mode<= 1'b0;
            ret_slot <= 4'd0;
            alloc_oh <= {NB{1'b0}};
            m_mask   <= {NB{1'b0}};
            c_free   <= {NB{1'b0}};
            c_exp    <= {NB{1'b0}};
            m0       <= 4'd0;
            s_x0 <= 12'd0; s_x1 <= 12'd0; s_y <= 13'd0; s_len <= 13'd0;
            ret_w <= 12'd0; ret_h <= 12'd0; ret_fill <= 20'd0; ret_area <= 20'd0;
            r_a_th <= 32'd0;
            mul_start <= 1'b0;
            m_a <= 32'd0; m_b <= 11'd0;
            o_cnt <= 10'd0;
            f_cnt_cur <= 10'd0;
        end else begin
            f_pop    <= 1'b0;
            mul_start <= 1'b0;

            if (!cfg_en) begin
                state <= S_IDLE;
            end else if (clr_all) begin
                // 计数与 enable 打开时同步清零(原在输出块里做, 挪到本块避免多驱动)
                f_cnt_cur <= 10'd0;
                o_cnt     <= 10'd0;
            end else case (state)
                // ---- 取一段: 优先把 FIFO 排空, 空完再处理帧末 ----
                S_IDLE: begin
                    if (!f_empty) begin
                        s_x0  <= f_dout[11:0];
                        s_x1  <= f_dout[23:12];
                        s_y   <= f_dout[36:24];
                        s_len <= f_dout[23:12] - f_dout[11:0] + 13'd1;
                        f_pop <= 1'b1;
                        state <= S_MATCH;
                    end else if (fend_req) begin
                        fend_mode <= 1'b1;
                        state     <= S_FEND;
                    end
                end

                // ---- 组合匹配: 寄存命中/空闲/过期掩码 ----
                S_MATCH: begin
                    m_mask <= c_match;
                    for (i = 0; i < NB; i = i + 1) begin
                        c_free[i] <= ~b_act[i];
                        c_exp[i]  <= b_act[i] & (s_y > b_lr[i]) & ((s_y - b_lr[i]) > GAPY);
                    end
                    state <= S_MPRI;
                end

                // ---- 优先级/分配决策 ----
                S_MPRI: begin
                    if (|m_mask) begin
                        m0       <= low_idx(m_mask);
                        alloc_oh <= {NB{1'b0}};
                        state    <= S_APPLY;
                    end else if (|c_free) begin
                        alloc_oh <= ({{(NB-1){1'b0}}, 1'b1} << low_idx(c_free));
                        state    <= S_APPLY;
                    end else if (|c_exp) begin
                        ret_slot  <= low_idx(c_exp);
                        fend_mode <= 1'b0;
                        state     <= S_PREP;
                    end else begin
                        state <= S_IDLE;                 // 无可用槽, 丢弃本段
                    end
                end

                // ---- 写回 ----
                S_APPLY: begin
                    alloc_oh <= {NB{1'b0}};
                    state    <= S_IDLE;
                end

                // ---- 退休准备: 冲掉挂起行 + 装 area = w*h ----
                S_PREP: begin
                    ret_w    <= b_x1[ret_slot] - b_x0[ret_slot] + 12'd1;
                    ret_h    <= b_y1[ret_slot][11:0] - b_y0[ret_slot][11:0] + 12'd1;
                    ret_lsp  <= b_rmx[ret_slot] - b_rmn[ret_slot] + 12'd1;
                    ret_fill <= b_sum[ret_slot]
                              + (b_rs[ret_slot]
                                 ? {8'd0, (b_rmx[ret_slot] - b_rmn[ret_slot] + 12'd1)}
                                 : 20'd0);
                    m_a     <= {12'd0, (b_x1[ret_slot] - b_x0[ret_slot] + 12'd1)};
                    m_b     <= b_y1[ret_slot][10:0] - b_y0[ret_slot][10:0] + 11'd1;
                    state   <= S_MULS0;
                end

                S_MULS0: begin                       // area = w*h
                    mul_start <= 1'b1;
                    state     <= S_MULW0;
                end

                S_MULW0: begin
                    if (mul_done_p) begin
                        ret_area <= m_res[19:0];
                        m_a      <= {12'd0, m_res[19:0]};
                        m_b      <= {1'b0, fil_th};
                        state    <= S_MULS1;
                    end
                end

                S_MULS1: begin                       // a_th = area*fil_th
                    mul_start <= 1'b1;
                    state     <= S_MULW1;
                end

                S_MULW1: begin
                    if (mul_done_p) begin
                        r_a_th <= m_res;
                        state  <= S_CLS;
                    end
                end

                // ---- 分类 + 找插入位置 ----
                S_CLS: begin
                    state <= S_PUSH;
                end

                // ---- 写 top 列表 ----
                S_PUSH: begin
                    if (ins_en) begin
                        l_val[ins_idx] <= 1'b1;
                        l_x0 [ins_idx] <= b_x0[ret_slot];
                        l_x1 [ins_idx] <= b_x1[ret_slot];
                        l_y0 [ins_idx] <= b_y0[ret_slot];
                        l_y1 [ins_idx] <= b_y1[ret_slot];
                        l_cls[ins_idx] <= cls_now;
                        l_sc [ins_idx] <= ret_fill;
                        if (f_cnt_cur != 10'd999) f_cnt_cur <= f_cnt_cur + 10'd1;
                    end
                    state <= S_CLR;
                end

                // ---- 释放槽位 ----
                S_CLR: begin
                    if (fend_mode) begin
                        state <= S_FEND;
                    end else begin
                        alloc_oh <= ({{(NB-1){1'b0}}, 1'b1} << ret_slot);
                        state    <= S_APPLY;         // 复用它开新 blob
                    end
                end

                // ---- 帧末: 逐个退休还在活动的 blob ----
                S_FEND: begin
                    t_found = 1'b0;
                    for (i = NB-1; i >= 0; i = i - 1)
                        if (b_act[i]) begin t_idx = i[3:0]; t_found = 1'b1; end
                    if (t_found) begin
                        ret_slot <= t_idx;
                        state    <= S_PREP;
                    end else begin
                        state <= S_COMMIT;
                    end
                end

                // ---- 提交输出 + hold ----
                S_COMMIT: begin
                    fend_mode <= 1'b0;
                    o_cnt     <= f_cnt_cur;    // 本帧总数锁存给上层/telemetry
                    f_cnt_cur <= 10'd0;        // 下一帧重新计数
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------- 输出与 hold
    reg [4:0] hold_cnt;
    reg       any_l;

    always @* begin
        any_l = 1'b0;
        for (i = 0; i < NBX; i = i + 1) any_l = any_l | l_val[i];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_bx0 <= {NBX*12{1'b0}}; o_bx1 <= {NBX*12{1'b0}};
            o_by0 <= {NBX*13{1'b0}}; o_by1 <= {NBX*13{1'b0}};
            o_bcls <= {NBX*3{1'b0}}; o_bval <= {NBX{1'b0}};
            hold_cnt <= 5'd0;
            for (i = 0; i < NBX; i = i + 1) begin
                l_val[i] <= 1'b0; l_x0[i] <= 12'd0; l_x1[i] <= 12'd0;
                l_y0[i] <= 13'd0; l_y1[i] <= 13'd0;
                l_cls[i] <= 3'd0; l_sc[i] <= 20'd0;
            end
        end else begin
            if (clr_all || !cfg_en) begin
                o_bval <= {NBX{1'b0}};
                hold_cnt <= 5'd0;
            end
            if ((state == S_COMMIT) && ~clr_all) begin
                for (i = 0; i < NBX; i = i + 1) begin
                    l_val[i] <= 1'b0;              // 列表每帧重建
                    if (any_l) begin
                        o_bx0 [i*12 +: 12] <= l_x0[i];
                        o_bx1 [i*12 +: 12] <= l_x1[i];
                        o_by0 [i*13 +: 13] <= l_y0[i];
                        o_by1 [i*13 +: 13] <= l_y1[i];
                        o_bcls[i*3  +: 3]  <= l_cls[i];
                        o_bval[i]          <= l_val[i] & (i[2:0] < nbox);
                    end
                end
                if (any_l)          hold_cnt <= HOLD5;
                else if (hold_cnt != 5'd0) hold_cnt <= hold_cnt - 5'd1;
                else                o_bval <= {NBX{1'b0}};
            end
        end
    end

endmodule
