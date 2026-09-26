///////////////////////////////////////////////////////////////////////////////
// remove_isolated.v — 孤立白点消除(闪烁白点的克星, 对应 Python remove_isolated)
// 3x3 窗口内白色邻居数(不含自身) < MIN_NEIGH 的白像素被清除。
// 默认 MIN_NEIGH=1: 只删"周围一个白邻居都没有"的孤立单点, 1px 边线端点不删。
// 对齐: 输出延迟 OUT_DELAY = 2*DEPTH+2; 前 2 行/前 2 列无效(de=0)
///////////////////////////////////////////////////////////////////////////////
module remove_isolated #(
    parameter DEPTH      = 1280,
    parameter MIN_NEIGH  = 1
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             i_de,
    input  wire             i_hs,
    input  wire             i_vs,
    input  wire [7:0]       i_edge,    // 0 或 255
    output reg              o_de,
    output reg              o_hs,
    output reg              o_vs,
    output reg  [7:0]       o_edge
);
    localparam OUT_DELAY = DEPTH + 1;    // 窗口中心 = 输入的上一行前一列

    // ---- 3 行窗口 ----
    wire [7:0] row1_in, row2_in;
    tip_line_buffer #(.W(8), .DEPTH(DEPTH)) u_lb1 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(i_edge), .dout(row1_in));
    tip_line_buffer #(.W(8), .DEPTH(DEPTH)) u_lb2 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(row1_in), .dout(row2_in));

    reg [7:0] cur0, cur1;
    reg [7:0] r1_0, r1_1;
    reg [7:0] r2_0, r2_1;
    always @(posedge clk) begin
        cur1 <= cur0; cur0 <= i_edge;
        r1_1 <= r1_0; r1_0 <= row1_in;
        r2_1 <= r2_0; r2_0 <= row2_in;
    end

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

    // 窗口 9 值(中心 = r1_0), 用 1bit 判定
    wire w00 = (r2_1  != 8'd0);   // 左上
    wire w01 = (r2_0  != 8'd0);   // 上
    wire w02 = (row2_in != 8'd0); // 右上
    wire w10 = (r1_1  != 8'd0);   // 左
    wire w11 = (r1_0  != 8'd0);   // 中心
    wire w12 = (row1_in != 8'd0); // 右
    wire w20 = (cur1  != 8'd0);   // 左下
    wire w21 = (cur0  != 8'd0);   // 下
    wire w22 = (i_edge != 8'd0);  // 右下

    wire [3:0] win_sum = w00 + w01 + w02 + w10 + w12 + w20 + w21 + w22; // 不含中心
    wire keep = w11 && (win_sum >= MIN_NEIGH);

    // ---- 输出对齐 ----
    wire win_d, hs_d, vs_d;
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dv
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(win_valid), .dout(win_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dh
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_hs),      .dout(hs_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_ds
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_vs),      .dout(vs_d));
    wire keep_d;
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dk
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(keep),      .dout(keep_d));

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
            o_edge <= win_d ? (keep_d ? 8'hFF : 8'd0) : 8'd0;
        end
    end
endmodule
