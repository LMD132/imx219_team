//=============================================================================
// shp_detect.v -- 赛题4: 三类平面图形的流式候选检测与几何分类
//
// 赛题原文: "在边缘检测的基础上, 识别画面中的特定形状(如圆形、矩形);
//            可采用特征匹配法: 在边缘图像中检测轮廓, 计算几何特征;
//            将识别结果显示在屏幕上(如'检测到圆形')"
//
// 按"特征匹配法"实现, 全部在像素流上完成, 不需要整帧缓存:
//
//  1) 游程(Run-Length)连通域: 二值边缘流里每一行会出来若干段"连续白点"。
//     每段结束时, 拿它的 [x0,x1] 与"还在活动的 blob 表"比较:
//       有重叠且行号接近 -> 并进同一个 blob;  完全对不上 -> 开一个新 blob;
//     一行的左右两段(比如圆的左弧和右弧)会先后落进同一个 blob 的 x 范围内,
//     于是被正确并到一起。表里最多 NB=8 个并发 blob(够画面上 8 个图形)。
//
//  2) shp_summary 为每个 blob 存32方向极值点和每4行左右轮廓摘要。
//     只有最近行游程证据允许并槽；历史bbox只用于无漏检的候选预筛。
//
//  3) blob退休后由 shp_geometry 串行检查顶点、直边、圆/椭圆残差和
//     条带外凹陷。只产生圆(1)、矩形(2)、三角形(3)；十字及不可靠轮廓拒识。
//     旧填充率仍可用于框排序，但不再控制类别。
//
//  4) 帧末原子提交NBX个框；空帧最多保持2帧。游程溢出或槽位不足时
//     整帧输出无效并增加诊断计数，避免残缺轮廓被肯定分类。
//
// 资源: blob表/最近行游程、摘要RAM和串行定点几何计算；以构建报告为准。
//
// 时序: 游程事件经深度FQ=24的FIFO，几何分类在目标退休后进行。
//       密纹理造成的过载记录在o_ovf，受影响帧不输出形状框。
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
    parameter integer HOLD = 2       // 临时漏检最多保持两帧
)(
    input  wire        clk,
    input  wire        rst_n,

    // 运行期参数(alg_cfg_sync 送过来; 全部有内部限幅)
    input  wire        cfg_en,          // 0 = 关闭形状识别(直通, 不画任何框)
    input  wire [7:0]  cfg_min_size,    // bbox 最小边长(px), 8..255, 默认 24
    input  wire [2:0]  cfg_max_boxes,   // 显示框数上限 1..6, 默认 4
    input  wire [9:0]  cfg_fill_th,     // 旧版填充率字段，保留接口；不控制新分类
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
    output reg  [NBX*3-1:0]  o_bcls,     // 1=圆 2=矩 3=三角 0=无效
    output reg  [NBX-1:0]    o_bval,

    output reg  [9:0]  o_cnt,            // 本帧提交的合格图形数(0..999)
    output reg  [15:0] o_ovf,            // 饱和的处理异常计数(含游程溢出/无空槽)
    output reg  [31:0] o_slot_drop_total, // 累计无槽游程事件, 32 位自然回卷
    output reg  [31:0] o_fifo_full_total, // 累计 FIFO 满时到达的游程
    output reg         o_last_fault,     // 最近提交帧是否整体丢弃
    output reg  [3:0]  o_last_reason,    // 最近提交帧故障来源位图
    output reg         o_frame_valid     // 复位后是否已有完整提交帧
);

    // FQ/HOLD 是 integer 参数, 转定宽 localparam 再比较/做下标,
    // 避免个别综合器对 integer 位选支持不好
    localparam [4:0] FQ5   = FQ;
    localparam [4:0] HOLD5 = (HOLD > 2) ? 5'd2 : HOLD;

    // ---------------------------------------------------------------- 限幅
    wire [7:0]  min_sz  = (cfg_min_size  <  8'd8)   ?  8'd8   : cfg_min_size;
    wire [2:0]  nbox    = (cfg_max_boxes == 3'd0)   ?  3'd1   : cfg_max_boxes;
    // 旧调参字段照常限幅，供兼容性寄存器路径使用；不影响几何类别。
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
    // {late_frame, frame_boundary, row, right, left}.  A boundary travels
    // through the same queue as spans, so busy processing cannot move runs
    // from the next frame into the previous one.
    reg  [38:0] fifo [0:FQ-1];
    localparam [4:0] S_IDLE=5'd0, S_COMMIT=5'd13;
    reg [4:0] state;
    wire no_slot_drop;
    wire malformed_retire;
    reg  [4:0]  f_wp, f_rp, f_cnt;
    reg  [4:0]  pending_edges, lost_edges;
    reg         sync_lost;
    reg         capture_fault;
    reg         vs_r;
    reg         frame_fault;
    reg [3:0]   frame_reason;
    wire        f_empty = (f_cnt == 5'd0);
    wire        f_full  = (f_cnt == FQ5);
    reg         f_pop;                       // 主状态机 1 拍脉冲
    wire [38:0] f_dout  = fifo[f_rp];
    wire vs_edge = in_vs && !vs_r;
    wire synthetic_boundary = (state==S_IDLE) && f_empty &&
                              (lost_edges!=0) && cfg_en;
    wire marker_read = (state==S_IDLE) && !f_empty && f_dout[37];
    // After a lost marker, discard whole source frames.  The next real VS
    // may resynchronise only after all old queued work and synthetic commits
    // have finished; that boundary itself is marked invalid.
    wire recovery_edge = vs_edge && sync_lost && f_empty &&
                         (lost_edges==0) && (pending_edges==0) &&
                         (state==S_IDLE) && !f_pop;
    wire push_req = vs_edge || span_end;
    wire push_ok = push_req && !f_full && (!sync_lost || recovery_edge);
    wire lost_boundary = vs_edge && (f_full || (sync_lost && !recovery_edge));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_wp <= 5'd0; f_rp <= 5'd0; f_cnt <= 5'd0; o_ovf <= 16'd0;
            o_slot_drop_total <= 32'd0;
            o_fifo_full_total <= 32'd0;
            pending_edges <= 5'd0; lost_edges <= 5'd0; sync_lost <= 1'b0;
            capture_fault <= 1'b0;
            frame_fault <= 1'b0;
            frame_reason <= 4'b0;
        end else if (!cfg_en) begin
            f_wp <= 5'd0; f_rp <= 5'd0; f_cnt <= 5'd0;   // 关闭时清空
            pending_edges <= 5'd0; lost_edges <= 5'd0; sync_lost <= 1'b0;
            capture_fault <= 1'b0;
            frame_fault <= 1'b0;
            frame_reason <= 4'b0;
        end else begin
            if (no_slot_drop)
                o_slot_drop_total <= o_slot_drop_total + 32'd1;
            if (span_end && f_full)
                o_fifo_full_total <= o_fifo_full_total + 32'd1;
            if (state==S_COMMIT) begin
                frame_fault <= 1'b0;
                frame_reason <= 4'b0;
            end
            // 2026-10-02 故障分级(fault grading): 只有"整帧都不可信"的原因
            //   才作废整帧。原来 no_slot_drop(槽位不足) 和 marker 坏(捕获期丢
            //   一条游程) 也会把整帧结果清零, 于是一帧几万条游程里丢一条,
            //   屏幕就一个框都不显示 —— 实拍"放上去根本不识别"的主因。
            //   这两类现在只记录来源码/计数, 帧照常提交其余合格目标:
            //     no_slot_drop 只影响当次那一个候选目标;
            //     marker 坏只伤丢游程附近的局部轮廓。
            if ((vs_edge && pending_edges!=0) || lost_boundary ||
                synthetic_boundary)
                frame_fault <= 1'b1;
            // Match the fault latch's event and commit boundaries.  The
            // source bits are sticky within one committed frame, unlike
            // o_ovf which saturates across the entire power-on lifetime.
            if (no_slot_drop) frame_reason[0] <= 1'b1;
            if (marker_read && f_dout[38]) frame_reason[1] <= 1'b1;
            if (vs_edge && pending_edges!=0) frame_reason[2] <= 1'b1;
            if (lost_boundary || synthetic_boundary) frame_reason[3] <= 1'b1;
            // Dropped input belongs to the CAPTURE frame, which can be one
            // or more frames ahead of the blob currently being retired.
            if (vs_edge) capture_fault <= 1'b0;
            else if (span_end && !push_ok) capture_fault <= 1'b1;
            if (push_ok) begin
                // The VS marker wins an otherwise simultaneous span-end;
                // that dropped span also invalidates the frame.
                fifo[f_wp] <= vs_edge ? {(capture_fault || span_end ||
                                        (pending_edges!=0) || recovery_edge),
                                        1'b1,37'd0} :
                                       {2'b00,y_r,x_r,sx0};
                f_wp <= (f_wp == (FQ5 - 5'd1)) ? 5'd0 : (f_wp + 5'd1);
            end
            if (lost_boundary) sync_lost <= 1'b1;
            else if (recovery_edge)
                sync_lost <= 1'b0;
            case ({vs_edge, state==S_COMMIT})
                2'b10: if (pending_edges!=5'h1f) pending_edges<=pending_edges+5'd1;
                2'b01: if (pending_edges!=0) pending_edges<=pending_edges-5'd1;
                default: ;
            endcase
            case ({lost_boundary,synthetic_boundary})
                2'b10: if (lost_edges!=5'h1f) lost_edges<=lost_edges+5'd1;
                2'b01: lost_edges<=lost_edges-5'd1;
                default: ;
            endcase
            // Count bad geometry storage as well as dropped input work. If
            // two anomalies coincide, this diagnostic counts the cycle once.
            if (((span_end && (!push_ok || vs_edge)) || no_slot_drop ||
                 malformed_retire || (vs_edge && pending_edges!=0) ||
                 lost_boundary) &&
                o_ovf != 16'hFFFF)
                o_ovf <= o_ovf + 16'd1;
            if (f_pop) f_rp <= (f_rp == (FQ5 - 5'd1)) ? 5'd0 : (f_rp + 5'd1);
            case ({push_ok, f_pop})
                2'b10:   f_cnt <= f_cnt + 5'd1;
                2'b01:   f_cnt <= f_cnt - 5'd1;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------- blob 表
    reg            b_act [0:NB-1];
    reg            b_amb [0:NB-1];      // two long disjoint runs shared first row
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
    reg  [11:0]    b_mxc [0:NB-1];      // 已完成行里最大的 x 跨度(0=还没有已完成行)
    reg  [12:0]    b_my0 [0:NB-1];      // 取到该最大跨度的首行
    reg  [12:0]    b_my1 [0:NB-1];      // ...末行(连成一片时取整个区间)

    // ------------------------------------------------------- top 列表(NBX)
    reg            l_val [0:NBX-1];
    reg  [11:0]    l_x0  [0:NBX-1];
    reg  [11:0]    l_x1  [0:NBX-1];
    reg  [12:0]    l_y0  [0:NBX-1];
    reg  [12:0]    l_y1  [0:NBX-1];
    reg  [2:0]     l_cls [0:NBX-1];
    reg  [19:0]    l_sc  [0:NBX-1];

    // ------------------------------------------------------------ 主状态机
    localparam S_MATCH  = 5'd1,     // 组合匹配 -> 寄存掩码
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
               S_SUM_INIT=5'd14,S_SUM_SCAN=5'd15,S_SUM_SPAN=5'd16,
               S_SUM_ACCEPT=5'd17,S_SUM_FINISH=5'd18,
               S_QMATCH=5'd19,S_QWAIT=5'd20,
               S_GEOM_START=5'd21,S_GEOM_WAIT=5'd22;

    reg         fend_mode;
    reg  [3:0]  ret_slot;
    reg  [NB-1:0] alloc_oh;
    reg  [NB-1:0] m_mask;                // 本段命中的槽(寄存)
    reg  [NB-1:0] qm_mask;
    reg  [NB-1:0] c_free;                // 空闲槽掩码
    reg  [NB-1:0] c_exp;                 // 过期槽掩码
    reg  [3:0]  m0;                      // 命中槽里最小的一个
    reg  [11:0] s_x0, s_x1;
    reg  [12:0] s_y;
    reg  [12:0] s_len;

    reg sum_valid;
    reg [1:0] sum_op;
    reg [2:0] sum_slot,sum_other;
    reg [3:0] sum_scan,sum_dst;
    reg [4:0] sum_after;
    wire summary_ready,recent_ready,recent_query_ready,recent_query_done;
    wire sum_ready=summary_ready&&recent_ready;
    wire [NB-1:0] summary_bad,recent_bad;
    wire [NB-1:0] recent_matches;
    reg [NB-1:0] recent_candidates;
    integer qi;
    always @* begin
     for(qi=0;qi<NB;qi=qi+1)
      recent_candidates[qi]=b_act[qi]&&
       ({1'b0,s_x0}<={1'b0,b_x1[qi]}+GAPX)&&
       ({1'b0,s_x1}+GAPX>={1'b0,b_x0[qi]});
    end
    wire summary_rd_ready,summary_rd_valid;
    wire [25:0] summary_rd_data;
    wire geom_req,geom_ready,geom_done,geom_valid;
    assign malformed_retire = (state==S_GEOM_START) && geom_ready &&
                              (summary_bad[ret_slot] || recent_bad[ret_slot]);
    wire [2:0] geom_rd_slot,geom_cls;
    wire [7:0] geom_rd_index;
    wire clr_all;
    wire summary_rst_n=rst_n&&cfg_en&&!clr_all;
    shp_summary #(.W(W),.H(H),.NB(NB)) summaries(
     .clk(clk),.rst_n(summary_rst_n),.cmd_valid(sum_valid&&recent_ready),.cmd_ready(summary_ready),
     .cmd_op(sum_op),.cmd_slot(sum_slot),.cmd_other(sum_other),.cmd_x0(s_x0),.cmd_x1(s_x1),.cmd_y(s_y),
     .rd_req(geom_req),.rd_ready(summary_rd_ready),.rd_slot(geom_rd_slot),.rd_index(geom_rd_index),
     .rd_valid(summary_rd_valid),.rd_data(summary_rd_data),.bad(summary_bad));
    shp_geometry geometry(
     .clk(clk),.rst_n(summary_rst_n),.start(state==S_GEOM_START&&geom_ready),
     .start_ready(geom_ready),.slot(ret_slot[2:0]),
     .bbox_x0(b_x0[ret_slot]),.bbox_x1(b_x1[ret_slot]),
     .bbox_y0(b_y0[ret_slot]),.bbox_y1(b_y1[ret_slot]),
     .bad(summary_bad[ret_slot]||recent_bad[ret_slot]||b_amb[ret_slot]),
     .done(geom_done),.valid(geom_valid),.cls(geom_cls),
     .rd_req(geom_req),.rd_slot(geom_rd_slot),.rd_index(geom_rd_index),
     .rd_valid(summary_rd_valid),.rd_data(summary_rd_data));
    shp_recent #(.W(W),.H(H),.NB(NB),.GAPX(GAPX),.GAPY(GAPY)) connections(
     .clk(clk),.rst_n(summary_rst_n),.cmd_valid(sum_valid&&summary_ready),.cmd_ready(recent_ready),
     .cmd_op(sum_op),.cmd_slot(sum_slot),.cmd_other(sum_other),.cmd_x0(s_x0),.cmd_x1(s_x1),.cmd_y(s_y),
     .query_start(state==S_QMATCH),.query_ready(recent_query_ready),
     .query_mask(recent_candidates),
     .query_x0(s_x0),.query_x1(s_x1),.query_y(s_y),
     .query_done(recent_query_done),.o_matches(recent_matches),.bad(recent_bad));

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
    reg  [12:0] ret_ytop, ret_ybot;      // bbox 上/下边(退休时锁存)
    reg  [12:0] ret_my0,  ret_my1;       // 最宽行的首/末行(退休时锁存)

    integer i;
    reg [3:0]  t_idx;
    reg        t_found;
    reg [19:0] t_min;

    // VS 边沿入队为帧边界；其相对游程的顺序由同一 FIFO 保证。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_r <= 1'b0;
        else vs_r <= in_vs;
    end

    // en 关闭时清表(en 上升沿重新开始)
    reg en_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) en_r <= 1'b0;
        else        en_r <= cfg_en;
    end
    assign clr_all = cfg_en & ~en_r;      // en 刚打开: 清干净

    // ------------------------------------------------- 匹配/优先级(组合)
    wire [NB-1:0] c_match=qm_mask;
    assign no_slot_drop=(state==S_MPRI)&&!(|m_mask)&&!(|c_free)&&!(|c_exp);

    // ---- 最宽行记录(合并值): 打包 {span[11:0], my0[12:0], my1[12:0]} = 38bit ----
    //   mx2     : 合并两份记录 —— 取跨度大的; 跨度相等时行号区间取并集。
    //   slot_mx : 单个槽的候选 = 已记录的最宽行 ∪ (本拍被冲掉的挂起行)。
    // 8 槽串行比较在 74.25MHz 域跑不完一个周期(旧写法报 -6.98ns), 故拆三级折叠:
    //   S_MATCH 折半寄存(8->4) → S_MPRI 折半寄存(4->2) → S_APPLY 组合折成 1 份。
    function [37:0] mx2;
        input [37:0] a, b;
        reg [11:0] sa, sb;
        begin
            sa = a[37:26]; sb = b[37:26];
            if (sa > sb)          mx2 = a;
            else if (sb > sa)     mx2 = b;
            else if (sa == 12'd0) mx2 = 38'd0;      // 两侧都"还没有已完成行"
            else                  mx2 = { sa,
                        (a[25:13] < b[25:13]) ? a[25:13] : b[25:13],
                        (a[12:0]  > b[12:0])  ? a[12:0]  : b[12:0] };
        end
    endfunction

    function [37:0] slot_mx;
        input [11:0] mxc;   input [12:0] my0i, my1i;
        input        flush; input [11:0] sp;   input [12:0] fy;
        begin
            // 挂起行在"换行"那一拍才算完成; 最后一行由退休侧的 sp_last 补偿。
            slot_mx = mx2({mxc, my0i, my1i},
                          flush ? {sp, fy, fy} : {12'd0, 13'd0, 13'd0});
        end
    endfunction

    wire [37:0] mx_s0 = c_match[0] ? slot_mx(b_mxc[0], b_my0[0], b_my1[0],
                          b_rs[0] & (s_y != b_lr[0]), b_rmx[0] - b_rmn[0] + 12'd1, b_lr[0]) : 38'd0;
    wire [37:0] mx_s1 = c_match[1] ? slot_mx(b_mxc[1], b_my0[1], b_my1[1],
                          b_rs[1] & (s_y != b_lr[1]), b_rmx[1] - b_rmn[1] + 12'd1, b_lr[1]) : 38'd0;
    wire [37:0] mx_s2 = c_match[2] ? slot_mx(b_mxc[2], b_my0[2], b_my1[2],
                          b_rs[2] & (s_y != b_lr[2]), b_rmx[2] - b_rmn[2] + 12'd1, b_lr[2]) : 38'd0;
    wire [37:0] mx_s3 = c_match[3] ? slot_mx(b_mxc[3], b_my0[3], b_my1[3],
                          b_rs[3] & (s_y != b_lr[3]), b_rmx[3] - b_rmn[3] + 12'd1, b_lr[3]) : 38'd0;
    wire [37:0] mx_s4 = c_match[4] ? slot_mx(b_mxc[4], b_my0[4], b_my1[4],
                          b_rs[4] & (s_y != b_lr[4]), b_rmx[4] - b_rmn[4] + 12'd1, b_lr[4]) : 38'd0;
    wire [37:0] mx_s5 = c_match[5] ? slot_mx(b_mxc[5], b_my0[5], b_my1[5],
                          b_rs[5] & (s_y != b_lr[5]), b_rmx[5] - b_rmn[5] + 12'd1, b_lr[5]) : 38'd0;
    wire [37:0] mx_s6 = c_match[6] ? slot_mx(b_mxc[6], b_my0[6], b_my1[6],
                          b_rs[6] & (s_y != b_lr[6]), b_rmx[6] - b_rmn[6] + 12'd1, b_lr[6]) : 38'd0;
    wire [37:0] mx_s7 = c_match[7] ? slot_mx(b_mxc[7], b_my0[7], b_my1[7],
                          b_rs[7] & (s_y != b_lr[7]), b_rmx[7] - b_rmn[7] + 12'd1, b_lr[7]) : 38'd0;

    wire [37:0] mx_p0 = mx2(mx_s0, mx_s1);
    wire [37:0] mx_p1 = mx2(mx_s2, mx_s3);
    wire [37:0] mx_p2 = mx2(mx_s4, mx_s5);
    wire [37:0] mx_p3 = mx2(mx_s6, mx_s7);

    reg  [37:0] pm_mx0, pm_mx1, pm_mx2, pm_mx3;   // S_MATCH 折半寄存(8->4)
    reg  [37:0] pq_mx0, pq_mx1;                    // S_MPRI  折半寄存(4->2)
    wire [37:0] mx_fin = mx2(pq_mx0, pq_mx1);      // S_APPLY 组合(2->1)
    wire [11:0] mg_mxc = mx_fin[37:26];            // 最宽行跨度(合并后)
    wire [12:0] mg_my0 = mx_fin[25:13];            // 该跨度对应的行区间
    wire [12:0] mg_my1 = mx_fin[12:0];

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
                // (最宽行记录的合并已移出本循环: 按 mx2/slot_mx 三级折叠,
                //  见上方函数与 S_MATCH/S_MPRI 的折半寄存, 避免 8 槽串行比较)
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

    // ---- 退休用组合量(ret_slot 指向正要退休的 blob) -------------------------
    //   sp_last = "挂起行"(blob 最后一行)的跨度。挂起行还没进 b_sum/b_mxc,
    //   退休时把它也算进最宽行(和 ret_fill 的算法一致), 得到 sp_my0/sp_my1。
    wire [11:0] sp_last = b_rmx[ret_slot] - b_rmn[ret_slot] + 12'd1;
    wire        sp_gt   = (sp_last >  b_mxc[ret_slot]);
    wire        sp_eq   = (sp_last == b_mxc[ret_slot]);
    wire [12:0] sp_my0  = sp_gt ? b_lr[ret_slot] :
                          sp_eq ? ((b_lr[ret_slot] < b_my0[ret_slot]) ? b_lr[ret_slot] : b_my0[ret_slot])
                                : b_my0[ret_slot];
    wire [12:0] sp_my1  = sp_gt ? b_lr[ret_slot] :
                          sp_eq ? ((b_lr[ret_slot] > b_my1[ret_slot]) ? b_lr[ret_slot] : b_my1[ret_slot])
                                : b_my1[ret_slot];

    wire ok_size=(ret_w>={4'd0,min_sz})&&(ret_h>={4'd0,min_sz});
    wire ok_area=({7'd0,ret_area}<=area_max);

    // Classes come exclusively from shp_geometry; the legacy fill/plateau
    // heuristics are not a fallback for ambiguous rotation or cross shapes.
    wire qualified = ok_size & ok_area & geom_valid & (geom_cls>=1) & (geom_cls<=3)
                    & ~summary_bad[ret_slot] & ~recent_bad[ret_slot]
                    & ~b_amb[ret_slot];
    wire [2:0] cls_now = geom_cls;

    // top 列表插入位置(组合, S_CLS 拍)
    reg  [2:0]  ins_idx;
    reg         ins_en;
    reg  [2:0]  free_i;
    reg         free_found;
    reg  [19:0] min_s;
    reg  [2:0]  min_i;
    reg         ring_dup,ring_replace;
    reg  [2:0]  ring_idx;
    reg  [11:0] ring_w,ring_h;
    reg  [12:0] ring_cx2;
    reg  [13:0] ring_cy2;
    always @* begin
        free_i = 3'd0; free_found = 1'b0;
        for (i = NBX-1; i >= 0; i = i - 1)
            if (!l_val[i]) begin free_i = i[2:0]; free_found = 1'b1; end
        min_s = 20'hFFFFF; min_i = 3'd0;
        for (i = 0; i < NBX; i = i + 1)
            if (l_val[i] & (l_sc[i] < min_s)) begin min_s = l_sc[i]; min_i = i[2:0]; end
        ring_dup=1'b0;ring_replace=1'b0;ring_idx=3'd0;
        ring_w=12'd0;ring_h=12'd0;ring_cx2=13'd0;ring_cy2=14'd0;
        // Treat only a concentric, nested pair of *independently classified*
        // circles as one annulus. Bbox containment by itself is insufficient.
        for (i = 0; i < NBX; i = i + 1) begin
            ring_w=l_x1[i]-l_x0[i]+12'd1;
            ring_h=l_y1[i]-l_y0[i]+12'd1;
            ring_cx2={1'b0,l_x0[i]}+{1'b0,l_x1[i]};
            ring_cy2={1'b0,l_y0[i]}+{1'b0,l_y1[i]};
            if (qualified && cls_now==3'd1 && l_val[i] && l_cls[i]==3'd1 &&
                (({1'b0,b_x0[ret_slot]}+{1'b0,b_x1[ret_slot]}>=ring_cx2) ?
                  ({1'b0,b_x0[ret_slot]}+{1'b0,b_x1[ret_slot]}-ring_cx2<=13'd8) :
                  (ring_cx2-({1'b0,b_x0[ret_slot]}+{1'b0,b_x1[ret_slot]})<=13'd8)) &&
                (({1'b0,b_y0[ret_slot]}+{1'b0,b_y1[ret_slot]}>=ring_cy2) ?
                  ({1'b0,b_y0[ret_slot]}+{1'b0,b_y1[ret_slot]}-ring_cy2<=14'd8) :
                  (ring_cy2-({1'b0,b_y0[ret_slot]}+{1'b0,b_y1[ret_slot]})<=14'd8)) &&
                (((b_x0[ret_slot]<=l_x0[i] && b_x1[ret_slot]>=l_x1[i] &&
                   b_y0[ret_slot]<=l_y0[i] && b_y1[ret_slot]>=l_y1[i]) &&
                   ({1'b0,ring_w}*2 >= {1'b0,ret_w}) &&
                   ({1'b0,ring_h}*2 >= {1'b0,ret_h})) ||
                 ((l_x0[i]<=b_x0[ret_slot] && l_x1[i]>=b_x1[ret_slot] &&
                   l_y0[i]<=b_y0[ret_slot] && l_y1[i]>=b_y1[ret_slot]) &&
                   ({1'b0,ret_w}*2 >= {1'b0,ring_w}) &&
                   ({1'b0,ret_h}*2 >= {1'b0,ring_h})))) begin
                ring_dup=1'b1;ring_idx=i[2:0];
                ring_replace=(ret_w>ring_w && ret_h>ring_h);
            end
        end
        if (ring_dup)begin ins_idx=ring_idx;ins_en=ring_replace;end
        else if (free_found)          begin ins_idx = free_i;  ins_en = qualified; end
        else if (ret_fill > min_s) begin ins_idx = min_i; ins_en = qualified; end
        else                     begin ins_idx = 3'd0;    ins_en = 1'b0; end
    end

    // ------------------------------------------------------------ 槽位写回
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NB; i = i + 1) begin
                b_act[i] <= 1'b0; b_amb[i] <= 1'b0;
                b_x0[i] <= 12'd0; b_x1[i] <= 12'd0;
                b_y0[i] <= 13'd0; b_y1[i] <= 13'd0; b_lr[i] <= 13'd0;
                b_cnt[i] <= 20'd0; b_sum[i] <= 20'd0;
                b_rmn[i] <= 12'd0; b_rmx[i] <= 12'd0; b_rs[i] <= 1'b0;
                b_mxc[i] <= 12'd0; b_my0[i] <= 13'd0; b_my1[i] <= 13'd0;
            end
        end else begin
            if (clr_all) begin
                for (i = 0; i < NB; i = i + 1) begin
                    b_act[i] <= 1'b0; b_amb[i] <= 1'b0;
                    b_cnt[i] <= 20'd0; b_sum[i] <= 20'd0;
                    b_rs[i] <= 1'b0; b_rmn[i] <= 12'd0; b_rmx[i] <= 12'd0;
                    b_mxc[i] <= 12'd0; b_my0[i] <= 13'd0; b_my1[i] <= 13'd0;
                end
            end
            if ((state == S_APPLY) && ~clr_all) begin
                for (i = 0; i < NB; i = i + 1) begin
                    if (m_mask[i] & (i[3:0] != m0) & b_act[i])
                        b_act[i] <= 1'b0;                      // 并进 m0
                    if (m_mask[i] & (i[3:0] == m0)) begin
                        b_act[i] <= 1'b1;
                        // Two separate full-width top edges on the first
                        // row can otherwise masquerade as one rectangle when
                        // their gap is below GAPX. Curved ring arcs at their
                        // extrema are short and do not trigger this guard.
                        if (b_y0[i]==s_y && b_lr[i]==s_y &&
                            {1'b0,b_rmx[i]}+13'd1 < {1'b0,s_x0} &&
                            (b_rmx[i]-b_rmn[i]+12'd1)>=min_sz &&
                            s_len>={5'd0,min_sz}) b_amb[i]<=1'b1;
                        b_x0[i] <= mg_x0;  b_x1[i] <= mg_x1;
                        b_y0[i] <= mg_y0;  b_y1[i] <= mg_y1;
                        b_lr[i] <= s_y;
                        b_cnt[i] <= mg_cnt;
                        // 累加: mg_sum 只带"上一次换行时冲掉的整行跨度",
                        // 旧版写成 b_sum <= mg_sum(覆盖) -> 填充面积只剩最后一行
                        b_sum[i] <= b_sum[i] + mg_sum;
                        b_rmn[i] <= mg_rmn; b_rmx[i] <= mg_rmx;
                        b_rs[i]  <= 1'b1;
                        b_mxc[i] <= mg_mxc;              // 最宽行记录一起并过来
                        b_my0[i] <= mg_my0; b_my1[i] <= mg_my1;
                    end
                    if (alloc_oh[i]) begin                     // 新 blob
                        b_act[i] <= 1'b1;
                        b_amb[i] <= 1'b0;
                        b_x0[i] <= s_x0;   b_x1[i] <= s_x1;
                        b_y0[i] <= s_y;    b_y1[i] <= s_y;
                        b_lr[i] <= s_y;
                        b_cnt[i] <= {7'd0, s_len};
                        b_sum[i] <= 20'd0;
                        b_rmn[i] <= s_x0;  b_rmx[i] <= s_x1;
                        b_rs[i]  <= 1'b1;
                        b_mxc[i] <= 12'd0;               // 还没有"已完成行"
                        b_my0[i] <= s_y;   b_my1[i] <= s_y;
                    end
                end
            end
            if (state == S_CLR) begin
                b_act[ret_slot] <= 1'b0;
                b_amb[ret_slot] <= 1'b0;
            end
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
            qm_mask  <= {NB{1'b0}};
            c_free   <= {NB{1'b0}};
            c_exp    <= {NB{1'b0}};
            m0       <= 4'd0;
            s_x0 <= 12'd0; s_x1 <= 12'd0; s_y <= 13'd0; s_len <= 13'd0;
            ret_w <= 12'd0; ret_h <= 12'd0; ret_fill <= 20'd0; ret_area <= 20'd0;
            ret_lsp <= 12'd0; ret_ytop <= 13'd0; ret_ybot <= 13'd0;
            ret_my0 <= 13'd0; ret_my1 <= 13'd0;
            pm_mx0 <= 38'd0; pm_mx1 <= 38'd0; pm_mx2 <= 38'd0; pm_mx3 <= 38'd0;
            pq_mx0 <= 38'd0; pq_mx1 <= 38'd0;
            r_a_th <= 32'd0;
            mul_start <= 1'b0;
            m_a <= 32'd0; m_b <= 11'd0;
            o_cnt <= 10'd0;
            o_last_fault <= 1'b0;
            o_last_reason <= 4'b0;
            o_frame_valid <= 1'b0;
            f_cnt_cur <= 10'd0;
            sum_valid<=0;sum_op<=0;sum_slot<=0;sum_other<=0;
            sum_scan<=0;sum_dst<=0;sum_after<=S_IDLE;
        end else begin
            f_pop    <= 1'b0;
            mul_start <= 1'b0;

            if (!cfg_en) begin
                state <= S_IDLE;
                sum_valid<=0;
            end else if (clr_all) begin
                // 计数与 enable 打开时同步清零(原在输出块里做, 挪到本块避免多驱动)
                f_cnt_cur <= 10'd0;
                o_cnt     <= 10'd0;
                sum_valid<=0;state<=S_IDLE;
            end else case (state)
                // ---- 取一段: 优先把 FIFO 排空, 空完再处理帧末 ----
                S_IDLE: begin
                    if (!f_empty) begin
                        f_pop <= 1'b1;
                        if (f_dout[37]) begin
                            fend_mode <= 1'b1;
                            state <= S_FEND;
                        end else begin
                            s_x0  <= f_dout[11:0];
                            s_x1  <= f_dout[23:12];
                            s_y   <= f_dout[36:24];
                            s_len <= f_dout[23:12] - f_dout[11:0] + 13'd1;
                            qm_mask <= {NB{1'b0}};
                            state <= S_QMATCH;
                        end
                    end else if (synthetic_boundary) begin
                        fend_mode <= 1'b1;
                        state     <= S_FEND;
                    end
                end

                // RAM scan returns the eight-slot match mask after NB*NR reads.
                S_QMATCH: if(recent_query_ready) state<=S_QWAIT;
                S_QWAIT: if(recent_query_done) begin
                    for(i=0;i<NB;i=i+1)qm_mask[i]<=b_act[i]&recent_matches[i];
                    state<=S_MATCH;
                end

                // ---- 组合匹配: 寄存命中/空闲/过期掩码 ----
                S_MATCH: begin
                    m_mask <= c_match;
                    for (i = 0; i < NB; i = i + 1) begin
                        c_free[i] <= ~b_act[i];
                        c_exp[i]  <= b_act[i] & (s_y > b_lr[i]) & ((s_y - b_lr[i]) > GAPY);
                    end
                    pm_mx0 <= mx_p0; pm_mx1 <= mx_p1;    // 最宽行候选: 8->4 折半寄存
                    pm_mx2 <= mx_p2; pm_mx3 <= mx_p3;
                    state <= S_MPRI;
                end

                // ---- 优先级/分配决策 ----
                S_MPRI: begin
                    pq_mx0 <= mx2(pm_mx0, pm_mx1);       // 最宽行候选: 4->2 折半寄存
                    pq_mx1 <= mx2(pm_mx2, pm_mx3);
                    if (|m_mask) begin
                        m0       <= low_idx(m_mask);
                        alloc_oh <= {NB{1'b0}};
                        state    <= S_SUM_INIT;
                    end else if (|c_free) begin
                        alloc_oh <= ({{(NB-1){1'b0}}, 1'b1} << low_idx(c_free));
                        state    <= S_SUM_INIT;
                    end else if (|c_exp) begin
                        ret_slot  <= low_idx(c_exp);
                        fend_mode <= 1'b0;
                        state     <= S_PREP;
                    end else begin
                        state <= S_IDLE;                 // 无可用槽, 丢弃本段
                    end
                end

                // Accumulate/merge all geometry before the blob table can
                // release any source slot. Commands complete before readout.
                S_SUM_INIT:begin
                    sum_dst<=(|alloc_oh)?low_idx(alloc_oh):m0;
                    sum_scan<=0;
                    if(|alloc_oh)begin
                        sum_op<=0;sum_slot<=low_idx(alloc_oh);sum_other<=0;
                        sum_valid<=1;sum_after<=S_SUM_SCAN;state<=S_SUM_ACCEPT;
                    end else state<=S_SUM_SCAN;
                end
                S_SUM_SCAN:begin
                    if(sum_scan==NB)state<=S_SUM_SPAN;
                    else begin
                        sum_scan<=sum_scan+1'b1;
                        if(m_mask[sum_scan]&&sum_scan!=sum_dst)begin
                            sum_op<=2;sum_slot<=sum_dst[2:0];sum_other<=sum_scan[2:0];
                            sum_valid<=1;sum_after<=S_SUM_SCAN;state<=S_SUM_ACCEPT;
                        end
                    end
                end
                S_SUM_SPAN:begin
                    sum_op<=1;sum_slot<=sum_dst[2:0];sum_other<=0;
                    sum_valid<=1;sum_after<=S_APPLY;state<=S_SUM_ACCEPT;
                end
                S_SUM_ACCEPT:if(sum_ready)begin sum_valid<=0;state<=S_SUM_FINISH;end
                S_SUM_FINISH:if(sum_ready)state<=sum_after;

                // ---- 写回 ----
                S_APPLY: begin
                    alloc_oh <= {NB{1'b0}};
                    state    <= S_IDLE;
                end

                // ---- 退休准备: 冲掉挂起行 + 装 area = w*h ----
                S_PREP: begin
                    ret_w    <= b_x1[ret_slot] - b_x0[ret_slot] + 12'd1;
                    ret_h    <= b_y1[ret_slot][11:0] - b_y0[ret_slot][11:0] + 12'd1;
                    ret_lsp  <= sp_last;              // 最后一行(挂起行)跨度
                    ret_ytop <= b_y0[ret_slot];       // bbox 上下边 + 最宽行位置
                    ret_ybot <= b_y1[ret_slot];
                    ret_my0  <= sp_my0;               // (挂起行也算进最宽行)
                    ret_my1  <= sp_my1;
                    ret_fill <= b_sum[ret_slot]
                              + (b_rs[ret_slot]
                                 ? {8'd0, (b_rmx[ret_slot] - b_rmn[ret_slot] + 12'd1)}
                                 : 20'd0);
                    m_a     <= {12'd0, (b_x1[ret_slot] - b_x0[ret_slot] + 12'd1)};
                    m_b     <= b_y1[ret_slot][10:0] - b_y0[ret_slot][10:0] + 11'd1;
                    ret_area <= (b_x1[ret_slot]-b_x0[ret_slot]+12'd1)*
                                (b_y1[ret_slot]-b_y0[ret_slot]+13'd1);
                    state   <= S_GEOM_START;
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

                S_GEOM_START: if(geom_ready) state<=S_GEOM_WAIT;
                S_GEOM_WAIT: if(geom_done) state<=S_CLS;

                // ---- 写 top 列表 ----
                S_PUSH: begin
                    if (ins_en) begin
                        if (!ring_dup && f_cnt_cur != 10'd999)
                            f_cnt_cur <= f_cnt_cur + 10'd1;
                    end
                    state <= S_CLR;
                end

                // ---- 释放槽位 ----
                S_CLR: begin
                    if (fend_mode) begin
                        state <= S_FEND;
                    end else begin
                        alloc_oh <= ({{(NB-1){1'b0}}, 1'b1} << ret_slot);
                        state    <= S_SUM_INIT;      // 清摘要后复用它开新 blob
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
                    o_cnt     <= frame_fault ? 10'd0 : f_cnt_cur;
                    o_last_fault <= frame_fault;
                    o_last_reason <= frame_reason;
                    o_frame_valid <= 1'b1;
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
                for (i = 0; i < NBX; i = i + 1) l_val[i] <= 1'b0;
            end else if (state == S_PUSH && ins_en) begin
                // Keep the pending list in one sequential block, including
                // disable/commit, so a partial frame cannot outlive cfg_en.
                l_val[ins_idx] <= 1'b1;
                l_x0 [ins_idx] <= b_x0[ret_slot];
                l_x1 [ins_idx] <= b_x1[ret_slot];
                l_y0 [ins_idx] <= b_y0[ret_slot];
                l_y1 [ins_idx] <= b_y1[ret_slot];
                l_cls[ins_idx] <= cls_now;
                l_sc [ins_idx] <= ret_fill;
            end else if (state == S_COMMIT) begin
                for (i = 0; i < NBX; i = i + 1) begin
                    l_val[i] <= 1'b0;              // 列表每帧重建
                    if (any_l && !frame_fault) begin
                        o_bx0 [i*12 +: 12] <= l_x0[i];
                        o_bx1 [i*12 +: 12] <= l_x1[i];
                        o_by0 [i*13 +: 13] <= l_y0[i];
                        o_by1 [i*13 +: 13] <= l_y1[i];
                        o_bcls[i*3  +: 3]  <= l_cls[i];
                        o_bval[i]          <= l_val[i] & (i[2:0] < nbox);
                    end
                end
                // A nonempty commit itself is not an extra hold frame.
                if (frame_fault) begin o_bval <= {NBX{1'b0}}; hold_cnt <= 5'd0; end
                else if (any_l)     hold_cnt <= (HOLD5==0)?5'd0:HOLD5-5'd1;
                else if (hold_cnt != 5'd0) hold_cnt <= hold_cnt - 5'd1;
                else                o_bval <= {NBX{1'b0}};
            end
        end
    end

endmodule

// Bounded actual recent runs, NOT a historical bounding-box span. One RAM
// read per cycle; scan all slots for a query. Overwrite of a still-recent
// interval makes the destination uncertain rather than guessing a class.
module shp_recent #(
 // Up to four separated contour runs per row across GAPY+1 live rows.
 // 32 entries avoid overwriting a still-recent inner/outer ring interval,
 // including raster aliasing at the narrow top/bottom arcs.
 parameter integer W=1280,H=720,NB=8,GAPX=6,GAPY=4,NR=32
)(
 input wire clk,rst_n,
 input wire cmd_valid,output wire cmd_ready,input wire [1:0] cmd_op,
 input wire [2:0] cmd_slot,cmd_other,input wire [11:0] cmd_x0,cmd_x1,
 input wire [12:0] cmd_y,
 input wire query_start,output wire query_ready,input wire [NB-1:0] query_mask,
 input wire [11:0] query_x0,query_x1,input wire [12:0] query_y,
 output reg query_done,output reg [NB-1:0] o_matches,
 output reg [NB-1:0] bad
);
 localparam IDLE=0,Q_READ=1,Q_CHECK=2,M_READ=3,M_CHECK=4,
            A_READ=5,A_CHECK=6;
 localparam integer DEPTH=NB*NR,AW=$clog2(DEPTH),PW=$clog2(NR);
 reg [2:0] state;
 reg [36:0] memory[0:DEPTH-1]; // {row[12:0],left[11:0],right[11:0]}
 reg [36:0] read_data;
 reg [DEPTH-1:0] valid;
 reg [PW-1:0] next_index[0:NB-1];
 reg ordered[0:NB-1]; // false after a merge whose append order is not guaranteed
 reg [AW-1:0] scan_index;
 wire [2:0] scan_slot=scan_index/NR;
 wire [PW-1:0] scan_offset=scan_index%NR;
 reg [PW-1:0] merge_index;
 reg [2:0] dest,source;
 reg [NB-1:0] qmask;
 reg [AW-1:0] qfirst,qnext;
 reg qfirst_found,qnext_found;
 reg [12:0] merge_y,append_y,qy;
 reg [11:0] append_x0,append_x1,qx0,qx1;
 reg merging;
 wire [AW-1:0] append_addr=dest*NR+next_index[dest];
 wire [AW-1:0] merge_addr=source*NR+merge_index;
 wire [AW-1:0] read_addr=(state==Q_READ)?scan_index:
                         (state==M_READ)?merge_addr:append_addr;
 wire q_hit=valid[scan_index]&&qy>=read_data[36:24]&&
        (qy-read_data[36:24])<=GAPY&&
        {1'b0,qx0}<={1'b0,read_data[11:0]}+GAPX&&
        {1'b0,qx1}+GAPX>={1'b0,read_data[23:12]};
 assign cmd_ready=(state==IDLE);
 assign query_ready=(state==IDLE)&&!cmd_valid;
 integer qj;
 always @* begin
  qfirst=0;qnext=0;qfirst_found=0;qnext_found=0;
  for(qj=NB-1;qj>=0;qj=qj-1)
   if(query_mask[qj])begin
    qfirst=qj*NR+((next_index[qj]==0)?NR-1:next_index[qj]-1'b1);
    qfirst_found=1;
   end
  for(qj=NB-1;qj>=0;qj=qj-1)
   if(qj>scan_slot&&qmask[qj])begin
    qnext=qj*NR+((next_index[qj]==0)?NR-1:next_index[qj]-1'b1);
    qnext_found=1;
   end
 end
 integer si;
 always @(posedge clk)begin
  read_data<=memory[read_addr];
  if(state==A_CHECK&&rst_n)memory[append_addr]<={append_y,append_x0,append_x1};
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;valid<=0;bad<=0;query_done<=0;o_matches<=0;
   scan_index<=0;merge_index<=0;dest<=0;source<=0;merge_y<=0;qmask<=0;
   append_y<=0;append_x0<=0;append_x1<=0;qy<=0;qx0<=0;qx1<=0;merging<=0;
   for(si=0;si<NB;si=si+1)begin next_index[si]<=0;ordered[si]<=1;end
  end else begin
   query_done<=0;
   case(state)
    IDLE:begin
     if(cmd_valid)begin
      if(cmd_slot<NB)case(cmd_op)
       0:begin
        valid[cmd_slot*NR +: NR]<=0;next_index[cmd_slot]<=0;
        bad[cmd_slot]<=0;ordered[cmd_slot]<=1;
       end
       1:begin
        dest<=cmd_slot;append_y<=cmd_y;append_x0<=cmd_x0;append_x1<=cmd_x1;
        merging<=0;
        if(cmd_y>=H||cmd_x0>cmd_x1||cmd_x1>=W)bad[cmd_slot]<=1;
        else state<=A_READ;
       end
       2:begin
        if(cmd_other>=NB||cmd_other==cmd_slot)bad[cmd_slot]<=1;
        else begin
         dest<=cmd_slot;source<=cmd_other;merge_y<=cmd_y;merge_index<=0;
         merging<=1;ordered[cmd_slot]<=0;
         bad[cmd_slot]<=bad[cmd_slot]|bad[cmd_other];state<=M_READ;
        end
       end
       default:bad[cmd_slot]<=1;
      endcase
     end else if(query_start)begin
      qx0<=query_x0;qx1<=query_x1;qy<=query_y;
      qmask<=query_mask;scan_index<=qfirst;o_matches<=0;
      if(qfirst_found)state<=Q_READ;
      else query_done<=1;
     end
    end
    Q_READ:state<=Q_CHECK;
    Q_CHECK:begin
     if(q_hit)
      o_matches[scan_index/NR]<=1;
     // The query needs one boolean per slot: once a run matches, scanning
     // older runs in this slot cannot change the answer.  This bounds the
     // cost of several contours at the same raster height.
     if(q_hit || (ordered[scan_slot]&&
         (!valid[scan_index]||
          (qy>=read_data[36:24]&&qy-read_data[36:24]>GAPY)))||
        scan_offset==next_index[scan_slot])begin
      if(qnext_found)begin scan_index<=qnext;state<=Q_READ;end
      else begin state<=IDLE;query_done<=1;end
     end else begin
      scan_index<=(scan_offset==0)?scan_index+NR-1:scan_index-1'b1;
      state<=Q_READ;
     end
    end
    M_READ:state<=M_CHECK;
    M_CHECK:begin
     if(valid[merge_addr]&&merge_y>=read_data[36:24]&&
        (merge_y-read_data[36:24])<=GAPY)begin
      append_y<=read_data[36:24];append_x0<=read_data[23:12];
      append_x1<=read_data[11:0];state<=A_READ;
     end else if(merge_index==NR-1)state<=IDLE;
     else begin merge_index<=merge_index+1'b1;state<=M_READ;end
    end
    A_READ:state<=A_CHECK;
    A_CHECK:begin
     if(valid[append_addr]&&append_y>=read_data[36:24]&&
        (append_y-read_data[36:24])<=GAPY)bad[dest]<=1;
     valid[append_addr]<=1;
     next_index[dest]<=(next_index[dest]==NR-1)?0:next_index[dest]+1'b1;
     if(merging&&merge_index!=NR-1)begin
      merge_index<=merge_index+1'b1;state<=M_READ;
     end else state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
