///////////////////////////////////////////////////////////////////////////////
// median3x3.v — 3x3 中值滤波(赛题高阶①)
// 对应 Python: median3x3()。3 级并行排序网络(21 比较器), 精确中值。
// 结构: 两级行缓存 -> 3x3 窗口 -> 行排序x3 -> 列排序x3 -> 主对角排序 -> 中值
// 对齐: 输出相对输入延迟 OUT_DELAY = 2*DEPTH+2 拍; 前 2 行/前 2 列输出无效(de=0)
///////////////////////////////////////////////////////////////////////////////
module median3x3 #(
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
    localparam OUT_DELAY = DEPTH + 1;   // 窗口中心 = 输入的上一行前一列

    // ---- 行缓存: row1 = 上一行, row2 = 上上行 ----
    wire [W-1:0] row1_in, row2_in;
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb1 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(i_pix), .dout(row1_in));
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb2 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(row1_in), .dout(row2_in));

    // ---- 当前行与上下行的列打拍(各 2 拍): 窗口中心 = row1.c-1 ----
    reg [W-1:0] cur0, cur1;      // 当前行 col-1, col-2
    reg [W-1:0] r1_0, r1_1;      // row1    col-1, col-2
    reg [W-1:0] r2_0, r2_1;      // row2    col-1, col-2
    always @(posedge clk) begin
        cur1 <= cur0; cur0 <= i_pix;
        r1_1 <= r1_0; r1_0 <= row1_in;
        r2_1 <= r2_0; r2_0 <= row2_in;
    end

    // ---- 行列计数(用于边界有效性, 避免行首环形污染) ----
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

    // ---- 3x3 窗口 ----
    //         col-2        col-1        col
    // row2 :  r2_1         r2_0         row2_in
    // row1 :  r1_1         r1_0(中心)   row1_in
    // cur  :  cur1         cur0         i_pix
    wire [W-1:0] p00 = r2_1;
    wire [W-1:0] p01 = r2_0;
    wire [W-1:0] p02 = row2_in;
    wire [W-1:0] p10 = r1_1;
    wire [W-1:0] p11 = r1_0;
    wire [W-1:0] p12 = row1_in;
    wire [W-1:0] p20 = cur1;
    wire [W-1:0] p21 = cur0;
    wire [W-1:0] p22 = i_pix;

    // ---- 排序网络: sort3 升序 = (min, mid, max) ----
    // 行排序(9 比较器)
    wire [W-1:0] r1_min01 = (p00 < p01) ? p00 : p01;
    wire [W-1:0] r1_max01 = (p00 < p01) ? p01 : p00;
    wire [W-1:0] r1_min = (r1_min01 < p02) ? r1_min01 : p02;
    wire [W-1:0] r1_max = (r1_max01 > p02) ? r1_max01 : p02;
    wire [W-1:0] r1_mid = p00 + p01 + p02 - r1_min - r1_max;

    wire [W-1:0] r2_min01 = (p10 < p11) ? p10 : p11;
    wire [W-1:0] r2_max01 = (p10 < p11) ? p11 : p10;
    wire [W-1:0] r2_min = (r2_min01 < p12) ? r2_min01 : p12;
    wire [W-1:0] r2_max = (r2_max01 > p12) ? r2_max01 : p12;
    wire [W-1:0] r2_mid = p10 + p11 + p12 - r2_min - r2_max;

    wire [W-1:0] r3_min01 = (p20 < p21) ? p20 : p21;
    wire [W-1:0] r3_max01 = (p20 < p21) ? p21 : p20;
    wire [W-1:0] r3_min = (r3_min01 < p22) ? r3_min01 : p22;
    wire [W-1:0] r3_max = (r3_max01 > p22) ? r3_max01 : p22;
    wire [W-1:0] r3_mid = p20 + p21 + p22 - r3_min - r3_max;

    // 列排序(9 比较器): 列1=(r1min,r2min,r3min), 列2=(r1mid,r2mid,r3mid), 列3=(r1max,r2max,r3max)
    wire [W-1:0] c1_min01 = (r1_min < r2_min) ? r1_min : r2_min;
    wire [W-1:0] c1_max01 = (r1_min < r2_min) ? r2_min : r1_min;
    wire [W-1:0] c1_min = (c1_min01 < r3_min) ? c1_min01 : r3_min;
    wire [W-1:0] c1_max = (c1_max01 > r3_min) ? c1_max01 : r3_min;
    wire [W-1:0] c1_mid = r1_min + r2_min + r3_min - c1_min - c1_max;

    wire [W-1:0] c2_min01 = (r1_mid < r2_mid) ? r1_mid : r2_mid;
    wire [W-1:0] c2_max01 = (r1_mid < r2_mid) ? r2_mid : r1_mid;
    wire [W-1:0] c2_min = (c2_min01 < r3_mid) ? c2_min01 : r3_mid;
    wire [W-1:0] c2_max = (c2_max01 > r3_mid) ? c2_max01 : r3_mid;
    wire [W-1:0] c2_mid = r1_mid + r2_mid + r3_mid - c2_min - c2_max;

    wire [W-1:0] c3_min01 = (r1_max < r2_max) ? r1_max : r2_max;
    wire [W-1:0] c3_max01 = (r1_max < r2_max) ? r2_max : r1_max;
    wire [W-1:0] c3_min = (c3_min01 < r3_max) ? c3_min01 : r3_max;
    wire [W-1:0] c3_max = (c3_max01 > r3_max) ? c3_max01 : r3_max;
    wire [W-1:0] c3_mid = r1_max + r2_max + r3_max - c3_min - c3_max;

    // 主对角线: (c1_max, c2_mid, c3_min) 升序取中值 = 全局中值(3 比较器)
    wire [W-1:0] d_min01 = (c1_max < c2_mid) ? c1_max : c2_mid;
    wire [W-1:0] d_max01 = (c1_max < c2_mid) ? c2_mid : c1_max;
    wire [W-1:0] d_min = (d_min01 < c3_min) ? d_min01 : c3_min;
    wire [W-1:0] d_max = (d_max01 > c3_min) ? d_max01 : c3_min;
    wire [W-1:0] d_mid = c1_max + c2_mid + c3_min - d_min - d_max;
    wire [W-1:0] median = d_mid;

    // ---- 输出打拍对齐: 中心像素时刻 = 输入后 OUT_DELAY 拍 ----
    wire win_d, hs_d, vs_d;
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dv
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(win_valid), .dout(win_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dh
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_hs),      .dout(hs_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_ds
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_vs),      .dout(vs_d));

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
            o_pix <= win_d ? median : {W{1'b0}};
        end
    end
endmodule
