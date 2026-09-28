//=============================================================================
// alg_ebridge.v -- 赛题4 边缘断线桥接(edge gap bridging / morphological closing)
//
//  背景(实测): CANNY 档输出是 1px 细线, 被摄物边缘较柔和或有光照梯度时,
//  一根本该连续的直线会被打成若干短段("木棍被截了几截"): 段与段之间是
//  1~5 px 的空洞(空洞像素的梯度 < 低阈值 LO, 所以迟滞也接不上)。这些短段
//  在帧间一亮一暗, 看上去像"电流沿着轮廓流动"。
//
//  做法(纯二值边缘图后处理, 不改前级任何一级):
//  在 7x7 窗口里, 只沿 4 条"轴线"方向做闭运算 —— 一个空洞像素只要满足
//    * 左右两侧 K 像素内都有边缘(同一行), 或
//    * 上下两侧 K 像素内都有边缘(同一列), 或
//    * 左上--右下 / 右上--左下 两条对角线两侧 K 像素内都有边缘
//  就把它补成边缘。因为只在轴线方向判断, 相距 2~3px 的两条平行线不会被糊到一起
//  (全方向膨胀会把平行线并成一条粗线, 所以不能用)。
//
//  K = cfg_k (UART 的 B 命令, 0..3): 0=关闭(逐位透传); K=1 填 1px 空洞;
//  K=2 填 1~3px 空洞; K=3 填 1~5px 空洞。默认 2。
//  只在 cfg_mode != 0 (双阈值档: SOBEL 双阈值 / CANNY) 时生效, 单阈值档旁路,
//  这样用户对照的 SOBEL 单阈值档改动前后完全一致。
//
//  窗口: 7x7, 0 边界(PAD_EDGE=0, 与 alg_despeckle 一致), 中心 win[24]。
//        用 0 边界是因为上级(alg_thresh)是 PAD_EDGE=0, 视场外本来就是 0。
//  流水线延迟: 输入 -> out_de = 4 拍 (窗口 3 + 输出寄存 1), 与 cfg_k/cfg_mode
//        无关(换档不改变延迟, 画面不跳, ROWD 也不随档位变化)。
//  资源: 6 条行缓存(DW=1, 各 W 位) + 49bit 窗口, 约 1 块 BRAM。
//=============================================================================

module alg_ebridge #(
    parameter integer W    = 1280,
    parameter integer VEXT = 16,
    parameter integer H    = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [12:0] in_y,
    input  wire [7:0]  in_data,
    input  wire [1:0]  cfg_k,        // 0..3: 桥接档位(0 = 关闭)
    input  wire [1:0]  cfg_mode,     // 0 = SOBEL 单阈值档 -> 旁路
    output wire        out_vs,
    output wire        out_hs,
    output wire        out_de_full,
    output wire        out_de,
    output wire [11:0] out_x,
    output wire [12:0] out_y,
    output reg  [7:0]  out_data
);

wire        w_vs, w_hs, w_de;
wire [11:0] w_x;
wire [12:0] w_y;
wire [48:0] win;

alg_win #(
    .DW(1), .W(W), .VEXT(VEXT), .H(H), .N(7), .PAD_EDGE(0)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data(in_data != 8'd0),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

// win[(i*7+j)]: i = 0 最上行, j = 0 最左列; 中心 = [3][3] = win[24]
wire cen = win[24];

wire l1 = win[23], l2 = win[22], l3 = win[21];      // 左 1/2/3
wire r1 = win[25], r2 = win[26], r3 = win[27];      // 右 1/2/3
wire u1 = win[17], u2 = win[10], u3 = win[3];       // 上 1/2/3
wire d1 = win[31], d2 = win[38], d3 = win[45];      // 下 1/2/3
wire p1 = win[16], p2 = win[8],  p3 = win[0];       // 左上 1/2/3
wire q1 = win[32], q2 = win[40], q3 = win[48];      // 右下 1/2/3
wire s1 = win[18], s2 = win[12], s3 = win[6];       // 右上 1/2/3
wire t1 = win[30], t2 = win[36], t3 = win[42];      // 左下 1/2/3

// 距离 1..K 内有没有边缘(K 是运行期值, 0..3)
function conn_k;
    input [1:0] k;
    input       a;      // 距离 1
    input       b;      // 距离 2
    input       cc;     // 距离 3
    begin
        conn_k = (a & (k >= 2'd1)) | (b & (k >= 2'd2)) | (cc & (k >= 2'd3));
    end
endfunction

wire en = (cfg_k != 2'd0) && (cfg_mode != 2'd0);

wire hl = conn_k(cfg_k, l1, l2, l3);
wire hr = conn_k(cfg_k, r1, r2, r3);
wire vu = conn_k(cfg_k, u1, u2, u3);
wire vd = conn_k(cfg_k, d1, d2, d3);
wire g1 = conn_k(cfg_k, p1, p2, p3);
wire g2 = conn_k(cfg_k, q1, q2, q3);
wire g3 = conn_k(cfg_k, s1, s2, s3);
wire g4 = conn_k(cfg_k, t1, t2, t3);

wire fill   = (hl & hr) | (vu & vd) | (g1 & g2) | (g3 & g4);
wire edge_b = cen | (en & fill);

always @(posedge clk) begin
    if (!rst_n) out_data <= 8'd0;
    else        out_data <= edge_b ? 8'hFF : 8'h00;
end

// 时序/坐标与 out_data(4 拍) 同拍
wire        c_vs, c_hs, c_de;
wire [11:0] c_x;
wire [12:0] c_y;
alg_stream_delay #(.DW(1), .D(1)) u_cdly (
    .clk(clk), .rst_n(rst_n),
    .in_vs(w_vs), .in_hs(w_hs), .in_de(w_de),
    .in_x(w_x), .in_y(w_y), .in_data(1'b0),
    .out_vs(c_vs), .out_hs(c_hs), .out_de(c_de),
    .out_x(c_x), .out_y(c_y), .out_data()
);

assign out_vs      = c_vs;
assign out_hs      = c_hs;
assign out_de_full = c_de;
assign out_de      = c_de & (c_y < H);
assign out_x       = c_x;
assign out_y       = c_y;

endmodule
