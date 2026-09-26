///////////////////////////////////////////////////////////////////////////////
// hysteresis.v — Canny 双阈值滞后(赛题高阶④, 第四步)
// 对应 Python: threshold_hysteresis()。
//   strong_p = mag >= t_hi ; weak_p = mag >= t_lo
//   strong_d = 3x3 dilate(strong_p) ; edge = weak_p & strong_d
// 防呆: t_lo > t_hi 时自动交换(与 Python 一致)。
// 对齐: 输出延迟 OUT_DELAY = 2*DEPTH+2; 前 2 行/前 2 列无效(de=0)
///////////////////////////////////////////////////////////////////////////////
module hysteresis #(
    parameter DEPTH = 1280
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             i_de,
    input  wire             i_hs,
    input  wire             i_vs,
    input  wire [7:0]       i_mag,
    input  wire [7:0]       t_lo,
    input  wire [7:0]       t_hi,
    output reg              o_de,
    output reg              o_hs,
    output reg              o_vs,
    output reg  [7:0]       o_edge
);
    localparam OUT_DELAY = DEPTH + 1;    // 窗口中心 = 输入的上一行前一列

    // ---- 防呆: t_lo > t_hi 交换 ----
    wire [7:0] lo = (t_lo > t_hi) ? t_hi : t_lo;
    wire [7:0] hi = (t_lo > t_hi) ? t_lo : t_hi;

    wire strong_p = (i_mag >= hi);
    wire weak_p   = (i_mag >= lo);

    // ---- 3 行 strong_p 缓冲做 3x3 dilate ----
    wire s1, s2;
    tip_line_buffer #(.W(1), .DEPTH(DEPTH)) u_lb1 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(strong_p), .dout(s1));
    tip_line_buffer #(.W(1), .DEPTH(DEPTH)) u_lb2 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(s1), .dout(s2));

    reg s0_0, s0_1;   // 当前行 col-1, col-2
    reg s1_0, s1_1;
    reg s2_0, s2_1;
    always @(posedge clk) begin
        s0_1 <= s0_0; s0_0 <= strong_p;
        s1_1 <= s1_0; s1_0 <= s1;
        s2_1 <= s2_0; s2_0 <= s2;
    end

    // 窗口 OR(中心 = s1_0 位置)
    wire strong_d =
        s2_1 | s2_0 | s2 | s1_1 | s1_0 | s1 | s0_1 | s0_0 | strong_p;

    // ---- 行列计数 ----
    reg [15:0] hcnt, vcnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            hcnt <= 16'd0; vcnt <= 16'd0;
        end else if (i_vs) begin
            hcnt <= 16'd0; vcnt <= 16'd0;
        end else if (i_hs) begin
            hcnt <= 16'd0;
            vcnt <= vcnt + 1'b1;
        end else if (i_de) begin
            hcnt <= hcnt + 1'b1;
        end
    end
    wire win_valid = (hcnt >= 16'd2) && (vcnt >= 16'd2);

    wire edge_cur = weak_c & strong_d;   // 中心像素 weak_p 与 dilate 后 strong_p

    // ---- 输出对齐(weak_p/edge_cur 相对输入打拍) ----
    wire win_d, hs_d, vs_d;
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dv
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(win_valid), .dout(win_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dh
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_hs),      .dout(hs_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_ds
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_vs),      .dout(vs_d));
    wire weak_c, edge_d;
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_wk
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(weak_p),    .dout(weak_c));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_de
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(edge_cur),  .dout(edge_d));

    always @(posedge clk) begin
        if (!rst_n) begin
            o_de   <= 1'b0;
            o_hs   <= 1'b0;
            o_vs   <= 1'b0;
            o_edge <= 8'd0;
        end else begin
            o_de   <= win_d;
            o_hs   <= hs_d;
            o_vs   <= vs_d;
            o_edge <= win_d ? (edge_d ? 8'hFF : 8'd0) : 8'd0;
        end
    end
endmodule
