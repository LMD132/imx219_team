///////////////////////////////////////////////////////////////////////////////
// sobel3x3.v — 3x3 Sobel 梯度幅值(赛题基础③: 基础要求 Sobel |Gx|+|Gy|)
// 对应 Python: sobel3x3() + gradient(manhattan: |Gx|+|Gy|)。
// 核:
//   Gx = [-1 0 1; -2 0 2; -1 0 1]
//   Gy = [-1 -2 -1; 0 0 0; 1 2 1]
// 幅值 mag = |Gx| + |Gy|, 最大 4*255*2 = 2040 -> 11bit(输出给 12bit 保险)。
// 注意: 不做 0..255 截位(与 Python 全量程一致, 供 Canny NMS 使用)。
// 对齐: 输出延迟 OUT_DELAY = 2*DEPTH+2; 前 2 行/前 2 列无效(de=0)
///////////////////////////////////////////////////////////////////////////////
module sobel3x3 #(
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
    output reg  [11:0]      o_mag,
    output reg  [1:0]       o_dir   // 梯度方向量化: 0=0°(左右),1=45°(主对角),2=90°(上下),3=135°(副对角)
);
    localparam OUT_DELAY = DEPTH + 1;   // 窗口中心 = 输入的上一行前一列

    // ---- 行缓存 ----
    wire [W-1:0] row1_in, row2_in;
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb1 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(i_pix), .dout(row1_in));
    tip_line_buffer #(.W(W), .DEPTH(DEPTH)) u_lb2 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(row1_in), .dout(row2_in));

    // ---- 列打拍 ----
    reg [W-1:0] cur0, cur1;
    reg [W-1:0] r1_0, r1_1;
    reg [W-1:0] r2_0, r2_1;
    always @(posedge clk) begin
        cur1 <= cur0; cur0 <= i_pix;
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

    // ---- 3x3 窗口 ----
    //         col-2    col-1    col
    // row2 :  r2_1     r2_0     row2_in
    // row1 :  r1_1     r1_0     row1_in   (中心)
    // cur  :  cur1     cur0     i_pix
    wire [W-1:0] p00 = r2_1;
    wire [W-1:0] p01 = r2_0;
    wire [W-1:0] p02 = row2_in;
    wire [W-1:0] p10 = r1_1;
    wire [W-1:0] p11 = r1_0;
    wire [W-1:0] p12 = row1_in;
    wire [W-1:0] p20 = cur1;
    wire [W-1:0] p21 = cur0;
    wire [W-1:0] p22 = i_pix;

    // ---- 梯度(避免 signed 陷阱: 正负两侧分别求和再相减取绝对值) ----
    wire [W+2:0] gx_hi = p02 + {1'b0, p12, 1'b0} + p22;   // 2*p12 = p12<<1
    wire [W+2:0] gx_lo = p00 + {1'b0, p10, 1'b0} + p20;
    wire [W+2:0] gy_hi = p20 + {1'b0, p21, 1'b0} + p22;
    wire [W+2:0] gy_lo = p00 + {1'b0, p01, 1'b0} + p02;

    wire [W+2:0] gx_abs = (gx_hi > gx_lo) ? (gx_hi - gx_lo) : (gx_lo - gx_hi);
    wire [W+2:0] gy_abs = (gy_hi > gy_lo) ? (gy_hi - gy_lo) : (gy_lo - gy_hi);

    wire [11:0] mag = gx_abs + gy_abs;   // 最大 2040, 11bit 足够

    // ---- 梯度方向量化(近似 Python atan2 %180 四方向, 边界差约 0.1°) ----
    //   Python: deg=atan2(gy,gx)%180; q0: deg<22.5|>=157.5; q45: 22.5..67.5;
    //           q90: 67.5..112.5; q135: 112.5..157.5
    //   硬件近似: tan22.5=0.4142≈5/12, tan67.5=2.4142≈12/5
    wire [15:0] gy_abs12 = gy_abs * 12'd12;   // 12*|gy|
    wire [15:0] gx_abs5  = gx_abs * 5'd5;    // 5*|gx|
    wire [15:0] gy_abs5  = gy_abs * 5'd5;
    wire [15:0] gx_abs12 = gx_abs * 12'd12;
    wire is_q0  = (gy_abs12 <= gx_abs5);     // |gy|/|gx| <= 5/12 ≈ 0.4167 ≈ tan22.5
    wire is_q90 = (gy_abs5  >= gx_abs12);    // |gy|/|gx| >= 12/5 = 2.4 ≈ tan67.5
    wire gx_pos = (gx_hi >= gx_lo);
    wire gy_pos = (gy_hi >= gy_lo);
    reg  [1:0] dir;
    always @* begin
        if (is_q0)
            dir = 2'd0;
        else if (is_q90)
            dir = 2'd2;
        else
            dir = (gx_pos == gy_pos) ? 2'd1 : 2'd3;   // 45° 或 135°
    end

    // ---- 输出对齐 ----
    wire win_d, hs_d, vs_d;
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dv
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(win_valid), .dout(win_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dh
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_hs),      .dout(hs_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_ds
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_vs),      .dout(vs_d));
    wire [1:0] dir_d;
    line_delay_n #(.WIDTH(2), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dd
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(dir),       .dout(dir_d));

    always @(posedge clk) begin
        if (!rst_n) begin
            o_de  <= 1'b0;
            o_hs  <= 1'b0;
            o_vs  <= 1'b0;
            o_mag <= 12'd0;
            o_dir <= 2'd0;
        end else begin
            o_de  <= win_d;
            o_hs  <= hs_d;
            o_vs  <= vs_d;
            o_mag <= win_d ? mag : 12'd0;
            o_dir <= win_d ? dir_d : 2'd0;
        end
    end
endmodule
