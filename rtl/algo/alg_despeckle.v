//=============================================================================
// alg_despeckle.v -- 赛题4 高阶④ 孤立点消除(remove_isolated)
//
//  Python 语义: 3x3 内白色邻居数(不含自身) >= 1 才保留。
//  e0 = 1 且 cnt(含自身) >= 2  <=>  白邻居 >= 1
//  边界补 0 (PAD_EDGE=0); en=0 时原样输出(0/255), 延迟仍 4 拍。
//
//  流水线延迟: 输入 -> out_de = 4 拍 (窗口 3 + 寄存 1)
//=============================================================================

module alg_despeckle #(
    parameter integer W    = 1280,
    parameter integer VEXT = 16,
    parameter integer H    = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [12:0] in_y,
    input  wire [7:0]  in_data,
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
wire [8:0]  win;

alg_win #(
    .DW(1), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(0)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data(in_data != 8'd0),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

wire [3:0] cnt = win[0] + win[1] + win[2] + win[3] + win[4]
               + win[5] + win[6] + win[7] + win[8];
wire e0 = win[4];
wire keep = en ? (e0 & (cnt >= 4'd2)) : e0;

always @(posedge clk) begin
    if (!rst_n) out_data <= 8'd0;
    else        out_data <= keep ? 8'hFF : 8'h00;
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
