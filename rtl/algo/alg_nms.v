//=============================================================================
// alg_nms.v -- 赛题4 高阶④ Canny 非极大值抑制(NMS)
//
//  输入: {dir[1:0], mag[10:0]}  (13bit, 来自 alg_sobel3, 全量程 mag)
//  3x3 邻域(EDGE 边界), 按梯度方向取两侧邻居做非对称比较:
//      0  (左右) -> (m > L)  & (m >= R)
//      90 (上下) -> (m > U)  & (m >= D)
//      45 (主对角) -> (m > UL) & (m >= DR)
//      135(副对角) -> (m > UR) & (m >= DL)
//  保留则输出 clip(m,0,255), 否则 0   (与 Python nms_rtl() 一致)
//
//  流水线延迟: 输入 -> out_de = 4 拍 (窗口 3 + 寄存 1)
//=============================================================================

module alg_nms #(
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
    input  wire [10:0] in_mag,
    input  wire [1:0]  in_dir,
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
wire [116:0] win;

alg_win #(
    .DW(13), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(1)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data({in_dir, in_mag}),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

// win[k*13 +: 13] = {dir, mag}
wire [10:0] m0 = win[10:0];
wire [10:0] m1 = win[23:13];
wire [10:0] m2 = win[36:26];
wire [10:0] m3 = win[49:39];
wire [10:0] m4 = win[62:52];
wire [10:0] m5 = win[75:65];
wire [10:0] m6 = win[88:78];
wire [10:0] m7 = win[101:91];
wire [10:0] m8 = win[114:104];
wire [1:0]  dc = win[64:63];       // 中心方向

wire keep0 = (m4 > m3) & (m4 >= m5);     // 0   : L / R
wire keep1 = (m4 > m1) & (m4 >= m7);     // 90  : U / D
wire keep2 = (m4 > m0) & (m4 >= m8);     // 45  : UL / DR
wire keep3 = (m4 > m2) & (m4 >= m6);     // 135 : UR / DL

wire keep = (dc == 2'd0) ? keep0 :
            (dc == 2'd1) ? keep1 :
            (dc == 2'd2) ? keep2 : keep3;

wire [10:0] mv = (m4 > 11'd255) ? 11'd255 : m4;

always @(posedge clk) begin
    if (!rst_n) out_data <= 8'd0;
    else        out_data <= keep ? mv[7:0] : 8'd0;
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
