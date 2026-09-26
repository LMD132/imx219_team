//=============================================================================
// alg_thresh.v -- 赛题4 基础③/高阶④ 阈值与滞后
//
//  三种模式(与 FPGA-Python/rtl_model.py 的 threshold_rtl / hysteresis_rtl 一致):
//    mode=0 (SOBEL 单阈值): edge = (mag >= cfg_t)              -> 0/255
//    mode=1 (SOBEL 双阈值): strong=mag>=hi; weak=mag>=lo;
//                           edge = weak & dilate3x3(strong)
//    mode=2 (CANNY)       : 同 mode=1, 但输入来自 NMS 输出(0..255)
//  防呆: cfg_lo > cfg_hi 时自动交换。
//
//  实现要点(逐位等价 Python, 见 docs/ALGO_RTL.md):
//    * 三个判定位 {strong, weak, single} 在输入端算出后一起送 alg_win
//      (N=3, PAD_EDGE=0): 窗口中心 tap(4) 给出中心像素的 weak/single,
//      9 个 tap 的 strong 相或 = dilate3x3(strong)(视场外补 0, 等价 cv2.dilate)。
//    * weak/single 必须与窗口中心严格同拍。若另开一条 stream_delay 支路,
//      因为 alg_win 的输出标签 = 输入标签 - H2(行、列都减一), 两条支路的坐标
//      永远差一行(实测 weak 取到了下一行), 会产生 68/153 个错误像素。
//      改用同一个窗口的中心 tap 后与 Python 完全一致。
//  流水线延迟: 输入 -> out_de = 4 拍 (窗口 3 + 输出寄存 1)
//=============================================================================

module alg_thresh #(
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
    input  wire [10:0] in_data,
    input  wire [1:0]  cfg_mode,
    input  wire [10:0] cfg_t,
    input  wire [10:0] cfg_lo,
    input  wire [10:0] cfg_hi,
    output wire        out_vs,
    output wire        out_hs,
    output wire        out_de_full,
    output wire        out_de,
    output wire [11:0] out_x,
    output wire [12:0] out_y,
    output reg  [7:0]  out_data
);

wire swap = (cfg_lo > cfg_hi);
wire [10:0] lo = swap ? cfg_hi : cfg_lo;
wire [10:0] hi = swap ? cfg_lo : cfg_hi;

wire strong_b = (in_data >= hi);
wire weak_b   = (in_data >= lo);
wire single_b = (in_data >= cfg_t);

wire        w_vs, w_hs, w_de;
wire [11:0] w_x;
wire [12:0] w_y;
wire [26:0] win;

alg_win #(
    .DW(3), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(0)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data({strong_b, weak_b, single_b}),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

wire [2:0] cen = win[14:12];
wire weak_d    = cen[1];
wire single_d  = cen[0];

wire str_area = win[2]  | win[5]  | win[8]  | win[11] | win[14]
              | win[17] | win[20] | win[23] | win[26];

wire edge_b = (cfg_mode == 2'd0) ? single_d : (weak_d & str_area);

always @(posedge clk) begin
    if (!rst_n) out_data <= 8'd0;
    else        out_data <= edge_b ? 8'hFF : 8'h00;
end

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