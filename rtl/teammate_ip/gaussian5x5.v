///////////////////////////////////////////////////////////////////////////////
// gaussian5x5.v — 5x5 高斯滤波(Canny 前置平滑, 赛题高阶④)
// 对应 Python: gaussian5x5()。整数核(与 Python 逐位一致):
//   [32,38,40,38,32]
//   [38,45,47,45,38]
//   [40,47,50,47,40]
//   [38,45,47,45,38]
//   [32,38,40,38,32]   总和=1010
// 输出 = (sum >> 10) + ((sum >> 9) & 1)  即四舍五入到最近整数。
// 对齐: 输出延迟 OUT_DELAY = 4*DEPTH+4; 前 4 行/前 4 列无效(de=0)
///////////////////////////////////////////////////////////////////////////////
module gaussian5x5 #(
    parameter W     = 8,
    parameter DEPTH = 1280
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             i_de,
    input  wire             i_hs,
    input  wire             i_vs,
    input  wire [W-1:0]     i_pix,
    output reg              o_de,
    output reg              o_hs,
    output reg              o_vs,
    output reg  [W-1:0]     o_pix
);
    localparam OUT_DELAY = 2*DEPTH + 2;  // 5x5 窗口中心 = 输入的上2行前2列
    localparam PW = W + 10;   // 累加位宽: 25*255*50 = 318750 < 2^19, 给 18bit 有余量

    // ---- 行缓存: 4 级串联, row1..row4 = 延迟 1..4 行 ----
    wire [W-1:0] row1_in, row2_in, row3_in, row4_in;
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb1 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(i_pix),   .dout(row1_in));
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb2 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(row1_in), .dout(row2_in));
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb3 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(row2_in), .dout(row3_in));
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb4 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(row3_in), .dout(row4_in));

    // ---- 每行列打拍 4 拍: 窗口中心 = row2.c-2 ----
    reg [W-1:0] c0, c1, c2, c3;   // 当前行 col-1..col-4
    reg [W-1:0] r1_0, r1_1, r1_2, r1_3;
    reg [W-1:0] r2_0, r2_1, r2_2, r2_3;
    reg [W-1:0] r3_0, r3_1, r3_2, r3_3;
    reg [W-1:0] r4_0, r4_1, r4_2, r4_3;
    always @(posedge clk) begin
        c3 <= c2; c2 <= c1; c1 <= c0; c0 <= i_pix;
        r1_3 <= r1_2; r1_2 <= r1_1; r1_1 <= r1_0; r1_0 <= row1_in;
        r2_3 <= r2_2; r2_2 <= r2_1; r2_1 <= r2_0; r2_0 <= row2_in;
        r3_3 <= r3_2; r3_2 <= r3_1; r3_1 <= r3_0; r3_0 <= row3_in;
        r4_3 <= r4_2; r4_2 <= r4_1; r4_1 <= r4_0; r4_0 <= row4_in;
    end

    // ---- 行列计数(边界有效) ----
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
    wire win_valid = (hcnt >= 16'd4) && (vcnt >= 16'd4);

    // ---- 5x5 窗口乘加(与 Python 核逐位一致) ----
    // row4(延迟4行): r4_3 r4_2 r4_1 r4_0 row4_in  -> 系数 {32,38,40,38,32}
    // row3(延迟3行): r3_3 r3_2 r3_1 r3_0 row3_in  -> 系数 {38,45,47,45,38}
    // row2(延迟2行): r2_3 r2_2 r2_1 r2_0 row2_in  -> 系数 {40,47,50,47,40} (中心行)
    // row1(延迟1行): r1_3 r1_2 r1_1 r1_0 row1_in  -> 系数 {38,45,47,45,38}
    // cur (当前行):  c3   c2   c1   c0   i_pix    -> 系数 {32,38,40,38,32}
    wire [PW-1:0] r4s = 32*(r4_3) + 38*(r4_2) + 40*(r4_1) + 38*(r4_0) + 32*(row4_in);
    wire [PW-1:0] r3s = 38*(r3_3) + 45*(r3_2) + 47*(r3_1) + 45*(r3_0) + 38*(row3_in);
    wire [PW-1:0] r2s = 40*(r2_3) + 47*(r2_2) + 50*(r2_1) + 47*(r2_0) + 40*(row2_in);
    wire [PW-1:0] r1s = 38*(r1_3) + 45*(r1_2) + 47*(r1_1) + 45*(r1_0) + 38*(row1_in);
    wire [PW-1:0] c0s = 32*(c3)    + 38*(c2)    + 40*(c1)    + 38*(c0)    + 32*(i_pix);
    wire [PW-1:0] acc = r4s + r3s + r2s + r1s + c0s;

    wire [W-1:0] gauss_out = acc[PW-1:10] + ((acc >> 9) & 1'b1);

    // ---- 输出对齐 ----
    wire win_d, hs_d, vs_d;
    delay_n #(.N(OUT_DELAY), .W(1)) u_dv (.clk(clk), .din(win_valid), .dout(win_d));
    delay_n #(.N(OUT_DELAY), .W(1)) u_dh (.clk(clk), .din(i_hs),      .dout(hs_d));
    delay_n #(.N(OUT_DELAY), .W(1)) u_ds (.clk(clk), .din(i_vs),      .dout(vs_d));

    always @(posedge clk) begin
        if (!rst_n) begin
            o_de  <= 1'b0;
            o_hs  <= 1'b0;
            o_vs  <= 1'b0;
            o_pix <= {W{1'b0}};
        end else begin
            o_de  <= win_d;
            o_hs  <= hs_d;
            o_vs  <= vs_d;
            o_pix <= win_d ? gauss_out : {W{1'b0}};
        end
    end
endmodule
